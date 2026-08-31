import Foundation

public enum AppleCompanionStatus: String, Codable, Equatable, Sendable {
    case idle
    case processing
    case running
    case waitingApproval
    case waitingQuestion

    public init(_ status: AgentStatus) {
        switch status {
        case .idle: self = .idle
        case .processing: self = .processing
        case .running: self = .running
        case .waitingApproval: self = .waitingApproval
        case .waitingQuestion: self = .waitingQuestion
        }
    }
}

public enum AppleCompanionPendingAction: String, Codable, Equatable, Sendable {
    case approval
    case question
}

public enum AppleCompanionMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

public struct AppleCompanionMessagePreview: Codable, Equatable, Sendable {
    public let role: AppleCompanionMessageRole
    public let text: String

    public init(role: AppleCompanionMessageRole, text: String) {
        self.role = role
        self.text = text
    }
}

public struct AppleCompanionQuestionPayload: Codable, Equatable, Sendable {
    public let header: String?
    public let question: String
    public let options: [String]
    public let descriptions: [String]
    public let index: Int
    public let total: Int
    public let allowsMultipleSelection: Bool

    public init(
        header: String?,
        question: String,
        options: [String],
        descriptions: [String],
        index: Int,
        total: Int,
        allowsMultipleSelection: Bool
    ) {
        self.header = header
        self.question = question
        self.options = options
        self.descriptions = descriptions
        self.index = index
        self.total = total
        self.allowsMultipleSelection = allowsMultipleSelection
    }
}

public struct AppleCompanionSessionPreview: Codable, Equatable, Sendable {
    public let sessionId: String?
    public let source: String
    public let status: AppleCompanionStatus
    public let toolName: String?
    public let workspaceName: String?
    public let message: String?
    /// 该会话最近若干条消息（含角色），用于在伴侣端逐会话显示多轮转写。
    /// 向后兼容：旧客户端无此字段时按空数组处理。
    public let messages: [AppleCompanionMessagePreview]
    public let updatedAt: Date

