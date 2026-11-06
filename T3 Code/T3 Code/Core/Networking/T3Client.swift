import Foundation

actor T3Client {
    private struct SubscriptionTemplate {
        let method: String
        let payload: Any
        let onValue: (Any) -> Void
    }

    private let connection: T3Connection
    private var pendingResponses: [String: CheckedContinuation<Any?, Error>] = [:]
    private var streamSubscribers: [String: (Any) -> Void] = [:]
    private var subscriptionTemplates: [String: SubscriptionTemplate] = [:]
    private var demuxTask: Task<Void, Never>?
    private var statusObserverTask: Task<Void, Never>?
    private(set) var status: T3Connection.ConnectionStatus = .offline
    private var statusListeners: [(T3Connection.ConnectionStatus) -> Void] = []

    init(connection: T3Connection) {
        self.connection = connection
    }

    @discardableResult
    func start() async -> Bool {
        let inbound = await connection.inboundStream()
        let status = await connection.statusStream()
        demuxTask = Task { [weak self] in
            for await msg in inbound {
                await self?.handle(msg)
            }
        }
        statusObserverTask = Task { [weak self] in
            for await s in status {
                await self?.update(status: s)
            }
        }
        return await connection.connect()
    }

    func stop() async {
        demuxTask?.cancel()
        statusObserverTask?.cancel()
        await connection.disconnect()
        pendingResponses.values.forEach { $0.resume(throwing: T3Error.notConnected) }
        pendingResponses.removeAll()
        streamSubscribers.removeAll()
        subscriptionTemplates.removeAll()
    }

    func addStatusListener(_ listener: @escaping (T3Connection.ConnectionStatus) -> Void) {
        statusListeners.append(listener)
        listener(status)
    }

    private func update(status newStatus: T3Connection.ConnectionStatus) async {
        let wasConnected = (self.status == .connected)
        self.status = newStatus
        for listener in statusListeners {
            listener(newStatus)
        }
        switch newStatus {
        case .connected:
            await resubscribeAll()
        case .offline, .error, .connecting:
            if wasConnected {
                failPendingRequests()
            }
        }
    }

    private func failPendingRequests() {
        guard !pendingResponses.isEmpty else { return }
        let waiters = pendingResponses
        pendingResponses.removeAll()
        for cont in waiters.values {
            cont.resume(throwing: T3Error.notConnected)
        }
    }

    private func resubscribeAll() async {
        guard !subscriptionTemplates.isEmpty else { return }
        for (id, template) in subscriptionTemplates {
            do {
                try await connection.send([
                    .streamRequest(id: id,
                                   tag: template.method,
                                   payload: template.payload,
                                   headers: [])
                ])
            } catch {
                NSLog("Failed to resubscribe to \(template.method): \(error)")
            }
        }
    }

    private func handle(_ msg: EffectRPCMessage) async {
        switch msg {
        case let .exit(requestId, success, value, _, errorMessage):
            if let cont = pendingResponses.removeValue(forKey: requestId) {
                if success {
                    cont.resume(returning: value)
                } else {
                    cont.resume(throwing: T3Error.requestFailed(errorMessage ?? "unknown"))
                }
            }
            streamSubscribers.removeValue(forKey: requestId)
            subscriptionTemplates.removeValue(forKey: requestId)
        case let .chunk(requestId, values):
            if let listener = streamSubscribers[requestId] {
                for v in values {
                    listener(v)
                }
                try? await connection.send([.ack(requestId: requestId)])
            }
        case .pong, .ping, .eof:
            break
        case let .defect(message):
            for cont in pendingResponses.values {
                cont.resume(throwing: T3Error.requestFailed(message))
            }
            pendingResponses.removeAll()
            streamSubscribers.removeAll()
            subscriptionTemplates.removeAll()
        default:
            break
        }
    }

    func request(method: String, payload: Any) async throws -> Any? {
        let id = await connection.nextRequestId()
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            Task {
                do {
                    try await connection.send([
                        .request(id: id, tag: method, payload: payload, headers: [])
                    ])
                } catch {
                    pendingResponses.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        }
    }

    func subscribe(method: String,
                   payload: Any,
                   onValue: @escaping (Any) -> Void) async throws -> StreamSubscription {
        let id = await connection.nextRequestId()
        streamSubscribers[id] = onValue
        subscriptionTemplates[id] = SubscriptionTemplate(method: method,
                                                         payload: payload,
                                                         onValue: onValue)
        try await connection.send([
            .streamRequest(id: id, tag: method, payload: payload, headers: [])
        ])
        return StreamSubscription(client: self, requestId: id)
    }

    func cancel(requestId: String) async {
        streamSubscribers.removeValue(forKey: requestId)
        subscriptionTemplates.removeValue(forKey: requestId)
        pendingResponses.removeValue(forKey: requestId)?
            .resume(throwing: CancellationError())
        try? await connection.send([
            .interrupt(requestId: requestId, interruptors: [])
        ])
    }
}

struct StreamSubscription: Sendable {
    private weak var client: T3Client?
    let requestId: String

    nonisolated init(client: T3Client, requestId: String) {
        self.client = client
        self.requestId = requestId
    }

    nonisolated func cancel() async {
        await client?.cancel(requestId: requestId)
    }
}

extension T3Client {
    func subscribeShell(onItem: @escaping (ShellStreamItem) -> Void)
    async throws -> StreamSubscription {
        try await subscribe(method: "orchestration.subscribeShell", payload: [String: Any]()) { value in
            do {
                let item = try ShellStreamItem.decode(from: value)
                onItem(item)
            } catch {
                NSLog("Failed to decode shell stream item: \(error)")
            }
        }
    }

    func subscribeThread(threadId: ThreadID,
                         onItem: @escaping (ThreadStreamItem) -> Void)
    async throws -> StreamSubscription {
        try await subscribe(method: "orchestration.subscribeThread",
                            payload: ["threadId": threadId.rawValue]) { value in
            do {
                let item = try ThreadStreamItem.decode(from: value)
                onItem(item)
            } catch {
                NSLog("Failed to decode thread stream item: \(error)")
            }
        }
    }

    func dispatchTurnStart(threadId: ThreadID,
                           text: String,
                           attachments: [UploadImage] = [],
                           modelSelection: ModelSelection?,
                           runtimeMode: RuntimeMode,
                           interactionMode: ProviderInteractionMode) async throws {
        let messageId = MessageID.newClientID().rawValue
        let commandId = CommandID.new().rawValue
        let now = ISO8601Decoder.formatter.string(from: Date())

        var payload: [String: Any] = [
            "type": "thread.turn.start",
            "commandId": commandId,
            "threadId": threadId.rawValue,
            "message": [
                "messageId": messageId,
                "role": "user",
                "text": text,
                "attachments": attachments.map { $0.encoded() }
            ],
            "runtimeMode": runtimeMode.rawValue,
            "interactionMode": interactionMode.rawValue,
            "createdAt": now
        ]
        if let modelSelection {
            payload["modelSelection"] = modelSelection.encoded
        }
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func createThreadAndStart(project: ProjectShell,
                              text: String,
                              attachments: [UploadImage] = [],
                              modelSelection: ModelSelection,
                              runtimeMode: RuntimeMode,
                              interactionMode: ProviderInteractionMode) async throws -> ThreadID {
        let threadId = ThreadID.new()
        let messageId = MessageID.newClientID().rawValue
        let commandId = CommandID.new().rawValue
        let now = ISO8601Decoder.formatter.string(from: Date())
        let titleSeed = Self.titleSeed(text: text, attachments: attachments)

        let payload: [String: Any] = [
            "type": "thread.turn.start",
            "commandId": commandId,
            "threadId": threadId.rawValue,
            "message": [
                "messageId": messageId,
                "role": "user",
                "text": text,
                "attachments": attachments.map { $0.encoded() }
            ],
            "modelSelection": modelSelection.encoded,
            "titleSeed": titleSeed,
            "runtimeMode": runtimeMode.rawValue,
            "interactionMode": interactionMode.rawValue,
            "bootstrap": [
                "createThread": [
                    "projectId": project.id.rawValue,
                    "title": titleSeed,
                    "modelSelection": modelSelection.encoded,
                    "runtimeMode": runtimeMode.rawValue,
                    "interactionMode": interactionMode.rawValue,
                    "branch": NSNull(),
                    "worktreePath": NSNull(),
                    "createdAt": now
                ]
            ],
            "createdAt": now
        ]

        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
        return threadId
    }

    func getServerConfig() async throws -> ServerRuntimeConfig {
        let value = try await request(method: "server.getConfig", payload: [String: Any]())
        guard let value else {
            throw T3Error.decodingFailed("服务器返回的配置信息为空")
        }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(ServerRuntimeConfig.self, from: data)
    }

    // MARK: - Mutating orchestration commands

    func interruptTurn(threadId: ThreadID, turnId: TurnID? = nil) async throws {
        var payload: [String: Any] = [
            "type": "thread.turn.interrupt",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue,
            "createdAt": ISO8601Decoder.formatter.string(from: Date())
        ]
        if let turnId {
            payload["turnId"] = turnId.rawValue
        }
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func respondApproval(threadId: ThreadID,
                         requestId: ApprovalRequestID,
                         decision: ApprovalDecision) async throws {
        let payload: [String: Any] = [
            "type": "thread.approval.respond",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue,
            "requestId": requestId.rawValue,
            "decision": decision.rawValue,
            "createdAt": ISO8601Decoder.formatter.string(from: Date())
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func respondUserInput(threadId: ThreadID,
                          requestId: ApprovalRequestID,
                          answers: [String: Any]) async throws {
        let payload: [String: Any] = [
            "type": "thread.user-input.respond",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue,
            "requestId": requestId.rawValue,
            "answers": answers,
            "createdAt": ISO8601Decoder.formatter.string(from: Date())
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func setRuntimeMode(threadId: ThreadID, mode: RuntimeMode) async throws {
        let payload: [String: Any] = [
            "type": "thread.runtime-mode.set",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue,
            "runtimeMode": mode.rawValue,
            "createdAt": ISO8601Decoder.formatter.string(from: Date())
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func setInteractionMode(threadId: ThreadID, mode: ProviderInteractionMode) async throws {
        let payload: [String: Any] = [
            "type": "thread.interaction-mode.set",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue,
            "interactionMode": mode.rawValue,
            "createdAt": ISO8601Decoder.formatter.string(from: Date())
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func updateThreadModelSelection(threadId: ThreadID, modelSelection: ModelSelection) async throws {
        let payload: [String: Any] = [
            "type": "thread.meta.update",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue,
            "modelSelection": modelSelection.encoded
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func renameThread(threadId: ThreadID, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let payload: [String: Any] = [
            "type": "thread.meta.update",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue,
            "title": trimmed
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func archiveThread(threadId: ThreadID) async throws {
        let payload: [String: Any] = [
            "type": "thread.archive",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func unarchiveThread(threadId: ThreadID) async throws {
        let payload: [String: Any] = [
            "type": "thread.unarchive",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func deleteThread(threadId: ThreadID) async throws {
        let payload: [String: Any] = [
            "type": "thread.delete",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func stopSession(threadId: ThreadID) async throws {
        let payload: [String: Any] = [
            "type": "thread.session.stop",
            "commandId": CommandID.new().rawValue,
            "threadId": threadId.rawValue,
            "createdAt": ISO8601Decoder.formatter.string(from: Date())
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    func startTurnFromProposedPlan(threadId: ThreadID,
                                   planId: String,
                                   sourceThreadId: ThreadID,
                                   modelSelection: ModelSelection,
                                   runtimeMode: RuntimeMode,
                                   interactionMode: ProviderInteractionMode) async throws {
        let messageId = MessageID.newClientID().rawValue
        let commandId = CommandID.new().rawValue
        let now = ISO8601Decoder.formatter.string(from: Date())
        let payload: [String: Any] = [
            "type": "thread.turn.start",
            "commandId": commandId,
            "threadId": threadId.rawValue,
            "message": [
                "messageId": messageId,
                "role": "user",
                "text": "Implement the proposed plan.",
                "attachments": []
            ],
            "modelSelection": modelSelection.encoded,
            "runtimeMode": runtimeMode.rawValue,
            "interactionMode": interactionMode.rawValue,
            "sourceProposedPlan": [
                "threadId": sourceThreadId.rawValue,
                "planId": planId
            ],
            "createdAt": now
        ]
        _ = try await request(method: "orchestration.dispatchCommand", payload: payload)
    }

    private static func titleSeed(text: String, attachments: [UploadImage]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed: String
        if !trimmed.isEmpty {
            seed = trimmed
        } else if let first = attachments.first {
            seed = "图片：\(first.name)"
        } else {
            seed = "新会话"
        }
        if seed.count <= 80 {
            return seed
        }
        return String(seed.prefix(77)) + "..."
    }

    // MARK: - Git / VCS

    func refreshVcsStatus(cwd: String) async throws -> VcsStatusSummary {
        let payload: [String: Any] = ["cwd": cwd]
        guard let value = try await request(method: "vcs.refreshStatus", payload: payload) else {
            throw T3Error.decodingFailed("Git 状态响应为空")
        }
        return try VcsStatusSummary.decode(from: value)
    }

    func vcsPull(cwd: String) async throws -> VcsPullSummary {
        let payload: [String: Any] = ["cwd": cwd]
        guard let value = try await request(method: "vcs.pull", payload: payload) else {
            throw T3Error.decodingFailed("Git 拉取响应为空")
        }
        return try VcsPullSummary.decode(from: value)
    }

    func runGitStackedAction(cwd: String,
                             action: GitStackedAction,
                             commitMessage: String? = nil) async throws -> GitActionSummary {
        let actionId = UUID().uuidString
        var payload: [String: Any] = [
            "actionId": actionId,
            "cwd": cwd,
            "action": action.rawValue
        ]
        if let commitMessage {
            let trimmed = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                payload["commitMessage"] = trimmed
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            let lock = NSLock()

            func resumeOnce(_ result: Result<GitActionSummary, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            Task {
                do {
                    let subscription = try await subscribe(method: "git.runStackedAction", payload: payload) {
                        value in
                        guard let dict = value as? [String: Any],
                              let kind = dict["kind"] as? String else { return }
                        switch kind {
                        case "action_finished":
                            let result = (dict["result"] as? [String: Any]) ?? [:]
                            let toast = (result["toast"] as? [String: Any]) ?? [:]
                            let title = (toast["title"] as? String) ?? "操作完成"
                            let description = toast["description"] as? String
                            resumeOnce(.success(.init(toastTitle: title, toastDescription: description)))
                        case "action_failed":
                            let message = (dict["message"] as? String) ?? "Git 操作失败。"
                            resumeOnce(.failure(T3Error.requestFailed(message)))
                        default:
                            break
                        }
                    }

                    Task.detached {
                        try? await Task.sleep(nanoseconds: 120_000_000_000)
                        await subscription.cancel()
                        resumeOnce(.failure(T3Error.requestFailed("Git 操作超时。")))
                    }
                } catch {
                    resumeOnce(.failure(error))
                }
            }
        }
    }
}

struct UploadImage: Sendable {
    let name: String
    let mimeType: String
    let sizeBytes: Int
    let dataURL: String

    nonisolated func encoded() -> [String: Any] {
        [
            "type": "image",
            "name": name,
            "mimeType": mimeType,
            "sizeBytes": sizeBytes,
            "dataUrl": dataURL
        ]
    }
}
