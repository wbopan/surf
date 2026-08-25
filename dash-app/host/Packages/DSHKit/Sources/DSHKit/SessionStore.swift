import Foundation
// Swift 6 起 @Published/ObservableObject 必须显式 import Combine
// （以前靠 Foundation 的隐式重导出）。
import Combine

/// MainActor mirror of the harness session/workspace state, kept fresh via the
/// two downlink event streams. iOS-ready: only Foundation + Combine-free
/// ObservableObject (NSObject-free; @Published works on all platforms).
@MainActor
public final class SessionStore: ObservableObject {

    public let transport: any DSHTransport

    /// Full snapshot of sessions (archived filtered out).
    @Published public private(set) var flatSessions: [SessionSummary] = []
    /// Grouped view: workspaces in listed order, then a synthetic "Other" group.
    @Published public private(set) var groups: [SessionGroup] = []
    @Published public private(set) var host: HostInfo?
    @Published public private(set) var lastFullRefresh: Date?

    public static let otherGroupID = "dshkit.other"

    /// Invoked on the main actor after every committed state change (used by
    /// non-Combine consumers such as the CLI).
    public var onContentChange: (@MainActor () -> Void)?

    /// Sessions (canonical ids) currently waiting for approval / answer.
    @Published public private(set) var pendingApproval: Set<String> = []
    @Published public private(set) var pendingQuestion: Set<String> = []

    private var sessionsById: [String: SessionSummary] = [:]
    private var archivedIds: Set<String> = []
    private var workspaces: [Workspace] = []
    private var streamTasks: [Task<Void, Never>] = []
    private var refetchTask: Task<Void, Never>?
    private var started = false

    /// Debounce window for coalescing `session/event` bursts into one refetch.
    public var refetchDebounce: Duration = .milliseconds(400)

    public init(transport: any DSHTransport) {
        self.transport = transport
    }

    // MARK: - Lifecycle

