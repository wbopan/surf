import Foundation

/// 桥客户端：壳这一侧的 `/clam/bridge`。
///
/// 一条 WebSocket，JSON 文本帧，**未知帧一律忽略不崩**（协议向前兼容：新版桥加帧型不会打死旧壳）。
/// 断线指数退避重连；重连成功后调用方会重新拉一次 snapshot——桥对客户端零状态，
/// 所以"重连=重新握手+重新拉全量"永远是安全动作。
@MainActor
final class BridgeClient {
    /// 桥协议版本，必须与 clam-bridge 的 `PROTOCOL_VERSION` 一致。
    static let protocolVersion = 1

    /// 收到一帧（已解析成字典）。
    var onFrame: (([String: Any]) -> Void)?
    /// 连接状态变化（true = 已握手）。
    var onConnected: ((Bool) -> Void)?

    private(set) var isConnected = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var url: URL?
    private var retry = 0
    private var reconnectWork: DispatchWorkItem?
    private var stopped = true
    private let clientId = UUID().uuidString

    // MARK: - 生命周期

    func start(baseURL: URL, path: String) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.path = path
        components.query = nil
        guard let url = components.url else { return }
        self.url = url
        stopped = false
        retry = 0
        connect()
    }

    func stop() {
        stopped = true
        reconnectWork?.cancel()
        reconnectWork = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
        setConnected(false)
    }

    // MARK: - 发送

    func send(_ frame: [String: Any]) {
        guard let task, isConnected || frame["type"] as? String == "hello" else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error {
                Log.write("桥发送失败：\(error.localizedDescription)", to: ClamPaths.logURL, tag: "bridge")
            }
        }
    }

    // MARK: - 连接

    private func connect() {
        guard !stopped, let url else { return }
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
        // 握手首帧。服务端回 hello 之后才算连上（isConnected）。
        send(["type": "hello",
              "protocolVersion": Self.protocolVersion,
              "appVersion": AppInfo.buildTimestamp,
              "clientId": clientId])
    }

    private func receive() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                switch result {
                case .success(let message):
                    self.dispatch(message)
                    self.receive()
                case .failure(let error):
                    Log.write("桥连接中断：\(error.localizedDescription)",
                              to: ClamPaths.logURL, tag: "bridge")
                    self.setConnected(false)
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func dispatch(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw): data = raw
        @unknown default: data = nil
        }
        guard let data,
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return } // 坏帧忽略

        if frame["type"] as? String == "hello" {
            retry = 0
            setConnected(true)
        }
        onFrame?(frame)
    }

    private func setConnected(_ value: Bool) {
        guard isConnected != value else { return }
        isConnected = value
        onConnected?(value)
    }

    /// 指数退避：0.5s 起，翻倍封顶 8s。
    private func scheduleReconnect() {
        guard !stopped, reconnectWork == nil else { return }
        task?.cancel()
        task = nil
        session = nil
        let delay = min(8.0, 0.5 * pow(2.0, Double(retry)))
        retry += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            self.connect()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
