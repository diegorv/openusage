import Foundation
import PostHog

/// Build-time configuration for the PostHog project. The project token is a client-side, write-only
/// key (it ships in every distributed binary, like any analytics SDK key), so it is safe to commit;
/// an `OPENUSAGE_POSTHOG_TOKEN` environment override is supported for local testing without editing
/// source. The host is region-bound — a US token will not ingest against the EU host.
enum TelemetryConfig {
    /// Sentinel meaning "no real token configured" — the sink stays inert (no setup, no network) while
    /// the resolved token equals this. Do NOT change this value.
    static let placeholderToken = "phc_REPLACE_ME"

    /// The project token baked into the build. Replace `phc_REPLACE_ME` with the real US-region
    /// `phc_…` key (safe to commit — it's a client write-only key), or leave it and set
    /// `OPENUSAGE_POSTHOG_TOKEN` at runtime for local testing.
    private static let bakedToken = "phc_vGEqXEpQNwViyKnMNWvmKWpv8XxMT3yaeYi6gfidr4nf"

    static var token: String {
        let env = ProcessInfo.processInfo.environment["OPENUSAGE_POSTHOG_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        return bakedToken
    }

    /// US cloud. Switch to "https://eu.i.posthog.com" only with an EU-region project token.
    static let host = "https://us.i.posthog.com"
}

/// The transport seam telemetry is emitted through. Abstracted from PostHog so the recorder's
/// daily-rollup/dedup logic can be unit-tested against a fake sink.
@MainActor
protocol TelemetrySink: AnyObject {
    func capture(_ event: String, _ properties: [String: Any])
    /// Mirror the optional-analytics preference without disabling daily activity or crash reporting.
    func setOptionalAnalyticsEnabled(_ enabled: Bool)
    func flush()
}

/// Anonymous PostHog sink. Off by default: PostHog is only set up (and only touches the network) once
/// the user turns telemetry on, and turning it off opts the SDK out. Crash autocapture follows the same
/// toggle. No `identify()`/`group()`/`alias()`, `personProfiles = .never`, and only IDs/counts/enums are
/// ever sent — never free-form error messages. When no real project token is configured the sink is inert.
@MainActor
final class PostHogTelemetrySink: TelemetrySink {
    nonisolated static func errorAutocaptureEnabled(optionalAnalyticsEnabled enabled: Bool) -> Bool { enabled }

    private let token: String
    private let host: String
    private var configured = false
    private var enabled: Bool

    init(enabled: Bool, token: String = TelemetryConfig.token, host: String = TelemetryConfig.host) {
        self.token = token
        self.host = host
        self.enabled = enabled
        guard token.hasPrefix("phc_"), token != TelemetryConfig.placeholderToken else {
            AppLog.info(.config, "telemetry inert: no PostHog project token configured")
            return
        }
        if enabled { setUp() } else { AppLog.info(.config, "telemetry disabled") }
    }

    private func setUp() {
        guard !configured, token.hasPrefix("phc_"), token != TelemetryConfig.placeholderToken else { return }
        configured = true

        let config = PostHogConfig(projectToken: token, host: host)
        // Fully anonymous: no person profiles, no anonymous->identified merge.
        config.personProfiles = .never
        // We use no feature flags and emit our own daily rollups, so skip both startup fetches/autocapture.
        config.preloadFeatureFlags = false
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.optOut = false
        // Crash / uncaught-exception autocapture (anonymous `$exception` events, sent on the NEXT launch
        // after a crash). posthog-ios also gates it on a server-side switch (remote config
        // `errorTracking.autocaptureExceptions`), read from cache at init.
        // Never reference sessionReplay / surveys / captureElementInteractions / tracingHeaders here:
        // they do not exist on a macOS target.
        config.errorTrackingConfig.autoCapture = Self.errorAutocaptureEnabled(optionalAnalyticsEnabled: true)
        PostHogSDK.shared.setup(config)
        // Clear a persisted SDK opt-out from a previous disable.
        PostHogSDK.shared.optIn()

        // Super properties ride on every subsequent event (anonymous, non-PII).
        PostHogSDK.shared.register([
            "app_version": AppInfo.version,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ])
        AppLog.info(.config, "telemetry initialized")
    }

    func capture(_ event: String, _ properties: [String: Any]) {
        guard configured, enabled else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    func setOptionalAnalyticsEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled {
            setUp()
            if configured { PostHogSDK.shared.optIn() }
        } else if configured {
            // Stops sends and queued events; crash autocapture stays installed until the next launch,
            // which then skips setup entirely.
            PostHogSDK.shared.optOut()
        }
        AppLog.info(.config, "telemetry preference=\(enabled)")
    }

    func flush() {
        guard configured, enabled else { return }
        PostHogSDK.shared.flush()
    }
}