    public init(
        sessionId: String?,
        source: String,
        status: AppleCompanionStatus,
        toolName: String?,
        workspaceName: String?,
        message: String?,
        messages: [AppleCompanionMessagePreview] = [],
        updatedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.source = source
        self.status = status
        self.toolName = toolName
        self.workspaceName = workspaceName
        self.message = message
        self.messages = messages
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, source, status, toolName, workspaceName, message, messages, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        source = try c.decode(String.self, forKey: .source)
        status = try c.decode(AppleCompanionStatus.self, forKey: .status)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        workspaceName = try c.decodeIfPresent(String.self, forKey: .workspaceName)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        messages = try c.decodeIfPresent([AppleCompanionMessagePreview].self, forKey: .messages) ?? []
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

public struct AppleCompanionStatePayload: Codable, Equatable, Sendable {
    public let version: Int
    /// Additive protocol fields. `version` remains the v1 field used by
    /// shipped companion builds; new peers use the explicit major/minor pair
    /// so an unknown major can be rejected before an action is dispatched.
    public let protocolMajor: Int?
    public let protocolMinor: Int?
    public let sequence: UInt64
    public let sessionId: String?
    public let source: String
    public let status: AppleCompanionStatus
    public let toolName: String?
    public let workspaceName: String?
    public let messages: [AppleCompanionMessagePreview]
    public let pendingAction: AppleCompanionPendingAction?
    public let pendingRequestID: RequestID?
    public let pendingRequestKind: InteractionRequestKind?
    public let sessionGeneration: UInt64?
    public let lastAcceptedSequence: UInt64?
    public let question: AppleCompanionQuestionPayload?
    public let sessions: [AppleCompanionSessionPreview]
    public let updatedAt: Date

    public init(
        version: Int = 1,
        protocolMajor: Int? = nil,
        protocolMinor: Int? = nil,
        sequence: UInt64,
        sessionId: String?,
        source: String,
        status: AppleCompanionStatus,
        toolName: String?,
        workspaceName: String?,
        messages: [AppleCompanionMessagePreview],
        pendingAction: AppleCompanionPendingAction?,
        pendingRequestID: RequestID? = nil,
        pendingRequestKind: InteractionRequestKind? = nil,
        sessionGeneration: UInt64? = nil,
        lastAcceptedSequence: UInt64? = nil,
        question: AppleCompanionQuestionPayload? = nil,
        sessions: [AppleCompanionSessionPreview] = [],
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.sequence = sequence
        self.sessionId = sessionId
        self.source = source
        self.status = status
        self.toolName = toolName
        self.workspaceName = workspaceName
        self.messages = messages
        self.pendingAction = pendingAction
        self.pendingRequestID = pendingRequestID
        self.pendingRequestKind = pendingRequestKind
        self.sessionGeneration = sessionGeneration
        self.lastAcceptedSequence = lastAcceptedSequence
        self.question = question
        self.sessions = sessions
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case protocolMajor
        case protocolMinor
        case sequence
        case sessionId
        case source
        case status
        case toolName
        case workspaceName
        case messages
        case pendingAction
        case pendingRequestID
        case pendingRequestKind
        case sessionGeneration
        case lastAcceptedSequence
        case question
        case sessions
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        protocolMajor = try container.decodeIfPresent(Int.self, forKey: .protocolMajor)
        protocolMinor = try container.decodeIfPresent(Int.self, forKey: .protocolMinor)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        source = try container.decode(String.self, forKey: .source)
        status = try container.decode(AppleCompanionStatus.self, forKey: .status)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        workspaceName = try container.decodeIfPresent(String.self, forKey: .workspaceName)
        messages = try container.decode([AppleCompanionMessagePreview].self, forKey: .messages)
        pendingAction = try container.decodeIfPresent(AppleCompanionPendingAction.self, forKey: .pendingAction)
        pendingRequestID = try container.decodeIfPresent(RequestID.self, forKey: .pendingRequestID)
        pendingRequestKind = try container.decodeIfPresent(InteractionRequestKind.self, forKey: .pendingRequestKind)
        sessionGeneration = try container.decodeIfPresent(UInt64.self, forKey: .sessionGeneration)
        lastAcceptedSequence = try container.decodeIfPresent(UInt64.self, forKey: .lastAcceptedSequence)
        question = try container.decodeIfPresent(AppleCompanionQuestionPayload.self, forKey: .question)
        sessions = try container.decodeIfPresent([AppleCompanionSessionPreview].self, forKey: .sessions) ?? []
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public var effectiveMajor: Int { protocolMajor ?? version }
    public var effectiveMinor: Int { protocolMinor ?? 0 }

    /// Build the companion state exclusively from the external (redacted)
    /// projection. This initializer intentionally has no local snapshot or
    /// provider payload parameter, making it impossible for a publisher to
    /// accidentally bypass the privacy boundary.
    public init(sequence: UInt64, snapshot: RedactedInteractionSnapshot, updatedAt: Date = Date()) {
        let target = snapshot.presentation.prominentRequest.flatMap { snapshot.requests[$0] }
        let session = target.flatMap { snapshot.sessions[$0.session] }
        let waitingKind = target?.kind
        self.init(
            version: 1,
            protocolMajor: 1,
            protocolMinor: 0,
            sequence: sequence,
            sessionId: target?.session.key.providerSessionID,
            source: target?.session.key.provider.rawValue ?? "codeisland",
            status: waitingKind == .permission ? .waitingApproval : waitingKind == .question ? .waitingQuestion : .idle,
            toolName: nil,
            workspaceName: session?.title ?? target?.title,
            messages: [],
            pendingAction: waitingKind.map { $0 == .permission ? .approval : .question },
            pendingRequestID: target?.id,
            pendingRequestKind: waitingKind,
            sessionGeneration: target?.session.generation,
            lastAcceptedSequence: nil,
            question: nil,
            sessions: snapshot.sessions.values.sorted { $0.session.generation < $1.session.generation }.map {
                AppleCompanionSessionPreview(
                    sessionId: $0.session.key.providerSessionID,
                    source: $0.session.key.provider.rawValue,
                    status: $0.pendingKinds.contains(.permission) ? .waitingApproval
                        : $0.pendingKinds.contains(.question) ? .waitingQuestion : .idle,
                    toolName: nil,
                    workspaceName: $0.title,
                    message: nil,
                    updatedAt: updatedAt
                )
            },
            updatedAt: updatedAt
        )
    }
}

public enum AppleCompanionCommandType: String, Codable, Equatable, Hashable, Sendable {
    case requestCurrentState
    case approveCurrentPermission
    case denyCurrentPermission
    case skipCurrentQuestion
    case answerQuestion
    case focus
}

public struct AppleCompanionCommandPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let protocolMajor: Int?
    public let protocolMinor: Int?
    public let type: AppleCompanionCommandType
    public let sessionId: String?
    public let sessionGeneration: UInt64?
    public let requestID: RequestID?
    public let observedSequence: UInt64?
    public let source: String?
    public let answerKey: String?
    public let answer: String?

    public init(version: Int = 1, protocolMajor: Int? = nil, protocolMinor: Int? = nil,
                type: AppleCompanionCommandType, sessionId: String? = nil,
                sessionGeneration: UInt64? = nil, requestID: RequestID? = nil,
                observedSequence: UInt64? = nil, source: String? = nil,
                answerKey: String? = nil, answer: String? = nil) {
        self.version = version
        self.protocolMajor = protocolMajor
        self.protocolMinor = protocolMinor
        self.type = type
        self.sessionId = sessionId
        self.sessionGeneration = sessionGeneration
        self.requestID = requestID
        self.observedSequence = observedSequence
        self.source = source
        self.answerKey = answerKey
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey {
        case version, protocolMajor, protocolMinor, type, sessionId,
             sessionGeneration, requestID, observedSequence, source, answerKey, answer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        protocolMajor = try container.decodeIfPresent(Int.self, forKey: .protocolMajor)
        protocolMinor = try container.decodeIfPresent(Int.self, forKey: .protocolMinor)
        type = try container.decode(AppleCompanionCommandType.self, forKey: .type)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        sessionGeneration = try container.decodeIfPresent(UInt64.self, forKey: .sessionGeneration)
        requestID = try container.decodeIfPresent(RequestID.self, forKey: .requestID)
        observedSequence = try container.decodeIfPresent(UInt64.self, forKey: .observedSequence)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        answerKey = try container.decodeIfPresent(String.self, forKey: .answerKey)
        answer = try container.decodeIfPresent(String.self, forKey: .answer)
    }

    public var effectiveMajor: Int { protocolMajor ?? version }
    public var effectiveMinor: Int { protocolMinor ?? 0 }
}
