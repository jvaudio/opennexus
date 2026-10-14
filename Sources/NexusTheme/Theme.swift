import Foundation

/// A theme supplies colour, the diagram font and the base node and line character.
/// Node styles supply shape and weight; structures supply layout. Themes are plain
/// data and round-trip as `.nexustheme` JSON.
public struct Theme: Sendable, Identifiable, Equatable, Codable {
    public enum Grid: Sendable, Equatable, Codable {
        case none
        case dots(color: RGBA, spacing: Double)
        case lines(color: RGBA, spacing: Double)

        private enum K: String, CodingKey { case kind, color, spacing }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            let kind = try c.decode(String.self, forKey: .kind)
            let color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? .clear
            let spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 22
            switch kind {
            case "dots": self = .dots(color: color, spacing: spacing)
            case "lines": self = .lines(color: color, spacing: spacing)
            default: self = .none
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            switch self {
            case .none: try c.encode("plain", forKey: .kind)
            case .dots(let col, let s):
                try c.encode("dots", forKey: .kind)
                try c.encode(col, forKey: .color)
                try c.encode(s, forKey: .spacing)
            case .lines(let col, let s):
                try c.encode("lines", forKey: .kind)
                try c.encode(col, forKey: .color)
                try c.encode(s, forKey: .spacing)
            }
        }

        public var color: RGBA? {
            switch self {
            case .none: nil
            case .dots(let c, _), .lines(let c, _): c
            }
        }
    }

    public struct Fill: Sendable, Equatable, Codable {
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

    /// Diagram font: system (SF Pro), serif (New York), mono (SF Mono), hand, or a family name.
    public var font: String = "system"
    /// Branch line shape: curved, straight, elbow, rounded.
    public var lineShape: String = "curved"
    /// Multiplier on the default branch-line widths.
    public var lineWidth: Double = 1
    public var nodeRadius: Double = Tokens.Radius.node
    public var rootRadius: Double = Tokens.Radius.root
    public var mainBorderWidth: Double = 2
    /// Weight of main-topic text (medium unless the theme asks for more).
    public var mainWeight: String = "medium"
    /// Minimum text contrast this theme guarantees: 4.5 (AA) or 7 (AAA).
    public var contrastTarget: Double = 4.5
    /// The theme designed as this one's light or dark partner.
    public var counterpart: String?
    /// How each diagram family is coloured: by branch, by node type, or by risk.
    public var colorModes: [String: String] = [
        "mindmap": "branch", "dfd": "type", "architecture": "type",
        "threatModel": "risk",
    ]

    public func branchColor(index: Int, shift: Int = 0) -> RGBA {
        guard !palette.isEmpty else { return ring }
        let n = palette.count
        return palette[((index + shift) % n + n) % n]
    }

