import Foundation

// MARK: - Identity

public struct ProviderID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public struct SessionKey: Hashable, Codable, Sendable {
    public let provider: ProviderID
    public let providerSessionID: String

    public init(provider: ProviderID, providerSessionID: String) {
        self.provider = provider
        self.providerSessionID = providerSessionID
    }

    public init(provider: String, providerSessionID: String) {
        self.init(provider: ProviderID(provider), providerSessionID: providerSessionID)
    }
}

public struct SessionRef: Hashable, Codable, Sendable {
    public let key: SessionKey
    public let generation: UInt64

    public init(key: SessionKey, generation: UInt64) {
        self.key = key
        self.generation = generation
    }

    public init(provider: ProviderID, providerSessionID: String, generation: UInt64) {
        self.init(key: SessionKey(provider: provider, providerSessionID: providerSessionID), generation: generation)
    }

    public init(provider: String, providerSessionID: String, generation: UInt64) {
        self.init(provider: ProviderID(provider), providerSessionID: providerSessionID, generation: generation)
    }
}

public enum InteractionRequestKind: Hashable, Codable, Sendable {
    case permission
    case question
}

public struct StableRequestKey: Hashable, Codable, Sendable {
    public let upstreamID: String
    public let kind: InteractionRequestKind
    public let discriminator: String?

    public init(upstreamID: String, kind: InteractionRequestKind, discriminator: String? = nil) {
        self.upstreamID = upstreamID
        self.kind = kind
        self.discriminator = discriminator
    }
}

public enum RequestCorrelation: Hashable, Codable, Sendable {
    case stable(StableRequestKey)
    case occurrence(UUID)
}

public struct RequestID: Hashable, Codable, Sendable {
    public let session: SessionRef
    public let correlation: RequestCorrelation

    public init(session: SessionRef, correlation: RequestCorrelation) {
        self.session = session
        self.correlation = correlation
    }

    public init(session: SessionRef, upstreamID: String, kind: InteractionRequestKind, discriminator: String? = nil) {
        self.init(session: session, correlation: .stable(StableRequestKey(upstreamID: upstreamID, kind: kind, discriminator: discriminator)))
    }

    public static func occurrence(session: SessionRef, uuid: UUID) -> RequestID {
        RequestID(session: session, correlation: .occurrence(uuid))
    }
}

public struct EffectID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct TransportToken: Hashable, Codable, Sendable {
    public let session: SessionRef
    public let rawValue: UUID

    public init(session: SessionRef, rawValue: UUID) {
        self.session = session
        self.rawValue = rawValue
    }
}

public struct ChannelToken: Hashable, Codable, Sendable {
    public let session: SessionRef
    public let rawValue: UUID

    public init(session: SessionRef, rawValue: UUID) {
        self.session = session
        self.rawValue = rawValue
    }
}

public struct AutoControlToken: Hashable, Codable, Sendable {
    public let session: SessionRef
    public let rawValue: UUID

    public init(session: SessionRef, rawValue: UUID) {
        self.session = session
        self.rawValue = rawValue
    }
}

public struct BufferToken: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

// MARK: - Session generation

public enum SessionCloseReason: Sendable, Equatable, Codable {
    case providerClosed
    case userClosed
    case staleReplacement
}

public enum SessionLifecycleFact: Sendable, Equatable, Codable {
    case opened
    case observed
    case closed(SessionCloseReason)
}

public enum SessionGenerationEvidence: Sendable, Equatable, Codable {
    case initialOpen
    case explicitReopen
    case providerObservation
    case providerClose
}

public struct SessionIdentityFact: Sendable, Equatable, Codable {
    public let key: SessionKey
    public let lifecycle: SessionLifecycleFact
    public let evidence: SessionGenerationEvidence
    public let sequence: UInt64

    public init(key: SessionKey, lifecycle: SessionLifecycleFact, evidence: SessionGenerationEvidence, sequence: UInt64) {
        self.key = key
        self.lifecycle = lifecycle
        self.evidence = evidence
        self.sequence = sequence
    }

    public init(session: SessionRef, lifecycle: SessionLifecycleFact, evidence: SessionGenerationEvidence, sequence: UInt64) {
        self.init(key: session.key, lifecycle: lifecycle, evidence: evidence, sequence: sequence)
    }
}

@MainActor
public protocol SessionGenerationAuthority: AnyObject {
    func current(for key: SessionKey) -> SessionRef?
    @discardableResult func apply(_ fact: SessionIdentityFact) -> SessionRef
    func isCurrent(_ ref: SessionRef) -> Bool
}

/// The only owner allowed to create a new session generation.
@MainActor
public final class InMemorySessionGenerationAuthority: SessionGenerationAuthority {
    private struct State {
        var ref: SessionRef
        var lastSequence: UInt64
        var closed: Bool
    }

    private var states: [SessionKey: State] = [:]

    public init() {}

    public func current(for key: SessionKey) -> SessionRef? { states[key]?.ref }

    public func isCurrent(_ ref: SessionRef) -> Bool {
        guard let state = states[ref.key] else { return false }
        return state.ref == ref && !state.closed
    }

    public func apply(_ fact: SessionIdentityFact) -> SessionRef {
        guard let state = states[fact.key] else {
            guard fact.lifecycle == .opened, fact.evidence == .initialOpen else {
                return SessionRef(key: fact.key, generation: 0)
            }
            let ref = SessionRef(key: fact.key, generation: 1)
            states[fact.key] = State(ref: ref, lastSequence: fact.sequence, closed: false)
            return ref
        }

        // Same or older evidence is deliberately idempotent. A provider's sequence
        // is not allowed to resurrect a closed generation.
        guard fact.sequence > state.lastSequence else { return state.ref }

        if state.closed {
            guard fact.lifecycle == .opened, fact.evidence == .explicitReopen else {
                return state.ref
            }
            let ref = SessionRef(key: fact.key, generation: state.ref.generation + 1)
            states[fact.key] = State(ref: ref, lastSequence: fact.sequence, closed: false)
            return ref
        }

        switch (fact.lifecycle, fact.evidence) {
        case (.closed, .providerClose):
            states[fact.key] = State(ref: state.ref, lastSequence: fact.sequence, closed: true)
        case (.observed, .providerObservation), (.opened, .initialOpen):
            states[fact.key] = State(ref: state.ref, lastSequence: fact.sequence, closed: false)
        default:
            break
        }
        return state.ref
    }

