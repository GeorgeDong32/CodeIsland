import Combine
import Foundation
import MultipeerConnectivity
import os
import CodeIslandCore

@MainActor
final class AppleCompanionPublisher: NSObject, ObservableObject {
    static let shared = AppleCompanionPublisher()

    private static let serviceType = "codeisland"
    private static let log = Logger(subsystem: "com.codeisland", category: "apple-companion")

    @Published private(set) var enabled = false
    @Published private(set) var advertising = false
    @Published private(set) var connectedPeerNames: [String] = []
    @Published private(set) var lastError: String?

    var bluetoothPoweredOn: Bool { bluetooth.poweredOn }
    var bluetoothAdvertising: Bool { bluetooth.advertising }
    var bluetoothSubscribed: Bool { bluetooth.hasSubscribers }

    var onControlCommand: ((BuddyControlCommand) -> Void)?
    var onFocusRequest: ((MascotID) -> Void)?
    var onQuestionAnswer: ((String) -> Void)?

    /// Phase 6 consumer seam. When installed, the companion can only read the
    /// redacted projection and can only send typed Center inputs. The legacy
    /// callbacks remain as an additive migration bridge until AppState's
    /// interaction owner is cut over; they are never used when this seam is
    /// attached.
    private var externalSnapshotProvider: (() -> RedactedInteractionSnapshot)?
    private var interactionInputSink: ((InteractionInput) -> Void)?
    private let interactionAdapter = AppleCompanionCompatibilityAdapter()

