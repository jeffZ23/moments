import Foundation
import MomentCore

enum BackendError: LocalizedError {
    case notConfigured
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "BACKEND_URL or BACKEND_TOKEN is missing from Secrets.xcconfig."
        case .http(let code, let message): return "Backend error \(code): \(message)"
        }
    }
}

/// Talks to the Moments backend (a Cloudflare Worker that calls Claude).
final class BackendClient: PickService {
    private let config: AppConfig
    private let session: URLSession

    init(config: AppConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.default
        // Moments are short-lived; if the backend is slow, fall back to saved picks instead of waiting.
        configuration.timeoutIntervalForRequest = 25
        session = URLSession(configuration: configuration)
    }

    func pick(_ request: PickRequestPayload) async throws -> PickResponsePayload {
        try await post("v1/pick", request)
    }

    func cards(for tracks: [Track]) async throws -> [SongCard] {
        let response: CardsResponsePayload = try await post("v1/cards", CardsRequestPayload(tracks: tracks), timeout: 120)
        return response.songCards
    }

    func discover(_ request: DiscoverRequestPayload) async throws -> DiscoverResponsePayload {
        try await post("v1/discover", request)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, _ body: Body, timeout: TimeInterval? = nil) async throws -> Response {
        guard let base = config.backendURL, !config.backendToken.isEmpty else { throw BackendError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.backendToken)", forHTTPHeaderField: "Authorization")
        if let timeout { request.timeoutInterval = timeout }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw BackendError.http(status, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
