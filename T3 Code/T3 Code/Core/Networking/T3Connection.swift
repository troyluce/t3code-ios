import Foundation

actor T3Connection {
    enum ConnectionStatus: Equatable {
        case offline, connecting, connected, error(String)
    }

    struct Config: Sendable {
        var serverURL: URL
        var bearerToken: String?
        var orchestrationProtocolVersion: Int = 1
    }

    private var config: Config
    private var task: URLSessionWebSocketTask?
    private var session: URLSession
    private let socketDelegate: WebSocketSessionDelegate
    private var nextRequestNumber: UInt64 = 1
    private var statusContinuation: AsyncStream<ConnectionStatus>.Continuation?
    private var inboundContinuation: AsyncStream<EffectRPCMessage>.Continuation?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldAutoReconnect: Bool = false
    private var reconnectAttempt: Int = 0
    private let maximumWebSocketMessageSize = 64 * 1024 * 1024
    private let maxReconnectDelaySeconds: Double = 30
    private let baseReconnectDelaySeconds: Double = 1

    init(config: Config) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 0
        let socketDelegate = WebSocketSessionDelegate()
        self.socketDelegate = socketDelegate
        self.session = URLSession(configuration: cfg, delegate: socketDelegate, delegateQueue: nil)
    }

    func updateConfig(_ newConfig: Config) {
        self.config = newConfig
    }

    func statusStream() -> AsyncStream<ConnectionStatus> {
        AsyncStream { continuation in
            self.statusContinuation = continuation
        }
    }

    func inboundStream() -> AsyncStream<EffectRPCMessage> {
        AsyncStream { continuation in
            self.inboundContinuation = continuation
        }
    }

    func nextRequestId() -> String {
        let n = nextRequestNumber
        nextRequestNumber &+= 1
        return String(n)
    }

    @discardableResult
    func connect() async -> Bool {
        shouldAutoReconnect = true
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        return await connectInternal()
    }

    func disconnect() {
        shouldAutoReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownConnection(yieldOffline: true)
    }

    private func connectInternal() async -> Bool {
        teardownConnection(yieldOffline: false)
        statusContinuation?.yield(.connecting)

        let wsURL: URL
        do {
            var authorization: PairingFlow.WebSocketToken?
            if let token = config.bearerToken, !token.isEmpty {
                let issued = try await PairingFlow.issueWebSocketToken(
                    serverURL: config.serverURL,
                    bearerToken: token
                )
                authorization = issued
            }
            wsURL = try PairingFlow.webSocketURL(serverURL: config.serverURL, authorization: authorization,
                                                protocolVersion: config.orchestrationProtocolVersion)
        } catch {
            statusContinuation?.yield(.error(formatConnectionError(error)))
            scheduleReconnect()
            return false
        }

        var request = URLRequest(url: wsURL)
        if let token = config.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumWebSocketMessageSize
        self.task = task
        let openWait = Task {
            try await socketDelegate.waitForOpen(task: task, timeoutNanoseconds: 10_000_000_000)
        }
        task.resume()

        do {
            try await openWait.value
        } catch {
            if self.task === task {
                task.cancel(with: .goingAway, reason: nil)
                self.task = nil
            }
            statusContinuation?.yield(.error(formatWebSocketError(error, task: task)))
            scheduleReconnect()
            return false
        }

        reconnectAttempt = 0
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        heartbeatTask = Task { [weak self] in
            await self?.heartbeatLoop()
        }

        statusContinuation?.yield(.connected)
        return true
    }

    private func teardownConnection(yieldOffline: Bool) {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if yieldOffline {
            statusContinuation?.yield(.offline)
        }
    }

    private func scheduleReconnect() {
        guard shouldAutoReconnect else { return }
        reconnectTask?.cancel()
        reconnectAttempt += 1
        let delay = backoffDelay(for: reconnectAttempt)
        reconnectTask = Task { [weak self] in
            let nanos = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard let self else { return }
            if Task.isCancelled { return }
            await self.attemptReconnectIfWanted()
        }
    }

    private func attemptReconnectIfWanted() async {
        guard shouldAutoReconnect else { return }
        _ = await connectInternal()
    }

    private func backoffDelay(for attempt: Int) -> Double {
        let exponent = min(attempt - 1, 6)
        let base = baseReconnectDelaySeconds * pow(2.0, Double(exponent))
        let capped = min(base, maxReconnectDelaySeconds)
        let jitter = Double.random(in: 0...0.4)
        return capped + jitter
    }

    func send(_ messages: [EffectRPCMessage]) async throws {
        guard let task else { throw T3Error.notConnected }
        for message in messages {
            let data = try EffectRPCEncoder.encode(message)
            guard let text = String(data: data, encoding: .utf8) else {
                throw T3Error.requestFailed("RPC 消息编码失败")
            }
            try await task.send(.string(text))
        }
    }

    private func receiveLoop() async {
        guard let task else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: continue
                }
                let messages = try EffectRPCDecoder.decodeFrame(data)
                for m in messages {
                    if case .ping = m {
                        try await send([.pong])
                    } else {
                        inboundContinuation?.yield(m)
                    }
                }
            } catch {
                if Task.isCancelled || !isCurrentTask(task) {
                    return
                }
                self.task = nil
                statusContinuation?.yield(.error(formatWebSocketError(error, task: task)))
                scheduleReconnect()
                return
            }
        }
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            do {
                try await send([.ping])
            } catch {
                if Task.isCancelled {
                    return
                }
                return
            }
        }
    }

    private func isCurrentTask(_ candidate: URLSessionWebSocketTask) -> Bool {
        task === candidate
    }

    private func formatConnectionError(_ error: Error) -> String {
        let nsError = error as NSError
        var message = ChineseLocalization.errorDescription(error)
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = "连接失败"
        }
        return "\(message) (\(nsError.domain) \(nsError.code))"
    }

    private func formatWebSocketError(_ error: Error, task: URLSessionWebSocketTask) -> String {
        var parts = [formatConnectionError(error)]
        if task.closeCode != .invalid {
            parts.append(formatCloseCode(task.closeCode))
        }
        if let closeReason = task.closeReason,
           let reason = String(data: closeReason, encoding: .utf8),
           !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(reason)
        }
        return parts.joined(separator: " · ")
    }

    private func formatCloseCode(_ code: URLSessionWebSocketTask.CloseCode) -> String {
        switch code {
        case .noStatusReceived:
            return "服务器关闭连接时未提供 WebSocket 状态"
        case .abnormalClosure:
            return "WebSocket 连接异常关闭"
        default:
            return "关闭代码 \(code.rawValue)"
        }
    }
}