    public func isClosed(_ ref: SessionRef) -> Bool {
        states[ref.key]?.ref == ref && states[ref.key]?.closed == true
    }
}

// MARK: - Typed content and provider capabilities

public enum Sensitivity: Sendable, Equatable, Codable {
    case `public`
    case privateData
    case secret
}

public struct SensitiveText: Sendable, Equatable, Codable {
    public let value: String
    public let sensitivity: Sensitivity

    public init(_ value: String, sensitivity: Sensitivity = .public) {
        self.value = value
        self.sensitivity = sensitivity
    }
}

public indirect enum DisplayValue: Sendable, Equatable, Codable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    case list([DisplayValue])
    case object([String: DisplayValue])
    case redacted(Sensitivity)
}

public struct QuestionOption: Sendable, Equatable, Codable {
    public let key: String
    public let label: SensitiveText

    public init(key: String, label: SensitiveText) {
        self.key = key
        self.label = label
    }
}

public struct QuestionItem: Sendable, Equatable, Codable {
    public let key: String
    public let prompt: SensitiveText
    public let options: [QuestionOption]
    public let allowsMultiple: Bool

    public init(key: String, prompt: SensitiveText, options: [QuestionOption] = [], allowsMultiple: Bool = false) {
        self.key = key
        self.prompt = prompt
        self.options = options
        self.allowsMultiple = allowsMultiple
    }
}

public struct AnswerSchema: Sendable, Equatable, Codable {
    public let keysInProviderOrder: [String]
    public let allowsCustomText: Bool

    public init(keysInProviderOrder: [String], allowsCustomText: Bool = false) {
        self.keysInProviderOrder = keysInProviderOrder
        self.allowsCustomText = allowsCustomText
    }
}

public enum QuestionAnswerValue: Sendable, Equatable, Codable {
    case option(String)
    case custom(SensitiveText)
}

public struct QuestionAnswer: Sendable, Equatable, Codable {
    public let questionKey: String
    public let values: [QuestionAnswerValue]

    public init(questionKey: String, values: [QuestionAnswerValue]) {
        self.questionKey = questionKey
        self.values = values
    }
}

public struct PlanContent: Sendable, Equatable, Codable {
    public let planText: SensitiveText?
    public let allowedPromptCount: Int
    public let suggestedMode: PlanMode?

    public init(planText: SensitiveText? = nil, allowedPromptCount: Int = 0, suggestedMode: PlanMode? = nil) {
        self.planText = planText
        self.allowedPromptCount = allowedPromptCount
        self.suggestedMode = suggestedMode
    }
}

public enum PlanMode: Hashable, Sendable, Equatable, Codable {
    case suggested(String)
    case manual
}

public enum PermissionVariant: Sendable, Equatable, Codable {
    case regular
    case plan(PlanContent)
}

public struct PermissionContent: Sendable, Equatable, Codable {
    public let toolName: String?
    public let summary: String?
    public let displayInput: DisplayValue?
    public let variant: PermissionVariant

    public init(toolName: String? = nil, summary: String? = nil, displayInput: DisplayValue? = nil, variant: PermissionVariant = .regular) {
        self.toolName = toolName
        self.summary = summary
        self.displayInput = displayInput
        self.variant = variant
    }
}

public struct QuestionContent: Sendable, Equatable, Codable {
    public let items: [QuestionItem]
    public let answerSchema: AnswerSchema

    public init(items: [QuestionItem], answerSchema: AnswerSchema) {
        self.items = items
        self.answerSchema = answerSchema
    }
}

public enum RequestContent: Sendable, Equatable, Codable {
    case permission(PermissionContent)
    case question(QuestionContent)
}

public enum QuestionResolutionAction: Hashable, Sendable, Equatable, Codable {
    case reject
    case abandon
    case continueWithoutAnswer
}

public struct ResolutionCapabilities: Sendable, Equatable, Codable {
    public let allowAlways: Bool
    public let planModes: Set<PlanMode>
    public let questionActions: Set<QuestionResolutionAction>

    public init(allowAlways: Bool = false, planModes: Set<PlanMode> = [], questionActions: Set<QuestionResolutionAction> = []) {
        self.allowAlways = allowAlways
        self.planModes = planModes
        self.questionActions = questionActions
    }
}

public enum RequestBehavior: Sendable, Equatable, Codable {
    case blocking(ResolutionCapabilities)
    case displayOnly
    case nativeOwned
}

public enum ResolutionChannel: Sendable, Equatable, Codable {
    case none
    case response(TransportToken)
}

public enum ObservedPermissionMode: Sendable, Equatable, Codable {
    case defaultMode
    case auto
    case acceptEdits
    case bypassPermissions
    case unknown(String?)
}

public enum ProviderPermissionMode: Sendable, Equatable, Codable {
    case defaultMode
    case auto
    case acceptEdits
    case bypassPermissions
}

public enum AutoRule: Sendable, Equatable, Codable {
    case tool(String, scope: String?)
}

public struct AutoCapabilities: Sendable, Equatable, Codable {
    public let nativeAuto: Bool
    public let acceptEditsRules: Bool
    public let explicitBypass: Bool
    public let independentControlChannel: Bool

