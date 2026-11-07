import Foundation

/// Adapts protocol 2 records to the app's timeline and command interfaces.
/// Instances are owned by T3Client and accessed only on that actor.
final class OrchestrationV2 {
    struct Operation {
        let method: String
        let payload: [String: Any]
    }

    private var projections: [String: [String: Any]] = [:]
    private var shells: [String: [String: Any]] = [:]
    private var projects: [String: [String: Any]] = [:]

    func streamItem(_ value: Any, method: String, input: Any) throws -> Any? {
        guard var item = value as? [String: Any], let kind = item["kind"] as? String else { return value }
        if kind == "synchronized" || kind == "unknown-event" { return nil }
        if method == "orchestration.subscribeShell" {
            if kind == "snapshot", var snapshot = item["snapshot"] as? [String: Any] {
                let threads = (snapshot["threads"] as? [[String: Any]] ?? []) + (snapshot["archivedThreads"] as? [[String: Any]] ?? [])
                if item["resolvedRepositoryIdentityRoots"] == nil {
                    shells.removeAll()
                    projects.removeAll()
                }
                for thread in threads { if let id = thread["id"] as? String { shells[id] = thread } }
                for project in records(snapshot, "projects") { if let id = project["id"] as? String { projects[id] = project } }
                snapshot["threads"] = shells.values.map(normalizeShell)
                snapshot["projects"] = projects.values.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
                snapshot["updatedAt"] = latestDate(Array(shells.values), fallback: "1970-01-01T00:00:00Z")
                item["snapshot"] = snapshot
            } else {
                let aliases = ["project.updated": "project-upserted", "project.removed": "project-removed",
                               "thread.updated": "thread-upserted", "thread.removed": "thread-removed"]
                guard let translated = aliases[kind] else { return nil }
                item["kind"] = translated
                if let project = item["project"] as? [String: Any], let id = project["id"] as? String { projects[id] = project }
                if kind == "project.removed", let id = item["projectId"] as? String {
                    projects.removeValue(forKey: id)
                    shells = shells.filter { $0.value["projectId"] as? String != id }
                }
                if kind == "thread.removed", let id = item["threadId"] as? String { shells.removeValue(forKey: id) }
                if let thread = item["thread"] as? [String: Any] {
                    if let id = thread["id"] as? String { shells[id] = thread }
                    item["thread"] = normalizeShell(thread)
                }
            }
            return item
        }
        guard method == "orchestration.subscribeThread",
              let threadId = (input as? [String: Any])?["threadId"] as? String else { return value }
        let sequence = item["snapshotSequence"] as? Int ?? item["sequence"] as? Int ?? 0
        if kind == "snapshot", let projection = item["projection"] as? [String: Any] {
            projections[threadId] = projection
        } else if kind == "event", let event = item["event"] as? [String: Any],
                  let type = event["type"] as? String, let payload = event["payload"] as? [String: Any],
                  var projection = projections[threadId] {
            if type.hasPrefix("thread."), payload["modelSelection"] != nil {
                projection["thread"] = payload
            } else {
                let collections = ["run": "runs", "run-attempt": "attempts", "node": "nodes", "subagent": "subagents",
                                   "provider-session": "providerSessions", "provider-thread": "providerThreads",
                                   "provider-turn": "providerTurns", "runtime-request": "runtimeRequests",
                                   "message": "messages", "turn-item": "turnItems", "plan": "plans"]
                if type == "provider-session.detached", let id = payload["providerSessionId"] as? String {
                    projection["providerSessions"] = records(projection, "providerSessions").filter { $0["id"] as? String != id }
                } else if let prefix = type.split(separator: ".").first.map(String.init),
                          let collection = collections[prefix], let id = payload["id"] as? String {
                    var values = records(projection, collection)
                    if let index = values.firstIndex(where: { $0["id"] as? String == id }) { values[index] = payload }
                    else { values.append(payload) }
                    projection[collection] = values
                }
            }
            projection["updatedAt"] = event["occurredAt"] ?? projection["updatedAt"]
            projections[threadId] = projection
        } else { return nil }
        guard let projection = projections[threadId] else { return nil }
        return ["kind": "snapshot", "snapshot": ["snapshotSequence": sequence, "thread": normalizeProjection(projection)]]
    }