    /// Fetch host.describe + session.list + workspace.list, then subscribe to
    /// both event streams. Safe to call once; idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        await refreshAll()
        streamTasks.append(Task { [weak self] in await self?.pump(.mux) })
        streamTasks.append(Task { [weak self] in await self?.pump(.host) })
    }

    public func stop() {
        streamTasks.forEach { $0.cancel() }
        streamTasks.removeAll()
        refetchTask?.cancel()
        refetchTask = nil
        started = false
    }

    // MARK: - Status

    /// Status dot precedence: pendingApproval > pendingQuestion > running > idle.
    public func status(of sessionID: String) -> SessionStatus {
        let id = DSHDecode.normalizeSessionId(sessionID)
        if pendingApproval.contains(id) { return .pendingApproval }
        if pendingQuestion.contains(id) { return .pendingQuestion }
        if sessionsById[id]?.running == true { return .running }
        return .idle
    }

    public func session(id: String) -> SessionSummary? {
        sessionsById[DSHDecode.normalizeSessionId(id)]
    }

    // MARK: - Actions

    @discardableResult
    public func createSession(workspaceId: String? = nil,
                              cwd: String? = nil,
                              agentPreset: String? = nil) async throws -> String {
        var payload: [String: Any] = [:]
        if let workspaceId {
            payload["workspaceId"] = workspaceId
        } else if let cwd {
            payload["cwd"] = cwd
        } else {
            payload["cwd"] = FileManager.default.currentDirectoryPath
        }
        if let agentPreset { payload["agentPreset"] = agentPreset }
        let data = try await call("session.create", payload)
        guard let sid = DSHDecode.sessionId(fromValue: data) else {
            throw DSHWireError.badEnvelope
        }
        scheduleRefetch(immediate: true)
        return sid
    }

    public func renameSession(id: String, title: String) async throws {
        _ = try await call("session.rename", ["sessionId": DSHDecode.normalizeSessionId(id),
                                              "title": title])
        scheduleRefetch(immediate: true)
    }

    public func cancelSession(id: String) async throws {
        _ = try await call("session.cancel", ["sessionId": DSHDecode.normalizeSessionId(id)])
    }

    /// Archive a session (`workspace.archiveSession`, mirrors the web sidebar's
    /// row action). Non-destructive: the log stays; the row just disappears from
    /// every grouping surface. The response echoes the full updated archive set,
    /// which is applied locally for instant removal (same as the web echo path).
    public func archiveSession(id: String) async throws {
        let value = try await call("workspace.archiveSession",
                                   ["sessionId": DSHDecode.normalizeSessionId(id)])
        if let archived = DSHDecode.archivedSessionIds(fromValue: value) {
            archivedIds = Set(archived)
            rebuildGroups()
        } else {
            // Echo undecodable — fall back to a full list round.
            scheduleRefetch(immediate: true)
        }
    }

    // MARK: - Fetching

    private func refreshAll() async {
        // host.describe is best-effort; a failure must not block the mirror.
        if let value = try? await call("host.describe", [:]) {
            host = DSHDecode.hostInfo(fromValue: value)
        }
        await refetchLists()
        lastFullRefresh = Date()
    }

    /// Retry budget for one refetch round. Health-check passing does not imply
    /// `/api` is serving yet right after harness boot, so a failed round retries
    /// with exponential backoff (0.3s..2.4s, ~4.5s total) instead of going
    /// silently stale until the next stream event.
    private let refetchAttempts = 5

    private func refetchLists() async {
        var delay: Duration = .milliseconds(300)
        for attempt in 0..<refetchAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: delay)
                delay *= 2
                if Task.isCancelled { return }
            }
            guard let sessionsValue = try? await call("session.list", [:]),
                  let workspacesValue = try? await call("workspace.list", [:]) else {
                continue
            }
            let sessions = DSHDecode.sessions(fromValue: sessionsValue)
            let (wsItems, archived) = DSHDecode.workspaces(fromValue: workspacesValue)
            sessionsById = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            workspaces = wsItems
            archivedIds = Set(archived)
            rebuildGroups()
            return
        }
    }

    /// Debounced refetch: any session/event marks data dirty; one network
    /// round of session.list+workspace.list settles a burst.
    private func scheduleRefetch(immediate: Bool = false) {
        refetchTask?.cancel()
        if immediate {
            refetchTask = Task { [weak self] in
                guard let self else { return }
                if !Task.isCancelled { await self.refetchLists() }
                if !Task.isCancelled { self.lastFullRefresh = Date() }
            }
        } else {
            refetchTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.refetchDebounce)
                guard !Task.isCancelled else { return }
                await self.refetchLists()
                self.lastFullRefresh = Date()
            }
        }
    }

    // MARK: - Event streams

    private func pump(_ kind: DSHEventStreamKind) async {
        for await streamEvent in transport.stream(kind) {
            if Task.isCancelled { return }
            switch streamEvent {
            case .reconnected:
                // Missed frames while disconnected: full refetch.
                scheduleRefetch(immediate: true)
            case .event(let event):
                handle(event)
            }
        }
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .sessionEvent(let sessionId, _, _):
            // Any new event resolves pending approval/question heuristically
            // (the agent moved on / answer was consumed) and dirties the row.
            pendingApproval.remove(sessionId)
            pendingQuestion.remove(sessionId)
            scheduleRefetch()

        case .approvalRequested(let sessionId):
            if let sessionId {
                pendingApproval.insert(sessionId)
                commit()
            }

        case .questionRequested(let sessionId):
            if let sessionId {
                pendingQuestion.insert(sessionId)
                commit()
            }

        case .hostSessionStatus(let sessionId, let running):
            // Running flips apply immediately, in place, no refetch needed.
            if var s = sessionsById[sessionId] {
                s.running = running
                sessionsById[sessionId] = s
                rebuildGroups()
            } else {
                // Session we don't know yet — go get the list.
                scheduleRefetch()
            }
            if !running {
                // Turn end heuristic backup: pending dots clear when idle.
                pendingApproval.remove(sessionId)
                pendingQuestion.remove(sessionId)
                commit()
            }

        case .hostAgentError:
            break // informational; sidebar state unaffected

        case .unknown:
            break // defensive: future frame types ignored
        }
    }

    // MARK: - Grouping

    private func rebuildGroups() {
        var grouped = Set<String>()
        var result: [SessionGroup] = []
        for ws in workspaces {
            grouped.formUnion(ws.sessionIds)
            let sessions = ws.sessionIds.compactMap { id -> SessionSummary? in
                guard !archivedIds.contains(id), let s = sessionsById[id] else { return nil }
                return s
            }
            result.append(SessionGroup(id: ws.id,
                                       title: ws.title.isEmpty ? (ws.path as NSString).lastPathComponent : ws.title,
                                       workspaceId: ws.id,
                                       sessions: sessions))
        }
        let others = sessionsById.values
            .filter { !archivedIds.contains($0.id) && !grouped.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
        if !others.isEmpty {
            result.append(SessionGroup(id: Self.otherGroupID, title: "Other",
                                       workspaceId: nil, sessions: others))
        }
        groups = result
        commit()
    }

    /// Publish + notify. @Published mutation triggers objectWillChange; this
    /// also fires the plain callback for non-Combine consumers.
    private func commit() {
        flatSessions = groups.flatMap(\.sessions)
        onContentChange?()
    }

    // MARK: - Unary helper

    private func call(_ method: String, _ payload: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await transport.call(method, payload: data)
    }
}
