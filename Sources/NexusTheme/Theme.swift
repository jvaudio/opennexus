import Foundation

/// A theme supplies colour. Node styles supply shape and weight; structures supply layout.
public struct Theme: Sendable, Identifiable, Equatable {
    public enum Grid: Sendable, Equatable {
        case none
        case dots(color: RGBA, spacing: Double)
        case lines(color: RGBA, spacing: Double)
    }

    public struct Fill: Sendable, Equatable {
        public var background: RGBA
        public var foreground: RGBA
        public var borderWidth: Double
        public var borderColor: RGBA
        public var dashed: Bool

        public init(
            background: RGBA, foreground: RGBA, borderWidth: Double = 0, borderColor: RGBA = .clear,
            dashed: Bool = false
        ) {
            self.background = background
            self.foreground = foreground
            self.borderWidth = borderWidth
            self.borderColor = borderColor
            self.dashed = dashed
        }
    }

    public var id: String
    public var name: String
    public var isDark: Bool
    public var canvas: RGBA
    public var grid: Grid
    public var root: Fill
    /// Main topics: background and text; the border takes the branch colour.
    public var main: Fill
    public var sub: Fill
    /// Eight branch colours, assigned to main topics in order.
    public var palette: [RGBA]
    /// Selection ring (Iris in most themes).
    public var ring: RGBA
    public var ringSoft: RGBA
    public var arrow: RGBA
    public var ink: RGBA
    public var ink2: RGBA
    public var relationship: RGBA
    public var amber: RGBA
    public var amberSoft: RGBA
    public var ai: RGBA
    public var aiSoft: RGBA
    public var aiBackground: RGBA
    public var aiForeground: RGBA
    public var critical: RGBA
    // Technical node fills.
    public var decision: RGBA
    public var entity: RGBA
    public var entityLine: RGBA
    public var process: RGBA
    public var processLine: RGBA
    public var store: RGBA
    public var storeLine: RGBA
    /// Use SF Mono for node text (Blueprint).
    public var monospaced: Bool
    /// Resting shadow under main topics.
    public var nodeShadowOpacity: Double

    public func branchColor(index: Int, shift: Int = 0) -> RGBA {
        guard !palette.isEmpty else { return ring }
        let n = palette.count
        return palette[((index + shift) % n + n) % n]
    }
}

extension Theme {
    public static let classic = Theme(
        id: "classic", name: "Classic", isDark: false,
        canvas: RGBA(hex: "#F7F7F5"), grid: .dots(color: RGBA(hex: "#D6D6DC"), spacing: 22),
        root: Fill(background: RGBA(hex: "#17171C"), foreground: .white),
        main: Fill(background: .white, foreground: RGBA(hex: "#17171C")),
        sub: Fill(background: RGBA(hex: "#17171C").alpha(0.045), foreground: RGBA(hex: "#2C2C33")),
        palette: Tokens.classicPalette,
        ring: RGBA(hex: "#5850EC"), ringSoft: RGBA(hex: "#5850EC").alpha(0.25),
        arrow: RGBA(hex: "#4A4A55"), ink: RGBA(hex: "#17171C"), ink2: RGBA(hex: "#4A4A55"),
        relationship: RGBA(hex: "#E8A317"), amber: RGBA(hex: "#F2B135"), amberSoft: RGBA(hex: "#F2B135").alpha(0.18),
        ai: RGBA(hex: "#0F9F9A"), aiSoft: RGBA(hex: "#0F9F9A").alpha(0.22),
        aiBackground: RGBA(hex: "#0F9F9A").alpha(0.08),
        aiForeground: RGBA(hex: "#0B6E6A"), critical: RGBA(hex: "#D93A3F"),
        decision: RGBA(hex: "#FBE7B5"), entity: RGBA(hex: "#E3F0FC"), entityLine: RGBA(hex: "#1E6FB8"),
        process: RGBA(hex: "#ECEBFE"), processLine: RGBA(hex: "#5850EC"),
        store: RGBA(hex: "#DDF3F1"), storeLine: RGBA(hex: "#0F7F7A"),
        monospaced: false, nodeShadowOpacity: 0.06)

