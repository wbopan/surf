import Foundation
import DSHKit

// dshkit-cli — M2 acceptance vehicle.
// Usage: swift run dshkit-cli --base http://127.0.0.1:50241

func parseBaseURL() -> URL? {
    var args = CommandLine.arguments.dropFirst()
    var base: String?
    while let arg = args.popFirst() {
        if arg == "--base", let next = args.popFirst() {
            base = next
        } else if arg.hasPrefix("--base=") {
            base = String(arg.dropFirst("--base=".count))
        }
    }
    return base.flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:50241")
}

func relativeTime(_ date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    switch s {
    case ..<60: return "\(s)s ago"
    case ..<3600: return "\(s / 60)m ago"
    case ..<86400: return "\(s / 3600)h ago"
    default: return "\(s / 86400)d ago"
    }
}

@MainActor func statusMark(_ store: SessionStore, _ id: String) -> String {
    switch store.status(of: id) {
    case .running: return "●running"
    case .pendingApproval: return "●approval"
    case .pendingQuestion: return "●question"
    case .idle: return "○idle"
    }
}

guard let base = parseBaseURL() else {
    FileHandle.standardError.write("invalid --base URL\n".data(using: .utf8)!)
    exit(2)
}

let transport = DSHTransportFactory.live(baseURL: base)
let store = SessionStore(transport: transport)

var generation = 0
@MainActor func render(store: SessionStore) {
    generation += 1
    var out = "\u{1B}[2J\u{1B}[H]dshkit-cli — \(base.absoluteString)  (update #\(generation))\n"
    if let host = store.host {
        out += "host: v\(host.version ?? "?")  provider=\(host.provider ?? "?")  model=\(host.model ?? "?")"
        out += "  attached=\(host.attachedSessions.map(String.init) ?? "?")\n"
    }
    out += "────────────────────────────────────────────────\n"
    if store.groups.isEmpty {
        out += "(no sessions)\n"
    }
    for group in store.groups {
        out += "▸ \(group.title)  (\(group.sessions.count))\n"
        for s in group.sessions {
            let title = s.title ?? (s.blank ? "(blank)" : "(untitled)")
            let flags = [s.isSubagent ? "sub" : nil].compactMap { $0 }.joined(separator: ",")
            let suffix = flags.isEmpty ? "" : "  [\(flags)]"
            out += "    \(statusMark(store, s.id))  \(title)\(suffix) — \(relativeTime(s.updatedAt))\n"
        }
    }
    out += "\n(subscribed to events; Ctrl-C to exit)\n"
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
}

store.onContentChange = { render(store: store) }

await store.start()

// Keep the process alive; default SIGINT handling terminates on Ctrl-C.
while !Task.isCancelled {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}