    public var isMonochromePalette: Bool { Set(palette).count == 1 }
}

extension Theme {
    /// Light-theme semantic defaults; dark themes override.
    static func make(
        id: String, name: String, dark: Bool, canvas: String, grid: Grid, root: Fill, main: Fill, sub: Fill,
        palette: [String], ring: String? = nil, font: String = "system", line: String = "curved",
        lineWidth: Double = 1, radius: Double = Tokens.Radius.node, rootRadius: Double = Tokens.Radius.root,
        border: Double = 2, mainWeight: String = "medium", contrast: Double = 4.5, counterpart: String? = nil,
        relationship: String? = nil, shadow: Double? = nil
    ) -> Theme {
        let ringC = RGBA(hex: ring ?? (dark ? "#8F89FF" : "#5850EC"))
        let ink = dark ? RGBA(hex: "#F2F2F5") : RGBA(hex: "#17171C")
        let ink2 = dark ? RGBA(hex: "#B4B4BE") : RGBA(hex: "#4A4A55")
        let aurora = dark ? RGBA(hex: "#3FD3C9") : RGBA(hex: "#0F9F9A")
        var t = Theme(
            id: id, name: name, isDark: dark, canvas: RGBA(hex: canvas), grid: grid, root: root, main: main, sub: sub,
            palette: palette.map(RGBA.init(hex:)), ring: ringC, ringSoft: ringC.alpha(dark ? 0.32 : 0.25),
            arrow: ink2, ink: ink, ink2: ink2,
            relationship: RGBA(hex: relationship ?? (dark ? "#F2B135" : "#E8A317")),
            amber: RGBA(hex: "#F2B135"), amberSoft: RGBA(hex: "#F2B135").alpha(0.18),
            ai: aurora, aiSoft: aurora.alpha(dark ? 0.25 : 0.22), aiBackground: aurora.alpha(dark ? 0.10 : 0.08),
            aiForeground: dark ? RGBA(hex: "#8FE7E0") : RGBA(hex: "#0B6E6A"),
            critical: dark ? RGBA(hex: "#F06C6F") : RGBA(hex: "#D93A3F"),
            decision: dark ? RGBA(hex: "#4A3A12") : RGBA(hex: "#FBE7B5"),
            entity: dark ? RGBA(hex: "#16324A") : RGBA(hex: "#E3F0FC"),
            entityLine: dark ? RGBA(hex: "#4DA9F0") : RGBA(hex: "#1E6FB8"),
            process: dark ? RGBA(hex: "#26244A") : RGBA(hex: "#ECEBFE"), processLine: ringC,
            store: dark ? RGBA(hex: "#11302F") : RGBA(hex: "#DDF3F1"),
            storeLine: dark ? RGBA(hex: "#3FD3C9") : RGBA(hex: "#0F7F7A"),
            monospaced: font == "mono", nodeShadowOpacity: shadow ?? (dark ? 0.4 : 0.06))
        t.font = font
        t.lineShape = line
        t.lineWidth = lineWidth
        t.nodeRadius = radius
        t.rootRadius = rootRadius
        t.mainBorderWidth = border
        t.mainWeight = mainWeight
        t.contrastTarget = contrast
        t.counterpart = counterpart
        return t
    }

    private static func fill(
        _ bg: String, _ fg: String, border: Double = 0, borderColor: String? = nil,
        dashed: Bool = false
    ) -> Fill {
        Fill(
            background: RGBA(hex: bg), foreground: RGBA(hex: fg), borderWidth: border,
            borderColor: borderColor.map(RGBA.init(hex:)) ?? .clear, dashed: dashed)
    }

    public static let classic = make(
        id: "classic", name: "Classic", dark: false, canvas: "#F7F7F5",
        grid: .dots(color: RGBA(hex: "#D6D6DC"), spacing: 22),
        root: fill("#17171C", "#FFFFFF"), main: fill("#FFFFFF", "#17171C"), sub: fill("#17171C0B", "#2C2C33"),
        palette: ["#5850EC", "#E4572E", "#0F9F9A", "#E0A100", "#D6408B", "#1E8BE0", "#5AA02C", "#9B51E0"],
        counterpart: "graphite")

    public static let paper = make(
        id: "paper", name: "Paper", dark: false, canvas: "#F4EFE4",
        grid: .dots(color: RGBA(hex: "#DED4C0"), spacing: 22),
        root: fill("#3B2F2A", "#FBF7EE"), main: fill("#FFFBF2", "#2B2420"), sub: fill("#2B24200D", "#3A322C"),
        palette: ["#8C5A3C", "#3D6B5A", "#B0413E", "#B07A1E", "#5B6E8C", "#7A5C8C", "#4F7A3A", "#A0522D"],
        ring: "#5850EC", font: "serif", counterpart: "graphite", relationship: "#B07A1E")

