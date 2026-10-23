import Foundation
import NexusCore

/// Everything needed to paint one node, after every style layer has been merged.
public struct NodeAppearance: Equatable, Sendable {
    public enum Fill: Equatable, Sendable {
        case none
        case solid(RGBA)
        case gradient(RGBA, RGBA)

        public var representative: RGBA? {
            switch self {
            case .none: nil
            case .solid(let c): c
            case .gradient(let a, let b): a.mix(b, 0.5)
            }
        }
    }

    public enum BorderPattern: String, Sendable, CaseIterable {
        case none, solid, dashed, dotted, hand, double
    }

    public struct Shadow: Equatable, Sendable {
        public var color: RGBA
        public var dx: Double
        public var dy: Double
        public var radius: Double
    }

    public var shape: String
    public var cornerRadius: Double
    public var fill: Fill
    public var border: BorderPattern
    public var borderWidth: Double
    public var borderColor: RGBA
    public var shadow: Shadow?
    public var text: RGBA
    /// The colour behind the text (fill over canvas), used for the contrast guarantee.
    public var textBackground: RGBA
    public var font: String
    public var fontSize: Double
    public var fontWeight: NodeTypography.Weight
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var code: Bool
    public var textCase: String
    public var align: String
    public var lineHeight: Double
    public var paddingX: Double
    public var paddingY: Double
    public var minWidth: Double
    public var maxWidth: Double
    public var numbering: NumberingStyle?

    /// Underline-style nodes draw only a baseline, and branch lines attach to it.
    public var isUnderline: Bool { shape == "underline" }
}

/// One branch line, resolved.
public struct BranchLineAppearance: Equatable, Sendable {
    public var shape: String
    public var color: RGBA
    public var width: Double
    public var dash: String
    public var glow: Bool
    public var endCap: String
    public var taper: Bool
}

/// Everything about a canvas that styling depends on.
public struct StyleEnvironment: Sendable {
    public private(set) var theme: Theme
    public private(set) var nodeStyle: NodeStyle
    public private(set) var canvasStyle: CanvasStyle
    /// defaults → theme → node style for each role, built once per environment (these
    /// layers are the same for every node, and building them per node dominated reflow).
    let roleBase: [NodeRoleStyle: TopicStyle]
    /// Settings › Appearance › Adapt text colour to background (off keeps theme ink).
    public var adaptText = true
    public var palette: [RGBA]
    public var mode: ColorThemeMode
    public var quickStyles: [QuickStyle]
    public var canvas: RGBA

    public init(
        theme: Theme, canvasStyle: CanvasStyle, customPalettes: [ColorPalette] = [],
        customQuickStyles: [QuickStyle] = []
    ) {
        self.theme = theme
        self.nodeStyle = NodeStyle.named(canvasStyle.nodeStyle)
        self.canvasStyle = canvasStyle
        let paletteID = canvasStyle.palette
        let own = canvasStyle.colors.compactMap(RGBA.init(hexString:))
        if paletteID == "theme" || paletteID.isEmpty {
            palette = theme.palette
        } else if paletteID == "canvas", !own.isEmpty {
            palette = own
        } else if let p = (ColorPalette.builtIn + customPalettes).first(where: { $0.id == paletteID }) {
            palette = p.colors
        } else {
            palette = theme.palette
        }
        mode = ColorThemeMode(rawValue: canvasStyle.colorTheme) ?? .rainbow
        // A canvas's own look for a built-in quick style replaces the built-in one (D244).
        quickStyles = (QuickStyle.builtIn + customQuickStyles).map { q in
            guard let own = canvasStyle.quickStyles[q.id], !own.isEmpty else { return q }
            var q = q
            q.style = own
            return q
        }
        canvas = canvasStyle.background.flatMap(RGBA.init(hexString:)) ?? theme.canvas
        let nodeStyle = nodeStyle
        roleBase = Dictionary(
            uniqueKeysWithValues: NodeRoleStyle.allCases.map { role in
                let base = StyleResolver.themeLayer(theme, role: role).merged(over: StyleResolver.defaults(role))
                let styled = nodeStyle.layer(role).merged(over: base)
                return (role, canvasStyle.roles[role.rawValue].map { $0.merged(over: styled) } ?? styled)
            })
    }