    private weak var appState: AppState?
    private let peerID: MCPeerID
    private lazy var session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID,
        discoveryInfo: ["protocol": "1"],
        serviceType: Self.serviceType
    )
    private var heartbeatTimer: Timer?
    private var sequence: UInt64 = 0
    private let bluetooth = AppleCompanionBluetoothPeripheral()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private override init() {
        let hostName = Host.current().localizedName ?? "Mac"
        let displayName = "CodeIsland \(hostName)"
        self.peerID = MCPeerID(displayName: String(displayName.prefix(63)))
        super.init()
        self.session.delegate = self
        self.advertiser.delegate = self
    }

    func attach(_ appState: AppState) {
        self.appState = appState
    }

    /// Connect the publisher to the single InteractionCenter coordinator. The
    /// closure returns only `RedactedInteractionSnapshot`; callers cannot pass
    /// a local snapshot, SessionSnapshot, continuation or raw protocol object.
    func attachExternalProjection(
        snapshot: @escaping () -> RedactedInteractionSnapshot,
        send: @escaping (InteractionInput) -> Void
    ) {
        externalSnapshotProvider = snapshot
        interactionInputSink = send
    }

    func configure(enabled: Bool, heartbeatSeconds: Double) {
        self.enabled = enabled
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        guard enabled else {
            advertiser.stopAdvertisingPeer()
            bluetooth.configure(enabled: false)
            advertising = false
            connectedPeerNames = []
            session.disconnect()
            return
        }

        lastError = nil
        advertiser.startAdvertisingPeer()
        bluetooth.configure(enabled: true)
        advertising = true
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: max(1.0, heartbeatSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flush(reason: "heartbeat")
            }
        }
        flush(reason: "enabled")
    }

    func notifyDirty() {
        flush(reason: "change")
    }

    func reconnect() {
        guard enabled else { return }
        advertiser.stopAdvertisingPeer()
        session.disconnect()
        connectedPeerNames = []
        advertiser.startAdvertisingPeer()
        advertising = true
        bluetooth.configure(enabled: true)
        flush(reason: "reconnect")
    }

    private func flush(reason: String) {
        guard enabled else { return }
        sequence &+= 1
        let payload: AppleCompanionStatePayload
        if let externalSnapshotProvider {
            payload = AppleCompanionStatePayload(
                sequence: sequence,
                snapshot: externalSnapshotProvider(),
                updatedAt: Date()
            )
        } else if let appState {
            // Temporary migration bridge. Production wiring installs the
            // external projection above; retaining this fallback keeps old
            // companion clients usable until the Center owner is switched.
            payload = appState.appleCompanionStatePayload(sequence: sequence)
        } else {
            return
        }

        bluetooth.publish(payload)

        guard !session.connectedPeers.isEmpty else { return }
        do {
            let data = try encoder.encode(payload)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            Self.log.debug("push(\(reason)): seq=\(payload.sequence) source=\(payload.source) status=\(payload.status.rawValue) peers=\(self.session.connectedPeers.count)")
        } catch {
            lastError = error.localizedDescription
            Self.log.error("push failed: \(error.localizedDescription)")
        }
    }

    private func handleCommand(_ command: AppleCompanionCommandPayload) {
        if let externalSnapshotProvider, let interactionInputSink {
            guard interactionAdapter.accepts(command, latestSequence: sequence) else {
                lastError = "Ignored unsupported companion protocol"
                return
            }
            if command.type == .focus {
                handleFocusRequest(MascotID(sourceName: command.source) ?? .claude)
                return
            }
            if command.type == .requestCurrentState {
                flush(reason: "requested")
                return
            }
            let decision = interactionAdapter.decision(
                command,
                snapshot: externalSnapshotProvider(),
                latestSequence: sequence
            )
            switch decision {
            case let .action(input):
                interactionInputSink(input)
            case .ignored:
                // Stale/ambiguous/unsupported commands deliberately do not
                // fall through to the legacy queue callbacks.
                lastError = "Ignored stale or unsupported companion command"
            }
            return
        }

        switch command.type {
        case .requestCurrentState:
            flush(reason: "requested")
        case .approveCurrentPermission:
            onControlCommand?(.approveCurrentPermission)
        case .denyCurrentPermission:
            onControlCommand?(.denyCurrentPermission)
        case .skipCurrentQuestion:
            onControlCommand?(.skipCurrentQuestion)
        case .answerQuestion:
            if let answer = command.answer?.trimmingCharacters(in: .whitespacesAndNewlines),
               !answer.isEmpty {
                onQuestionAnswer?(answer)
            }
        case .focus:
            handleFocusRequest(MascotID(sourceName: command.source) ?? .claude)
        }
    }

    /// Focus requests from a companion are routed through the external
    /// projection when available. This prevents the publisher from receiving
    /// local session metadata (including terminal handles).
    func handleFocusRequest(_ mascot: MascotID) {
        if let externalSnapshotProvider, let interactionInputSink {
            let sessions = externalSnapshotProvider().sessions.values
                .filter { $0.session.key.provider.rawValue == mascot.sourceName }
                .sorted {
                    if $0.pendingCount != $1.pendingCount { return $0.pendingCount > $1.pendingCount }
                    return $0.session.key.providerSessionID < $1.session.key.providerSessionID
                }
            guard let target = sessions.first else { return }
            interactionInputSink(.user(.navigate(.session(target.session))))
            return
        }
        onFocusRequest?(mascot)
    }

    private func refreshConnectedPeers() {
        connectedPeerNames = session.connectedPeers.map(\.displayName).sorted()
    }
}

extension AppleCompanionPublisher: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor in
            guard self.enabled else {
                invitationHandler(false, nil)
                return
            }
            Self.log.info("accepted invitation from \(peerID.displayName)")
            invitationHandler(true, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.advertising = false
            self.lastError = error.localizedDescription
            Self.log.error("advertising failed: \(error.localizedDescription)")
        }
    }
}

extension AppleCompanionPublisher: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            self.refreshConnectedPeers()
            if state == .connected {
                self.flush(reason: "peer-connected")
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            do {
                let command = try self.decoder.decode(AppleCompanionCommandPayload.self, from: data)
                self.handleCommand(command)
            } catch {
                self.lastError = "Ignored command from \(peerID.displayName): \(error.localizedDescription)"
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {}

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {}
}
