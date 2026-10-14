import Foundation
import NexusCore

/// The theme builder's live contrast check: node text against its background for every
/// role, node style and branch colour a theme can produce.
public enum ContrastChecker {
    public struct Report: Sendable, Equatable {
        public var minimum: Double
        public var worst: String
        public var target: Double
        public var detail: String = ""
        public var passes: Bool { minimum >= target - 0.005 }
        /// "AA · 7.4 : 1", "AAA · 9.1 : 1", or "Fails AA · 3.2 : 1".
        public var badge: String {
            let ratio = String(format: "%.1f : 1", minimum)
            if minimum >= 7 { return "AAA · \(ratio)" }
            if minimum >= 4.5 { return "AA · \(ratio)" }
            return "Fails AA · \(ratio)"
        }
    }

    public static func check(
        _ theme: Theme, styles: [NodeStyle] = NodeStyle.allCases,
        palette: [RGBA]? = nil
    ) -> Report {
        var minimum = Double.infinity
        var worst = ""
        var detail = ""
        let colors = palette ?? theme.palette
        for style in styles {
            var cs = CanvasStyle(theme: theme.id, nodeStyle: style.rawValue)
            cs.palette = "theme"
            var t = theme
            t.palette = colors.isEmpty ? theme.palette : colors
            let env = StyleEnvironment(theme: t, canvasStyle: cs)
            for role in NodeRoleStyle.allCases {
                for (i, branch) in (role == .root ? [t.ring] : Array(Set(t.palette))).enumerated() {
                    let a = StyleResolver.appearance(
                        role: role, depth: role == .root ? 0 : role == .sub ? 2 : 1,
                        node: nil, branch: branch, env: env)
                    let r = Contrast.ratio(a.text, a.textBackground, backdrop: env.canvas)
                    if r < minimum {
                        minimum = r
                        worst = "\(style.name) \(role.rawValue) #\(i)"
                        detail = "text \(a.text.hex) on \(a.textBackground.hex) branch \(branch.hex)"
                    }
                }
            }
        }
        var report = Report(minimum: minimum, worst: worst, target: theme.contrastTarget)
        report.detail = detail
        return report
    }

    /// Colour-theme editor: how many colours carry auto-contrast text at AA (Solid style).
    public static func paletteCount(_ colors: [RGBA], on theme: Theme) -> (passing: Int, total: Int) {
        let passing = colors.filter { c in
            let text = [RGBA.white, RGBA(hex: "#121317")].max { Contrast.ratio($0, c) < Contrast.ratio($1, c) }!
            return Contrast.ratio(text, c.composited(over: theme.canvas)) >= 4.5
        }.count
        return (passing, colors.count)
    }
}