    func operations(for command: [String: Any]) throws -> [Operation] {
        guard let type = command["type"] as? String else { throw T3Error.requestFailed("会话命令缺少类型。") }
        var value = command
        value.removeValue(forKey: "createdAt")
        switch type {
        case "thread.turn.start":
            guard let message = value["message"] as? [String: Any], let threadId = value["threadId"] as? String else {
                throw T3Error.requestFailed("消息内容无效。")
            }
            if let bootstrap = value["bootstrap"] as? [String: Any], let creation = bootstrap["createThread"] as? [String: Any] {
                var launch = creation
                launch.removeValue(forKey: "createdAt")
                launch.removeValue(forKey: "branch")
                launch.removeValue(forKey: "worktreePath")
                launch["commandId"] = value["commandId"]
                launch["threadId"] = threadId
                launch["workspaceStrategy"] = ["type": "root"]
                launch["initialMessage"] = ["messageId": message["messageId"] ?? UUID().uuidString,
                                             "text": message["text"] ?? "", "attachments": message["attachments"] ?? []]
                return [Operation(method: "orchestration.launchThread", payload: launch)]
            }
            var operations: [Operation] = []
            let thread = projections[threadId]?["thread"] as? [String: Any] ?? shells[threadId]
            for (field, commandType) in [("runtimeMode", "thread.runtime-mode.set"), ("interactionMode", "thread.interaction-mode.set")] {
                if let desired = value[field] as? String, let current = thread?[field] as? String, desired != current {
                    operations.append(Operation(method: "orchestration.dispatchCommand", payload: ["type": commandType,
                        "commandId": UUID().uuidString, "threadId": threadId, field: desired]))
                }
            }
            var dispatch: [String: Any] = ["type": "message.dispatch", "commandId": value["commandId"] ?? UUID().uuidString,
                "threadId": threadId, "messageId": message["messageId"] ?? UUID().uuidString,
                "text": message["text"] ?? "", "attachments": message["attachments"] ?? []]
            if let model = value["modelSelection"] { dispatch["modelSelection"] = model }
            if let source = value["sourceProposedPlan"] { dispatch["sourcePlanRef"] = source }
            if let activeRun = activeRunId(threadId) {
                dispatch["dispatchMode"] = ["type": "steer_active", "targetRunId": activeRun]
            } else { dispatch["dispatchMode"] = ["type": "start_immediately"] }
            operations.append(Operation(method: "orchestration.dispatchCommand", payload: dispatch))
            return operations
        case "thread.turn.interrupt":
            if let run = (value["threadId"] as? String).flatMap(activeRunId) ?? value["turnId"] as? String {
                value["type"] = "run.interrupt"
                value["runId"] = run
                value.removeValue(forKey: "turnId")
            } else { value["type"] = "thread.stop" }
        case "thread.session.stop": value["type"] = "thread.stop"
        case "thread.approval.respond", "thread.user-input.respond": value["type"] = "runtime-request.respond"
        case "thread.meta.update":
            value["type"] = value["modelSelection"] == nil ? "thread.metadata.update" : "thread.model-selection.set"
        default: break
        }
        return [Operation(method: "orchestration.dispatchCommand", payload: value)]
    }

    private func activeRunId(_ threadId: String) -> String? {
        if let projection = projections[threadId], let run = records(projection, "runs").last(where: {
            ["preparing", "starting", "running", "waiting"].contains($0["status"] as? String ?? "")
        }) {
            return run["id"] as? String
        }
        return shells[threadId]?["activeRunId"] as? String
    }

    private func normalizeShell(_ source: [String: Any]) -> [String: Any] {
        var thread = source
        let pending = source["pendingRuntimeRequest"] as? [String: Any]
        thread["hasPendingUserInput"] = pending?["kind"] as? String == "user_input"
        thread["hasPendingApprovals"] = pending != nil && pending?["kind"] as? String != "user_input"
        if let id = source["latestRunId"] as? String {
            let fallback = source["updatedAt"] as? String ?? "1970-01-01T00:00:00Z"
            thread["latestTurn"] = ["turnId": id, "state": state(source["status"] as? String),
                "requestedAt": source["latestRunRequestedAt"] as? String ?? fallback,
                "startedAt": source["latestRunStartedAt"] ?? NSNull(),
                "completedAt": source["latestRunCompletedAt"] ?? NSNull()]
        }
        return thread
    }

