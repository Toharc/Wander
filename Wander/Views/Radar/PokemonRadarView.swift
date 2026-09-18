import SwiftUI
import MapKit
import CoreLocation

@MainActor
final class PokemonRadarViewModel: ObservableObject {
    @Published var pokemon: [RadarPokemon] = []
    @Published var species: [PokemonSpecies] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var filters = RadarSearchFilters()
    @Published var query = ""
    @Published var selected: RadarPokemon?

    let service = PokemonRadarService()
    let settings = PokemonRadarSettings.shared

    func loadSpecies() async { species = await PokemonSpeciesIndex.shared.load() }

    var matchingSpecies: [PokemonSpecies] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return species.filter { $0.name.localizedCaseInsensitiveContains(q) || String($0.id) == q }
            .prefix(20)
            .map { $0 }
    }

    func addSpecies(_ item: PokemonSpecies) {
        filters.pokemonIDs.insert(item.id)
        query = ""
    }

    func refresh(center: CLLocationCoordinate2D) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            pokemon = try await service.search(
                center: center,
                filters: filters,
                configuration: settings.liveConfiguration,
                demoMode: settings.demoMode
            ).sorted { lhs, rhs in
                let li = lhs.ivPercent ?? -1
                let ri = rhs.ivPercent ?? -1
                if li != ri { return li > ri }
                return lhs.distanceKm(from: center) < rhs.distanceKm(from: center)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func name(for id: Int) -> String {
        species.first(where: { $0.id == id })?.displayName ?? "Pokémon #\(id)"
    }
}

struct PokemonRadarView: View {
    @StateObject private var model = PokemonRadarViewModel()
    @ObservedObject private var settings = PokemonRadarSettings.shared
    @State private var camera: MapCameraPosition
    @State private var searchCenter: CLLocationCoordinate2D
    @State private var showSettings = false
    var onPreview: (RadarPokemon) -> Void

    init(
        initialCenter: CLLocationCoordinate2D = .init(latitude: 32.0853, longitude: 34.7818),
        onPreview: @escaping (RadarPokemon) -> Void = { _ in }
    ) {
        _camera = State(initialValue: .region(MKCoordinateRegion(
            center: initialCenter,
            span: .init(latitudeDelta: 0.18, longitudeDelta: 0.18)
        )))
        _searchCenter = State(initialValue: initialCenter)
        self.onPreview = onPreview
    }

    var body: some View {
        NavigationSplitView {
            filterSidebar
                .navigationTitle("Pokémon Radar")
        } detail: {
            ZStack(alignment: .bottom) {
                radarMap
                if let mon = model.selected {
                    spawnCard(mon)
                }
            }
            .navigationTitle(settings.demoMode ? "Radar • Demo" : "Radar • Live")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await model.loadSpecies()
            await model.refresh(center: searchCenter)
        }
        .sheet(isPresented: $showSettings) {
            PokemonRadarSettingsView()
        }
    }

    private var filterSidebar: some View {
        List {
            Section {
                TextField("Search Pokémon (Gible, Mewtwo…)", text: $model.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                ForEach(model.matchingSpecies) { item in
                    Button {
                        model.addSpecies(item)
                    } label: {
                        HStack {
                            Text(item.displayName)
                            Spacer()
                            Text("#\(item.id)").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !model.filters.pokemonIDs.isEmpty {
                Section("Hunting") {
                    ForEach(model.filters.pokemonIDs.sorted(), id: \.self) { id in
                        HStack {
                            Text(model.name(for: id))
                            Spacer()
                            Button(role: .destructive) {
                                model.filters.pokemonIDs.remove(id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button("Clear Pokémon") {
                        model.filters.pokemonIDs.removeAll()
                    }
                }
            }

            Section("Filters") {
                Stepper(
                    "Minimum IV: \(model.filters.minIV ?? 0)%",
                    value: Binding(
                        get: { model.filters.minIV ?? 0 },
                        set: { model.filters.minIV = $0 == 0 ? nil : $0 }
                    ),
                    in: 0...100,
                    step: 5
                )

                Stepper(
                    "Minimum CP: \(model.filters.minCP ?? 0)",
                    value: Binding(
                        get: { model.filters.minCP ?? 0 },
                        set: { model.filters.minCP = $0 == 0 ? nil : $0 }
                    ),
                    in: 0...5000,
                    step: 100
                )

                Stepper(
                    "Minimum level: \(Int(model.filters.minLevel ?? 0))",
                    value: Binding(
                        get: { Int(model.filters.minLevel ?? 0) },
                        set: { model.filters.minLevel = $0 == 0 ? nil : Double($0) }
                    ),
                    in: 0...50
                )

                Stepper(
                    "Radius: \(Int(model.filters.maxDistanceKm)) km",
                    value: $model.filters.maxDistanceKm,
                    in: 1...100,
                    step: 5
                )

                Button("100% IV only") {
                    model.filters.minIV = 100
                }
            }

            Section {
                Button {
                    Task { await model.refresh(center: searchCenter) }
                } label: {
                    Label(model.isLoading ? "Searching…" : "Search this map", systemImage: "scope")
                }
                .disabled(model.isLoading)

                Button {
                    showSettings = true
                } label: {
                    Label("Radar Settings", systemImage: "gearshape")
                }
            }

            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Results • \(model.pokemon.count)") {
                ForEach(model.pokemon) { mon in
                    Button {
                        model.selected = mon
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(model.name(for: mon.pokemonID))
                                    .fontWeight(.semibold)
                                Spacer()
                                if let iv = mon.ivPercent {
                                    Text("\(iv)%")
                                        .font(.caption.bold())
                                }
                            }

                            HStack(spacing: 8) {
                                if let cp = mon.cp { Text("CP \(cp)") }
                                if let level = mon.level { Text("L\(Int(level))") }
                                Text(String(format: "%.1f km", mon.distanceKm(from: searchCenter)))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var radarMap: some View {
        Map(position: $camera) {
            ForEach(model.pokemon) { mon in
                Annotation(model.name(for: mon.pokemonID), coordinate: mon.coordinate) {
                    Button {
                        model.selected = mon
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "scope")
                                .font(.title3)
                            if let iv = mon.ivPercent {
                                Text("\(iv)%")
                                    .font(.caption2.bold())
                            }
                        }
                        .padding(7)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            searchCenter = context.region.center
        }
    }

    private func spawnCard(_ mon: RadarPokemon) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.name(for: mon.pokemonID))
                        .font(.headline)

                    HStack(spacing: 10) {
                        if let iv = mon.ivPercent { Text("IV \(iv)%") }
                        if let cp = mon.cp { Text("CP \(cp)") }
                        if let level = mon.level { Text("Level \(Int(level))") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    model.selected = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }

            if let expires = mon.expiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let seconds = max(0, Int(expires.timeIntervalSinceNow))
                    Text("Despawns in \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .font(.caption.monospacedDigit())
                }
            }

            Button {
                onPreview(mon)
            } label: {
                Label("Preview in Teleport", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding()
        .frame(maxWidth: 520)
    }
}

struct PokemonRadarSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = PokemonRadarSettings.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Demo Mode", isOn: $settings.demoMode)
                } footer: {
                    Text("Demo Mode uses sample spawns so the UI can be tested before a live Golbat backend is configured.")
                }

                Section("Golbat") {
                    TextField("https://your-server.example", text: $settings.baseURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("X-Golbat-Secret", text: $settings.apiSecret)
                }
            }
            .navigationTitle("Radar Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