    public static let graphite = make(
        id: "graphite", name: "Graphite", dark: true, canvas: "#121317",
        grid: .dots(color: RGBA(hex: "#2A2C33"), spacing: 22),
        root: fill("#F2F2F5", "#121317"), main: fill("#1C1D22", "#F2F2F5"), sub: fill("#FFFFFF0E", "#D9D9E0"),
        palette: ["#8F89FF", "#F06C4B", "#3FD3C9", "#F2B135", "#E25CA0", "#4DA9F0", "#86C94F", "#B57BEF"],
        counterpart: "classic")

    public static let midnightNeon = make(
        id: "midnightNeon", name: "Midnight Neon", dark: true, canvas: "#0A0820",
        grid: .dots(color: RGBA(hex: "#231E4D"), spacing: 22),
        root: fill("#F7F5FF", "#0A0820"), main: fill("#14102E", "#F2F0FF"), sub: fill("#FFFFFF0F", "#D8D4F5"),
        palette: ["#FF4FD8", "#3DF5FF", "#B6FF3D", "#FFE14D", "#8F89FF", "#FF7A45", "#4DFFB8", "#FF5C7A"],
        ring: "#3DF5FF", relationship: "#FFE14D", shadow: 0.5)

    public static let blueprint: Theme = {
        var t = make(
            id: "blueprint", name: "Blueprint", dark: true, canvas: "#0D3560",
            grid: .lines(color: RGBA.white.alpha(0.07), spacing: 20),
            root: fill("#0D3560", "#FFFFFF", border: 2, borderColor: "#FFFFFF"), main: fill("#0D3560", "#E6F1FF"),
            sub: fill("#00000000", "#CFE3FA", border: 1, borderColor: "#9CC8F58C", dashed: true),
            palette: Array(repeating: "#9CC8F5", count: 8), ring: "#FFFFFF", font: "mono", line: "elbow",
            lineWidth: 0.75, radius: 2, rootRadius: 2, border: 1.5, relationship: "#FFD27A", shadow: 0)
        t.arrow = RGBA(hex: "#9CC8F5")
        t.ink2 = RGBA(hex: "#CFE3FA")
        t.ai = RGBA(hex: "#7FF0E6")
        t.critical = RGBA(hex: "#FF9C9E")
        t.decision = RGBA(hex: "#FFD27A").alpha(0.20)
        t.entity = RGBA(hex: "#9CC8F5").alpha(0.12)
        t.entityLine = .white
        t.process = RGBA.white.alpha(0.06)
        t.processLine = RGBA(hex: "#9CC8F5")
        t.store = RGBA(hex: "#7FF0E6").alpha(0.10)
        t.storeLine = RGBA(hex: "#7FF0E6")
        return t
    }()

    public static let whiteboard = make(
        id: "whiteboard", name: "Whiteboard", dark: false, canvas: "#FFFFFF",
        grid: .dots(color: RGBA(hex: "#E6E6EC"), spacing: 24),
        root: fill("#FFFFFF", "#17171C", border: 2.5, borderColor: "#17171C"), main: fill("#FFFFFF", "#17171C"),
        sub: fill("#00000000", "#2C2C33"),
        palette: ["#2B59C3", "#D7263D", "#1B998B", "#E36414", "#7B2CBF", "#2E86AB", "#5C946E", "#C08A00"],
        font: "hand", radius: 8, rootRadius: 12, border: 2.2, mainWeight: "bold", shadow: 0)

    public static let pastel = make(
        id: "pastel", name: "Pastel", dark: false, canvas: "#FBF7F4",
        grid: .dots(color: RGBA(hex: "#EADFD8"), spacing: 22),
        root: fill("#5B5470", "#FFFFFF"), main: fill("#FFFFFF", "#2E2A3A"), sub: fill("#5B54700D", "#3E3A4C"),
        palette: ["#F4A6A6", "#A6D9C8", "#B9B4F0", "#F6D6A8", "#A8C8F0", "#E8B4D8", "#C5E3A6", "#F7C5A8"],
        ring: "#7A6FE0", radius: 12, rootRadius: 18, border: 2.5, shadow: 0.04)

