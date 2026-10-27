import XCTest
@testable import OpenUsage

/// Crash reporting follows the telemetry toggle.
final class TelemetrySinkTests: XCTestCase {
    func testErrorAutocaptureFollowsTelemetryToggle() {
        XCTAssertTrue(PostHogTelemetrySink.errorAutocaptureEnabled(optionalAnalyticsEnabled: true))
        XCTAssertFalse(PostHogTelemetrySink.errorAutocaptureEnabled(optionalAnalyticsEnabled: false))
    }
}
