import SwiftUI
import MapKit
import CoreLocation

/// iOS 16-friendly Pokémon control center:
/// live/demo radar + map + continuous on-screen joystick in one place.
struct PokemonControlCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var radar = PokemonRadarViewModel()
    @ObservedObject private var settings = PokemonRadarSettings.shared
    @ObservedObject private var session = SimulationSession.shared

    @State private var coordinate = CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818)
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818),
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
    )

    @State private var knobOffset: CGSize = .zero
    @State private var joyFraction: Double = 0
    @State private var joyBearing: Double = 0
    @State private var movementTimer: Timer?
    @State private var speedMps: Double = 1.7
    @State private var status = ""
    @State private var showSettings = false
    @State private var startedMovementSession = false
    @State private var locationCommandInFlight = false

    private let joystickRadius: CGFloat = 54
    private let tickInterval: TimeInterval = 0.5

    var body: some View {
        NavigationStack {
            ZStack {
                radarMap

                VStack(spacing: 0) {
                    topPanel
                    Spacer()
                    bottomPanel
                }
                .padding(12)
            }
            .navigationTitle("Pokémon Control")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Close") { dismiss() },
                trailing: Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            )
            .sheet(isPresented: $showSettings) {
                PokemonRadarSettingsView()
            }
            .task {
                if let last = session.lastTeleportCoordinate {
                    coordinate = last
                    region.center = last
                }
                await radar.loadSpecies()
                await refreshRadar()
            }
            .onDisappear {
                stopMovementTimer()
                parkCurrentLocation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .stopSimulationRequested)) { _ in
                stopMovementTimer()
                knobOffset = .zero
                joyFraction = 0
                startedMovementSession = false
            }
        }
    }

    private var radarMap: some View {
        Map(coordinateRegion: $region, annotationItems: radar.pokemon) { mon in
            MapAnnotation(coordinate: mon.coordinate) {
                Button {
                    radar.selected = mon
                } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "scope")
                            .font(.headline)
                        Text(radar.name(for: mon.pokemonID))
                            .font(.caption2.bold())
                            .lineLimit(1)
                        if let iv = mon.ivPercent {
                            Text("\(iv)%")
                                .font(.caption2)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .overlay {
            // The simulated position stays at the map centre while moving.
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.20))
                    .frame(width: 34, height: 34)
                Circle()
                    .fill(Color.blue)
                    .frame(width: 12, height: 12)
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: 12, height: 12)
            }
            .allowsHitTesting(false)
        }
    }

    private var topPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label(
                    settings.demoMode ? "DEMO" : "LIVE",
                    systemImage: settings.demoMode ? "testtube.2" : "dot.radiowaves.left.and.right"
                )
                .font(.caption.bold())

                Spacer()

                Text("Nearby: \(radar.pokemon.count)")
                    .font(.caption.bold())

                Button {
                    Task { await refreshRadar() }
                } label: {
                    Image(systemName: radar.isLoading ? "hourglass" : "arrow.clockwise")
                }
                .disabled(radar.isLoading)

                Menu {
                    ForEach([1, 5, 10, 25, 50], id: \.self) { km in
                        Button("\(km) km") {
                            radar.filters.maxDistanceKm = Double(km)
                            Task { await refreshRadar() }
                        }
                    }
                } label: {
                    Label("\(Int(radar.filters.maxDistanceKm)) km", systemImage: "scope")
                        .font(.caption)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Pokémon by name", text: $radar.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !radar.filters.pokemonIDs.isEmpty {
                    Button("Clear") {
                        radar.filters.pokemonIDs.removeAll()
                        radar.query = ""
                        Task { await refreshRadar() }
                    }
                    .font(.caption)
                }
            }

            if !radar.matchingSpecies.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(radar.matchingSpecies.prefix(8)) { species in
                            Button(species.displayName) {
                                radar.addSpecies(species)
                                Task { await refreshRadar() }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if let selected = radar.selected {
                selectedPokemonRow(selected)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func selectedPokemonRow(_ mon: RadarPokemon) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(radar.name(for: mon.pokemonID))
                    .font(.subheadline.bold())
                HStack(spacing: 6) {
                    if let iv = mon.ivPercent { Text("IV \(iv)%") }
                    if let cp = mon.cp { Text("CP \(cp)") }
                    Text(String(format: "%.1f km", mon.distanceKm(from: coordinate)))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                teleport(to: mon.coordinate)
            } label: {
                Label("Go", systemImage: "location.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var bottomPanel: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speed")
                    .font(.caption.bold())

                HStack(spacing: 6) {
                    speedButton("Walk", 1.7)
                    speedButton("Run", 3.3)
                    speedButton("Fast", 6.0)
                }

                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        Task { await refreshRadar() }
                    } label: {
                        Label("Refresh", systemImage: "scope")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        session.stopAll()
                        status = "Location simulation stopped."
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer(minLength: 6)

            joystick
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func speedButton(_ title: String, _ value: Double) -> some View {
        Button(title) {
            speedMps = value
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .disabled(abs(speedMps - value) < 0.01)
    }

    private var joystick: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: joystickRadius * 2, height: joystickRadius * 2)

            Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                .frame(width: joystickRadius * 2, height: joystickRadius * 2)

            Image(systemName: "arrow.up")
                .font(.caption)
                .foregroundStyle(.secondary)
                .offset(y: -joystickRadius + 12)

            Circle()
                .fill(Color.accentColor)
                .frame(width: 42, height: 42)
                .shadow(radius: 2)
                .offset(knobOffset)
        }
        .frame(width: joystickRadius * 2, height: joystickRadius * 2)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    updateJoystick(value.translation)
                    startMovementTimerIfNeeded()
                }
                .onEnded { _ in
                    knobOffset = .zero
                    joyFraction = 0
                    stopMovementTimer()
                    parkCurrentLocation()
                    Task { await refreshRadar() }
                }
        )
    }

    private func updateJoystick(_ translation: CGSize) {
        let dx = translation.width
        let dy = translation.height
        let length = max(0.001, sqrt(dx * dx + dy * dy))
        let clamped = min(length, joystickRadius)
        let scale = clamped / length

        knobOffset = CGSize(width: dx * scale, height: dy * scale)
        joyFraction = Double(clamped / joystickRadius)
        joyBearing = atan2(Double(dx), Double(-dy))
    }

    private func startMovementTimerIfNeeded() {
        guard movementTimer == nil else { return }
        guard !GslocMode.enabled else {
            status = "Joystick needs the normal Wander tunnel. Turn off gs-loc mode first."
            return
        }

        movementTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            Task { @MainActor in
                stepMovement()
            }
        }
        stepMovement()
    }

    private func stopMovementTimer() {
        movementTimer?.invalidate()
        movementTimer = nil
    }

    private func stepMovement() {
        guard joyFraction > 0.05, !locationCommandInFlight else { return }
        let metres = speedMps * tickInterval * joyFraction
        let next = destination(from: coordinate, metres: metres, bearingRadians: joyBearing)
        sendLocation(next, noteTeleport: false)
    }

    private func teleport(to target: CLLocationCoordinate2D) {
        stopMovementTimer()
        knobOffset = .zero
        joyFraction = 0
        sendLocation(target, noteTeleport: true)
    }

    private func sendLocation(_ target: CLLocationCoordinate2D, noteTeleport: Bool) {
        guard !locationCommandInFlight else { return }

        let pairingURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingURL.path) || GslocMode.enabled else {
            status = "Pairing file required. Import it in Settings first."
            return
        }

        // Match the proven Teleport path: bring Wander's tunnel up first when that
        // option is enabled, then inject only after the endpoint is reachable.
        if UserDefaults.standard.bool(forKey: UserDefaults.Keys.useOwnTunnel),
           !GslocMode.enabled,
           !isTunnelSimEndpointReachable() {
            status = "Starting Wander tunnel…"
            locationCommandInFlight = true
            Task {
                await WanderTunnel.shared.ensureStarted()
                await MainActor.run {
                    locationCommandInFlight = false
                    performLocationUpdate(target, pairingURL: pairingURL, noteTeleport: noteTeleport)
                }
            }
            return
        }

        performLocationUpdate(target, pairingURL: pairingURL, noteTeleport: noteTeleport)
    }

    private func performLocationUpdate(
        _ target: CLLocationCoordinate2D,
        pairingURL: URL,
        noteTeleport: Bool
    ) {
        guard !locationCommandInFlight else { return }

        locationCommandInFlight = true
        status = "Sending location…"
        let applied = CoarseLocation.apply(target)
        let simulationWasActive = session.isActive

        LocationSimulationCommandQueue.shared.async {
            var code = simulate_location(
                DeviceConnectionContext.targetIPAddress,
                applied.latitude,
                applied.longitude,
                pairingURL.path
            )

            // Same recovery used by the normal Teleport screen: if the first
            // inject fails because the developer image is not mounted, mount the
            // personalized DDI once and retry.
            var mountFailure: String? = nil
            if code != 0, !simulationWasActive, isPairing(), !isMounted() {
                let mountError = mountPersonalDDI(
                    imagePath: URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg").path,
                    trustcachePath: URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg.trustcache").path,
                    manifestPath: URL.documentsDirectory.appendingPathComponent("DDI/BuildManifest.plist").path
                )
                if mountError == nil {
                    MountingProgress.shared.checkforMounted()
                    code = simulate_location(
                        DeviceConnectionContext.targetIPAddress,
                        applied.latitude,
                        applied.longitude,
                        pairingURL.path
                    )
                } else {
                    mountFailure = mountError
                }
            }

            DispatchQueue.main.async {
                locationCommandInFlight = false

                guard code == 0 else {
                    if let mountFailure {
                        status = "Developer image mount failed: \(mountFailure)"
                    } else {
                        status = "Location injection failed (error \(code)). Check LocalDevVPN + Developer Mode."
                    }
                    return
                }

                // Only move our map AFTER the device accepted the location. This
                // prevents the old false-positive where the Wander dot moved even
                // though Apple Maps / Pokémon GO stayed at the real location.
                coordinate = target
                region.center = target

                if !startedMovementSession {
                    startedMovementSession = true
                    session.movementModeDidBecomeActiveWriter()
                    session.started()
                }

                status = "Device location updated."
                if noteTeleport {
                    session.noteTeleport(to: target)
                    Task { await refreshRadar() }
                }
            }
        }
    }

    private func parkCurrentLocation() {
        guard startedMovementSession else { return }
        NotificationCenter.default.post(
            name: .holdLocationRequested,
            object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
    }

    private func refreshRadar() async {
        await radar.refresh(center: coordinate)
    }

    private func destination(
        from start: CLLocationCoordinate2D,
        metres: Double,
        bearingRadians: Double
    ) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let angularDistance = metres / earthRadius
        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180

        let lat2 = asin(
            sin(lat1) * cos(angularDistance) +
            cos(lat1) * sin(angularDistance) * cos(bearingRadians)
        )

        let lon2 = lon1 + atan2(
            sin(bearingRadians) * sin(angularDistance) * cos(lat1),
            cos(angularDistance) - sin(lat1) * sin(lat2)
        )

        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }
}
