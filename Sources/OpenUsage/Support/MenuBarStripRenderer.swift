import AppKit
import SwiftUI

/// Renders the Text-style menu-bar strip (`MenuBarContent`) into a template `NSImage` for the
/// `MenuBarExtra` label: provider mark + bare value for a single metric, or a tight labeled stack for
/// two. Black-on-clear so macOS tints it for light/dark; sized to its natural width. The image is built
/// outside the `label:` view builder (an `ImageRenderer` inline there throws obscure errors).
@MainActor
enum MenuBarStripRenderer {
    /// Last render, memoized on (content, style). The observation loop re-renders on every snapshot
    /// write — several times per refresh pass — but the strip's visible content rarely changes.
    /// Returning the same `NSImage` instance lets `StatusItemImageUpdater` skip the status-item set
    /// (an unconditional set still costs a WindowServer redraw), and keeps `ImageRenderer` (which
    /// retains a little memory per run on macOS) to actual visual changes.
    private static var lastRender: (content: MenuBarContent, style: MenuBarStyle, colors: GaugeColors, image: NSImage?)?

    /// The strip image for the given content and style, or `nil` when the content renders nothing
    /// in that style (caller falls back to the app icon). Memoized: equal inputs return the
    /// previously rendered instance.
    static func image(
        for content: MenuBarContent,
        style: MenuBarStyle,
        colors: GaugeColors = GaugeColors(mode: .monochrome, custom: 0)
    ) -> NSImage? {
        if let lastRender, lastRender.content == content, lastRender.style == style, lastRender.colors == colors {
            AppLog.debug(.menubar, "strip cache hit")
            return lastRender.image
        }
        AppLog.debug(.menubar, "strip cache miss (rendering)")
        let image: NSImage?
        switch style {
        case .text:
            image = colors.mode == .monochrome
                ? textImage(for: content)
                : coloredTextImage(for: content, colors: colors)
        case .bars: image = barsImage(for: content)
        }
        lastRender = (content, style, colors, image)
        return image
    }

    /// The Text strip with colored gauges. A template image can't carry color, so the strip renders
    /// twice with the same layout: a black mask (text, glyphs, unlit segments) filled with the label
    /// color at draw time — so it still follows the menu bar's light/dark appearance — and the lit
    /// segments in color on top.
    static func coloredTextImage(for content: MenuBarContent, colors: GaugeColors) -> NSImage? {
        guard !content.isEmpty else { return nil }
        let maskRenderer = ImageRenderer(content: MenuBarTextStrip(content: content, layer: .mask(colors)))
        let colorRenderer = ImageRenderer(content: MenuBarTextStrip(content: content, layer: .color(colors)))
        maskRenderer.scale = 2
        colorRenderer.scale = 2
        guard let mask = maskRenderer.cgImage, let color = colorRenderer.cgImage else { return nil }
        let full = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        let bounds = (visibleBounds(of: mask) ?? full).union(visibleBounds(of: color) ?? full)
        guard let trimmedMask = mask.cropping(to: bounds), let trimmedColor = color.cropping(to: bounds) else {
            return nil
        }
        let size = NSSize(width: bounds.width / maskRenderer.scale, height: bounds.height / maskRenderer.scale)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.clip(to: rect, mask: trimmedMask)
            NSColor.labelColor.setFill()
            rect.fill()
            context.restoreGState()
            context.draw(trimmedColor, in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    /// The pinned-metrics strip, or `nil` when nothing is pinned or no pinned metric has data yet
    /// (caller falls back to the app icon).
    ///
    /// The render is trimmed to its visible pixels: the view's anti-aliasing padding and the provider
    /// glyph's normalization inset would otherwise ship as transparent margins, widening the status
    /// item past its artwork (the menu bar already pads every item, so baked-in margins read as an
    /// extra-large gap next to neighboring items).
    static func textImage(for content: MenuBarContent) -> NSImage? {
        guard !content.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarTextStrip(content: content))
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = true
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    /// Crops fully transparent margins off a rendered strip, or `nil` when the image has no visible
    /// pixels (caller keeps the untrimmed render).
    nonisolated static func trimmedToVisibleContent(_ image: CGImage) -> CGImage? {
        guard let bounds = visibleBounds(of: image) else { return nil }
        return image.cropping(to: bounds)
    }

    /// The bounding box of pixels with non-zero alpha, in pixel coordinates (origin at the top-left
    /// row, matching `CGImage.cropping(to:)`), or `nil` for a fully transparent image.
    nonisolated static func visibleBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The compact Bars glyph (≤4 bounded-metric bars), or `nil` when no pinned metric has a fill.
    static func barsImage(for content: MenuBarContent) -> NSImage? {
        let fractions = content.bars.map(\.fraction)
        guard !fractions.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarBars(fractions: fractions, side: 18))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    /// The screen-share privacy stand-in: the wordmark instead of usage values, shown while
    /// `MenuBarPrivacyStore.concealUsage` is true so a shared or recorded screen never carries token
    /// counts or spend. Deterministic, so rendered once; `nil` only if `ImageRenderer` fails entirely
    /// (caller falls back to the app icon).
    static let privacyImage: NSImage? = {
        let renderer = ImageRenderer(content: MenuBarPrivacyLabel())
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = true
        image.accessibilityDescription = "OpenUsage, usage hidden while the screen is shared"
        return image
    }()

    /// Last-resort icon if the brand mark fails to load.
    static let fallbackIcon: NSImage = {
        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "OpenUsage"
        ) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

/// The brand gauge mark plus wordmark drawn in place of the strip while screen-share privacy is
/// concealing usage. Same black-on-clear template treatment, glyph box, and type size as a
/// single-metric Text strip, so the swap doesn't jump the menu bar's rhythm.
private struct MenuBarPrivacyLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            // The same mark and inset as `MenuBarIcon` (the art carries its own margin), sized to the
            // strip's glyph box so the swap keeps the provider-glyph scale.
            if let mark = ProviderMarks.mark(for: "openusage") {
                ProviderIconShape(mark: mark, inset: 0.08)
                    .fill(Color.black)
                    .frame(width: 16, height: 16)
            }
            Text("OpenUsage")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }
}

/// The gauge coloring the Text strip renders with: the chosen mode plus the `.custom` color.
struct GaugeColors: Equatable {
    let mode: MenuBarBarColors
    let custom: UInt32

