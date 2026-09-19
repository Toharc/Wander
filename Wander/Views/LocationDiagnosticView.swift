//
//  LocationDiagnosticView.swift
//  Wander
//
//  Read-only Core Location diagnostics. This screen compares two snapshots of the
//  public CLLocation fields that iOS delivers to apps. It does not modify location,
//  hide simulation state, or change how another app evaluates a fix.
//

import SwiftUI
import CoreLocation
import UIKit

@MainActor
final class LocationDiagnostic: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Reading {
        let timestamp: Date
        let lat: Double
        let lng: Double
        let altitude: Double
        let ellipsoidalAltitude: Double
        let horizontalAccuracy: Double
        let verticalAccuracy: Double
        let speed: Double
        let speedAccuracy: Double
        let course: Double
        let courseAccuracy: Double
        let ageSeconds: Double
        let isSimulatedBySoftware: String
        let isProducedByAccessory: String
    }

    @Published var reading: Reading?
    @Published var updates = 0
    @Published var authStatus: CLAuthorizationStatus = .notDetermined
    @Published var accuracyAuth: CLAccuracyAuthorization = .fullAccuracy
    @Published var lastError: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        authStatus = manager.authorizationStatus
        accuracyAuth = manager.accuracyAuthorization
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authStatus = manager.authorizationStatus
            self.accuracyAuth = manager.accuracyAuthorization
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        var simulated = "unavailable"
        var accessory = "unavailable"
        if let source = loc.sourceInformation {
            simulated = source.isSimulatedBySoftware ? "true" : "false"
            accessory = source.isProducedByAccessory ? "true" : "false"
        }

        let reading = Reading(
            timestamp: loc.timestamp,
            lat: loc.coordinate.latitude,
            lng: loc.coordinate.longitude,
            altitude: loc.altitude,
            ellipsoidalAltitude: loc.ellipsoidalAltitude,
            horizontalAccuracy: loc.horizontalAccuracy,
            verticalAccuracy: loc.verticalAccuracy,
            speed: loc.speed,
            speedAccuracy: loc.speedAccuracy,
            course: loc.course,
            courseAccuracy: loc.courseAccuracy,
            ageSeconds: max(0, -loc.timestamp.timeIntervalSinceNow),
            isSimulatedBySoftware: simulated,
            isProducedByAccessory: accessory
        )

        Task { @MainActor in
            self.reading = reading
            self.updates += 1
            self.lastError = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
        }
    }
}

struct LocationDiagnosticView: View {
    @StateObject private var diag = LocationDiagnostic()
    @Environment(\.dismiss) private var dismiss
    @State private var baseline: LocationDiagnostic.Reading?
    @State private var comparison: LocationDiagnostic.Reading?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Read-only diagnostic. Capture one snapshot in a known state, then capture another after changing the location source. Wander compares only public Core Location fields.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                statusSection