    public init(nativeAuto: Bool = false, acceptEditsRules: Bool = false, explicitBypass: Bool = false, independentControlChannel: Bool = true) {
        self.nativeAuto = nativeAuto
        self.acceptEditsRules = acceptEditsRules
        self.explicitBypass = explicitBypass
        self.independentControlChannel = independentControlChannel
    }
}

public struct ProviderCapabilities: Sendable, Equatable, Codable {
    public let auto: AutoCapabilities
    public let questionActions: Set<QuestionResolutionAction>
    public let canNeutralFinalize: Bool

    public init(auto: AutoCapabilities = AutoCapabilities(), questionActions: Set<QuestionResolutionAction> = [], canNeutralFinalize: Bool = false) {
        self.auto = auto
        self.questionActions = questionActions
        self.canNeutralFinalize = canNeutralFinalize
    }
}

// MARK: - Session display/navigation observations

public enum NavigationTarget: Sendable, Equatable, Codable {
    case request(RequestID)
    case session(SessionRef)
}

public enum TerminalTarget: Sendable, Equatable, Codable {
    case local(bundleID: String)
    case remote(hostID: String)
    case unavailable
}

public struct NavigationContext: Sendable, Equatable, Codable {
    public let terminal: TerminalTarget?
    public let isRemote: Bool

    public init(terminal: TerminalTarget? = nil, isRemote: Bool = false) {
        self.terminal = terminal
        self.isRemote = isRemote
    }
}

public struct SubagentDisplayFact: Sendable, Equatable, Codable {
    public let id: String
    public let title: String?
    public let status: String?

