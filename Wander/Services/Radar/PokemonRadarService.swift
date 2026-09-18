import Foundation
import CoreLocation

actor PokemonRadarService {
    struct Configuration {
        var baseURL: URL
        var apiSecret: String
    }

    enum RadarError: LocalizedError {
        case configuration
        case badResponse
        case server(Int)
        case decode

        var errorDescription: String? {
            switch self {
            case .configuration: return "Configure a Golbat server in Radar Settings, or enable Demo Mode."
            case .badResponse: return "Invalid radar response."
            case .server(let code): return "Radar server returned HTTP \(code)."
            case .decode: return "Could not decode Pokémon data."
            }
        }
    }

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func search(center: CLLocationCoordinate2D,
                filters: RadarSearchFilters,
                configuration: Configuration?,
                demoMode: Bool) async throws -> [RadarPokemon] {
        if demoMode { return demo(center: center, filters: filters) }
        guard let configuration else { throw RadarError.configuration }

        let latRadius = filters.maxDistanceKm / 111.0
        let lonScale = max(cos(center.latitude * .pi / 180.0), 0.05)
        let lonRadius = filters.maxDistanceKm / (111.0 * lonScale)
        let body: [String: Any] = [
            "min": ["lat": center.latitude - latRadius, "lon": center.longitude - lonRadius],
            "max": ["lat": center.latitude + latRadius, "lon": center.longitude + lonRadius],
            "center": ["lat": center.latitude, "lon": center.longitude],
            "limit": filters.limit,
            "searchIds": Array(filters.pokemonIDs).sorted()
        ]

        let url = configuration.baseURL.appending(path: "api/pokemon/search")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiSecret, forHTTPHeaderField: "X-Golbat-Secret")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RadarError.badResponse }
        guard (200...299).contains(http.statusCode) else { throw RadarError.server(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode([RadarPokemon].self, from: data) else {
            throw RadarError.decode
        }
        return applyLocalFilters(decoded, filters: filters)
    }

    private func applyLocalFilters(_ input: [RadarPokemon], filters: RadarSearchFilters) -> [RadarPokemon] {
        input.filter { mon in
            if let minIV = filters.minIV, (mon.ivPercent ?? -1) < minIV { return false }
            if let minCP = filters.minCP, (mon.cp ?? -1) < minCP { return false }
            if let minLevel = filters.minLevel, (mon.level ?? -1) < minLevel { return false }
            return filters.pokemonIDs.isEmpty || filters.pokemonIDs.contains(mon.pokemonID)
        }
    }

    private func demo(center: CLLocationCoordinate2D, filters: RadarSearchFilters) -> [RadarPokemon] {
        let now = Int64(Date().timeIntervalSince1970)
        let ids = filters.pokemonIDs.isEmpty ? [25, 443, 447, 633, 150, 133] : Array(filters.pokemonIDs)
        let rows: [RadarPokemon] = ids.enumerated().map { i, id in
            let offset = Double(i + 1) * 0.006
            let atk = 15 - (i % 4)
            let def = 15 - ((i + 1) % 4)
            let sta = 15 - ((i + 2) % 4)
            return RadarPokemon(
                id: "demo-\(id)-\(i)", pokemonID: id,
                latitude: center.latitude + (i.isMultiple(of: 2) ? offset : -offset),
                longitude: center.longitude + (i.isMultiple(of: 3) ? offset : -offset / 2),
                expireTimestamp: now + Int64(420 + i * 95),
                cp: 600 + i * 237, level: 20 + Double(i * 2),
                attackIV: atk, defenseIV: def, staminaIV: sta,
                move1: nil, move2: nil, gender: nil
            )
        }
        return applyLocalFilters(rows, filters: filters)
    }
}
