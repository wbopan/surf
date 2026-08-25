import Foundation

/// Abstract client for the dsh web API. Base URL and auth headers are injected;
/// no loopback assumption lives here.
public protocol DSHTransport: Sendable {
    /// Perform a unary `POST {base}/api/<method>` call; returns the JSON data
    /// of the success envelope's `result.value`. Throws `DSHWireError` on
    /// transport / envelope / business errors.
    func call(_ method: String, payload: Data) async throws -> Data

    /// Open (or observe) a downlink event stream with automatic reconnection
    /// (exponential backoff, 1s → 30s cap). The client never sends frames.
    /// Each call opens its own connection; multiple clients are supported.
    func stream(_ kind: DSHEventStreamKind) -> AsyncStream<DSHStreamEvent>
}

public enum DSHTransportFactory {

    /// Build the live transport.
    /// - Parameters:
    ///   - baseURL: e.g. `http://127.0.0.1:50241` (any host; not just loopback).
    ///   - extraHeaders: reserved auth-header mounting point, re-evaluated per
    ///     request; unused in phase 1.
    public static func live(baseURL: URL,
                            extraHeaders: @escaping @Sendable () -> [String: String] = { [:] })
        -> any DSHTransport {
        LiveDSHTransport(baseURL: baseURL, extraHeadersProvider: extraHeaders)
    }
}

/// URLSession-backed live transport.
public final class LiveDSHTransport: DSHTransport, @unchecked Sendable {

    private let baseURL: URL
    private let extraHeadersProvider: @Sendable () -> [String: String]
    private let session: URLSession

    /// Separate URLSession for WebSockets so stream timeouts never interfere
    /// with unary calls (long-lived streams must never time out).
    private let wsSession: URLSession

    public init(baseURL: URL,
                extraHeadersProvider: @escaping @Sendable () -> [String: String] = { [:] },
                urlSession: URLSession? = nil) {
        self.baseURL = baseURL
        self.extraHeadersProvider = extraHeadersProvider
        self.session = urlSession ?? URLSession(configuration: .ephemeral)

        let wsConfig = URLSessionConfiguration.default
        wsConfig.timeoutIntervalForRequest = 0
        wsConfig.timeoutIntervalForResource = TimeInterval(Int.max)
        self.wsSession = URLSession(configuration: wsConfig)
    }

    public func call(_ method: String, payload: Data) async throws -> Data {
        guard let url = URL(string: "/api/\(method)", relativeTo: baseURL),
              let body = DSHWire.makeRequestBody(method: method, payloadJSON: payload,
                                                 rpcId: rpcId()) else {
            throw DSHWireError.badEnvelope
        }
        var request = URLRequest(url: url.absoluteURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeadersProvider() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DSHWireError.server(code: "transport", message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw DSHWireError.httpStatus(status)
        }
        let rpcId = rpcIdFromRequest(request)
        return try DSHWire.unwrapEnvelope(data, expectedRpcId: rpcId).get()
    }

    public func stream(_ kind: DSHEventStreamKind) -> AsyncStream<DSHStreamEvent> {
        let url = webSocketURL(kind)
        return AsyncStream { continuation in
            let task = Task { [wsSession] in
                var consecutiveFailures = 0
                var hadDrop = false
                while !Task.isCancelled {
                    let ws = wsSession.webSocketTask(with: url)
                    ws.resume()
                    var gotFrame = false
                    receiveLoop: while !Task.isCancelled {
                        let message: URLSessionWebSocketTask.Message
                        do {
                            message = try await ws.receive()
                        } catch {
                            break receiveLoop // socket closed / errored — reconnect
                        }
                        if !gotFrame {
                            gotFrame = true
                            consecutiveFailures = 0
                            if hadDrop {
                                hadDrop = false
                                continuation.yield(DSHStreamEvent.reconnected)
                            }
                        }
                        if case .string(let text) = message,
                           let data = text.data(using: .utf8),
                           let event = DSHWire.decodeFrame(data) {
                            continuation.yield(.event(event))
                        }
                    }
                    ws.cancel(with: .goingAway, reason: nil)
                    if Task.isCancelled { break }
                    hadDrop = hadDrop || gotFrame
                    consecutiveFailures += 1
                    let delay = min(pow(2.0, Double(consecutiveFailures - 1)), 30.0)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func rpcId() -> String { UUID().uuidString.lowercased() }

    private func rpcIdFromRequest(_ request: URLRequest) -> String {
        guard let body = request.httpBody,
              let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let id = obj["rpcId"] as? String else {
            return ""
        }
        return id
    }

    private func webSocketURL(_ kind: DSHEventStreamKind) -> URL {
        var components = URLComponents(url: baseURL.absoluteURL, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        components.path = kind.path
        components.query = nil
        switch components.scheme {
        case "https": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        return components.url ?? baseURL.appendingPathComponent(kind.path)
    }
}
