import Foundation

/// Pure, lenient JSON → model decoding for the dsh web API.
/// Unknown fields are ignored; missing fields get defaults; rows that fail to
/// decode are skipped without throwing.
public enum DSHDecode {

    /// Canonical session ids are `session-<uuid>`; subagent rows in
    /// `session.list` arrive with a bare UUID and are normalized here.
    /// Live-server verified (2026-08-24): 60 of 65 rows prefixed, the 5
    /// `origin:"subagent"` rows bare.
    public static func normalizeSessionId(_ raw: String) -> String {
        raw.hasPrefix("session-") ? raw : "session-" + raw
    }

    /// Decode the `value` of `session.list` (`{"items":[...]}`).
    /// Garbage rows are skipped.
    public static func sessions(fromValue data: Data) -> [SessionSummary] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        let rows = (obj["items"] as? [Any]) ?? []
        return rows.compactMap { $0 as? [String: Any] }.compactMap(rowToSession)
    }

    static func rowToSession(_ row: [String: Any]) -> SessionSummary? {
        guard let rawId = row["sessionId"] as? String, !rawId.isEmpty else { return nil }
        let updatedAtMs = row["updatedAt"] as? Double
            ?? (row["updatedAt"] as? NSNumber)?.doubleValue
            ?? 0
        let values = ((row["projections"] as? [String: Any])?["values"] as? [String: Any]) ?? [:]
        let title = values["title"] as? String
        let origin = row["origin"] as? String
        let parent = (row["parentSessionId"] as? String).map(normalizeSessionId)
        return SessionSummary(
            id: normalizeSessionId(rawId),
            title: (title?.isEmpty == true) ? nil : title,
            running: row["running"] as? Bool ?? false,
            blank: row["blank"] as? Bool ?? false,
            updatedAt: Date(timeIntervalSince1970: updatedAtMs / 1000),
            cwd: row["cwd"] as? String,
            agentPreset: row["agentPreset"] as? String,
            parentSessionId: parent,
            isSubagent: origin == "subagent" || parent != nil
        )
    }

    /// Decode the `value` of `workspace.list`
    /// (`{"items":[...],"archivedSessionIds":[...]}`).
    public static func workspaces(fromValue data: Data) -> (items: [Workspace], archivedSessionIds: [String]) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ([], [])
        }
        let rows = (obj["items"] as? [Any]) ?? []
        let items = rows.compactMap { $0 as? [String: Any] }.compactMap(rowToWorkspace)
        let archived = ((obj["archivedSessionIds"] as? [Any])?.compactMap { $0 as? String }) ?? []
        return (items, archived)
    }

    static func rowToWorkspace(_ row: [String: Any]) -> Workspace? {
        guard let id = row["workspaceId"] as? String, !id.isEmpty else { return nil }
        let sessionIds = ((row["sessionIds"] as? [Any])?.compactMap { $0 as? String }) ?? []
        return Workspace(
            id: id,
            path: row["path"] as? String ?? "",
            title: row["title"] as? String ?? "",
            sessionIds: sessionIds.map(normalizeSessionId),
            createdAt: isoDate(row["createdAt"]),
            updatedAt: isoDate(row["updatedAt"])
        )
    }

    /// Decode the `value` of `host.describe`.
    public static func hostInfo(fromValue data: Data) -> HostInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return HostInfo(
            version: obj["version"] as? String,
            cwd: obj["cwd"] as? String,
            provider: obj["provider"] as? String,
            model: obj["model"] as? String,
            attachedSessions: obj["attachedSessions"] as? Int,
            home: obj["home"] as? String,
            canOpenPath: obj["canOpenPath"] as? Bool
        )
    }

    /// Decode the `value` of `session.create` (`{"sessionId": ...}`).
    public static func sessionId(fromValue data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sid = obj["sessionId"] as? String, !sid.isEmpty else { return nil }
        return normalizeSessionId(sid)
    }

    static func isoDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
}