    /// The lit-segment color for a metric, or `nil` for the template black.
    func color(for metric: MenuBarContent.Metric, providerID: String) -> Color? {
        if mode == .monochrome { return nil }
        if metric.usedFraction >= 0.95 { return Color(red: 224 / 255, green: 80 / 255, blue: 80 / 255) }
        if metric.usedFraction >= 0.80 { return Color(red: 224 / 255, green: 160 / 255, blue: 48 / 255) }
        switch mode {
        case .monochrome, .alertsOnly: return nil
        case .provider: return TotalSpendPalette.color(for: providerID)
        case .custom:
            return Color(
                red: Double((custom >> 16) & 0xFF) / 255,
                green: Double((custom >> 8) & 0xFF) / 255,
                blue: Double(custom & 0xFF) / 255
            )
        }
    }
}

/// Which pass of the strip to draw. `.template` is the single monochrome render; a colored strip
/// draws `.mask` (everything but colored lit segments, black) and `.color` (only those segments).
private enum StripLayer {
    case template
    case mask(GaugeColors)
    case color(GaugeColors)
}

private struct MenuBarTextStrip: View {
    let content: MenuBarContent
    var layer: StripLayer = .template

    /// Black for template and mask passes; clear in the color pass, which keeps the layout but draws
    /// only the colored segments.
    private var ink: Color {
        if case .color = layer { return .clear }
        return .black
    }

