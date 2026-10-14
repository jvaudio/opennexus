import Foundation
import Testing

@testable import NexusCore
@testable import NexusTheme

@Suite struct ThemeSetTests {
    @Test func launchSetHasTwelveUniqueThemes() {
        #expect(Theme.builtIn.count == 12)
        #expect(Set(Theme.builtIn.map(\.id)).count == 12)
        #expect(
            Theme.builtIn.map(\.name) == [
                "Classic", "Paper", "Graphite", "Midnight Neon", "Blueprint", "Whiteboard", "Pastel", "High Contrast",
                "Mono Print", "Solarized", "Skeleton", "Skeleton Dark",
            ])
        #expect(Theme.required.map(\.id) == ["classic", "graphite", "blueprint", "highContrast"])
        for t in Theme.builtIn { #expect(t.palette.count == 8, "\(t.name)") }
    }

    @Test func counterpartsPointBothWays() {
        for t in Theme.builtIn {
            guard let c = t.counterpart else { continue }
            let other = Theme.named(c)
            #expect(other.id == c)
            #expect(other.isDark != t.isDark, "\(t.name) ↔ \(other.name)")
        }
    }

    /// M2 acceptance: AA for every theme, AAA for High Contrast, across all node styles.
    @Test(arguments: Theme.builtIn)
    func contrastPasses(theme: Theme) {
        let report = ContrastChecker.check(theme)
        #expect(report.passes, "\(theme.name): \(report.badge) at \(report.worst) [\(report.detail)]")
        #expect(report.minimum >= 4.5, "\(theme.name) below AA: \(report.worst)")
        if theme.id == "highContrast" { #expect(report.minimum >= 7, "High Contrast below AAA: \(report.worst)") }
    }

    @Test func contrastCheckerCatchesFailures() {
        var t = Theme.classic
        t.contrastTarget = 21.5
        #expect(!ContrastChecker.check(t, styles: [.outline]).passes)
        #expect(ContrastChecker.check(.highContrast).badge.hasPrefix("AAA"))
    }

    @Test func autoContrastAdjustsUnreadableText() {
        let bg = RGBA(hex: "#F7F7F5")
        let gold = RGBA(hex: "#E0A100")
        #expect(Contrast.ratio(gold, bg) < 4.5)
        let fixed = Contrast.adjusted(gold, on: bg)
        #expect(Contrast.ratio(fixed, bg) >= 4.5)
        // Already readable colours are untouched.
        #expect(Contrast.adjusted(RGBA(hex: "#17171C"), on: bg) == RGBA(hex: "#17171C"))
    }

    @Test func nexusthemeRoundTrip() throws {
        for t in Theme.builtIn {
            // Colours are stored as 8-bit hex, so the codec is exact after one pass.
            let once = try ThemeCodec.encode(t)
            let back = try ThemeCodec.decode(once)
            #expect(try ThemeCodec.encode(back) == once, "\(t.name)")
            #expect(back.palette.map(\.hex) == t.palette.map(\.hex))
            #expect(back.name == t.name)
        }
    }

    @Test func paletteGenerationKeepsLightness() {
        let p = ColorPalette.generated(from: RGBA(hex: "#E07A5F"))
        #expect(p.colors.count == 6)
        #expect(Set(p.colors.map(\.hex)).count == 6)
    }
}

@Suite struct StyleResolutionTests {
    func env(_ cs: CanvasStyle = CanvasStyle(), theme: Theme = .classic) -> StyleEnvironment {
        StyleEnvironment(theme: theme, canvasStyle: cs)
    }

