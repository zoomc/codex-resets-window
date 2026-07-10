import Foundation

enum CodexDataError: LocalizedError {
    case missingLogin
    case invalidLogin
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingLogin: "未找到本机 Codex 登录状态"
        case .invalidLogin: "本机 Codex 登录状态无效，请重新登录"
        case .invalidResponse: "无法读取 Codex 用量数据"
        }
    }
}

actor CodexDataService {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    func fetchUsage() async throws -> UsageSnapshot {
        let authURL = home.appending(path: ".codex/auth.json")
        guard let authData = try? Data(contentsOf: authURL) else { throw CodexDataError.missingLogin }
        guard let auth = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = (tokens["access_token"] ?? tokens["accessToken"]) as? String else {
            throw CodexDataError.invalidLogin
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = Self.accountID(from: token) ?? (tokens["account_id"] ?? tokens["accountId"]) as? String {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CodexDataError.invalidResponse }
        return try JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func loadSessions() -> [CodexSession] {
        let url = home.appending(path: ".codex/session_index.jsonl")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return contents.split(separator: "\n").compactMap { try? decoder.decode(CodexSession.self, from: Data($0.utf8)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func accountID(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }
}