private final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate {
    private let lock = NSLock()
    private var openContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var completedOpenResults: [Int: Result<Void, Error>] = [:]
    private var finishedOpenTaskIDs: Set<Int> = []
    private var openedTaskIDs: Set<Int> = []

    func waitForOpen(task: URLSessionWebSocketTask, timeoutNanoseconds: UInt64) async throws {
        let taskID = task.taskIdentifier
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            self?.completeOpenWait(
                taskID: taskID,
                result: .failure(T3Error.requestFailed("等待 WebSocket 连接超时"))
            )
        }
        defer { timeoutTask.cancel() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result = completedOpenResults.removeValue(forKey: taskID) {
                    finishedOpenTaskIDs.insert(taskID)
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    openContinuations[taskID] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            completeOpenWait(taskID: taskID, result: .failure(CancellationError()))
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        openedTaskIDs.insert(webSocketTask.taskIdentifier)
        lock.unlock()
        completeOpenWait(taskID: webSocketTask.taskIdentifier, result: .success(()))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let taskID = webSocketTask.taskIdentifier
        lock.lock()
        let wasOpened = openedTaskIDs.remove(taskID) != nil
        lock.unlock()
        guard !wasOpened else { return }
        completeOpenWait(
            taskID: taskID,
            result: .failure(T3Error.requestFailed("WebSocket 在建立连接前已关闭"))
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let taskID = task.taskIdentifier
        lock.lock()
        let wasOpened = openedTaskIDs.contains(taskID)
        lock.unlock()
        guard !wasOpened else { return }
        completeOpenWait(taskID: taskID, result: .failure(error))
    }

    private func completeOpenWait(taskID: Int, result: Result<Void, Error>) {
        lock.lock()
        if let continuation = openContinuations.removeValue(forKey: taskID) {
            completedOpenResults.removeValue(forKey: taskID)
            finishedOpenTaskIDs.insert(taskID)
            lock.unlock()
            continuation.resume(with: result)
        } else if finishedOpenTaskIDs.contains(taskID) {
            lock.unlock()
        } else {
            completedOpenResults[taskID] = result
            lock.unlock()
        }
    }
}

enum T3Error: Error, LocalizedError {
    case notConnected
    case invalidServerURL
    case pairingFailed(String)
    case requestFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "尚未连接 T3 服务器"
        case .invalidServerURL: "服务器地址无效"
        case .pairingFailed(let msg): "配对失败：\(msg)"
        case .requestFailed(let msg): "请求失败：\(msg)"
        case .decodingFailed(let msg): "解析响应失败：\(msg)"
        }
    }
}
