import Foundation

enum T3Error: Error { case requestFailed(String) }

@main
struct SendingRegression {
    static func main() throws {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message); print("FAIL: \(message)") }
        }
        let adapter = OrchestrationV2()
        let model: [String: Any] = ["instanceId": "codex", "model": "fixture-model"]
        var command: [String: Any] = ["type": "thread.turn.start", "commandId": "fixture-command", "threadId": "fixture-thread",
            "message": ["messageId": "fixture-message", "text": "Fixture prompt", "attachments": []],
            "modelSelection": model, "runtimeMode": "approval-required", "interactionMode": "default"]
        let sends = try adapter.operations(for: command)
        let send = sends.last!
        check(send.method == "orchestration.dispatchCommand", "existing thread RPC method")
        check(send.payload["createdBy"] as? String == "user", "message.dispatch requires createdBy=user in server 0.1.7")
        check(send.payload["creationSource"] as? String == "mobile", "message.dispatch requires creationSource=mobile in server 0.1.7")
        check((send.payload["dispatchMode"] as? [String: String])?["type"] == "start_immediately", "idle thread starts immediately")
        let encoded = try EffectRPCEncoder.encode(.request(id: "1", tag: send.method, payload: send.payload, headers: []))
        let request = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        check((request["payload"] as? [String: Any])?["createdBy"] as? String == "user", "actor survives RPC encoding")
        command["bootstrap"] = ["createThread": ["projectId": "fixture-project", "title": "Fixture", "modelSelection": model,
            "runtimeMode": "approval-required", "interactionMode": "default"]]
        let launch = try adapter.operations(for: command)[0]
        check(launch.method == "orchestration.launchThread", "new thread uses launchThread")
        check(launch.payload["creationSource"] as? String == "mobile", "new thread records mobile source")
        check((launch.payload["initialMessage"] as? [String: Any])?["text"] as? String == "Fixture prompt", "new thread preserves first message")

        // Captured from desktop 0.1.7 when the old iOS request lacked createdBy.
        let missingKey = "Missing key\n  at [\"createdBy\"]"
        let cases: [(String, Any, String?, String)] = [
            ("v2 schema defect", [["_tag": "Die", "defect": missingKey]], nil, missingKey),
            ("v2 typed failure", [["_tag": "Fail", "error": ["_tag": "OrchestrationV2DispatchCommandError", "message": "Fixture thread not found"]]], "OrchestrationV2DispatchCommandError", "Fixture thread not found"),
            ("v2 object defect", [["_tag": "Die", "defect": ["name": "Error", "message": "Fixture provider unavailable"]]], nil, "Fixture provider unavailable"),
            ("v2 string failure", [["_tag": "Fail", "error": "Fixture failure"]], nil, "Fixture failure"),
            ("v1 typed failure", ["_tag": "Fail", "error": ["_tag": "LegacyError", "message": "Fixture legacy error"]], "LegacyError", "Fixture legacy error"),
            ("v1 defect", ["_tag": "Die", "defect": "Fixture legacy defect"], nil, "Fixture legacy defect"),
            ("empty failure", [], nil, "服务器错误")
        ]
        for (label, cause, tag, expected) in cases {
            let frame: [String: Any] = ["_tag": "Exit", "requestId": "1", "exit": ["_tag": "Failure", "cause": cause]]
            let decoded = try EffectRPCDecoder.decodeFrame(JSONSerialization.data(withJSONObject: frame))
            guard case let .exit(id, success, _, errorTag, errorMessage) = decoded[0] else {
                failures.append("\(label): missing Exit"); continue
            }
            check(id == "1" && !success && errorTag == tag && errorMessage == expected, "\(label) preserves server reason")
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--emit-fixtures" {
            let fixtures: [[String: Any]] = [["method": send.method, "payload": send.payload], ["method": launch.method, "payload": launch.payload]]
            try JSONSerialization.data(withJSONObject: fixtures, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        guard failures.isEmpty else { print("FAIL: \(failures.count) sending regressions"); exit(1) }
        print("PASS: existing-thread send and new-thread first-message RPC payloads")
        print("PASS: protocol 1 and 2 typed errors and defects retain server reasons")
    }
}
