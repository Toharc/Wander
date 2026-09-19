import Foundation
import CoreLocation

enum LegacyIOS16Bridge {
    static let urlDefaultsKey = "wander.ios16Bridge.url"
    static let tokenDefaultsKey = "wander.ios16Bridge.token"

    enum BridgeError: LocalizedError {
        case notConfigured
        case invalidURL
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Configure the iOS 16 Windows Bridge in Radar Settings."
            case .invalidURL:
                return "The Windows Bridge URL is invalid."
            case .invalidResponse:
                return "The Windows Bridge returned an invalid response."
            case .server(let message):
                return message
            }
        }
    }

    private struct BridgeResponse: Decodable {
        let ok: Bool
        let error: String?
    }

    static var isConfigured: Bool {
        configuredURL != nil && !token.isEmpty
    }

    static var configuredURL: URL? {
        let raw = (UserDefaults.standard.string(forKey: urlDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let normalized = raw.contains("://") ? raw : "http://\(raw)"
        return URL(string: normalized)
    }

    static var token: String {
        (UserDefaults.standard.string(forKey: tokenDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func health() async throws {
        _ = try await request(path: "health", method: "GET", body: nil)
    }

    static func setLocation(_ coordinate: CLLocationCoordinate2D) async throws {
        let body: [String: Any] = [
            "lat": coordinate.latitude,
            "lon": coordinate.longitude
        ]
        _ = try await request(path: "location", method: "POST", body: body)
    }

    static func clearLocation() async throws {
        _ = try await request(path: "stop", method: "POST", body: [:])
    }

    @discardableResult
    private static func request(
        path: String,
        method: String,
        body: [String: Any]?
    ) async throws -> BridgeResponse {
        guard !token.isEmpty else { throw BridgeError.notConfigured }
        guard let base = configuredURL else { throw BridgeError.notConfigured }

        let url = base.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue(token, forHTTPHeaderField: "X-Wander-Token")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeError.invalidResponse
        }

        let decoded = try? JSONDecoder().decode(BridgeResponse.self, from: data)
        guard (200...299).contains(http.statusCode) else {
            throw BridgeError.server(decoded?.error ?? "Windows Bridge returned HTTP \(http.statusCode).")
        }
        guard let decoded else { throw BridgeError.invalidResponse }
        guard decoded.ok else {
            throw BridgeError.server(decoded.error ?? "Windows Bridge rejected the request.")
        }
        return decoded
    }
}
