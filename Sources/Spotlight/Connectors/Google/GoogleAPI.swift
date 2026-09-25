import Foundation

enum GoogleAPIError: Error, Equatable, CustomStringConvertible {
    // 404, which for Gmail history and Drive changes means "that bookmark is too old".
    case notFound
    case http(status: Int, body: String)

    var description: String {
        switch self {
        case .notFound: "Google: not found"
        case .http(let status, let body): "Google error \(status): \(body.prefix(200))"
        }
    }
}

// Calls Google's REST APIs as one account: adds the access token, decodes
// the JSON, and retries politely when Google says "too many requests".
struct GoogleAPI: Sendable {
    let email: String
    let tokens: GoogleTokens
    var http: any HTTPClient = URLSession.shared
    // How long to wait before retry number `attempt` (1, 2, ...): 5, 10, 20,
    // 40 seconds, long enough in total for a per-minute quota to reset.
    // Replaceable so tests don't actually sleep.
    var backoff: @Sendable (Int) async -> Void = { attempt in
        try? await Task.sleep(for: .seconds(5 * pow(2, Double(attempt - 1))))
    }

    static let maxAttempts = 5

    // GETs `url` with `query` and decodes the JSON reply into `T`.
    func get<T: Decodable>(_ url: String, _ query: [URLQueryItem] = [], as type: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await data(url, query))
    }

    func data(_ url: String, _ query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(string: url)!
        if !query.isEmpty { components.queryItems = query }
        for attempt in 1...Self.maxAttempts {
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(try await tokens.accessToken(for: email))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await http.send(request)
            switch response.statusCode {
            case 200..<300:
                return data
            case 404:
                throw GoogleAPIError.notFound
            // Google reports running out of quota as 403, not 429 ("Quota
            // exceeded", "rateLimitExceeded"). Other 403s (no permission) are real.
            case 403 where attempt < Self.maxAttempts && Self.isRateLimit(data):
                await backoff(attempt)
            // 429 = too many requests; 5xx = Google having a moment. Both are worth
            // retrying after a pause that doubles each time ("exponential backoff").
            // (`where` applies to one pattern only, so each gets its own.)
            case 429 where attempt < Self.maxAttempts, 500...599 where attempt < Self.maxAttempts:
                await backoff(attempt)
            default:
                throw GoogleAPIError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
            }
        }
        throw GoogleAPIError.http(status: 429, body: "gave up after \(Self.maxAttempts) attempts")
    }

    static func isRateLimit(_ body: Data) -> Bool {
        let text = String(decoding: body, as: UTF8.self)
        return ["rateLimitExceeded", "userRateLimitExceeded", "Quota exceeded"].contains { text.contains($0) }
    }
}

extension Array where Element: Sendable {
    // Runs `transform` on every element, at most `width` at a time, keeping
    // results in the original order and skipping nils. For fetching thousands
    // of emails without opening thousands of connections at once.
    func concurrentMap<T: Sendable>(
        width: Int, _ transform: @escaping @Sendable (Element) async throws -> T?
    ) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, T?).self) { group in
            var results = [T?](repeating: nil, count: count)
            var next = 0
            // Start `width` tasks, then start one more each time one finishes.
            for _ in 0..<Swift.min(width, count) {
                let index = next, element = self[index]
                group.addTask { (index, try await transform(element)) }
                next += 1
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                if next < count {
                    let index = next, element = self[index]
                    group.addTask { (index, try await transform(element)) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }
}
