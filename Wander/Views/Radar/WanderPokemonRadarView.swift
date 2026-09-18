import SwiftUI
import CoreLocation

/// Wander-specific wrapper: selecting a spawn hands its coordinate to the existing Teleport tab.
struct WanderPokemonRadarView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("primaryTabSelection") private var primaryTab = AppFeature.location.id

    var body: some View {
        PokemonRadarView { mon in
            NotificationCenter.default.post(
                name: .previewLocationRequested,
                object: nil,
                userInfo: ["lat": mon.latitude, "lng": mon.longitude]
            )
            primaryTab = AppFeature.location.id
            dismiss()
        }
    }
}