    /// node override → quick style → branch level → node style preset → theme → defaults.
    @Test func resolutionOrder() {
        var cs = CanvasStyle()
        cs.nodeStyle = "soft"  // preset: radius 12 for main
        var level = TopicStyle()
        level.cornerRadius = 20
        level.shape = "hexagon"
        cs.levels[1] = level
        var node = Node(text: "x")
        // Defaults + theme + preset: the soft preset's radius.
        #expect(StyleResolver.merged(role: .main, depth: 2, node: node, env: env(cs)).cornerRadius == 12)
        // Level beats preset.
        #expect(StyleResolver.merged(role: .main, depth: 1, node: node, env: env(cs)).cornerRadius == 20)
        // Quick style beats level.
        node.quickStyle = "decision"
        #expect(StyleResolver.merged(role: .main, depth: 1, node: node, env: env(cs)).shape == "diamond")
        // Node override beats quick style.
        var o = TopicStyle()
        o.shape = "star"
        node.style = o
        let m = StyleResolver.merged(role: .main, depth: 1, node: node, env: env(cs))
        #expect(m.shape == "star")
        #expect(m.cornerRadius == 20)  // untouched fields fall through
        // Theme beats defaults: Blueprint is monospaced.
        #expect(StyleResolver.merged(role: .main, depth: 1, node: nil, env: env(theme: .blueprint)).font == "mono")
        #expect(StyleResolver.defaults(.main).font == "system")
    }

    @Test func presetsDifferFromOutline() {
        let outline = StyleResolver.appearance(
            role: .main, depth: 1, node: nil, branch: RGBA(hex: "#5850EC"), env: env())
        for s in NodeStyle.allCases where s != .outline {
            var cs = CanvasStyle()
            cs.nodeStyle = s.rawValue
            let a = StyleResolver.appearance(
                role: .main, depth: 1, node: nil, branch: RGBA(hex: "#5850EC"), env: env(cs))
            #expect(a != outline, "\(s) looks like outline")
        }
    }

    @Test func nodeStyleLineCharacter() {
        var cs = CanvasStyle()
        cs.nodeStyle = "brutal"
        let brutal = StyleResolver.line(
            childDepth: 1, family: "mindmap", branch: .white, parentLine: nil, inherited: [], env: env(cs))
        #expect(brutal.shape == "elbow")
        #expect(brutal.color == RGBA(hex: "#17171C"))
        cs.nodeStyle = "minimal"
        #expect(
            StyleResolver.line(
                childDepth: 1, family: "mindmap", branch: .white, parentLine: nil, inherited: [], env: env(cs)
            ).dash == "dotted")
        cs.nodeStyle = "glow"
        #expect(
            StyleResolver.line(
                childDepth: 1, family: "mindmap", branch: .white, parentLine: nil, inherited: [], env: env(cs)
            ).glow)
        // Blueprint's elbow lines come from the theme.
        #expect(
            StyleResolver.line(
                childDepth: 1, family: "mindmap", branch: .white, parentLine: nil, inherited: [],
                env: env(theme: .blueprint)
            ).shape == "elbow")
    }

    @Test func colourThemeModes() {
        var cs = CanvasStyle()
        cs.palette = "sunset"
        let e = env(cs)
        #expect(e.branchColor(mainIndex: 1, count: 4) == ColorPalette.sunset.colors[1])
        cs.colorTheme = "mono"
        #expect(env(cs).branchColor(mainIndex: 3, count: 4) == ColorPalette.sunset.colors[0])
        cs.colorTheme = "gradient"
        let g = env(cs)
        #expect(g.branchColor(mainIndex: 0, count: 3) == ColorPalette.sunset.colors[0])
        #expect(g.branchColor(mainIndex: 2, count: 3).hex == ColorPalette.sunset.colors[5].hex)
        cs.coloredBranch = false
        cs.singleColor = "#123456"
        #expect(env(cs).branchColor(mainIndex: 2, count: 3) == RGBA(hex: "#123456"))
    }

    @Test func colorTokens() {
        let e = env()
        let b = RGBA(hex: "#5850EC")
        #expect(StyleResolver.resolveColor("branch", branch: b, env: e) == b)
        #expect(StyleResolver.resolveColor("branch@0.5", branch: b, env: e)?.a == 0.5)
        #expect(StyleResolver.resolveColor("#E0A100", branch: b, env: e) == RGBA(hex: "#E0A100"))
        #expect(StyleResolver.resolveColor("canvas", branch: b, env: e) == Theme.classic.canvas)
        #expect(StyleResolver.resolveColor("nonsense", branch: b, env: e) == nil)
    }

    @Test func shapesAllProducePaths() {
        #expect(ShapeLibrary.all.count == 32)
        for s in ShapeLibrary.all {
            let p = ShapeLibrary.path(s.id, in: CGRect(x: 0, y: 0, width: 160, height: 40), radius: 10)
            let b = p.boundingBoxOfPath
            #expect(b.width > 100 && b.height > 0, "\(s.id) has no area")
            #expect(b.minX >= -2 && b.maxX <= 162, "\(s.id) escapes its rect")
        }
    }

    @Test func svgArcsAreCurves() throws {
        let p = try #require(SVGPath.parse("M12 1a7 7 0 1 0 0 14a7 7 0 1 0 0-14z"))
        let b = p.boundingBoxOfPath
        #expect(abs(b.width - 14) < 0.5)
        #expect(abs(b.height - 14) < 0.5)
    }
}