    public init(id: String, title: String? = nil, status: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public enum MessageRole: Sendable, Equatable, Codable {
    case user
    case assistant
    case system
}

public struct RecentMessageFact: Sendable, Equatable, Codable {
    public let role: MessageRole
    public let preview: SensitiveText?

    public init(role: MessageRole, preview: SensitiveText? = nil) {
        self.role = role
        self.preview = preview
    }
}

public struct GitDisplayFact: Sendable, Equatable, Codable {
    public let branch: String?
    public let isWorktree: Bool

    public init(branch: String? = nil, isWorktree: Bool = false) {
        self.branch = branch
        self.isWorktree = isWorktree
    }
}

public struct RemoteDisplayFact: Sendable, Equatable, Codable {
    public let hostID: String
    public let hostName: String?

    public init(hostID: String, hostName: String? = nil) {
        self.hostID = hostID
        self.hostName = hostName
    }
}

public struct SessionDisplayFacts: Sendable, Equatable, Codable {
    public let title: String?
    public let project: String?
    public let source: String?
    public let cwd: String?
    public let model: String?
    public let status: String?
    public let currentTool: String?
    public let toolDescription: String?
    public let subagents: [SubagentDisplayFact]
    public let recentMessages: [RecentMessageFact]
    public let git: GitDisplayFact?
    public let providerSessionID: String?
    public let remote: RemoteDisplayFact?

    public init(title: String? = nil, project: String? = nil, source: String? = nil, cwd: String? = nil,
                model: String? = nil, status: String? = nil, currentTool: String? = nil,
                toolDescription: String? = nil, subagents: [SubagentDisplayFact] = [],
                recentMessages: [RecentMessageFact] = [], git: GitDisplayFact? = nil,
                providerSessionID: String? = nil, remote: RemoteDisplayFact? = nil) {
        self.title = title; self.project = project; self.source = source; self.cwd = cwd
        self.model = model; self.status = status; self.currentTool = currentTool
        self.toolDescription = toolDescription; self.subagents = subagents
        self.recentMessages = recentMessages; self.git = git; self.providerSessionID = providerSessionID
        self.remote = remote
    }
}

public struct SessionDisplayObservation: Sendable, Equatable, Codable {
    public let session: SessionRef
    public let facts: SessionDisplayFacts

    public init(session: SessionRef, facts: SessionDisplayFacts) {
        self.session = session; self.facts = facts
    }
}

public struct TerminalRouteFact: Sendable, Equatable, Codable {
    public let termApp: String?
    public let itermSessionID: String?
    public let ttyPath: String?
    public let kittyWindowID: String?
    public let tmuxPane: String?
    public let tmuxClientTTY: String?
    public let tmuxEnvironment: String?
    public let termBundleID: String?
    public let cmuxSurfaceID: String?
    public let cmuxWorkspaceID: String?
    public let zellijPaneID: String?
    public let zellijSessionName: String?
    public let weztermPaneID: String?
    public let supersetWorkspaceID: String?
    public let supersetPaneID: String?
    public let orcaTerminalHandle: String?
    public let orcaWorktreeID: String?
    public let cliPID: Int32?
    public let cliStartTime: Date?

    public init(termApp: String? = nil, itermSessionID: String? = nil, ttyPath: String? = nil,
                kittyWindowID: String? = nil, tmuxPane: String? = nil, tmuxClientTTY: String? = nil,
                tmuxEnvironment: String? = nil, termBundleID: String? = nil, cmuxSurfaceID: String? = nil,
                cmuxWorkspaceID: String? = nil, zellijPaneID: String? = nil, zellijSessionName: String? = nil,
                weztermPaneID: String? = nil, supersetWorkspaceID: String? = nil, supersetPaneID: String? = nil,
                orcaTerminalHandle: String? = nil, orcaWorktreeID: String? = nil, cliPID: Int32? = nil,
                cliStartTime: Date? = nil) {
        self.termApp = termApp; self.itermSessionID = itermSessionID; self.ttyPath = ttyPath
        self.kittyWindowID = kittyWindowID; self.tmuxPane = tmuxPane; self.tmuxClientTTY = tmuxClientTTY
        self.tmuxEnvironment = tmuxEnvironment; self.termBundleID = termBundleID
        self.cmuxSurfaceID = cmuxSurfaceID; self.cmuxWorkspaceID = cmuxWorkspaceID
        self.zellijPaneID = zellijPaneID; self.zellijSessionName = zellijSessionName
        self.weztermPaneID = weztermPaneID; self.supersetWorkspaceID = supersetWorkspaceID
        self.supersetPaneID = supersetPaneID; self.orcaTerminalHandle = orcaTerminalHandle
        self.orcaWorktreeID = orcaWorktreeID; self.cliPID = cliPID; self.cliStartTime = cliStartTime
    }
}

public struct SessionNavigationObservation: Sendable, Equatable, Codable {
    public let session: SessionRef
    public let context: NavigationContext
    public let route: TerminalRouteFact
    public let providerSessionID: String?
    public let remote: RemoteDisplayFact?

    public init(session: SessionRef, context: NavigationContext = NavigationContext(), route: TerminalRouteFact = TerminalRouteFact(), providerSessionID: String? = nil, remote: RemoteDisplayFact? = nil) {
        self.session = session; self.context = context; self.route = route
        self.providerSessionID = providerSessionID; self.remote = remote
    }
}

public enum UpstreamSessionLifecycle: Sendable, Equatable, Codable {
    case active
    case idle
    case waiting
    case closed
}

public enum CLIVisibility: Sendable, Equatable, Codable {
    case visible
    case notVisible
    case unknown
}

public enum VisibilityEvidence: Sendable, Equatable, Codable {
    case terminalTab
    case terminalFrontmost
    case nativeAppFrontmost
    case unavailable
}

public struct CompletionObservation: Sendable, Equatable, Codable {
    public let session: SessionRef
    public let message: String
    public let revision: UInt64

    public init(session: SessionRef, message: String, revision: UInt64) {
        self.session = session; self.message = message; self.revision = revision
    }
}

public struct SessionObservation: Sendable, Equatable, Codable {
    public let session: SessionRef
    public let lifecycle: UpstreamSessionLifecycle
    public let permissionMode: ObservedPermissionMode
    public let providerCapabilities: ProviderCapabilities
    public let display: SessionDisplayObservation
    public let navigation: SessionNavigationObservation
    public let cliVisibility: CLIVisibility
    public let completion: CompletionObservation?
    public let revision: UInt64
    public let observedAt: Date

    public init(session: SessionRef, lifecycle: UpstreamSessionLifecycle = .active,
                permissionMode: ObservedPermissionMode = .unknown(nil),
                providerCapabilities: ProviderCapabilities = ProviderCapabilities(),
                display: SessionDisplayObservation? = nil,
                navigation: SessionNavigationObservation? = nil,
                cliVisibility: CLIVisibility = .unknown, completion: CompletionObservation? = nil,
                revision: UInt64, observedAt: Date = Date()) {
        self.session = session; self.lifecycle = lifecycle; self.permissionMode = permissionMode
        self.providerCapabilities = providerCapabilities
        self.display = display ?? SessionDisplayObservation(session: session, facts: SessionDisplayFacts())
        self.navigation = navigation ?? SessionNavigationObservation(session: session)
        self.cliVisibility = cliVisibility; self.completion = completion
        self.revision = revision; self.observedAt = observedAt
    }
}

public struct VisibilityObservation: Sendable, Equatable, Codable {
    public let session: SessionRef
    public let state: CLIVisibility
    public let evidence: VisibilityEvidence
    public let revision: UInt64
    public let measuredAt: Date
    /// Maximum age for which this measurement may be used to suppress a
    /// presentation.  The detector owns this bound because different
    /// evidence sources have different freshness guarantees.  Presentation
    /// policy may impose a stricter global cap as well.
    public let maxAge: Duration

    public init(session: SessionRef, state: CLIVisibility, evidence: VisibilityEvidence = .unavailable, revision: UInt64, measuredAt: Date = Date(), maxAge: Duration = .seconds(5)) {
        self.session = session; self.state = state; self.evidence = evidence
        self.revision = revision; self.measuredAt = measuredAt; self.maxAge = maxAge
    }
}

public struct NativePromptObservation: Sendable, Equatable, Codable {
    public let session: SessionRef
    public let isPending: Bool
    public let title: String?
    public let revision: UInt64

    public init(session: SessionRef, isPending: Bool, title: String? = nil, revision: UInt64) {
        self.session = session; self.isPending = isPending; self.title = title; self.revision = revision
    }
}

// MARK: - Requests and ingress

public struct ReplayProof: Sendable, Equatable, Codable {
    public let providerIDMatches: Bool
    public let generationMatches: Bool
    public let upstreamIDMatches: Bool
    public let discriminatorMatches: Bool

    public init(providerIDMatches: Bool = true, generationMatches: Bool = true, upstreamIDMatches: Bool = true, discriminatorMatches: Bool = true) {
        self.providerIDMatches = providerIDMatches; self.generationMatches = generationMatches
        self.upstreamIDMatches = upstreamIDMatches; self.discriminatorMatches = discriminatorMatches
    }

    public var isValid: Bool { providerIDMatches && generationMatches && upstreamIDMatches && discriminatorMatches }
}

public enum RequestAssociation: Sendable, Equatable, Codable {
    case new
    case replay(of: RequestID, proof: ReplayProof)
}

public struct RequestArrival: Sendable, Equatable, Codable {
    public let id: RequestID
    public let session: SessionRef
    public let kind: InteractionRequestKind
    public let behavior: RequestBehavior
    public let content: RequestContent
    public let channel: ResolutionChannel
    public let association: RequestAssociation
    public let receivedAt: Date

    public init(id: RequestID, session: SessionRef, kind: InteractionRequestKind, behavior: RequestBehavior,
                content: RequestContent, channel: ResolutionChannel = .none,
                association: RequestAssociation = .new, receivedAt: Date = Date()) {
        self.id = id; self.session = session; self.kind = kind; self.behavior = behavior
        self.content = content; self.channel = channel; self.association = association; self.receivedAt = receivedAt
    }
}

public struct PendingIngressPolicy: Sendable, Equatable {
    public let maxRequestsPerSessionKey: Int
    public let maxAge: Duration

    public init(maxRequestsPerSessionKey: Int = 32, maxAge: Duration = .seconds(30)) {
        self.maxRequestsPerSessionKey = max(1, maxRequestsPerSessionKey); self.maxAge = maxAge
    }
}

public struct ProviderResponseHandle: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

public enum UnboundRequestBehavior: Sendable, Equatable, Codable {
    case blocking(ResolutionCapabilities)
    case displayOnly
}

public enum UnboundResolutionChannel: Sendable, Equatable, Codable {
    case none
    case response(ProviderResponseHandle)
}

public struct UnboundRequest: Sendable, Equatable, Codable {
    public let key: SessionKey
    public let bufferToken: BufferToken
    public let correlation: RequestCorrelation
    public let kind: InteractionRequestKind
    public let behavior: UnboundRequestBehavior
    public let content: RequestContent
    public let channel: UnboundResolutionChannel
    public let receivedAt: Date

    public init(key: SessionKey, bufferToken: BufferToken, correlation: RequestCorrelation, kind: InteractionRequestKind,
                behavior: UnboundRequestBehavior, content: RequestContent, channel: UnboundResolutionChannel = .none,
                receivedAt: Date = Date()) {
        self.key = key; self.bufferToken = bufferToken; self.correlation = correlation; self.kind = kind
        self.behavior = behavior; self.content = content; self.channel = channel; self.receivedAt = receivedAt
    }
}

public enum RequestIngressResult: Sendable, Equatable {
    case admitted(RequestArrival)
    case buffered(BufferToken)
    case finalizedWithoutResolution(DiagnosticCode)
}

public protocol TransportTokenFactory: Sendable {
    func bind(_ handle: ProviderResponseHandle, to session: SessionRef) -> TransportToken
}

public protocol RequestIngressBuffer: AnyObject, Sendable {
    func accept(_ request: UnboundRequest) -> RequestIngressResult
    func bind(_ session: SessionRef, tokenFactory: any TransportTokenFactory) -> [RequestArrival]
    func expire(now: Date) -> [BufferToken]
    func remove(_ key: SessionKey) -> [BufferToken]
}

/// An ingress buffer is intentionally keyed by SessionKey rather than a guessed
/// generation. Requests are bound only after the generation authority speaks.
public final class InMemoryRequestIngressBuffer: RequestIngressBuffer, @unchecked Sendable {
    private let policy: PendingIngressPolicy
    private let idFactory: any InteractionIDFactory
    private var entries: [SessionKey: [UnboundRequest]] = [:]
    private let lock = NSLock()

    public init(policy: PendingIngressPolicy = PendingIngressPolicy(), idFactory: any InteractionIDFactory = RandomInteractionIDFactory()) {
        self.policy = policy; self.idFactory = idFactory
    }

    public func accept(_ request: UnboundRequest) -> RequestIngressResult {
        if case .blocking = request.behavior {
            guard case .response = request.channel else { return .finalizedWithoutResolution(.invalidChannel) }
        } else if case .response = request.channel {
            return .finalizedWithoutResolution(.invalidChannel)
        }
        lock.lock(); defer { lock.unlock() }
        var list = entries[request.key, default: []].filter {
            request.receivedAt.timeIntervalSince($0.receivedAt) < policy.maxAge.timeInterval
        }
        guard list.count < policy.maxRequestsPerSessionKey else {
            return .finalizedWithoutResolution(.bufferOverflow)
        }
        list.append(request)
        entries[request.key] = list
        return .buffered(request.bufferToken)
    }

    public func bind(_ session: SessionRef, tokenFactory: any TransportTokenFactory) -> [RequestArrival] {
        lock.lock(); defer { lock.unlock() }
        let list = entries.removeValue(forKey: session.key) ?? []
        return list.map { request in
            let channel: ResolutionChannel
            switch request.channel {
            case .none: channel = .none
            case let .response(handle): channel = .response(tokenFactory.bind(handle, to: session))
            }
            let id = RequestID(session: session, correlation: request.correlation)
            let behavior: RequestBehavior
            switch request.behavior {
            case let .blocking(capabilities): behavior = .blocking(capabilities)
            case .displayOnly: behavior = .displayOnly
            }
            return RequestArrival(id: id, session: session, kind: request.kind, behavior: behavior,
                                  content: request.content, channel: channel, receivedAt: request.receivedAt)
        }
    }

    public func expire(now: Date) -> [BufferToken] {
        lock.lock(); defer { lock.unlock() }
        var expired: [BufferToken] = []
        for key in entries.keys {
            let kept = entries[key, default: []].filter { request in
                let age = now.timeIntervalSince(request.receivedAt)
                if age >= policy.maxAge.timeInterval { expired.append(request.bufferToken); return false }
                return true
            }
            if kept.isEmpty { entries.removeValue(forKey: key) } else { entries[key] = kept }
        }
        return expired
    }

    public func remove(_ key: SessionKey) -> [BufferToken] {
        lock.lock(); defer { lock.unlock() }
        return entries.removeValue(forKey: key)?.map(\.bufferToken) ?? []
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.values.reduce(0) { $0 + $1.count }
    }
}

public typealias BoundedRequestIngressBuffer = InMemoryRequestIngressBuffer

// MARK: - Input, effects and failures

public enum AutoModeIntent: Sendable, Equatable, Codable {
    case off
    case enable
    case bypassExplicit
}

public enum ResolutionCommand: Sendable, Equatable, Codable {
    case allowOnce
    case allowAlways
    case deny(message: String?)
    case allowPlan(mode: PlanMode)
    case answer([QuestionAnswer])
    case questionAction(QuestionResolutionAction, reason: String?)
}

public enum InteractionUserAction: Sendable, Equatable, Codable {
    case dismiss(RequestID)
    case reveal(RequestID)
    case resolve(RequestID, ResolutionCommand)
    case setAutoMode(SessionRef, AutoModeIntent)
    case navigate(NavigationTarget)
}

public enum ExternalActionKind: Hashable, Sendable, Equatable, Codable {
    case allow
    case deny
    case answer
}

public enum InteractionAdapterEvent: Sendable, Equatable {
    case transportEnded(token: TransportToken, evidence: TransportEndEvidence)
    case sessionChannelEnded(session: SessionRef, channel: ChannelToken, evidence: SessionChannelEndEvidence)
    case resolutionSucceeded(EffectID, request: RequestID, token: TransportToken)
    case resolutionFailed(EffectID, request: RequestID, token: TransportToken, failure: AdapterFailure)
    case autoModeDelivered(EffectID, session: SessionRef)
    case autoModeAwaitingConfirmation(EffectID, session: SessionRef)
    case autoModeFailed(EffectID, session: SessionRef, failure: AdapterFailure)
    case navigationFinished(EffectID, outcome: NavigationOutcome)
    case externallyResolved(RequestID, evidence: ExternalResolutionEvidence)
}

public enum TransportEndEvidence: Sendable, Equatable {
    case responseDelivered
    case providerResolved(ExternalResolutionEvidence)
    case peerDisconnected
    case timedOut
    case replacement
}

public enum TransportFinalization: Sendable, Equatable {
    case providerSafeNeutral(TransportEndReason)
    case externallyResolved(ExternalResolutionEvidence)
}

public enum ProviderNeutralResponse: Sendable, Equatable, Codable {
    case hookEmptyObject
    case codexEmptyAnswers
    case notificationAck
}

public struct TransportFinalizationRequest: Sendable, Equatable {
    public let token: TransportToken
    public let reason: TransportEndReason
    public let response: ProviderNeutralResponse

    public init(token: TransportToken, reason: TransportEndReason, response: ProviderNeutralResponse) {
        self.token = token; self.reason = reason; self.response = response
    }
}

public struct NeutralFinalizationReceipt: Sendable, Equatable {
    public let token: TransportToken
    public let response: ProviderNeutralResponse

    public init(token: TransportToken, response: ProviderNeutralResponse) {
        self.token = token; self.response = response
    }
}

public enum TransportFinalizationResult: Sendable, Equatable {
    case finalized(NeutralFinalizationReceipt)
    case quarantined(TransportQuarantine)
    case failed(AdapterFailure)
}

public enum TransportQuarantine: Sendable, Equatable {
    case noSafeNeutralResponse(TransportToken)
    case malformedChannel(TransportToken)
}

public enum TransportEndReason: Sendable, Equatable, Codable {
    case peerDisconnected
    case timedOut
    case replacement
    case ingressExpired
}

public enum SessionChannelEndEvidence: Sendable, Equatable, Codable {
    case providerSessionClosed
    case providerRestarted
}

public enum CancellationReason: Sendable, Equatable, Codable {
    case externallyResolved
    case superseded
    case sessionClosed
}

public enum ExternalResolutionEvidence: Sendable, Equatable, Codable {
    case providerRequestID
    case supersededBy(RequestID)
    case providerSessionClosed
}

public enum NavigationOutcome: Sendable, Equatable, Codable {
    case succeeded
    case unavailable
    case failed(String)
}

public enum AdapterFailure: Sendable, Equatable, Codable {
    case notDelivered(String)
    case deliveryUnknown(String)
    case protocolRejected(String)
    case unavailable(String)
}

public enum AvailableResolutionAction: Sendable, Equatable, Codable {
    case allowOnce
    case allowAlways
    case deny
    case allowPlan(PlanMode)
    case answer
    case questionAction(QuestionResolutionAction)
}

public enum InteractionEffect: Sendable, Equatable {
    case deliverResolution(ResolutionEffect)
    case finalizeTransport(FinalizeTransportEffect)
    case changeAutoMode(AutoModeEffect)
    case cancelTransport(CancelTransportEffect)
    case navigate(NavigationEffect)
    case feedback(InteractionFeedback)
    case diagnostic(InteractionDiagnostic)
}

public struct ResolutionEffect: Sendable, Equatable {
    public let effectID: EffectID
    public let requestID: RequestID
    public let token: TransportToken
    public let command: ResolutionCommand

    public init(effectID: EffectID, requestID: RequestID, token: TransportToken, command: ResolutionCommand) {
        self.effectID = effectID; self.requestID = requestID; self.token = token; self.command = command
    }
}

public struct FinalizeTransportEffect: Sendable, Equatable {
    public let effectID: EffectID
    public let requestID: RequestID
    public let token: TransportToken
    public let finalization: TransportFinalization

    public init(effectID: EffectID, requestID: RequestID, token: TransportToken, finalization: TransportFinalization) {
        self.effectID = effectID; self.requestID = requestID; self.token = token; self.finalization = finalization
    }
}

public struct CancelTransportEffect: Sendable, Equatable {
    public let effectID: EffectID
    public let requestID: RequestID
    public let token: TransportToken
    public let reason: CancellationReason

    public init(effectID: EffectID, requestID: RequestID, token: TransportToken, reason: CancellationReason) {
        self.effectID = effectID; self.requestID = requestID; self.token = token; self.reason = reason
    }
}

public struct AutoCommandTransaction: Sendable, Equatable {
    public let session: SessionRef
    public let commands: [AutoCommand]
    public let controlToken: AutoControlToken

    public init(session: SessionRef, commands: [AutoCommand], controlToken: AutoControlToken) {
        self.session = session; self.commands = commands; self.controlToken = controlToken
    }
}

public enum AutoCommand: Sendable, Equatable, Codable {
    case setMode(ProviderPermissionMode)
    case addRules([AutoRule])
    case removeRules([AutoRule])
}

public struct AutoModeEffect: Sendable, Equatable {
    public let effectID: EffectID
    public let transaction: AutoCommandTransaction

    public init(effectID: EffectID, transaction: AutoCommandTransaction) {
        self.effectID = effectID; self.transaction = transaction
    }
}

public struct NavigationEffect: Sendable, Equatable {
    public let effectID: EffectID
    public let target: NavigationTarget
    public let context: NavigationContext

    public init(effectID: EffectID, target: NavigationTarget, context: NavigationContext) {
        self.effectID = effectID; self.target = target; self.context = context
    }
}

public struct InteractionFeedback: Sendable, Equatable, Codable {
    public let message: String
    public let severity: FeedbackSeverity

    public init(message: String, severity: FeedbackSeverity) { self.message = message; self.severity = severity }
}

public enum FeedbackSeverity: Sendable, Equatable, Codable { case info, warning, error }

public enum DiagnosticCode: Sendable, Equatable, Codable {
    case invalidIdentity
    case invalidChannel
    case staleGeneration
    case staleRevision
    case bufferExpired
    case bufferOverflow
    case unsupportedSource
    case unknownProtocolMajor
    case duplicateEffect
    case terminalLedgerHit
}

public enum InteractionDiagnostic: Sendable, Equatable {
    case code(DiagnosticCode)
    case stale(String)
    case ambiguousLegacyTarget
}

public enum InteractionError: Sendable, Equatable, Codable {
    case invalidIdentity
    case invalidChannel
    case blockedByEarlierRequest(RequestID)
    case unavailable(String)
    case adapterFailure(String)
}

// MARK: - Snapshot and presentation

public enum RequestLifecycle: Sendable, Equatable, Codable {
    case pending
    case resolving(EffectID)
    case awaitingExternalConfirmation(EffectID)
}

public enum RequestPresentation: Sendable, Equatable, Codable {
    case normal
    case dismissed
}

public enum Surface: Sendable, Equatable, Codable {
    case collapsed
    case sessionList
    case request(RequestID)
    case completion(CompletionNotice)
}

public struct CompletionNotice: Sendable, Equatable, Codable {
    public let session: SessionRef
    public let message: String
    public let revision: UInt64

    public init(session: SessionRef, message: String, revision: UInt64) {
        self.session = session; self.message = message; self.revision = revision
    }
}

public struct RedactedCompletionNotice: Sendable, Equatable, Codable {
    public let session: SessionRef
    public let revision: UInt64

    public init(session: SessionRef, revision: UInt64) { self.session = session; self.revision = revision }
}

public enum RedactedSurface: Sendable, Equatable, Codable {
    case collapsed
    case sessionList
    case request(RequestID)
    case completion(RedactedCompletionNotice)
}

public struct Badge: Sendable, Equatable, Codable {
    public let pendingCount: Int
    public let kinds: Set<InteractionRequestKind>

    public init(pendingCount: Int, kinds: Set<InteractionRequestKind>) {
        self.pendingCount = pendingCount; self.kinds = kinds
    }
}

public struct NavigationSnapshot: Sendable, Equatable, Codable {
    public let context: NavigationContext
    public let route: TerminalRouteFact
    public let canNavigate: Bool
    public let lastFailure: String?

    public init(context: NavigationContext = NavigationContext(), route: TerminalRouteFact = TerminalRouteFact(), canNavigate: Bool = false, lastFailure: String? = nil) {
        self.context = context; self.route = route; self.canNavigate = canNavigate; self.lastFailure = lastFailure
    }
}

public enum AutoPhase: Sendable, Equatable, Codable {
    case idle
    case transitioning(EffectID)
    case delivered(EffectID)
    case awaitingConfirmation(EffectID)
    case confirmed(ProviderPermissionMode)
    case unknown
    case failed(String)
}

public struct AutoSnapshot: Sendable, Equatable, Codable {
    public let observedMode: ObservedPermissionMode?
    public let requestedMode: AutoModeIntent?
    public let phase: AutoPhase
    /// Provider capabilities are part of the read model so a renderer can
    /// distinguish unavailable Auto from a request that is still transitioning.
    public let capabilities: AutoCapabilities
    public let inFlightEffect: EffectID?

    public init(observedMode: ObservedPermissionMode? = nil, requestedMode: AutoModeIntent? = nil,
                phase: AutoPhase = .idle, capabilities: AutoCapabilities = AutoCapabilities(),
                inFlightEffect: EffectID? = nil) {
        self.observedMode = observedMode; self.requestedMode = requestedMode; self.phase = phase
        self.capabilities = capabilities; self.inFlightEffect = inFlightEffect
    }
}

public struct InteractionSessionSnapshot: Sendable, Equatable {
    public let session: SessionRef
    public let facts: SessionDisplayFacts
    public let completion: CompletionNotice?
    public let pendingCount: Int
    public let pendingKinds: Set<InteractionRequestKind>
    public let auto: AutoSnapshot
    public let navigation: NavigationSnapshot

    public init(session: SessionRef, facts: SessionDisplayFacts = SessionDisplayFacts(), completion: CompletionNotice? = nil,
                pendingCount: Int = 0, pendingKinds: Set<InteractionRequestKind> = [], auto: AutoSnapshot = AutoSnapshot(), navigation: NavigationSnapshot = NavigationSnapshot()) {
        self.session = session; self.facts = facts; self.completion = completion
        self.pendingCount = pendingCount; self.pendingKinds = pendingKinds; self.auto = auto; self.navigation = navigation
    }
}

public struct InteractionRequestSnapshot: Sendable, Equatable {
    public let id: RequestID
    public let session: SessionRef
    public let kind: InteractionRequestKind
    public let content: RequestContent
    public let lifecycle: RequestLifecycle
    public let presentation: RequestPresentation
    public let availableActions: [AvailableResolutionAction]
    public let queuePosition: Int
    public let error: InteractionError?

    public init(id: RequestID, session: SessionRef, kind: InteractionRequestKind, content: RequestContent,
                lifecycle: RequestLifecycle, presentation: RequestPresentation,
                availableActions: [AvailableResolutionAction] = [], queuePosition: Int = 0,
                error: InteractionError? = nil) {
        self.id = id; self.session = session; self.kind = kind; self.content = content
        self.lifecycle = lifecycle; self.presentation = presentation; self.availableActions = availableActions
        self.queuePosition = queuePosition; self.error = error
    }
}

public struct RedactedRequestSnapshot: Sendable, Equatable {
    public let id: RequestID
    public let session: SessionRef
    public let kind: InteractionRequestKind
    public let title: String?
    public let sensitivity: Sensitivity
    public let pending: Bool
    /// In-flight requests remain pending for badge/count purposes but must not
    /// accept another remote action until the Center confirms their outcome.
    public let actionable: Bool
    public let availableActionKinds: Set<ExternalActionKind>

    public init(id: RequestID, session: SessionRef, kind: InteractionRequestKind, title: String?, sensitivity: Sensitivity,
                pending: Bool, actionable: Bool = true, availableActionKinds: Set<ExternalActionKind>) {
        self.id = id; self.session = session; self.kind = kind; self.title = title; self.sensitivity = sensitivity
        self.pending = pending; self.actionable = actionable; self.availableActionKinds = availableActionKinds
    }
}

public struct PresentationSnapshot: Sendable, Equatable {
    public let surface: Surface
    public let prominentRequest: RequestID?
    public let badgeCounts: [SessionRef: Badge]
    public let feedbackNonce: UInt64

    public init(surface: Surface = .collapsed, prominentRequest: RequestID? = nil, badgeCounts: [SessionRef: Badge] = [:], feedbackNonce: UInt64 = 0) {
        self.surface = surface; self.prominentRequest = prominentRequest; self.badgeCounts = badgeCounts; self.feedbackNonce = feedbackNonce
    }
}

public struct RedactedPresentationSnapshot: Sendable, Equatable {
    public let surface: RedactedSurface
    public let prominentRequest: RequestID?

    public init(surface: RedactedSurface = .collapsed, prominentRequest: RequestID? = nil) {
        self.surface = surface; self.prominentRequest = prominentRequest
    }
}

public struct LocalInteractionSnapshot: Sendable, Equatable {
    public let sessions: [SessionRef: InteractionSessionSnapshot]
    public let requests: [RequestID: InteractionRequestSnapshot]
    public let presentation: PresentationSnapshot

    public init(sessions: [SessionRef: InteractionSessionSnapshot] = [:], requests: [RequestID: InteractionRequestSnapshot] = [:], presentation: PresentationSnapshot = PresentationSnapshot()) {
        self.sessions = sessions; self.requests = requests; self.presentation = presentation
    }
}

public struct RedactedSessionSnapshot: Sendable, Equatable {
    public let session: SessionRef
    public let title: String?
    public let pendingCount: Int
    public let pendingKinds: Set<InteractionRequestKind>

    public init(session: SessionRef, title: String? = nil, pendingCount: Int = 0, pendingKinds: Set<InteractionRequestKind> = []) {
        self.session = session; self.title = title; self.pendingCount = pendingCount; self.pendingKinds = pendingKinds
    }
}

public struct RedactedInteractionSnapshot: Sendable, Equatable {
    public let sessions: [SessionRef: RedactedSessionSnapshot]
    public let requests: [RequestID: RedactedRequestSnapshot]
    public let presentation: RedactedPresentationSnapshot

    public init(sessions: [SessionRef: RedactedSessionSnapshot] = [:], requests: [RequestID: RedactedRequestSnapshot] = [:], presentation: RedactedPresentationSnapshot = RedactedPresentationSnapshot()) {
        self.sessions = sessions; self.requests = requests; self.presentation = presentation
    }
}

public struct InteractionSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let local: LocalInteractionSnapshot
    public let external: RedactedInteractionSnapshot

    public init(revision: UInt64 = 0, local: LocalInteractionSnapshot = LocalInteractionSnapshot(), external: RedactedInteractionSnapshot = RedactedInteractionSnapshot()) {
        self.revision = revision; self.local = local; self.external = external
    }
}

public protocol LocalInteractionReader {
    var value: LocalInteractionSnapshot { get }
}

public protocol ExternalInteractionReader {
    var value: RedactedInteractionSnapshot { get }
}

public enum PresentationPolicyMode: Sendable, Equatable, Codable {
    case legacyProminent
    case adaptiveCLIFirst
}

public struct PresentationPolicy: Sendable, Equatable {
    public let mode: PresentationPolicyMode
    public let visibilityMaxAge: Duration

    public init(mode: PresentationPolicyMode = .legacyProminent, visibilityMaxAge: Duration = .seconds(5)) {
        self.mode = mode; self.visibilityMaxAge = visibilityMaxAge
    }
}

public struct TerminalLedgerPolicy: Sendable, Equatable {
    public let maxEntries: Int
    public let retention: Duration

    public init(maxEntries: Int = 256, retention: Duration = .seconds(300)) {
        self.maxEntries = max(1, maxEntries); self.retention = retention
    }
}

public enum AutoCompileError: Sendable, Equatable, Codable, Error {
    case unavailable
    case independentChannelRequired
    case bypassNotPermitted
}

public struct LegacyRequestView: Sendable, Equatable {
    public let id: RequestID
    public let kind: InteractionRequestKind
    public let isPending: Bool

    public init(id: RequestID, kind: InteractionRequestKind, isPending: Bool) {
        self.id = id; self.kind = kind; self.isPending = isPending
    }
}
