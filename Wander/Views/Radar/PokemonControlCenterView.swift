import SwiftUI
import MapKit
import CoreLocation


private struct PokemonControlMapItem: Identifiable {
    enum Kind {
        case player
        case pokemon(RadarPokemon)
    }

    let id: String
    let coordinate: CLLocationCoordinate2D
    let kind: Kind
}

/// iOS 16-friendly Pokémon control center:
/// live/demo radar + map + continuous on-screen joystick in one place.
struct PokemonControlCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var radar = PokemonRadarViewModel()
    @ObservedObject private var settings = PokemonRadarSettings.shared
    @ObservedObject private var session = SimulationSession.shared
    @StateObject private var currentLocation = CurrentLocation()

    @State private var coordinate = CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818)
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 32.0853, longitude: 34.7818),
        span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
    )

    @State private var knobOffset: CGSize = .zero
    @State private var joyFraction: Double = 0
    @State private var joyBearing: Double = 0
    @State private var movementTimer: Timer?
    @AppStorage("pokemonControl.speedKmh") private var speedKmh: Double = 6.0
    private var speedMps: Double { speedKmh / 3.6 }
    @State private var status = ""
    @State private var showSettings = false
    @State private var startedMovementSession = false
    @State private var locationCommandInFlight = false
    @State private var didCenterOnRealLocation = false
    @State private var pendingVisualCoordinate: CLLocationCoordinate2D?

    private let joystickRadius: CGFloat = 54
    // Keep movement updates at a steady 1 Hz. This avoids overlapping bridge writes and
    // matches the cadence used by Wander's main joystick path.
    private let tickInterval: TimeInterval = 1.0

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
                currentLocation.request()
                if session.isActive, let last = session.lastTeleportCoordinate {
                    coordinate = last
                    region.center = last
                    didCenterOnRealLocation = true
                }
                await radar.loadSpecies()
                if #available(iOS 17.4, *) {
                    // On-device tunnel path.
                } else if LegacyIOS16Bridge.isConfigured {
                    do {
                        try await LegacyIOS16Bridge.health()
                        status = "Windows Bridge connected."
                    } catch {
                        status = "Windows Bridge unavailable: \(error.localizedDescription)"
                    }
                } else {
                    status = "Configure the iOS 16 Windows Bridge in Radar Settings."
                }
                if didCenterOnRealLocation {
                    await refreshRadar()
                }
            }
            .onReceive(currentLocation.$coordinate.compactMap { $0 }) { real in
                // Before spoofing starts, use the first usable GPS fix as the map origin.
                // Center only once so later CoreLocation updates do not fight joystick movement.
                guard !session.isActive, !startedMovementSession else { return }
                guard !didCenterOnRealLocation else { return }

                didCenterOnRealLocation = true
                coordinate = real
                region = MKCoordinateRegion(
                    center: real,
                    span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
                )

                if let accuracy = currentLocation.horizontalAccuracy {
                    status = String(format: "Current location acquired (±%.0f m).", accuracy)
                } else {
                    status = "Current location acquired."
                }
                Task { await refreshRadar() }
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
                pendingVisualCoordinate = nil
            }
        }
    }

    private var mapItems: [PokemonControlMapItem] {
        var items = radar.pokemon.map {
            PokemonControlMapItem(id: "pokemon-\($0.id)", coordinate: $0.coordinate, kind: .pokemon($0))
        }
        items.append(PokemonControlMapItem(
            id: "player",
            coordinate: pendingVisualCoordinate ?? coordinate,
            kind: .player
        ))
        return items
    }

    private var radarMap: some View {
        Map(coordinateRegion: $region, annotationItems: mapItems) { item in
            MapAnnotation(coordinate: item.coordinate) {
                switch item.kind {
                case .player:
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.22))
                            .frame(width: 36, height: 36)
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 14, height: 14)
                        Circle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 14, height: 14)
                    }
                    .accessibilityLabel("Simulated location")

                case .pokemon(let mon):
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
        }
        .ignoresSafeArea(edges: .bottom)
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

            if currentLocation.accuracyAuthorization == .reducedAccuracy && !session.isActive {
                Text("Approximate Location is enabled. Turn on Precise Location in iPad Settings for a more accurate starting point.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                HStack {
                    Text("Speed")
                        .font(.caption.bold())
                    Spacer()
                    Text(String(format: "%.1f km/h", speedKmh))
                        .font(.caption.monospacedDigit())
                }

                Slider(value: $speedKmh, in: 1...30, step: 0.5)

                HStack(spacing: 6) {
                    speedButton("Walk", 5.0)
                    speedButton("Run", 10.0)
                    speedButton("Fast", 20.0)
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
                        stopLocationSimulation()
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

    private func stopLocationSimulation() {
        stopMovementTimer()
        knobOffset = .zero
        joyFraction = 0
        pendingVisualCoordinate = nil

        if #available(iOS 17.4, *) {
            session.stopAll()
            status = "Location simulation stopped."
        } else {
            Task {
                do {
                    try await LegacyIOS16Bridge.clearLocation()
                    await MainActor.run {
                        startedMovementSession = false
                        session.markStopped()
                        status = "Location simulation stopped."
                    }
                } catch {
                    await MainActor.run {
                        status = "Windows Bridge error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func speedButton(_ title: String, _ valueKmh: Double) -> some View {
        Button(title) {
            speedKmh = valueKmh
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .disabled(abs(speedKmh - valueKmh) < 0.01)
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
                    if let pending = pendingVisualCoordinate {
                        coordinate = pending
                        pendingVisualCoordinate = nil
                    }
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

        // Before this screen becomes a moving writer, stop any route/walk/hold loop
        // that may still be active elsewhere. The notification is handled synchronously
        // by Wander's movement screens, including this view, so claiming ownership here
        // cannot leave two independent location writers fighting each other.
        NotificationCenter.default.post(name: .stopSimulationRequested, object: nil)
        LocationSimulationCommandQueue.suppressResends = true
        session.movementModeDidBecomeActiveWriter()
        if !session.isActive {
            session.started()
        }
        startedMovementSession = true

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
        LocationSimulationCommandQueue.suppressResends = true

        let start = pendingVisualCoordinate ?? coordinate
        let metres = speedMps * tickInterval * joyFraction
        let next = destination(from: start, metres: metres, bearingRadians: joyBearing)

        // Move the on-screen marker immediately so joystick feedback is visible.
        // The authoritative coordinate is committed only after the device accepts the injection.
        pendingVisualCoordinate = next
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

        if #available(iOS 17.4, *) {
            // Continue through Wander's on-device developer tunnel.
        } else {
            sendLocationViaLegacyBridge(target, noteTeleport: noteTeleport)
            return
        }

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
                    pendingVisualCoordinate = nil
                    if let mountFailure {
                        status = "Developer image mount failed: \(mountFailure)"
                    } else {
                        status = "Location injection failed (error \(code)). Check LocalDevVPN + Developer Mode."
                    }
                    return
                }

                coordinate = target
                pendingVisualCoordinate = nil
                if noteTeleport {
                    region.center = target
                }

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

    private func sendLocationViaLegacyBridge(
        _ target: CLLocationCoordinate2D,
        noteTeleport: Bool
    ) {
        guard LegacyIOS16Bridge.isConfigured else {
            pendingVisualCoordinate = nil
            status = "iOS 16 needs the Windows Bridge. Configure it in Radar Settings."
            return
        }

        locationCommandInFlight = true
        status = "Sending through Windows Bridge…"

        Task {
            do {
                try await LegacyIOS16Bridge.setLocation(target)
                await MainActor.run {
                    locationCommandInFlight = false
                    coordinate = target
                    pendingVisualCoordinate = nil

                    if noteTeleport {
                        region.center = target
                    }

                    if !startedMovementSession {
                        startedMovementSession = true
                        session.movementModeDidBecomeActiveWriter()
                        session.started()
                    }

                    status = "Device location updated via Windows Bridge."
                    if noteTeleport {
                        session.noteTeleport(to: target)
                        Task { await refreshRadar() }
                    }
                }
            } catch {
                await MainActor.run {
                    locationCommandInFlight = false
                    pendingVisualCoordinate = nil
                    status = "Windows Bridge error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func parkCurrentLocation() {
        if #available(iOS 17.4, *) {
            // Local tunnel keeps the stationary fix warm.
        } else {
            return
        }
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