    /// Branch colour for a main branch at `index` of `count` (or a topic at a sibling
    /// position in Multi mode).
    public func branchColor(mainIndex index: Int, count: Int, siblingIndex: Int? = nil) -> RGBA {
        if !canvasStyle.coloredBranch {
            return canvasStyle.singleColor.flatMap(RGBA.init(hexString:)) ?? theme.ink2
        }
        guard !palette.isEmpty else { return theme.ring }
        let shift = canvasStyle.paletteShift
        switch mode {
        case .rainbow:
            return palette[((index + shift) % palette.count + palette.count) % palette.count]
        case .multi:
            let i = (siblingIndex ?? index) + shift
            return palette[(i % palette.count + palette.count) % palette.count]
        case .mono:
            return palette[(shift % palette.count + palette.count) % palette.count]
        case .gradient:
            let a = palette[(shift % palette.count + palette.count) % palette.count]
            let b = palette[((shift + palette.count - 1) % palette.count + palette.count) % palette.count]
            return a.mix(b, count <= 1 ? 0 : Double(index) / Double(count - 1))
        }
    }
}

/// Resolves a node's style in the order README §5 requires:
/// node override → quick style → branch level → node style preset → theme → defaults.
public enum StyleResolver {
    public static func defaults(_ role: NodeRoleStyle) -> TopicStyle {
        var t = TopicStyle()
        t.shape = "rounded"
        t.fill = "solid"
        t.border = "none"
        t.borderWidth = 0
        t.shadow = "none"
        t.font = "system"
        t.fontWeight = role == .root ? "bold" : role == .sub ? "regular" : "medium"
        t.italic = false
        t.underline = false
        t.strikethrough = false
        t.code = false
        t.textCase = "none"
        t.align = "center"
        t.autoContrast = true
        return t
    }

    /// The theme's contribution for a role.
    public static func themeLayer(_ theme: Theme, role: NodeRoleStyle) -> TopicStyle {
        var t = TopicStyle()
        t.font = theme.font
        switch role {
        case .root:
            t.fillColor = theme.root.background.hex
            t.textColor = theme.root.foreground.hex
            t.cornerRadius = theme.rootRadius
            if theme.root.borderWidth > 0 {
                t.border = "solid"
                t.borderWidth = theme.root.borderWidth
                t.borderColor = theme.root.borderColor.hex
            }
        case .main, .floating:
            t.fillColor = theme.main.background.hex
            t.textColor = theme.main.foreground.hex
            t.cornerRadius = theme.nodeRadius
            t.border = theme.font == "hand" ? "hand" : "solid"
            t.borderWidth = theme.mainBorderWidth
            t.borderColor = "branch"
            t.fontWeight = theme.mainWeight
            t.shadow = theme.nodeShadowOpacity > 0 ? "soft" : "none"
        case .sub:
            t.fillColor = theme.sub.background.hex
            t.textColor = theme.sub.foreground.hex
            t.cornerRadius = min(theme.nodeRadius, 8)
            if theme.sub.borderWidth > 0 {
                t.border = theme.sub.dashed ? "dashed" : "solid"
                t.borderWidth = theme.sub.borderWidth
                t.borderColor = theme.sub.borderColor.hex
            }
            if theme.mainWeight == "bold" { t.fontWeight = "medium" }
        }
        return t
    }