                if let current = diag.reading {
                    Section("Current CLLocation") {
                        readingRows(current)
                    }

                    Section("Capture") {
                        Button {
                            baseline = current
                            copied = false
                        } label: {
                            Label(
                                baseline == nil ? "Capture baseline" : "Replace baseline",
                                systemImage: "1.circle"
                            )
                        }

                        Button {
                            comparison = current
                            copied = false
                        } label: {
                            Label(
                                comparison == nil ? "Capture comparison" : "Replace comparison",
                                systemImage: "2.circle"
                            )
                        }

                        if baseline != nil || comparison != nil {
                            Button(role: .destructive) {
                                baseline = nil
                                comparison = nil
                                copied = false
                            } label: {
                                Label("Clear captured snapshots", systemImage: "trash")
                            }
                        }
                    }
                } else {
                    Section {
                        Label(
                            "Waiting for a location fix. Make sure Location Services are enabled for Wander.",
                            systemImage: "location.magnifyingglass"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if let baseline, let comparison {
                    comparisonSection(baseline: baseline, comparison: comparison)

                    Section {
                        Button {
                            UIPasteboard.general.string = report(
                                baseline: baseline,
                                comparison: comparison
                            )
                            copied = true
                        } label: {
                            Label(
                                copied ? "Copied" : "Copy comparison report",
                                systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc"
                            )
                        }
                    } footer: {
                        Text("The report contains location measurements and permission state only. It does not change or conceal any location metadata.")
                    }
                } else if baseline != nil {
                    Section {
                        Text("Baseline captured. Change the test condition, wait for a fresh fix, then tap Capture comparison.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = diag.lastError {
                    Section("Last Core Location error") {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Location Diagnostic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { diag.start() }
            .onDisappear { diag.stop() }
        }
    }

    private var statusSection: some View {
        Section("Location status") {
            row("Authorization", authString)
            row("Accuracy permission", accuracyString)
            row("Updates received", String(diag.updates))
        }
    }

    @ViewBuilder
    private func readingRows(_ r: LocationDiagnostic.Reading) -> some View {
        row("Latitude", String(format: "%.6f", r.lat))
        row("Longitude", String(format: "%.6f", r.lng))
        row("Altitude", String(format: "%.2f m", r.altitude))
        row("Ellipsoidal altitude", String(format: "%.2f m", r.ellipsoidalAltitude))
        row("Horizontal accuracy", metric(r.horizontalAccuracy, unit: "m"))
        row("Vertical accuracy", metric(r.verticalAccuracy, unit: "m"))
        row("Speed", metric(r.speed, unit: "m/s"))
        row("Speed accuracy", metric(r.speedAccuracy, unit: "m/s"))
        row("Course", metric(r.course, unit: "°"))
        row("Course accuracy", metric(r.courseAccuracy, unit: "°"))
        row("Fix age", String(format: "%.2f s", r.ageSeconds))
        row("Software simulated", r.isSimulatedBySoftware)
        row("Accessory produced", r.isProducedByAccessory)
    }

    private func comparisonSection(
        baseline: LocationDiagnostic.Reading,
        comparison: LocationDiagnostic.Reading
    ) -> some View {
        Section("Baseline ↔ Comparison") {
            deltaRow("Distance", distance(from: baseline, to: comparison), unit: "m")
            deltaRow("Altitude Δ", comparison.altitude - baseline.altitude, unit: "m")
            deltaRow(
                "Horizontal accuracy Δ",
                comparison.horizontalAccuracy - baseline.horizontalAccuracy,
                unit: "m"
            )
            deltaRow(
                "Vertical accuracy Δ",
                comparison.verticalAccuracy - baseline.verticalAccuracy,
                unit: "m"
            )
            deltaRow("Speed Δ", comparison.speed - baseline.speed, unit: "m/s")
            deltaRow("Course Δ", angularDelta(from: baseline.course, to: comparison.course), unit: "°")

            HStack {
                Text("Software simulated")
                Spacer()
                Text("\(baseline.isSimulatedBySoftware) → \(comparison.isSimulatedBySoftware)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Accessory produced")
                Spacer()
                Text("\(baseline.isProducedByAccessory) → \(comparison.isProducedByAccessory)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func deltaRow(_ label: String, _ value: Double, unit: String) -> some View {
        row(label, String(format: "%+.2f %@", value, unit))
    }

    private func metric(_ value: Double, unit: String) -> String {
        if value < 0 {
            return String(format: "%.2f %@ (unavailable)", value, unit)
        }
        return String(format: "%.2f %@", value, unit)
    }

    private func distance(
        from lhs: LocationDiagnostic.Reading,
        to rhs: LocationDiagnostic.Reading
    ) -> Double {
        let a = CLLocation(latitude: lhs.lat, longitude: lhs.lng)
        let b = CLLocation(latitude: rhs.lat, longitude: rhs.lng)
        return b.distance(from: a)
    }

    private func angularDelta(from lhs: Double, to rhs: Double) -> Double {
        guard lhs >= 0, rhs >= 0 else { return rhs - lhs }
        var value = rhs - lhs
        while value > 180 { value -= 360 }
        while value < -180 { value += 360 }
        return value
    }

    private var authString: String {
        switch diag.authStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When In Use"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not set"
        @unknown default: return "Unknown"
        }
    }

    private var accuracyString: String {
        diag.accuracyAuth == .fullAccuracy ? "Precise" : "Reduced"
    }

    private func report(
        baseline: LocationDiagnostic.Reading,
        comparison: LocationDiagnostic.Reading
    ) -> String {
        """
        Wander Location Diagnostic

        authorization=\(authString)
        accuracyPermission=\(accuracyString)

        [baseline]
        \(dump(baseline))

        [comparison]
        \(dump(comparison))

        [delta]
        distanceMeters=\(distance(from: baseline, to: comparison))
        altitudeDelta=\(comparison.altitude - baseline.altitude)
        horizontalAccuracyDelta=\(comparison.horizontalAccuracy - baseline.horizontalAccuracy)
        verticalAccuracyDelta=\(comparison.verticalAccuracy - baseline.verticalAccuracy)
        speedDelta=\(comparison.speed - baseline.speed)
        courseDelta=\(angularDelta(from: baseline.course, to: comparison.course))
        """
    }

    private func dump(_ r: LocationDiagnostic.Reading) -> String {
        """
        timestamp=\(r.timestamp.timeIntervalSince1970)
        lat=\(r.lat)
        lng=\(r.lng)
        altitude=\(r.altitude)
        ellipsoidalAltitude=\(r.ellipsoidalAltitude)
        horizontalAccuracy=\(r.horizontalAccuracy)
        verticalAccuracy=\(r.verticalAccuracy)
        speed=\(r.speed)
        speedAccuracy=\(r.speedAccuracy)
        course=\(r.course)
        courseAccuracy=\(r.courseAccuracy)
        fixAge=\(r.ageSeconds)
        isSimulatedBySoftware=\(r.isSimulatedBySoftware)
        isProducedByAccessory=\(r.isProducedByAccessory)
        """
    }
}