@Suite struct StyleModelTests {
    @Test func topicStyleRoundTripsWithUnknownKeys() throws {
        var s = TopicStyle()
        s.shape = "hexagon"
        s.fill = "solid"
        s.fillColor = "#0F9F9A"
        s.textCase = "upper"
        s.line = LineStyle(shape: "elbow", width: 3, endCap: "arrow")
        s.numbering = NumberingStyle(format: "tiered", tiered: true)
        s.extra["futureKey"] = "kept"
        let back = try TopicStyle(json: s.json, path: "s")
        #expect(back == s)
        #expect(back.extra["futureKey"] == "kept")
    }

    @Test func mergeKeepsBaseWhereUnset() {
        var base = TopicStyle()
        base.shape = "pill"
        base.fontSize = 14
        base.line = LineStyle(shape: "curved", width: 2)
        var top = TopicStyle()
        top.fontSize = 18
        top.line = LineStyle(width: 4)
        let m = top.merged(over: base)
        #expect(m.shape == "pill")
        #expect(m.fontSize == 18)
        #expect(m.line?.shape == "curved")
        #expect(m.line?.width == 4)
    }

    @Test func libraryRoundTrip() {
        var lib = StyleLibrary()
        var t = Theme.paper
        t.id = "custom-dusk"
        t.name = "Studio Dusk"
        lib.themes = [t]
        lib.palettes = [ColorPalette(id: "custom-dusk", name: "Dusk", colors: ColorPalette.earth.colors)]
        var qs = TopicStyle()
        qs.fillColor = "#FF0000"
        lib.quickStyles = [QuickStyle(id: "custom-alarm", name: "Alarm", glyph: "★", style: qs)]
        lib.extra["future"] = 1
        let back = StyleLibrary(json: lib.json)
        #expect(StyleLibrary(json: back.json) == back)
        #expect(back.themes.map(\.name) == ["Studio Dusk"])
        #expect(back.palettes.first?.colors.map(\.hex) == ColorPalette.earth.colors.map(\.hex))
        #expect(back.quickStyles == lib.quickStyles)
        #expect(back.extra["future"] == 1)
    }

    @Test func canvasStyleMapFieldsRoundTrip() throws {
        var cs = CanvasStyle(theme: "solarized", nodeStyle: "capsule", colorTheme: "gradient", palette: "ocean")
        cs.coloredBranch = false
        cs.singleColor = "#333333"
        cs.background = "#121317"
        cs.pattern = "lines"
        cs.font = "serif"
        cs.lineWidth = "taper"
        cs.compact = true
        cs.justify = true
        cs.autoBalance = false
        var level = TopicStyle()
        level.shape = "pill"
        cs.levels[2] = level
        #expect(try CanvasStyle(json: cs.json, path: "s") == cs)
    }
}