    /// Merges every layer for one node.
    public static func merged(role: NodeRoleStyle, depth: Int, node: Node?, env: StyleEnvironment) -> TopicStyle {
        var s = env.roleBase[role]!
        if let level = env.canvasStyle.levels[depth] { s = level.merged(over: s) }
        if let q = node?.quickStyle, let qs = env.quickStyles.first(where: { $0.id == q }) {
            s = qs.style.merged(over: s)
        }
        if let o = node?.style { s = o.merged(over: s) }
        return s
    }

    public static func appearance(
        role: NodeRoleStyle, depth: Int, node: Node?, branch: RGBA,
        env: StyleEnvironment
    ) -> NodeAppearance {
        let s = merged(role: role, depth: depth, node: node, env: env)
        let theme = env.theme
        func color(_ token: String?, fallback: RGBA) -> RGBA {
            resolveColor(token, branch: branch, env: env) ?? fallback
        }
        let fillColor = color(s.fillColor, fallback: theme.main.background)
        let baseFill: NodeAppearance.Fill =
            switch s.fill ?? "solid" {
            case "none": .none
            case "tint": .solid(fillColor.alpha(min(fillColor.a, 0.16)))
            case "gradient": .gradient(fillColor, fillColor.mix(.white, 0.35))
            default: fillColor.a == 0 ? .none : .solid(fillColor)
            }
        let pattern = NodeAppearance.BorderPattern(rawValue: s.border ?? "none") ?? .solid
        let borderWidth = pattern == .none ? 0 : (s.borderWidth ?? 2)
        let shadow: NodeAppearance.Shadow? =
            switch s.shadow ?? "none" {
            case "soft":
                NodeAppearance.Shadow(
                    color: RGBA.black.alpha(max(theme.nodeShadowOpacity, 0.08)), dx: 0, dy: 1,
                    radius: 2)
            case "hard":
                NodeAppearance.Shadow(
                    color: color(s.shadowColor, fallback: branch), dx: role == .root ? 4 : 3,
                    dy: role == .root ? 4 : 3, radius: 0)
            case "glow":
                NodeAppearance.Shadow(
                    color: color(s.shadowColor, fallback: branch.alpha(0.45)), dx: 0, dy: 0,
                    radius: role == .root ? 13 : 8)
            default: nil
            }
        var fill = baseFill
        var behind = fill.representative?.composited(over: env.canvas) ?? env.canvas
        let wanted =
            s.textColor == "auto"
            ? bestOf([.white, RGBA(hex: "#121317")], on: behind)
            : color(s.textColor, fallback: theme.ink)
        var text = wanted
        if (s.autoContrast ?? true) && env.adaptText {
            let target = theme.contrastTarget
            text = Contrast.adjusted(wanted, on: behind, backdrop: env.canvas, target: target)
            // Mid-tone fills (rose, violet, mid-grey) can fail with both white and ink text.
            // Then deepen or lighten the fill just enough, keeping its hue.
            if Contrast.ratio(text, behind) < target - 0.005, case .solid(let c) = fill {
                let towardDark = Contrast.relativeLuminance(text) > 0.5
                var t = 0.04
                while t <= 0.6 {
                    let candidate = c.mix(towardDark ? .black : .white, t).alpha(c.a)
                    let b = candidate.composited(over: env.canvas)
                    if Contrast.ratio(text, b) >= target {
                        fill = .solid(candidate)
                        behind = b
                        break
                    }
                    t += 0.04
                }
            }
        }
        let base = NodeTypography.for(role)
        let size = s.fontSize ?? base.fontSize
        let k = size / base.fontSize
        let lineHeight = (s.lineSpacing.map { size * $0 } ?? base.lineHeight * k).rounded()
        return NodeAppearance(
            shape: s.shape ?? "rounded", cornerRadius: s.cornerRadius ?? base.cornerRadius, fill: fill,
            border: pattern, borderWidth: borderWidth, borderColor: color(s.borderColor, fallback: branch),
            shadow: shadow, text: text, textBackground: behind, font: s.font ?? "system", fontSize: size,
            fontWeight: weight(s.fontWeight), italic: s.italic ?? false, underline: s.underline ?? false,
            strikethrough: s.strikethrough ?? false, code: s.code ?? false, textCase: s.textCase ?? "none",
            align: s.align ?? "center", lineHeight: lineHeight, paddingX: (base.paddingX * k).rounded(),
            paddingY: (base.paddingY * k).rounded(), minWidth: base.minWidth,
            maxWidth: s.width ?? base.maxWidth, numbering: s.numbering)
    }

