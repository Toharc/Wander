import Foundation
import CoreLocation

struct RadarPokemon: Identifiable, Decodable, Hashable {
    let id: String
    let pokemonID: Int
    let latitude: Double
    let longitude: Double
    let expireTimestamp: Int64?
    let cp: Int?
    let level: Double?
    let attackIV: Int?
    let defenseIV: Int?
    let staminaIV: Int?
    let move1: Int?
    let move2: Int?
    let gender: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case pokemonID = "pokemon_id"
        case latitude = "lat"
        case longitude = "lon"
        case expireTimestamp = "expire_timestamp"
        case cp
        case level
        case attackIV = "atk_iv"
        case defenseIV = "def_iv"
        case staminaIV = "sta_iv"
        case move1 = "move_1"
        case move2 = "move_2"
        case gender
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var ivPercent: Int? {
        guard let attackIV, let defenseIV, let staminaIV else { return nil }
        return Int(round(Double(attackIV + defenseIV + staminaIV) / 45.0 * 100.0))
    }

    var expiresAt: Date? {
        guard let expireTimestamp else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expireTimestamp))
    }

    func distanceKm(from center: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude)) / 1000.0
    }
}

struct RadarSearchFilters: Equatable {
    var pokemonIDs: Set<Int> = []
    var minIV: Int? = nil
    var minCP: Int? = nil
    var minLevel: Double? = nil
    var maxDistanceKm: Double = 25
    var limit: Int = 500
}

struct PokemonSpecies: Identifiable, Hashable, Codable {
    let id: Int
    let name: String

    var displayName: String {
        name.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
