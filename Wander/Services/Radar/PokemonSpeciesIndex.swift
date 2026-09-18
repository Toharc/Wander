import Foundation

actor PokemonSpeciesIndex {
    static let shared = PokemonSpeciesIndex()

    private var cached: [PokemonSpecies] = []
    private let cacheKey = "wanderRadar.speciesIndex.v1"

    func load() async -> [PokemonSpecies] {
        if !cached.isEmpty { return cached }

        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let saved = try? JSONDecoder().decode([PokemonSpecies].self, from: data),
           !saved.isEmpty {
            cached = saved
            return saved
        }

        struct PokeAPIList: Decodable {
            struct Item: Decodable { let name: String; let url: String }
            let results: [Item]
        }

        guard let url = URL(string: "https://pokeapi.co/api/v2/pokemon-species?limit=2000") else {
            return fallback
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return fallback
            }
            let list = try JSONDecoder().decode(PokeAPIList.self, from: data)
            let species: [PokemonSpecies] = list.results.compactMap { item in
                let pieces = item.url.split(separator: "/")
                guard let last = pieces.last, let id = Int(last) else { return nil }
                return PokemonSpecies(id: id, name: item.name)
            }
            if !species.isEmpty {
                cached = species
                if let encoded = try? JSONEncoder().encode(species) {
                    UserDefaults.standard.set(encoded, forKey: cacheKey)
                }
                return species
            }
        } catch {}
        cached = fallback
        return fallback
    }

    private var fallback: [PokemonSpecies] {
        [
            .init(id: 1, name: "bulbasaur"), .init(id: 4, name: "charmander"),
            .init(id: 7, name: "squirtle"), .init(id: 25, name: "pikachu"),
            .init(id: 94, name: "gengar"), .init(id: 133, name: "eevee"),
            .init(id: 143, name: "snorlax"), .init(id: 149, name: "dragonite"),
            .init(id: 150, name: "mewtwo"), .init(id: 246, name: "larvitar"),
            .init(id: 280, name: "ralts"), .init(id: 371, name: "bagon"),
            .init(id: 443, name: "gible"), .init(id: 447, name: "riolu"),
            .init(id: 633, name: "deino"), .init(id: 704, name: "goomy"),
            .init(id: 782, name: "jangmo-o"), .init(id: 885, name: "dreepy")
        ]
    }
}
