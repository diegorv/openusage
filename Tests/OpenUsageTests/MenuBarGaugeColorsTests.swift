import SwiftUI
import XCTest
@testable import OpenUsage

/// Gauge coloring: monochrome never colors, every other mode escalates to amber at 80% used and red
/// at 95% used, whatever the used/left display mode.
final class MenuBarGaugeColorsTests: XCTestCase {
    private func metric(used: Double) -> MenuBarContent.Metric {
        MenuBarContent.Metric(
            id: "claude.session", label: "S", value: "", fraction: 1 - used,
            usedFraction: used, isBounded: true, hasData: true
        )
    }

    private let amber = Color(red: 224 / 255, green: 160 / 255, blue: 48 / 255)
    private let red = Color(red: 224 / 255, green: 80 / 255, blue: 80 / 255)

    func testMonochromeNeverColors() {
        let colors = GaugeColors(mode: .monochrome, custom: 0xFF0000)
        XCTAssertNil(colors.color(for: metric(used: 0.99), providerID: "claude"))
    }

    func testAlertsOnlyColorsNearTheLimit() {
        let colors = GaugeColors(mode: .alertsOnly, custom: 0)
        XCTAssertNil(colors.color(for: metric(used: 0.79), providerID: "claude"))
        XCTAssertEqual(colors.color(for: metric(used: 0.80), providerID: "claude"), amber)
        XCTAssertEqual(colors.color(for: metric(used: 0.95), providerID: "claude"), red)
    }

    func testCustomUsesChosenColorBelowAlerts() {
        let colors = GaugeColors(mode: .custom, custom: 0x00FF00)
        XCTAssertEqual(colors.color(for: metric(used: 0.10), providerID: "claude"), Color(red: 0, green: 1, blue: 0))
        XCTAssertEqual(colors.color(for: metric(used: 0.96), providerID: "claude"), red)
    }

    func testProviderUsesBrandColor() {
        let colors = GaugeColors(mode: .provider, custom: 0)
        XCTAssertEqual(
            colors.color(for: metric(used: 0.10), providerID: "claude"),
            TotalSpendPalette.color(for: "claude")
        )
    }
}
