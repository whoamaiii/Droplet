import SwiftUI

private struct DropletMotionOverrideKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dropletReduceMotionOverride: Bool {
        get { self[DropletMotionOverrideKey.self] }
        set { self[DropletMotionOverrideKey.self] = newValue }
    }
}

/// System accessibility always wins. The additional true-only override lets
/// preview QA exercise the same rendering without changing macOS preferences.
@propertyWrapper
struct DropletReducedMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.dropletReduceMotionOverride) private var override
    var wrappedValue: Bool { system || override }
}
