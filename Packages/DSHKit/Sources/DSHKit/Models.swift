import Foundation

/// Summary of a session as rendered in a sidebar list.
/// `id` is always the canonical `session-<uuid>` form (subagent rows arrive
/// with a bare UUID and are normalized on decode).
public struct SessionSummary: Sendable, Equatable, Identifiable {
    public let id: String
    /// Sidebar title: `projections.values.title`; nil for blank sessions.
    public var title: String?
    public var running: Bool
    public var blank: Bool
    public var updatedAt: Date
    public var cwd: String?
    public var agentPreset: String?
    public let parentSessionId: String?
    public let isSubagent: Bool

    public init(id: String,
                title: String?,
                running: Bool,
                blank: Bool,
                updatedAt: Date,
                cwd: String? = nil,
                agentPreset: String? = nil,
                parentSessionId: String? = nil,
                isSubagent: Bool = false) {
        self.id = id
        self.title = title
        self.running = running
        self.blank = blank
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.agentPreset = agentPreset
        self.parentSessionId = parentSessionId
        self.isSubagent = isSubagent
    }
}

/// A workspace (grouping) from `workspace.list`.
public struct Workspace: Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let title: String
    /// Display order of sessions inside this workspace.
    public let sessionIds: [String]
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(id: String, path: String, title: String, sessionIds: [String],
                createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.path = path
        self.title = title
        self.sessionIds = sessionIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A rendered sidebar group: a workspace plus its ordered sessions,
/// or the synthetic "Other" group for ungrouped sessions.
public struct SessionGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let workspaceId: String?
    public var sessions: [SessionSummary]

    public init(id: String, title: String, workspaceId: String?, sessions: [SessionSummary]) {
        self.id = id
        self.title = title
        self.workspaceId = workspaceId
        self.sessions = sessions
    }
}

/// Sidebar status dot for a session.
public enum SessionStatus: Sendable, Equatable {
    case running
    case pendingApproval
    case pendingQuestion
    case idle
}

/// Result of `host.describe`.
public struct HostInfo: Sendable, Equatable {
    public let version: String?
    public let cwd: String?
    public let provider: String?
    public let model: String?
    public let attachedSessions: Int?
    public let home: String?
    public let canOpenPath: Bool?

    public init(version: String? = nil, cwd: String? = nil, provider: String? = nil,
                model: String? = nil, attachedSessions: Int? = nil,
                home: String? = nil, canOpenPath: Bool? = nil) {
        self.version = version
        self.cwd = cwd
        self.provider = provider
        self.model = model
        self.attachedSessions = attachedSessions
        self.home = home
        self.canOpenPath = canOpenPath
    }
}

/// A decoded frame from a downlink event stream (`events.mux` / `events.host`).
/// Unknown frame types decode to `.unknown` instead of failing.
public enum ServerEvent: Sendable, Equatable {
    case sessionEvent(sessionId: String, type: String, seq: Int?)
    case approvalRequested(sessionId: String?)
    case questionRequested(sessionId: String?)
    case hostSessionStatus(sessionId: String, running: Bool)
    case hostAgentError(sessionId: String?, message: String)
    case unknown(method: String)
}

/// Which downlink stream to subscribe to.
public enum DSHEventStreamKind: String, Sendable {
    case mux
    case host

    var path: String {
        switch self {
        case .mux: return "/api/events.mux"
        case .host: return "/api/events.host"
        }
    }
}

/// What a `DSHTransport.stream` yields.
public enum DSHStreamEvent: Sendable, Equatable {
    case event(ServerEvent)
    /// Emitted after a connection drop once the socket is delivering frames
    /// again — the signal for consumers to refetch full state.
    case reconnected
}
