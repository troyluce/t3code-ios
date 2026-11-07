import Foundation

enum T3Error: LocalizedError {
    case pairingFailed(String), invalidServerURL
    var errorDescription: String? {
        switch self {
        case .pairingFailed(let message): return message
        case .invalidServerURL: return "服务器地址无效"
        }
    }
}

final class PairingStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var legacy = false
    nonisolated(unsafe) static var requests: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.requests.append(path)
        var status = 404
        var json: [String: Any] = ["error": "route_not_found"]
        if path == "/oauth/token" && !Self.legacy {
            let body = bodyData()
            let form = String(data: body, encoding: .utf8) ?? ""
            let fields = URLComponents(string: "https://fixture.invalid/?" + form)?.queryItems ?? []
            let values = Dictionary(fields.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, rhs in rhs })
            precondition(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true)
            precondition(values["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange")
            precondition(values["subject_token"] == "fixture-pairing-code")
            precondition(values["subject_token_type"] == "urn:t3:params:oauth:token-type:environment-bootstrap")
            precondition(values["requested_token_type"] == "urn:ietf:params:oauth:token-type:access_token")
            status = 200
            json = ["access_token": "fixture-bearer", "token_type": "Bearer", "expires_in": 3600]
        } else if path == "/api/auth/bootstrap/bearer" && Self.legacy {
            status = 200
            json = ["sessionToken": "fixture-bearer"]
        } else if path == "/api/auth/websocket-ticket/rpc" && !Self.legacy {
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-bearer")
            status = 200
            json = ["ticket": "fixture-ticket", "expiresAt": "2030-01-01T00:00:00Z"]
        } else if path == "/api/auth/ws-token" && Self.legacy {
            status = 200
            json = ["token": "fixture-ticket"]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    private func bodyData() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@main
struct PairingRegression {
    static func main() async {
        URLProtocol.registerClass(PairingStub.self)
        do {
            let base = URL(string: "https://fixture.invalid")!
            for legacy in [false, true] {
                PairingStub.legacy = legacy
                PairingStub.requests = []
                let result = try await PairingFlow.exchangeToken(serverURL: base, oneTimeToken: "fixture-pairing-code")
                precondition(result.bearerToken == "fixture-bearer")
                let ticket = try await PairingFlow.issueWebSocketToken(serverURL: base, bearerToken: result.bearerToken)
                precondition(ticket.token == "fixture-ticket")
#if FIXED_CLIENT
                let url = try PairingFlow.webSocketURL(serverURL: base, authorization: ticket, protocolVersion: legacy ? 1 : 2)
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                precondition(url.scheme == "wss" && url.path == "/ws")
                precondition(query.contains { $0.name == (legacy ? "wsToken" : "wsTicket") && $0.value == "fixture-ticket" })
                precondition(legacy || query.contains { $0.name == "orchestrationProtocol" && $0.value == "2" })
#endif
                print("PASS: \(legacy ? "legacy fallback" : "OAuth and WebSocket ticket")")
            }
            print("PASS: pairing 404 regression")
        } catch {
            print("FAIL: pairing 404 regression: \(error.localizedDescription)")
            exit(1)
        }
    }
}