    /// The line from `parent` to one child. `chain` is the line styles of the parent and
    /// its ancestors that pass theirs down (nearest first).
    public static func line(
        childDepth: Int, family: String, branch: RGBA, parentLine: LineStyle?,
        inherited: [LineStyle], env: StyleEnvironment
    ) -> BranchLineAppearance {
        var l = LineStyle(shape: env.theme.lineShape, color: "branch")
        l = env.nodeStyle.line.merged(over: l)
        if let skeleton = env.canvasStyle.lineShape { l.shape = skeleton }
        for anc in inherited.reversed() { l = anc.merged(over: l) }
        if let parentLine { l = parentLine.merged(over: l) }
        let defaultWidth: Double =
            family == "org" || family == "tree" ? 2 : childDepth <= 1 ? 3 : childDepth == 2 ? 2 : 1.6
        var width = l.width ?? defaultWidth * env.theme.lineWidth
        if l.width != nil, childDepth > 1 { width = max(1, width * (childDepth == 2 ? 0.75 : 0.6)) }
        var taper = l.taper ?? false
        switch env.canvasStyle.lineWidth {
        case "thin": width *= 0.6
        case "bold": width *= 1.6
        case "taper": taper = true
        default: break
        }
        let lineColor: RGBA =
            !env.canvasStyle.coloredBranch && (l.color == nil || l.color == "branch")
            ? branch : resolveColor(l.color, branch: branch, env: env) ?? branch
        return BranchLineAppearance(
            shape: l.shape ?? "curved", color: lineColor, width: width, dash: l.dash ?? "solid",
            glow: l.glow ?? false, endCap: l.endCap ?? "none", taper: taper)
    }

    static func bestOf(_ options: [RGBA], on bg: RGBA) -> RGBA {
        options.max { Contrast.ratio($0, bg) < Contrast.ratio($1, bg) } ?? .black
    }

    public static func weight(_ s: String?) -> NodeTypography.Weight {
        switch s {
        case "regular": .regular
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        default: .medium
        }
    }

    /// Resolves a colour token: `branch`, `ink`, `ring`, `canvas`, `mainBg`, `rootBg`,
    /// `white`, hex, each optionally `@alpha`.
    public static func resolveColor(_ token: String?, branch: RGBA, env: StyleEnvironment) -> RGBA? {
        guard let token, !token.isEmpty else { return nil }
        var name = token
        var alpha: Double?
        if let at = token.firstIndex(of: "@") {
            name = String(token[..<at])
            alpha = Double(token[token.index(after: at)...])
        }
        let t = env.theme
        let base: RGBA? =
            switch name {
            case "branch": branch
            case "ink": t.ink
            case "ring": t.ring
            case "canvas": env.canvas
            case "mainBg": t.main.background
            case "rootBg": t.root.background
            case "white": .white
            case "ink2": t.ink2
            case "decision": t.decision
            case "entity": t.entity
            case "entityLine": t.entityLine
            case "process": t.process
            case "processLine": t.processLine
            case "store": t.store
            case "storeLine": t.storeLine
            case "critical": t.critical
            case "amber": t.amber
            case "amberSoft": t.amberSoft
            case "ai": t.ai
            case "aiSoft": t.aiSoft
            case "auto": nil
            default: RGBA(hexString: name)
            }
        guard let base else { return nil }
        return alpha.map { base.alpha(base.a * $0) } ?? base
    }
}
