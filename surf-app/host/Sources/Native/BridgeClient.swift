import Foundation

/// 桥客户端：壳这一侧的 `/surf/bridge`。
///
/// 一条 WebSocket，JSON 文本帧，**未知帧一律忽略不崩**（协议向前兼容：新版桥加帧型不会打死旧壳）。
/// 断线指数退避重连；重连成功后调用方会重新拉一次 snapshot——桥对客户端零状态，
/// 所以"重连=重新握手+重新拉全量"永远是安全动作。
@MainActor
final class BridgeClient {
    /// 桥协议版本，必须与 surf-bridge 的 `PROTOCOL_VERSION` 一致。
    static let protocolVersion = 1

    /// 桥这一侧的失败分类。**以前这些全是静默退避**——连不上就每 0.5s 翻倍地
    /// 重试，界面与诊断面板对此一无所知。连接状态机要拿它区分
    /// "后端整个不见了"（HTTP 也连不上）与"后端在但桥不通"（`.bridgeRejected`）。
    enum Failure: Equatable, Sendable {
        /// WS 建连就被拒（或 hello 之前就断了）。
        case handshakeRejected(String)
        /// WS 通了，但服务端在超时内没回 hello。
        case helloTimeout
        /// 已经握过手，之后掉线。
        case connectionLost(String)
    }

    /// 收到一帧（已解析成字典）。
    var onFrame: (([String: Any]) -> Void)?
    /// 连接状态变化（true = 已握手）。
    var onConnected: ((Bool) -> Void)?
    /// 失败上报。**只报事实，不改行为**：退避重连照旧由本类自己走。
    var onFailure: ((Failure) -> Void)?

    private(set) var isConnected = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var url: URL?
    private var retry = 0
    private var reconnectWork: DispatchWorkItem?
    private var stopped = true
    private let clientId = UUID().uuidString
    /// 本次连接尝试有没有收到过 hello。区分"握手被拒"与"握手后掉线"用它。
    private var handshaken = false
    private var helloTimeoutWork: DispatchWorkItem?
    /// hello 等多久算超时。只用于上报（诊断面板那一行），不触发任何动作。
    private let helloTimeout: TimeInterval = 5

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
        helloTimeoutWork?.cancel()
        helloTimeoutWork = nil
        handshaken = false
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
                Log.write("桥发送失败：\(error.localizedDescription)", to: SurfPaths.logURL, tag: "bridge")
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
        handshaken = false
        task.resume()
        receive()
        armHelloTimeout()
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
                              to: SurfPaths.logURL, tag: "bridge")
                    // 握过手 = 掉线；没握过 = 压根没连上（对状态机是两回事）。
                    self.onFailure?(self.handshaken
                        ? .connectionLost(error.localizedDescription)
                        : .handshakeRejected(error.localizedDescription))
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
            handshaken = true
            helloTimeoutWork?.cancel()
            helloTimeoutWork = nil
            setConnected(true)
        }
        onFrame?(frame)
    }

    private func setConnected(_ value: Bool) {
        guard isConnected != value else { return }
        isConnected = value
        onConnected?(value)
    }

    /// WS 通了但服务端迟迟不回 hello：只上报一次，不动重连逻辑
    /// （那种情形下退避重连帮不上忙，摊开事实比瞎重试有用）。
    private func armHelloTimeout() {
        helloTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, !self.handshaken else { return }
            Log.write("桥 hello 超时（\(Int(self.helloTimeout))s）", to: SurfPaths.logURL, tag: "bridge")
            self.onFailure?(.helloTimeout)
        }
        helloTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + helloTimeout, execute: work)
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
