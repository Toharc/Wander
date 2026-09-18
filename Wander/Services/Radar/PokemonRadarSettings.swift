import Foundation

@MainActor
final class PokemonRadarSettings: ObservableObject {
    static let shared = PokemonRadarSettings()

    @Published var baseURLText: String {
        didSet { UserDefaults.standard.set(baseURLText, forKey: Keys.baseURL) }
    }
    @Published var apiSecret: String {
        didSet { UserDefaults.standard.set(apiSecret, forKey: Keys.secret) }
    }
    @Published var demoMode: Bool {
        didSet { UserDefaults.standard.set(demoMode, forKey: Keys.demo) }
    }

    private enum Keys {
        static let baseURL = "wanderRadar.baseURL"
        static let secret = "wanderRadar.apiSecret"
        static let demo = "wanderRadar.demoMode"
    }

    private init() {
        baseURLText = UserDefaults.standard.string(forKey: Keys.baseURL) ?? ""
        apiSecret = UserDefaults.standard.string(forKey: Keys.secret) ?? ""
        if UserDefaults.standard.object(forKey: Keys.demo) == nil {
            demoMode = true
        } else {
            demoMode = UserDefaults.standard.bool(forKey: Keys.demo)
        }
    }

    var liveConfiguration: PokemonRadarService.Configuration? {
        guard !demoMode,
              let url = URL(string: baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)),
              !apiSecret.isEmpty else { return nil }
        return .init(baseURL: url, apiSecret: apiSecret)
    }
}
