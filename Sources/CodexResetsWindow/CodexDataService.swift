import Foundation

/// Every failure the usage request can produce.
///
/// The previous version collapsed 401, 429, 5xx, timeouts and decoding problems into a single
/// "usage data could not be loaded" message, so the user had no idea whether to re-login, wait, or
/// file a bug. Each case now maps to one actionable sentence.
enum CodexDataError: LocalizedError, Equatable {
    case missingLogin
    case invalidLogin
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case unexpectedStatus(status: Int)
    case timedOut
    case offline
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingLogin:
            "Codex login state was not found on this Mac."
        case .invalidLogin:
            "Codex login state is invalid. Please sign in again."
        case .unauthorized:
            "ChatGPT rejected the Codex login. Open Codex and sign in again."
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                "ChatGPT is rate limiting usage requests. Retrying in \(Int(retryAfter.rounded()))s."
            } else {
                "ChatGPT is rate limiting usage requests."
            }
        case .serverError(let status):
            "ChatGPT returned a server error (\(status))."
        case .unexpectedStatus(let status):
            "ChatGPT returned an unexpected response (\(status))."
        case .timedOut:
            "The usage request timed out."
        case .offline:
            "This Mac appears to be offline."
        case .decodingFailed:
            "ChatGPT changed its usage format, so the response could not be read."
        }
    }

    /// Whether a retry is likely to help.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .serverError, .timedOut, .offline: true
        case .missingLogin, .invalidLogin, .unauthorized, .unexpectedStatus, .decodingFailed: false
        }
    }

    /// Suggested delay before the next automatic attempt.
    var retryDelay: TimeInterval {
        switch self {
        case .rateLimited(let retryAfter): return max(30, retryAfter ?? 60)
        case .serverError: return 60
        case .timedOut, .offline: return 30
        default: return 60
        }
    }
}

/// Reads the local Codex login and performs the read-only usage request.
actor CodexDataService {
    private let config: AppConfig

    init(config: AppConfig = .default) { self.config = config }

    func fetchUsage() async throws -> UsageSnapshot {
        // Sandbox fixtures keep the integration tests off the network entirely.
        if let fixture = config.usageFixture {
            let data = try Data(contentsOf: fixture)
            return try decode(data)
        }
        let token = try accessToken()
        let request = try makeRequest(token: token)
        let data: Data
        do {
            let (payload, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CodexDataError.unexpectedStatus(status: 0) }
            switch http.statusCode {
            case 200: data = payload
            case 401, 403: throw CodexDataError.unauthorized
            case 429: throw CodexDataError.rateLimited(retryAfter: Self.retryAfter(from: http))
            case 500...599: throw CodexDataError.serverError(status: http.statusCode)
            default: throw CodexDataError.unexpectedStatus(status: http.statusCode)
            }
        } catch let error as CodexDataError {
            throw error
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut: throw CodexDataError.timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                throw CodexDataError.offline
            default: throw CodexDataError.unexpectedStatus(status: 0)
            }
        }
        return try decode(data)
    }

    // MARK: - Request construction

    private func makeRequest(token: String) throws -> URLRequest {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw CodexDataError.invalidLogin
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    private func decode(_ data: Data) throws -> UsageSnapshot {
        do {
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            AppLog.error("usage payload could not be decoded: \(error.localizedDescription)", category: .usage)
            throw CodexDataError.decodingFailed
        }
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        if let raw = response.value(forHTTPHeaderField: "Retry-After"), let value = Double(raw) {
            return value
        }
        return nil
    }

    // MARK: - Credentials

    private let authURL: URL = {
        AppConfig.default.codexHome.appendingPathComponent("auth.json")
    }()

    private var authLocation: URL { config.codexHome.appendingPathComponent("auth.json") }

    private func accessToken() throws -> String {
        guard let data = try? Data(contentsOf: authLocation) else { throw CodexDataError.missingLogin }
        guard let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = (tokens["access_token"] ?? tokens["accessToken"]) as? String,
              !token.isEmpty else { throw CodexDataError.invalidLogin }
        return token
    }

    private var accountID: String? {
        guard let data = try? Data(contentsOf: authLocation),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any] else { return nil }
        if let explicit = (tokens["account_id"] ?? tokens["accountId"]) as? String { return explicit }
        if let token = (tokens["access_token"] ?? tokens["accessToken"]) as? String {
            return Self.accountID(fromJWT: token)
        }
        return nil
    }

    /// Reads `chatgpt_account_id` out of the JWT payload without validating the signature.
    static func accountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = json["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String
    }
}
