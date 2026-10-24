import AppKit
import NexusTheme
import SwiftUI

/// The OpenNexus mark, Aperture (brand/BRAND.md §1): a ring left open on the right, with two
/// branches leaving the centre through the gap. Drawn from the spec's geometry on its
/// 64-unit grid, so it scales without assets and can animate; it always lays out as a
/// square showing the masters' `8 8 50 50` viewBox.
///
///     ApertureMark()                                   // follows light and dark
///     ApertureMark(palette: .appIcon)                  // on the Iris tile
///     ApertureMark(opticalSize: .boost(1.5))           // the ≤ 32 px weights
///     ApertureMark(decorative: true)                   // beside the visible name
public struct ApertureMark: View {
    public enum Palette: Hashable, Sendable {
        /// The light palette in Light mode, the dark one in Dark mode.
        case automatic
        case light, dark
        /// White ring and root with pale branches: on the Iris tile or saturated colour.
        case appIcon
        /// One colour throughout.
        case mono(Color)
    }

    /// How bold the mark is drawn: it gets bolder as it gets smaller (BRAND.md §1).
    public enum OpticalSize: Hashable, Sendable {
        /// From the rendered size: 1.0 at 128 pt and above, 1.5 at 32 pt, 1.9 at 16 pt and
        /// below, linear between.
        case automatic
        case boost(Double)
    }

    var palette: Palette
    var opticalSize: OpticalSize
    var decorative: Bool
    @Environment(\.colorScheme) private var scheme

    public init(palette: Palette = .automatic, opticalSize: OpticalSize = .automatic, decorative: Bool = false) {
        self.palette = palette
        self.opticalSize = opticalSize
        self.decorative = decorative
    }