    var body: some View {
        HStack(spacing: 11) {
            ForEach(content.groups, id: \.providerID) { group in
                HStack(spacing: 4) {
                    glyph(group.icon)
                    metricsView(group.metrics, providerID: group.providerID)
                }
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
    }

    /// A provider's pinned values, no labels: one metric as a single large number, two stacked on two
    /// tight lines (much narrower than side-by-side), read positionally.
    @ViewBuilder
    private func metricsView(_ metrics: [MenuBarContent.Metric], providerID: String) -> some View {
        if metrics.count <= 1 {
            HStack(spacing: 3) {
                Text(metrics.first?.value ?? "")
                    .font(.system(size: 13, weight: .semibold))
                if let metric = metrics.first { segments(metric, providerID: providerID, height: 10) }
            }
        } else {
            VStack(alignment: .trailing, spacing: -2) {
                ForEach(metrics, id: \.id) { metric in
                    HStack(spacing: 3) {
                        Text(metric.value)
                        segments(metric, providerID: providerID, height: 7)
                    }
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .fixedSize()
        }
    }

    /// A five-segment gauge beside a bounded value: anything above zero lights at least one segment,
    /// so a barely-used window never reads as idle.
    @ViewBuilder
    private func segments(_ metric: MenuBarContent.Metric, providerID: String, height: CGFloat) -> some View {
        if metric.isBounded, metric.hasData {
            let clamped = min(max(metric.fraction, 0), 1)
            let lit = clamped <= 0 ? 0 : max(1, Int((clamped * 5).rounded()))
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { index in
                    Rectangle()
                        .fill(segmentFill(lit: index < lit, metric: metric, providerID: providerID))
                        .frame(width: 4, height: height)
                }
            }
        }
    }

    private func segmentFill(lit: Bool, metric: MenuBarContent.Metric, providerID: String) -> Color {
        switch layer {
        case .template:
            return Color.black.opacity(lit ? 1 : 0.3)
        case .mask(let colors):
            if lit, colors.color(for: metric, providerID: providerID) != nil { return .clear }
            return Color.black.opacity(lit ? 1 : 0.3)
        case .color(let colors):
            guard lit, let color = colors.color(for: metric, providerID: providerID) else { return .clear }
            return color
        }
    }

    /// Side length of the glyph box. Sized to fill the strip's height so the mark reads at the same
    /// scale as the dual-line metric block beside it (the single number is shorter), instead of
    /// floating small in the middle. `ProviderIconShape` already normalizes every mark to its true
    /// bounding box, so a near-zero `inset` here makes each provider fill this box uniformly.
    private static let glyphSide: CGFloat = 16

    @ViewBuilder
    private func glyph(_ icon: IconSource) -> some View {
        if let mark = ProviderMarks.mark(for: icon.providerID) {
            ProviderIconShape(mark: mark, inset: 0.04)
                .fill(ink)
                .frame(width: Self.glyphSide, height: Self.glyphSide)
        } else {
            Circle().fill(ink).frame(width: Self.glyphSide - 1, height: Self.glyphSide - 1)
        }
    }
}

/// Draws up to four horizontal usage bars into a compact square — a 1:1 port of the original OpenUsage
/// tray bars: track 0.16 / fill 1.0 / remainder 0.24 opacity (black, so the template tints them), a
/// rounded leading edge with a small rounded moving edge, and near-full quantization so a 97% bar still
/// shows a visible tail.
private struct MenuBarBars: View {
    let fractions: [Double]
    let side: CGFloat

    var body: some View {
        Canvas { context, size in
            draw(into: &context, size: size)
        }
        .frame(width: side, height: side)
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        let n = max(1, min(4, fractions.count))
        let pad = max(1, (size.width * 0.08).rounded())
        let gap = max(1, (size.width * 0.03).rounded())
        let trackX = pad
        let trackW = size.width - 2 * pad

        let layoutN = CGFloat(max(2, n))
        let trackH = max(1, ((size.height - 2 * pad - (layoutN - 1) * gap) / layoutN).rounded(.down))
        let rx = max(1, (trackH / 3).rounded(.down))

        let totalBarsHeight = CGFloat(n) * trackH + CGFloat(n - 1) * gap
        let yOffset = pad + ((size.height - 2 * pad - totalBarsHeight) / 2).rounded(.down)

        for i in 0..<n {
            let y = yOffset + CGFloat(i) * (trackH + gap) + 1

            context.fill(
                bar(x: trackX, y: y, w: trackW, h: trackH, leading: rx, trailing: rx),
                with: .color(.black.opacity(0.16))
            )

            let fill = MenuBarBarGeometry.fill(trackW: trackW, fraction: i < fractions.count ? fractions[i] : 0)
            if fill.fillW > 0 {
                let trailing = fill.fillW >= trackW ? rx : max(0, (rx * 0.35).rounded(.down))
                context.fill(
                    bar(x: trackX, y: y, w: fill.fillW, h: trackH, leading: rx, trailing: trailing),
                    with: .color(.black)
                )
            }
            if fill.fillW > 0, fill.remainderW > 0, let dividerX = fill.dividerX {
                context.fill(
                    bar(x: trackX + dividerX, y: y, w: fill.remainderW, h: trackH,
                        leading: max(0, (rx * 0.2).rounded(.down)), trailing: rx),
                    with: .color(.black.opacity(0.24))
                )
            }
        }
    }

    private func bar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, leading: CGFloat, trailing: CGFloat) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: leading,
            bottomLeadingRadius: leading,
            bottomTrailingRadius: trailing,
            topTrailingRadius: trailing
        )
        .path(in: CGRect(x: x, y: y, width: w, height: h))
    }
}

/// Pure fill geometry for the Bars glyph, factored out so the near-full quantization and minimum-visible
/// remainder rules are unit-testable. A 1:1 port of the original OpenUsage tray math.
enum MenuBarBarGeometry {
    struct Fill: Equatable {
        let fillW: CGFloat
        let remainderW: CGFloat
        let dividerX: CGFloat?
    }

    /// Quantize near-full (0.7–1.0) bars by remainder in 15% steps, so a nearly-full bar still leaves a
    /// visible tail instead of reading as 100%.
    static func visualFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        let clamped = min(1, max(0, fraction))
        if clamped > 0.7, clamped < 1 {
            let remainder = 1 - clamped
            let quantized = min(1, (remainder / 0.15).rounded(.up) * 0.15)
            return max(0, 1 - quantized)
        }
        return clamped
    }

    static func fill(trackW: CGFloat, fraction: Double) -> Fill {
        guard fraction.isFinite, fraction > 0 else { return Fill(fillW: 0, remainderW: 0, dividerX: nil) }
        let visual = visualFraction(fraction)
        if visual >= 1 { return Fill(fillW: trackW, remainderW: 0, dividerX: nil) }
        let minVisible = max(4, (trackW * 0.2).rounded())
        let maxFillW = max(1, trackW - minVisible)
        let fillW = max(1, min(maxFillW, (trackW * CGFloat(visual)).rounded()))
        let trueRemainder = trackW - fillW
        let remainderW = min(trackW - 1, max(trueRemainder, minVisible))
        return Fill(fillW: fillW, remainderW: remainderW, dividerX: trackW - remainderW)
    }
}
