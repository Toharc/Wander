import SwiftUI
import CoreLocation

/// Lightweight compatibility surfaces for iOS 16.
/// Wander's newer MapKit-based route/joystick/timeline screens use APIs introduced in iOS 17,
/// so iOS 16 keeps the essential teleport flow available without compiling those newer map APIs.
struct LegacyFeatureUnavailableView: View {
    let title: String
    let message: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "info.circle")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title2.bold())
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(title)
        }
    }
}

struct LegacyLocationSimulationView: View {
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Coordinates") {
                    TextField("Latitude", text: $latitudeText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Longitude", text: $longitudeText)
                        .keyboardType(.numbersAndPunctuation)
                }

                Section {
                    Button {
                        simulate()
                    } label: {
                        Label("Teleport", systemImage: "location.fill")
                    }
                    .disabled(parsedCoordinate == nil)

                    Button(role: .destructive) {
                        clearSimulation()
                    } label: {
                        Label("Stop spoofing", systemImage: "stop.circle")
                    }
                }

                if !status.isEmpty {
                    Section {
                        Text(status)
                            .font(.footnote)
                    }
                }

                Section {
                    Text("iOS 16 compatibility mode. Advanced map, joystick and route screens require iOS 17, but direct teleport remains available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Teleport")
        }
    }

    private var parsedCoordinate: CLLocationCoordinate2D? {
        guard let lat = Double(latitudeText.replacingOccurrences(of: ",", with: ".")),
              let lon = Double(longitudeText.replacingOccurrences(of: ",", with: ".")),
              (-90...90).contains(lat),
              (-180...180).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func simulate() {
        guard let coordinate = parsedCoordinate else {
            status = "Enter valid latitude and longitude."
            return
        }
        let pairingURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingURL.path) || GslocMode.enabled else {
            status = "Pairing file required. Import it in Settings first."
            return
        }

        let target = CoarseLocation.apply(coordinate)
        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(
                DeviceConnectionContext.targetIPAddress,
                target.latitude,
                target.longitude,
                pairingURL.path
            )
            DispatchQueue.main.async {
                status = code == 0 ? "Location applied." : "Location simulation failed (error \(code))."
            }
        }
    }

    private func clearSimulation() {
        let pairingURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingURL.path) || GslocMode.enabled else {
            status = "Pairing file required. Import it in Settings first."
            return
        }

        LocationSimulationCommandQueue.shared.async {
            let code = stop_simulation(DeviceConnectionContext.targetIPAddress, pairingURL.path)
            DispatchQueue.main.async {
                status = code == 0 ? "Simulation stopped." : "Could not stop simulation (error \(code))."
            }
        }
    }
}