    public static let highContrast = make(
        id: "highContrast", name: "High Contrast", dark: false, canvas: "#FFFFFF", grid: .none,
        root: fill("#000000", "#FFFFFF"), main: fill("#FFFFFF", "#000000"),
        sub: fill("#FFFFFF", "#000000", border: 1.5, borderColor: "#000000"),
        palette: Array(repeating: "#000000", count: 8), ring: "#0040FF", lineWidth: 1.5, radius: 6, rootRadius: 8,
        border: 2.5, mainWeight: "bold", contrast: 7, relationship: "#000000", shadow: 0)

    public static let monoPrint = make(
        id: "monoPrint", name: "Mono Print", dark: false, canvas: "#FFFFFF", grid: .none,
        root: fill("#222222", "#FFFFFF"), main: fill("#FFFFFF", "#111111"), sub: fill("#0000000A", "#222222"),
        palette: ["#333333", "#555555", "#777777", "#444444", "#666666", "#888888", "#3A3A3A", "#5A5A5A"],
        ring: "#333333", relationship: "#555555", shadow: 0)

    public static let solarized = make(
        id: "solarized", name: "Solarized", dark: false, canvas: "#FDF6E3",
        grid: .dots(color: RGBA(hex: "#E9E0C6"), spacing: 22),
        root: fill("#073642", "#FDF6E3"), main: fill("#FFFDF6", "#073642"), sub: fill("#EEE8D5", "#4F6168"),
        palette: ["#268BD2", "#2AA198", "#CB4B16", "#B58900", "#D33682", "#6C71C4", "#859900", "#DC322F"],
        ring: "#268BD2", relationship: "#B58900", shadow: 0.05)

    public static let skeleton = make(
        id: "skeleton", name: "Skeleton", dark: false, canvas: "#F7F7F5",
        grid: .dots(color: RGBA(hex: "#E2E2E6"), spacing: 22),
        root: fill("#E4E4E9", "#3A3A44"), main: fill("#FFFFFF", "#4A4A55"), sub: fill("#00000000", "#5E5E69"),
        palette: Array(repeating: "#C8C8CF", count: 8), ring: "#5850EC", counterpart: "skeletonDark",
        relationship: "#A8A8B2", shadow: 0)

    public static let skeletonDark = make(
        id: "skeletonDark", name: "Skeleton Dark", dark: true, canvas: "#17181C",
        grid: .dots(color: RGBA(hex: "#26272D"), spacing: 22),
        root: fill("#2A2B31", "#D2D2DA"), main: fill("#1E1F24", "#C8C8CF"), sub: fill("#00000000", "#A2A2AE"),
        palette: Array(repeating: "#4A4B55", count: 8), counterpart: "skeleton", relationship: "#6A6B75", shadow: 0)

    /// The launch set of twelve, in the order the theme sheet shows them.
    public static let builtIn: [Theme] = [
        .classic, .paper, .graphite, .midnightNeon, .blueprint, .whiteboard, .pastel, .highContrast, .monoPrint,
        .solarized, .skeleton, .skeletonDark,
    ]

    /// The four themes the brief requires first.
    public static let required: [Theme] = [.classic, .graphite, .blueprint, .highContrast]

    public static var all: [Theme] { builtIn }

    public static func named(_ id: String, custom: [Theme] = []) -> Theme {
        builtIn.first { $0.id == id } ?? custom.first { $0.id == id } ?? .classic
    }
}

/// `.nexustheme` files: a theme as JSON (sorted keys, pretty).
public enum ThemeCodec {
    public static let fileExtension = "nexustheme"

    public static func encode(_ theme: Theme) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(theme)
    }

    public static func decode(_ data: Data) throws -> Theme {
        try JSONDecoder().decode(Theme.self, from: data)
    }
}