    public static let graphite = Theme(
        id: "graphite", name: "Graphite", isDark: true,
        canvas: RGBA(hex: "#121317"), grid: .dots(color: RGBA(hex: "#2A2C33"), spacing: 22),
        root: Fill(background: RGBA(hex: "#F2F2F5"), foreground: RGBA(hex: "#121317")),
        main: Fill(background: RGBA(hex: "#1C1D22"), foreground: RGBA(hex: "#F2F2F5")),
        sub: Fill(background: RGBA.white.alpha(0.055), foreground: RGBA(hex: "#D9D9E0")),
        palette: ["#8F89FF", "#F06C4B", "#3FD3C9", "#F2B135", "#E25CA0", "#4DA9F0", "#86C94F", "#B57BEF"]
            .map(RGBA.init(hex:)),
        ring: RGBA(hex: "#8F89FF"), ringSoft: RGBA(hex: "#8F89FF").alpha(0.32),
        arrow: RGBA(hex: "#B4B4BE"), ink: RGBA(hex: "#F2F2F5"), ink2: RGBA(hex: "#B4B4BE"),
        relationship: RGBA(hex: "#F2B135"), amber: RGBA(hex: "#F2B135"), amberSoft: RGBA(hex: "#F2B135").alpha(0.18),
        ai: RGBA(hex: "#3FD3C9"), aiSoft: RGBA(hex: "#3FD3C9").alpha(0.25),
        aiBackground: RGBA(hex: "#3FD3C9").alpha(0.10),
        aiForeground: RGBA(hex: "#8FE7E0"), critical: RGBA(hex: "#F06C6F"),
        decision: RGBA(hex: "#4A3A12"), entity: RGBA(hex: "#16324A"), entityLine: RGBA(hex: "#4DA9F0"),
        process: RGBA(hex: "#26244A"), processLine: RGBA(hex: "#8F89FF"),
        store: RGBA(hex: "#11302F"), storeLine: RGBA(hex: "#3FD3C9"),
        monospaced: false, nodeShadowOpacity: 0.4)

    public static let blueprint = Theme(
        id: "blueprint", name: "Blueprint", isDark: true,
        canvas: RGBA(hex: "#0D3560"), grid: .lines(color: RGBA.white.alpha(0.06), spacing: 24),
        root: Fill(background: RGBA(hex: "#0D3560"), foreground: .white, borderWidth: 2, borderColor: .white),
        main: Fill(background: RGBA(hex: "#0D3560"), foreground: RGBA(hex: "#E6F1FF")),
        sub: Fill(
            background: .clear, foreground: RGBA(hex: "#CFE3FA"), borderWidth: 1,
            borderColor: RGBA(hex: "#9CC8F5").alpha(0.55), dashed: true),
        palette: Array(repeating: RGBA(hex: "#9CC8F5"), count: 8),
        ring: .white, ringSoft: RGBA.white.alpha(0.3),
        arrow: RGBA(hex: "#9CC8F5"), ink: RGBA(hex: "#FFFFFF"), ink2: RGBA(hex: "#CFE3FA"),
        relationship: RGBA(hex: "#FFD27A"), amber: RGBA(hex: "#FFD27A"), amberSoft: RGBA(hex: "#FFD27A").alpha(0.18),
        ai: RGBA(hex: "#7FF0E6"), aiSoft: RGBA(hex: "#7FF0E6").alpha(0.25),
        aiBackground: RGBA(hex: "#7FF0E6").alpha(0.08),
        aiForeground: RGBA(hex: "#BDF7F1"), critical: RGBA(hex: "#FF9C9E"),
        decision: RGBA(hex: "#FFD27A").alpha(0.20), entity: RGBA(hex: "#9CC8F5").alpha(0.12), entityLine: .white,
        process: RGBA.white.alpha(0.06), processLine: RGBA(hex: "#9CC8F5"),
        store: RGBA(hex: "#7FF0E6").alpha(0.10), storeLine: RGBA(hex: "#7FF0E6"),
        monospaced: true, nodeShadowOpacity: 0)

    /// Themes available in this build. M2 completes the launch set of twelve.
    public static let all: [Theme] = [.classic, .graphite, .blueprint]

    public static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? .classic
    }
}
