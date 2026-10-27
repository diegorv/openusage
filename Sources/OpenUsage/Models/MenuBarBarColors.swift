import Foundation

/// How the Text strip's segmented gauges are colored in the menu bar. Anything but `.monochrome` turns
/// a gauge amber from 80% used and red from 95% used.
enum MenuBarBarColors: String, Hashable, Sendable, CaseIterable {
    case monochrome
    case alertsOnly
    case provider
    case custom

    var label: String {
        switch self {
        case .monochrome: return "Monochrome"
        case .alertsOnly: return "Alerts Only"
        case .provider: return "Provider Colors"
        case .custom: return "Custom"
        }
    }
}
