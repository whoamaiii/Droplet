#if DROPLET_PREVIEW
import SwiftUI
import Cocoa

@MainActor
final class PreviewAccessibilityState: ObservableObject {
    static let shared = PreviewAccessibilityState()
    @Published var reduceMotion = false
}

struct PreviewAccessibilityModifier: ViewModifier {
    @ObservedObject private var state = PreviewAccessibilityState.shared
    func body(content: Content) -> some View {
        content.environment(\.dropletReduceMotionOverride, state.reduceMotion)
    }
}

struct PreviewAppearanceControls: View {
    @ObservedObject private var state = PreviewAccessibilityState.shared
    var body: some View {
        HStack {
            Button("Light") { NSApp.appearance = NSAppearance(named: .aqua) }
            Button("Dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            Toggle("Reduce motion", isOn: $state.reduceMotion)
                .toggleStyle(.checkbox)
        }
        .font(.system(size: 10)).padding(.bottom, 8)
    }
}
#endif
