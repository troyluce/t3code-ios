import Foundation

struct PairingResult: Sendable {
    let bearerToken: String
}

enum PairingFlow {
    struct WebSocketToken: Sendable {
        let token: String
    }

    static func fetchEnvironment(serverURL: URL) async throws -> EnvironmentDescriptor {
        let url = serverBaseURL(from: serverURL).appendingPathComponent(".well-known/t3/environment")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw T3Error.pairingFailed("服务器没有响应")
        }
        guard http.statusCode == 200 else {
            throw T3Error.pairingFailed(
                "获取服务器环境失败（状态码 \(http.statusCode)）：\(errorMessage(from: data))"
            )
        }
        guard let descriptor = EnvironmentDescriptor.decodeLenient(data) else {
            throw T3Error.pairingFailed("服务器环境信息无效")
        }
        return descriptor
    }

    static func exchangeToken(serverURL: URL, oneTimeToken: String) async throws -> PairingResult {
        let url = serverBaseURL(from: serverURL).appendingPathComponent("api/auth/bootstrap/bearer")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        let body: [String: Any] = ["credential": oneTimeToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw T3Error.pairingFailed("服务器没有响应")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw T3Error.pairingFailed("配对令牌被拒绝：\(errorMessage(from: data))")
        }
        guard (200...299).contains(http.statusCode) else {
            throw T3Error.pairingFailed(
                "配对失败（状态码 \(http.statusCode)）：\(errorMessage(from: data))"
            )
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let token = (json["sessionToken"] ?? json["token"] ?? json["bearer"]) as? String,
               !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return PairingResult(bearerToken: token)
            }
        }

        throw T3Error.pairingFailed("配对响应中缺少登录令牌")
    }

    static func issueWebSocketToken(serverURL: URL, bearerToken: String) async throws -> WebSocketToken {
        let url = serverBaseURL(from: serverURL).appendingPathComponent("api/auth/ws-token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw T3Error.pairingFailed("服务器没有响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw T3Error.pairingFailed(
                "获取 WebSocket 令牌失败（状态码 \(http.statusCode)）：\(errorMessage(from: data))"
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw T3Error.pairingFailed("WebSocket 令牌响应无效")
        }
        return WebSocketToken(token: token)
    }

    static func parsePairingURL(_ raw: String) -> (serverURL: URL, token: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let comps = URLComponents(string: trimmed) else { return nil }

        if let host = comps.queryItems?.first(where: { $0.name == "host" })?.value,
           let backend = URL(string: host),
           let token = parseToken(from: comps) {
            return (serverBaseURL(from: backend), token)
        }

        if let token = parseToken(from: comps),
           let scheme = comps.scheme, let host = comps.host {
            var direct = URLComponents()
            direct.scheme = scheme
            direct.host = host
            direct.port = comps.port
            return direct.url.map { ($0, token) }
        }
        return nil
    }

    static func serverBaseURL(from url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        comps.path = ""
        comps.query = nil
        comps.fragment = nil
        return comps.url ?? url
    }

    private static func parseToken(from comps: URLComponents) -> String? {
        if let token = parseTokenFromFragment(comps.fragment) {
            return token
        }
        return comps.queryItems?.first(where: { $0.name == "token" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTokenFromFragment(_ fragment: String?) -> String? {
        guard let fragment,
              let comps = URLComponents(string: "?\(fragment)"),
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["error"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return "响应为空"
    }
}
