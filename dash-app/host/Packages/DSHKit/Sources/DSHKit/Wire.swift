import Foundation

/// Errors surfaced by the wire layer.
public enum DSHWireError: Error, Equatable, Sendable {
    case httpStatus(Int)
    /// Body was not a valid `server-response` envelope.
    case badEnvelope
    case rpcIdMismatch(expected: String, actual: String?)
    /// Business error (`result.ok == false`).
    case server(code: String, message: String)
}

/// The server's own message is the only text worth showing a human (it carries
/// e.g. the duplicate-workspace-name explanation); the transport-level cases
/// stay terse and English — they are bugs, not user-facing conditions.
extension DSHWireError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP \(code)"
        case .badEnvelope: return "Malformed server response"
        case .rpcIdMismatch: return "Mismatched RPC id"
        case .server(_, let message): return message
        }
    }
}

/// Pure wire-format helpers: request-body construction, envelope unwrapping,
/// and event-frame decoding. No I/O — fully unit-testable.
public enum DSHWire {

    /// Build the `client-request` JSON body for a unary call.
    public static func makeRequestBody(method: String, payloadJSON: Data, rpcId: String) -> Data? {
        guard let payload = (try? JSONSerialization.jsonObject(with: payloadJSON)) as? [String: Any] else {
            return nil
        }
        let body: [String: Any] = [
            "type": "client-request",
            "rpcId": rpcId,
            "method": method,
            "payload": payload
        ]
        return try? JSONSerialization.data(withJSONObject: body)
    }

    /// Unwrap a `server-response` envelope. On success returns the JSON data of
    /// `result.value`; verifies the rpcId echo.
    public static func unwrapEnvelope(_ data: Data, expectedRpcId: String) -> Result<Data, DSHWireError> {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String == "server-response",
              let result = obj["result"] as? [String: Any] else {
            return .failure(.badEnvelope)
        }
        let echoed = obj["rpcId"] as? String
        guard echoed == expectedRpcId else {
            return .failure(.rpcIdMismatch(expected: expectedRpcId, actual: echoed))
        }
        guard result["ok"] as? Bool == true else {
            let error = result["error"] as? [String: Any]
            let code = error?["code"] as? String ?? "unknown"
            let message = error?["message"] as? String ?? "Unknown server error"
            return .failure(.server(code: code, message: message))
        }
        guard let value = result["value"] else {
            return .failure(.badEnvelope)
        }
        guard let valueData = try? JSONSerialization.data(withJSONObject: value) else {
            return .failure(.badEnvelope)
        }
        return .success(valueData)
    }

    /// Decode one downlink WebSocket text frame into a `ServerEvent`.
    /// Returns nil for unparseable frames (skipped, never crashes).
    public static func decodeFrame(_ data: Data) -> ServerEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = obj["method"] as? String else {
            return nil
        }
        let payload = obj["payload"] as? [String: Any] ?? [:]
        switch method {
        case "session/event":
            guard let sid = payload["sessionId"] as? String else { return nil }
            let event = payload["event"] as? [String: Any] ?? [:]
            guard let type = event["type"] as? String else { return nil }
            let seq = event["seq"] as? Int
            return .sessionEvent(sessionId: DSHDecode.normalizeSessionId(sid), type: type, seq: seq)
        case "approval/requested":
            let sid = (payload["sessionId"] as? String).map(DSHDecode.normalizeSessionId)
            return .approvalRequested(sessionId: sid)
        case "question/requested":
            let sid = (payload["sessionId"] as? String).map(DSHDecode.normalizeSessionId)
            return .questionRequested(sessionId: sid)
        case "host/session-status":
            guard let sid = payload["sessionId"] as? String,
                  let running = payload["running"] as? Bool else { return nil }
            return .hostSessionStatus(sessionId: DSHDecode.normalizeSessionId(sid), running: running)
        case "host/agent-error":
            let message = payload["message"] as? String ?? "unknown agent error"
            let sid = (payload["sessionId"] as? String).map(DSHDecode.normalizeSessionId)
            return .hostAgentError(sessionId: sid, message: message)
        default:
            return .unknown(method: method)
        }
    }
}
