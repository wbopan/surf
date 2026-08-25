import AppKit
import Foundation
import UserNotifications

/// 订阅 dsh Web API 的事件流（/api/events.mux + /api/events.host），
/// 在应用非前台时发原生通知。断线指数退避重连，重连后不回填历史。
///
/// 帧协议（对照 dsh-client-connection 0.1.1-rc.2 源码确认）：
///   两条流都走 **WebSocket**（普通 GET 会收到 426 "upgrade required"；
///   进程内 apiproxy 的 SSE 是另一条传输路径，web profile 对外是 WS）。
///   每帧一个 JSON 文本消息：{ type: "server-request", rpcId, method: <帧型>, payload: <帧> }
///   纯下行：客户端发消息会被服务端以 1008 "downlink only" 关闭。
///   帧型：approval/requested、question/requested、session/event（mux）；
///         host/agent-error、host/session-status（host）。
final class EventsBridge: NSObject, UNUserNotificationCenterDelegate {
    private let port: Int
    private let session: URLSession
    private var muxTask: URLSessionWebSocketTask?
    private var hostTask: URLSessionWebSocketTask?
    private var stopped = false
    private var reconnectCount = 0
    private var reconnectWork: DispatchWorkItem?

    // host/session-status 跟踪：会话是否在运行
    private var sessionsRunning: [String: Bool] = [:]
    // 每会话"任务完成"通知冷却
    private var lastCompletionNotice: [String: Date] = [:]
    private let completionCooldown: TimeInterval = 300
    // 同一条 pending 批准/问题去重（重连会重放 pending）
    private var lastApprovalNotice: [String: Date] = [:]
    private var lastQuestionNotice: [String: Date] = [:]
    private let pendingCooldown: TimeInterval = 60

    init(port: Int) {
        self.port = port
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 0
        cfg.timeoutIntervalForResource = TimeInterval(Int.max)
        session = URLSession(configuration: cfg)
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - 生命周期

    func start() {
        stopped = false
        reconnectCount = 0
        connectMux()
        connectHost()
    }

    func stop() {
        stopped = true
        reconnectWork?.cancel()
        reconnectWork = nil
        muxTask?.cancel(with: .goingAway, reason: nil)
        muxTask = nil
        hostTask?.cancel(with: .goingAway, reason: nil)
        hostTask = nil
    }

    private var muxURL: URL { URL(string: "ws://127.0.0.1:\(port)/api/events.mux")! }
    private var hostURL: URL { URL(string: "ws://127.0.0.1:\(port)/api/events.host")! }

    private func connectMux() {
        guard !stopped else { return }
        let task = session.webSocketTask(with: muxURL)
        muxTask = task
        task.resume()
        receiveLoop(task)
    }

    private func connectHost() {
        guard !stopped else { return }
        let task = session.webSocketTask(with: hostURL)
        hostTask = task
        task.resume()
        receiveLoop(task)
    }

    /// 持续接收：成功则继续等下一帧；失败/关闭则调度重连。
    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.reconnectCount = 0 // 有帧到达 = 连接建立
                if case .string(let text) = message {
                    self.handleMessageText(text)
                }
                // 仅当还是当前任务时继续收（避免旧任务的收包循环）
                if !self.stopped, task === self.muxTask || task === self.hostTask {
                    self.receiveLoop(task)
                }
            case .failure:
                if !self.stopped {
                    self.scheduleReconnect()
                }
            }
        }
    }

    // MARK: - 帧解析

    private func handleMessageText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String,
              let payload = obj["payload"] as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in
            self?.handleFrame(method: method, payload: payload)
        }
    }

    // MARK: - 帧处理 → 通知

    private func handleFrame(method: String, payload: [String: Any]) {
        switch method {
        case "approval/requested":
            let approvalId = payload["approvalId"] as? String ?? UUID().uuidString
            if cooledDown(now: Date(), table: &lastApprovalNotice, key: approvalId) { return }
            let tool = payload["toolName"] as? String ?? ""
            let reason = payload["reason"] as? String ?? ""
            var body = ""
            if !tool.isEmpty { body += "工具：\(tool)" }
            if !reason.isEmpty { body += body.isEmpty ? reason : "\n\(reason)" }
            if body.isEmpty { body = "Harness 正在等待你的批准" }
            notify(id: "approval-\(approvalId)", title: "需要你的批准", body: body)

        case "question/requested":
            let questions = payload["questions"] as? [[String: Any]] ?? []
            let qid = questions.first?["id"] as? String ?? UUID().uuidString
            if cooledDown(now: Date(), table: &lastQuestionNotice, key: qid) { return }
            let question = questions.first?["question"] as? String ?? "Harness 正在等待你的回答"
            notify(id: "question-\(qid)", title: "需要你的回答", body: question)

        case "host/agent-error":
            let message = payload["message"] as? String ?? "未知错误"
            notify(id: "agent-error-\(UUID().uuidString)", title: "Agent 出错",
                   body: String(message.prefix(200)))

        case "host/session-status":
            let sid = payload["sessionId"] as? String ?? ""
            sessionsRunning[sid] = payload["running"] as? Bool ?? false

        case "session/event":
            handleSessionEvent(payload)

        default:
            break // 防御式：未知帧忽略
        }
    }

    private func handleSessionEvent(_ payload: [String: Any]) {
        guard let event = payload["event"] as? [String: Any],
              let type = event["type"] as? String else { return }
        let sid = payload["sessionId"] as? String ?? ""
        guard type == "turn/end" else { return }
        // 会话仍在运行（true）时是回合间暂停，不打扰；未知/已停止 → "任务完成"
        if sessionsRunning[sid] == true { return }
        let now = Date()
        if let last = lastCompletionNotice[sid], now.timeIntervalSince(last) < completionCooldown {
            return
        }
        lastCompletionNotice[sid] = now
        notify(id: "turn-end-\(sid)-\(Int(now.timeIntervalSince1970))", title: "任务完成",
               body: "Harness 回合已结束")
    }

    /// 冷却期内返回 true（跳过本次通知）。
    private func cooledDown(now: Date, table: inout [String: Date], key: String) -> Bool {
        if let last = table[key], now.timeIntervalSince(last) < pendingCooldown {
            return true
        }
        table[key] = now
        return false
    }

    // MARK: - 通知

    private func notify(id: String, title: String, body: String) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "dash"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error {
                Log.write("通知发送失败：\(error.localizedDescription)", tag: "events")
            }
        }
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let delay = min(pow(2.0, Double(reconnectCount)), 30)
        reconnectCount += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            Log.write("事件流重连（\(Int(delay))s 后）", tag: "events")
            self.connectMux()
            self.connectHost()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 点击通知 → 唤起应用并前置窗口。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        completionHandler()
    }
}
