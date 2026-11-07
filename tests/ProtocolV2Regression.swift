import Foundation

enum T3Error: Error { case requestFailed(String) }

@main
struct ProtocolV2Regression {
    static func main() throws {
        let adapter = OrchestrationV2()
        let date = "2026-01-01T00:00:00.000Z"
        let model: [String: Any] = ["instanceId": "provider-fixture", "model": "model-fixture"]
        let project: [String: Any] = ["id": "project-fixture", "title": "Fixture", "workspaceRoot": "/tmp/fixture", "createdAt": date, "updatedAt": date]
        let thread: [String: Any] = ["id": "thread-fixture", "projectId": "project-fixture", "title": "Fixture",
            "modelSelection": model, "runtimeMode": "full-access", "interactionMode": "default", "createdAt": date,
            "updatedAt": date, "status": "running", "latestRunId": "run-fixture", "activeRunId": "run-fixture"]
        let shell: [String: Any] = ["kind": "snapshot", "snapshot": ["schemaVersion": 2, "snapshotSequence": 1,
            "projects": [project], "threads": [thread], "archivedThreads": []]]
        let normalizedShell = try adapter.streamItem(shell, method: "orchestration.subscribeShell", input: [:])!
        guard case .snapshot(let decodedShell) = try ShellStreamItem.decode(from: normalizedShell) else { fatalError("Missing shell snapshot") }
        precondition(decodedShell.projects.count == 1 && decodedShell.threads.count == 1)
        precondition(decodedShell.threads[0].latestTurn?.state == .running)
        let enrichment: [String: Any] = ["kind": "snapshot", "resolvedRepositoryIdentityRoots": ["/tmp/fixture"],
            "snapshot": ["snapshotSequence": 1, "projects": [project], "threads": [], "archivedThreads": []]]
        let enriched = try adapter.streamItem(enrichment, method: "orchestration.subscribeShell", input: [:])!
        guard case .snapshot(let enrichedShell) = try ShellStreamItem.decode(from: enriched) else { fatalError("Missing enrichment") }
        precondition(enrichedShell.projects.count == 1 && enrichedShell.threads.count == 1)
        let completion = try adapter.streamItem(["kind": "synchronized"], method: "orchestration.subscribeShell", input: [:])
        precondition(completion == nil)
        let update: [String: Any] = ["kind": "thread.updated", "sequence": 2, "thread": thread]
        guard case .threadUpserted = try ShellStreamItem.decode(from: adapter.streamItem(update, method: "orchestration.subscribeShell", input: [:])!) else { fatalError("Missing shell update") }
        print("PASS: v2 shell snapshot, status, updates and completion marker")

        let message: [String: Any] = ["id": "message-fixture", "role": "assistant", "text": "Hello", "streaming": true,
            "createdAt": date, "updatedAt": date, "runId": "run-fixture", "attachments": []]
        let run: [String: Any] = ["id": "run-fixture", "ordinal": 1, "status": "running", "requestedAt": date]
        let projection: [String: Any] = ["thread": thread, "runs": [run], "messages": [message], "runtimeRequests": [],
            "turnItems": [], "plans": [], "providerSessions": [], "updatedAt": date]
        let input: [String: Any] = ["threadId": "thread-fixture"]
        let snapshot: [String: Any] = ["kind": "snapshot", "snapshotSequence": 3, "projection": projection]
        let normalizedThread = try adapter.streamItem(snapshot, method: "orchestration.subscribeThread", input: input)!
        guard case .snapshot(let detail, _) = try ThreadStreamItem.decode(from: normalizedThread) else { fatalError("Missing thread projection") }
        precondition(detail.messages.first?.text == "Hello")
        precondition(detail.messages.first?.turnId?.rawValue == "run-fixture")
        precondition(detail.latestTurn?.state == .running)
        var finished = message
        finished["text"] = "Hello world"
        finished["streaming"] = false
        let event: [String: Any] = ["kind": "event", "sequence": 4, "event": ["type": "message.updated", "payload": finished, "occurredAt": date]]
        let normalizedEvent = try adapter.streamItem(event, method: "orchestration.subscribeThread", input: input)!
        guard case .snapshot(let updated, _) = try ThreadStreamItem.decode(from: normalizedEvent) else { fatalError("Missing message update") }
        precondition(updated.messages.count == 1 && updated.messages[0].text == "Hello world" && !updated.messages[0].streaming)
        print("PASS: v2 thread projection and streaming message replacement")

        let command: [String: Any] = ["type": "thread.turn.start", "commandId": "command-fixture", "threadId": "thread-fixture",
            "message": ["messageId": "outgoing-fixture", "text": "Fixture prompt", "attachments": []],
            "runtimeMode": "full-access", "interactionMode": "default", "modelSelection": model]
        let send = try adapter.operations(for: command)
        precondition(send.count == 1 && send[0].payload["type"] as? String == "message.dispatch")
        precondition(send[0].payload["text"] as? String == "Fixture prompt")
        precondition((send[0].payload["dispatchMode"] as? [String: String])?["targetRunId"] == "run-fixture")
        var creation = command
        creation["bootstrap"] = ["createThread": ["projectId": "project-fixture", "title": "New fixture", "modelSelection": model,
            "runtimeMode": "approval-required", "interactionMode": "default"]]
        let launch = try adapter.operations(for: creation)
        precondition(launch.count == 1 && launch[0].method == "orchestration.launchThread")
        precondition((launch[0].payload["workspaceStrategy"] as? [String: String])?["type"] == "root")
        for (legacy, modern) in [("thread.approval.respond", "runtime-request.respond"), ("thread.user-input.respond", "runtime-request.respond"), ("thread.session.stop", "thread.stop")] {
            let operation = try adapter.operations(for: ["type": legacy, "threadId": "thread-fixture", "commandId": "fixture"])
            precondition(operation[0].payload["type"] as? String == modern)
        }
        let rename = try adapter.operations(for: ["type": "thread.meta.update", "threadId": "thread-fixture", "title": "Renamed", "commandId": "fixture"])
        precondition(rename[0].payload["type"] as? String == "thread.metadata.update")
        print("PASS: v2 send, steering, launch, approval, stop and rename commands")
    }
}
