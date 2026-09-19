//
//  CurrentLocation.swift
//  Wander
//
//  One-shot fetch of the device's real location so a map can open centered
//  and zoomed on where you actually are (before any simulation starts).
//

import CoreLocation

@MainActor
final class CurrentLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var horizontalAccuracy: CLLocationAccuracy?
    @Published var accuracyAuthorization: CLAccuracyAuthorization = .reducedAccuracy

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        accuracyAuthorization = manager.accuracyAuthorization
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        Task { @MainActor in
            self.accuracyAuthorization = accuracy
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let c = last.coordinate
        let accuracy = last.horizontalAccuracy
        Task { @MainActor in
            self.coordinate = c
            self.horizontalAccuracy = accuracy
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }
}