    private func normalizeProjection(_ projection: [String: Any]) -> [String: Any] {
        var thread = projection["thread"] as? [String: Any] ?? [:]
        let threadId = thread["id"] as? String ?? ""
        let fallback = projection["updatedAt"] as? String ?? thread["updatedAt"] as? String ?? "1970-01-01T00:00:00Z"
        let runs = records(projection, "runs")
        if let run = runs.max(by: { ($0["ordinal"] as? Int ?? 0) < ($1["ordinal"] as? Int ?? 0) }) {
            thread["latestTurn"] = ["turnId": run["id"] ?? "", "state": state(run["status"] as? String),
                "requestedAt": run["requestedAt"] ?? fallback, "startedAt": run["startedAt"] ?? NSNull(),
                "completedAt": run["completedAt"] ?? NSNull()]
        }
        var messages = records(projection, "messages")
        let inheritedItems = records(projection, "visibleTurnItems").compactMap { $0["item"] as? [String: Any] }
        for item in inheritedItems {
            guard let type = item["type"] as? String, ["user_message", "assistant_message"].contains(type),
                  let id = item["messageId"] as? String, !messages.contains(where: { $0["id"] as? String == id }) else { continue }
            messages.append(["id": id, "role": type == "user_message" ? "user" : "assistant", "text": item["text"] ?? "",
                "streaming": item["streaming"] ?? false, "attachments": item["attachments"] ?? [],
                "runId": item["runId"] ?? NSNull(), "createdAt": item["startedAt"] as? String ?? item["updatedAt"] as? String ?? fallback,
                "updatedAt": item["updatedAt"] ?? fallback])
        }
        thread["messages"] = messages.map { message in
            var result = message
            result["turnId"] = message["runId"]
            return result
        }
        let sessions = records(projection, "providerSessions")
        if let session = sessions.max(by: { ($0["updatedAt"] as? String ?? "") < ($1["updatedAt"] as? String ?? "") }) {
            let status = session["status"] as? String ?? "ready"
            thread["session"] = ["threadId": threadId, "status": status == "waiting" ? "running" : status,
                "providerName": session["driver"] ?? NSNull(), "providerInstanceId": session["providerInstanceId"] ?? NSNull(),
                "runtimeMode": thread["runtimeMode"] ?? "approval-required", "activeTurnId": activeRunId(threadId) as Any? ?? NSNull(),
                "lastError": session["lastError"] ?? NSNull(), "updatedAt": session["updatedAt"] ?? fallback]
        }
        var items = records(projection, "turnItems")
        for item in inheritedItems where !items.contains(where: { $0["id"] as? String == item["id"] as? String }) { items.append(item) }
        let pending = records(projection, "runtimeRequests").filter { $0["status"] as? String == "pending" }
        var activities: [[String: Any]] = []
        for request in pending {
            guard let id = request["id"] as? String else { continue }
            let item = items.first { $0["requestId"] as? String == id } ?? [:]
            let kind = request["kind"] as? String ?? "command"
            var payload: [String: Any] = ["requestId": id, "requestKind": kind,
                "detail": item["prompt"] ?? item["reason"] ?? item["title"] ?? "需要确认"]
            payload["questions"] = item["questions"] ?? []
            activities.append(["id": "request:" + id, "kind": kind == "user_input" ? "user-input.requested" : "approval.requested",
                "summary": kind == "user_input" ? "需要补充信息" : "需要审批", "tone": "approval",
                "createdAt": request["createdAt"] ?? fallback, "payload": payload])
        }
        for item in items {
            let type = item["type"] as? String ?? ""
            guard ["command_execution", "file_change", "reasoning", "dynamic_tool", "provider_error"].contains(type) else { continue }
            let running = isActive(item["status"] as? String)
            let title = item["title"] as? String ?? ["command_execution": "执行命令", "file_change": "修改文件",
                "reasoning": "思考", "dynamic_tool": "调用工具", "provider_error": "服务商错误"][type] ?? "工具活动"
            var details: [String: Any] = [:]
            if type == "command_execution" { details["command"] = item["input"] }
            if let file = item["fileName"] as? String { details["changedFiles"] = [file] }
            let payload: [String: Any] = ["title": title, "itemType": type,
                "detail": item["output"] ?? item["diffStr"] ?? item["text"] ?? "", "data": ["item": details]]
            activities.append(["id": item["id"] ?? UUID().uuidString, "kind": running ? "tool.updated" : "tool.completed",
                "summary": title, "tone": type == "reasoning" ? "thinking" : "tool",
                "createdAt": item["startedAt"] as? String ?? item["updatedAt"] as? String ?? fallback,
                "turnId": item["runId"] ?? NSNull(), "payload": payload])
        }
        thread["activities"] = activities
        thread["proposedPlans"] = records(projection, "plans").filter { $0["kind"] as? String == "proposed_plan" }.map { plan in
            ["id": plan["id"] ?? "", "turnId": plan["runId"] ?? NSNull(), "planMarkdown": plan["markdown"] ?? "",
             "createdAt": fallback, "updatedAt": fallback,
             "implementedAt": plan["status"] as? String == "completed" ? fallback as Any : NSNull()]
        }
        return thread
    }

    private func records(_ object: [String: Any], _ key: String) -> [[String: Any]] { object[key] as? [[String: Any]] ?? [] }
    private func latestDate(_ records: [[String: Any]], fallback: String) -> String { records.compactMap { $0["updatedAt"] as? String }.max() ?? fallback }
    private func isActive(_ value: String?) -> Bool { ["queued", "preparing", "starting", "running", "waiting", "pending"].contains(value ?? "") }
    private func state(_ value: String?) -> String {
        if isActive(value) { return "running" }
        if value == "failed" || value == "error" { return "error" }
        if value == "cancelled" || value == "interrupted" { return "interrupted" }
        return "completed"
    }
}
