import Foundation

/// HTTP client for the Suply API.
///
/// Configuration mirrors Android's `NetworkModule.kt`:
///   • 60s request + resource timeouts.
///   • JSON encode/decode (Codable). DTOs use explicit `CodingKeys` for
///     snake_case mapping — no `keyDecodingStrategy` set.
///   • Date fields stay as ISO-8601 strings (per handoff §3.1); consumers
///     parse via `ISO8601DateFormatter` when needed.
///   • No body logging in release builds — guarded by `#if DEBUG`.
///   • **No auth headers** — the consignee app is stateless and uses AWB
///     / container number as the credential (handoff §9). Login flow is
///     for the dashboard surface, not this app.
///
/// Errors are surfaced as `APIClient.Error`. Non-2xx responses include
/// the decoded `ApiError` envelope when the body parses as one.
///
/// `@unchecked Sendable`: all stored properties are `let` and the types
/// (`URL`, `URLSession`, `JSONDecoder`, `JSONEncoder`) are thread-safe in
/// practice though not all marked `Sendable` by Apple yet. The singleton
/// is read-only after init, so concurrent access is safe.
final class APIClient: @unchecked Sendable {

    enum Error: Swift.Error, CustomStringConvertible {
        case invalidBaseURL
        case invalidResponse
        case http(status: Int, body: ApiError?)
        case decoding(Swift.Error)
        case transport(Swift.Error)

        var description: String {
            switch self {
            case .invalidBaseURL:
                return "API_BASE_URL missing or malformed in Info.plist"
            case .invalidResponse:
                return "non-HTTP response from server"
            case .http(let status, let body):
                let msg = body?.message ?? body?.error ?? "no error body"
                return "HTTP \(status): \(msg)"
            case .decoding(let err):
                return "decoding failed: \(err)"
            case .transport(let err):
                return "transport failed: \(err)"
            }
        }
    }

    static let shared = APIClient()

    /// DIAGNOSTIC (see init): User-Agent that mimics Android OkHttp's
    /// default. Format is `okhttp/<version>`. Picked 4.12.0 as a
    /// representative modern OkHttp release — exact version probably
    /// doesn't matter to the backend if it's just sniffing the `okhttp/`
    /// prefix. Revert this once Suply's backend stops dispatching on
    /// the client header.
    private static let diagnosticUserAgent = "okhttp/4.12.0"

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        // Bootstrap from Info.plist — Shared.xcconfig defines API_BASE_URL.
        // Missing here is a build-config bug, not a runtime condition.
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
              let url = URL(string: raw) else {
            fatalError("API_BASE_URL missing or malformed in Info.plist — check Config/Shared.xcconfig")
        }
        baseURL = url

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        // DIAGNOSTIC: override User-Agent to match OkHttp's default
        // (`okhttp/x.y.z`) so the Suply backend can't dispatch on the
        // client header. The iOS-default UA is something like
        // `EchoAir/0.7.0 CFNetwork/... Darwin/...` — different shape
        // from Android. If `/api/vision/identify-shipment` starts
        // returning shipments for AWB-only payloads with this UA, the
        // backend's dispatch branches on UA (and the proper fix is on
        // the backend side, not iOS). If the 500 persists, UA-sniff is
        // ruled out and we move to the next diagnostic
        // (Accept-Encoding, or explicit `container_number: null`).
        config.httpAdditionalHeaders = ["User-Agent": Self.diagnosticUserAgent]
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    // MARK: - Endpoints

    /// POST /api/vision/identify-shipment with `{ "awb_number": "..." }`.
    func identifyShipment(awb: String) async throws -> VisionResponse {
        try await postJSON(
            path: "/api/vision/identify-shipment",
            body: VisionRequest(awbNumber: awb)
        )
    }

    /// POST /api/vision/identify-shipment with `{ "container_number": "..." }`.
    func identifyShipment(container: String) async throws -> VisionResponse {
        try await postJSON(
            path: "/api/vision/identify-shipment",
            body: VisionRequest(containerNumber: container)
        )
    }

    /// GET /api/devices/lookup?identifier={id}&include_shipment=true.
    func lookupDevice(identifier: String) async throws -> DeviceLookupResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/devices/lookup"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "identifier", value: identifier),
            URLQueryItem(name: "include_shipment", value: "true")
        ]
        guard let url = components?.url else {
            throw Error.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    // MARK: - Internals

    private func postJSON<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(body)

        #if DEBUG
        if let data = request.httpBody, let s = String(data: data, encoding: .utf8) {
            print("[APIClient] POST \(path) body=\(s)")
        }
        #endif

        return try await send(request)
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Error.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let apiError = try? decoder.decode(ApiError.self, from: data)
            throw Error.http(status: http.statusCode, body: apiError)
        }

        #if DEBUG
        if let s = String(data: data, encoding: .utf8) {
            print("[APIClient] \(http.statusCode) \(request.url?.path ?? "?") <- \(s.prefix(500))")
        }
        #endif

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw Error.decoding(error)
        }
    }
}
