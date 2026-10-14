import Foundation

/// Design tokens transcribed from `Handoff/docs/design-tokens.json` and artboards
/// 02 System and 04 Motion ("Luminous Graphite").
public enum Tokens {
    public enum Signal {
        public static let irisLight = RGBA(hex: "#5850EC")
        public static let irisDark = RGBA(hex: "#8F89FF")
        public static let amber = RGBA(hex: "#F2B135")
        public static let auroraLight = RGBA(hex: "#0F9F9A")
        public static let auroraDark = RGBA(hex: "#3FD3C9")
    }

    public struct Neutrals: Sendable {
        public var canvas, surface, line, ink3, ink2, ink: RGBA
    }

    public static let neutralsLight = Neutrals(
        canvas: RGBA(hex: "#F7F7F5"), surface: RGBA(hex: "#FFFFFF"), line: RGBA(hex: "#E2E2E6"),
        ink3: RGBA(hex: "#6B6B76"), ink2: RGBA(hex: "#4A4A55"), ink: RGBA(hex: "#17171C"))
    public static let neutralsDark = Neutrals(
        canvas: RGBA(hex: "#121317"), surface: RGBA(hex: "#1C1D22"), line: RGBA(hex: "#2B2C33"),
        ink3: RGBA(hex: "#8A8A96"), ink2: RGBA(hex: "#B4B4BE"), ink: RGBA(hex: "#F2F2F5"))

    /// Classic branch palette, assigned to main branches in order.
    public static let classicPalette: [RGBA] = [
        "#5850EC", "#E4572E", "#0F9F9A", "#E0A100", "#D6408B", "#1E8BE0", "#5AA02C", "#9B51E0",
    ].map(RGBA.init(hex:))

    public enum Radius {
        public static let node: Double = 10
        public static let root: Double = 16
        public static let panel: Double = 14
        public static let sheet: Double = 20
        public static let pill: Double = 999
    }

    /// Priority marker colours 1–9 (P0).
    public static let priorityColors: [RGBA] = [
        "#C62F35", "#C25E00", "#1E6FB8", "#2E7D4F", "#7A4CC2", "#4A4A55", "#4A4A55", "#4A4A55", "#4A4A55",
    ].map(RGBA.init(hex:))
}

/// Motion tokens (artboard 04). Durations in seconds.
public enum Motion {
    public struct Spring: Sendable, Equatable {
        public var response: Double
        public var dampingFraction: Double

        /// Mass-spring parameters for Core Animation (mass 1).
        public var stiffness: Double { pow(2 * .pi / response, 2) }
        public var damping: Double { 4 * .pi * dampingFraction / response }
    }

    public struct Curve: Sendable, Equatable {
        public var c1x, c1y, c2x, c2y: Double
    }

    public static let snap = Spring(response: 0.28, dampingFraction: 0.80)
    public static let settle = Spring(response: 0.36, dampingFraction: 0.68)
    /// Structure changes and Convert: nodes glide over about 600 ms.
    public static let morph = Spring(response: 0.52, dampingFraction: 0.92)
    public static let glide = Curve(c1x: 0.65, c1y: 0, c2x: 0.35, c2y: 1)
    public static let exit = Curve(c1x: 0.4, c1y: 0, c2x: 1, c2y: 1)

    public static let createNode = 0.180
    public static let deleteNode = 0.160
    public static let reorder = 0.250
    public static let fold = 0.220
    public static let reflow = 0.300
    public static let structureChange = 0.500
    public static let convert = 0.600
    public static let connectDraw = 0.300
    public static let connectHintStagger = 0.040
    public static let focus = 0.400
    public static let presentStep = 0.500
    public static let aiGhostEach = 0.250
    public static let nodeStyleCycle = 0.300
    public static let errorShake = 0.200
    /// Reduce Motion replaces every movement with this cross-fade.
    public static let reducedCrossFade = 0.150
}