    public var body: some View {
        let colors = Self.colors(palette, dark: scheme == .dark)
        let mark = Canvas { ctx, size in
            let side = min(size.width, size.height)
            let b: Double =
                switch opticalSize {
                case .automatic: Self.boost(forSize: side)
                case .boost(let v): v
                }
            Self.draw(
                in: &ctx, side: side, origin: CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2),
                b: b, colors: colors)
        }
        .aspectRatio(1, contentMode: .fit)
        if decorative {
            mark.accessibilityHidden(true)
        } else {
            mark.accessibilityElement().accessibilityLabel("OpenNexus").accessibilityAddTraits(.isImage)
        }
    }

    // MARK: Geometry (BRAND.md §1)

    /// The optical size boost `b` for a mark drawn `side` points (or pixels) wide.
    public static func boost(forSize side: Double) -> Double {
        if side >= 128 { return 1.0 }
        if side > 32 { return 1.5 - 0.5 * (side - 32) / (128 - 32) }
        if side > 16 { return 1.9 - 0.4 * (side - 16) / (32 - 16) }
        return 1.9
    }

    /// The mark's parts at boost `b`, in grid units.
    public struct Parts: Equatable, Sendable {
        public var ringStroke: Double
        /// The gap's half-angle, in degrees.
        public var gap: Double
        /// The ring's two ends: upper, then lower.
        public var ringEnds: (CGPoint, CGPoint)
        public var branchStroke: Double
        public var endRadius: Double
        public var rootRadius: Double

        public static func == (a: Parts, b: Parts) -> Bool {
            a.ringStroke == b.ringStroke && a.gap == b.gap && a.ringEnds.0 == b.ringEnds.0
                && a.ringEnds.1 == b.ringEnds.1 && a.branchStroke == b.branchStroke && a.endRadius == b.endRadius
                && a.rootRadius == b.rootRadius
        }
    }

    public static let center = CGPoint(x: 26, y: 32)
    public static let ringRadius = 14.0
    public static let upperNode = CGPoint(x: 51, y: 18.6)
    public static let lowerNode = CGPoint(x: 51, y: 45.4)
    /// The masters' viewBox: x 8–58, y 8–58.
    public static let viewBox = CGRect(x: 8, y: 8, width: 50, height: 50)

    public static func parts(b: Double) -> Parts {
        let s = 1 + 0.45 * (b - 1)
        let gap = 45 + 12 * (b - 1)
        let a = gap * .pi / 180
        let ex = center.x + ringRadius * cos(a)
        let dy = ringRadius * sin(a)
        return Parts(
            ringStroke: 5 * b, gap: gap,
            ringEnds: (CGPoint(x: ex, y: center.y - dy), CGPoint(x: ex, y: center.y + dy)),
            branchStroke: 3.4 * b, endRadius: 5 * s, rootRadius: 6.2 * s)
    }

    struct Colors {
        var ring, root, upper, lower: Color
    }

    static func colors(_ palette: Palette, dark: Bool) -> Colors {
        func c(_ v: RGBA) -> Color { Color(.sRGB, red: v.r, green: v.g, blue: v.b, opacity: v.a) }
        switch palette {
        case .automatic, .light, .dark:
            let d = palette == .dark || (palette == .automatic && dark)
            return Colors(
                ring: c(BrandColor.ring.resolved(dark: d)), root: c(BrandColor.root.resolved(dark: d)),
                upper: c(BrandColor.upper.resolved(dark: d)), lower: c(BrandColor.lower.resolved(dark: d)))
        case .appIcon:
            return Colors(
                ring: c(BrandColor.AppIcon.ring), root: c(BrandColor.AppIcon.root), upper: c(BrandColor.AppIcon.upper),
                lower: c(BrandColor.AppIcon.lower))
        case .mono(let m):
            return Colors(ring: m, root: m, upper: m, lower: m)
        }
    }

    /// Draws the mark into a square of `side` at `origin`, back to front: ring, upper and lower
    /// branches, their end nodes, then the root.
    static func draw(in ctx: inout GraphicsContext, side: Double, origin: CGPoint, b: Double, colors: Colors) {
        let k = side / viewBox.width
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -viewBox.minX, y: -viewBox.minY)
        let p = parts(b: b)
        let round = StrokeStyle(lineWidth: p.ringStroke, lineCap: .round)

        // The ring: from the upper end the long way round, through the top and the left, to the
        // lower end, so the gap faces +x (the masters' `A14 14 0 1 0`).
        var ring = Path()
        ring.move(to: p.ringEnds.0)
        let start = Angle.degrees(-p.gap)
        ring.addRelativeArc(center: center, radius: ringRadius, startAngle: start, delta: .degrees(-(360 - 2 * p.gap)))
        ctx.stroke(ring, with: .color(colors.ring), style: round)

        let branch = StrokeStyle(lineWidth: p.branchStroke, lineCap: .round)
        var upper = Path()
        upper.move(to: center)
        upper.addCurve(to: CGPoint(x: 50, y: 19), control1: CGPoint(x: 36, y: 32), control2: CGPoint(x: 40, y: 22))
        ctx.stroke(upper, with: .color(colors.upper), style: branch)
        var lower = Path()
        lower.move(to: center)
        lower.addCurve(to: CGPoint(x: 50, y: 45), control1: CGPoint(x: 36, y: 32), control2: CGPoint(x: 40, y: 42))
        ctx.stroke(lower, with: .color(colors.lower), style: branch)

        func dot(_ c: CGPoint, _ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        ctx.fill(dot(upperNode, p.endRadius), with: .color(colors.upper))
        ctx.fill(dot(lowerNode, p.endRadius), with: .color(colors.lower))
        ctx.fill(dot(center, p.rootRadius), with: .color(colors.root))
    }
}

/// The app icon as a tile, for Welcome and the About card (brand/BRAND.md §5): the running
/// app's own icon, so it's whatever the asset catalog (or `AppIcon.icon`) compiled.
public struct AppIconTile: View {
    var size: CGFloat
    var decorative: Bool

    public init(size: CGFloat, decorative: Bool = true) {
        self.size = size
        self.decorative = decorative
    }

    public var body: some View {
        let icon = Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
        if decorative {
            icon.accessibilityHidden(true)
        } else {
            icon.accessibilityLabel("OpenNexus")
        }
    }
}

/// The horizontal lockup from the kit (`BrandLockup` in the app's catalog, light and dark).
/// It's the kit's outlined wordmark, never live text (BRAND.md §3).
public struct BrandLockup: View {
    var height: CGFloat

    public init(height: CGFloat) { self.height = height }

    public var body: some View {
        Image("BrandLockup", bundle: .main)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: height)
            .accessibilityLabel("OpenNexus")
    }
}
