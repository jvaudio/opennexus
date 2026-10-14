import Foundation
import NexusCore

/// The nine node styles (artboard NS, P0 `styleLook`). Each is data: a style layer per
/// role plus branch-line character. Colours are tokens, resolved against the theme and
/// the branch: `branch`, `branch@0.14`, `ink`, `ring@0.2`, `canvas`, `mainBg`, `auto`, hex.
public enum NodeStyle: String, Sendable, CaseIterable, Identifiable, Codable {
    case outline, soft, solid, underline, capsule, sketch, brutal, glow, minimal

    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }

    public var bestFor: String {
        switch self {
        case .outline: "Default · everyday maps"
        case .soft: "Brainstorms · notes"
        case .solid: "Slides · posters"
        case .underline: "Classic mind maps · outlines"
        case .capsule: "Timelines · tags"
        case .sketch: "Workshops · whiteboards"
        case .brutal: "Architecture · engineering"
        case .glow: "Dark themes · presenting"
        case .minimal: "Reading · long text"
        }
    }

    public var summary: String {
        switch self {
        case .outline: "White card, 2 pt border in the branch colour. Crisp at any zoom and prints well."
        case .soft: "Tinted fills, no borders, generous radius. Calm and friendly; colour carries the grouping."
        case .solid: "Saturated filled cards with white type (ink on light hues). Maximum punch for Present mode."
        case .underline: "Text sits on its branch line, Xmind’s classic subtopic look. Lightest ink, densest maps."
        case .capsule: "Full pill radius with a tinted fill and hairline ring. Reads as chips; great for short labels."
        case .sketch: "Hand-drawn wobble borders and a marker font. Signals “draft”, invites edits."
        case .brutal:
            "Thick ink borders, hard offset shadows in the branch colour, elbow lines. Confident and technical."
        case .glow: "Hairline neon borders with a soft outer glow on dark canvases. Lines glow too."
        case .minimal: "No boxes at all: weight and colour alone, dotted hairline branches. The ideas, nothing else."
        }
    }

    public static func named(_ id: String) -> NodeStyle { NodeStyle(rawValue: id) ?? .outline }

    public var next: NodeStyle {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    private static func s(_ build: (inout TopicStyle) -> Void) -> TopicStyle {
        var t = TopicStyle()
        build(&t)
        return t
    }

    /// The style layer this preset contributes for a role.
    public func layer(_ role: NodeRoleStyle) -> TopicStyle {
        let root = role == .root
        let sub = role == .sub
        switch self {
        case .outline:
            return TopicStyle()
        case .soft:
            if root {
                return Self.s {
                    $0.fill = "solid"; $0.fillColor = "ring@0.2"; $0.border = "none"; $0.textColor = "ring"
                    $0.cornerRadius = 16; $0.shadow = "none"
                }
            }
            return Self.s {
                $0.fill = "solid"; $0.fillColor = sub ? "branch@0.08" : "branch@0.16"; $0.border = "none"
                $0.textColor = "ink"; $0.cornerRadius = sub ? 10 : 12; $0.shadow = "none"
                if !sub { $0.fontWeight = "semibold" }
            }
        case .solid:
            if root { return TopicStyle() }
            if sub {
                return Self.s {
                    $0.fill = "solid"; $0.fillColor = "branch@0.14"; $0.border = "none"; $0.textColor = "ink"
                    $0.cornerRadius = 7
                }
            }
            return Self.s {
                $0.fill = "solid"; $0.fillColor = "branch"; $0.border = "none"; $0.textColor = "auto"
                $0.cornerRadius = 9; $0.fontWeight = "semibold"; $0.shadow = "none"
            }
        case .underline:
            if root {
                return Self.s {
                    $0.shape = "pill"; $0.fill = "solid"; $0.fillColor = "canvas"; $0.border = "solid"
                    $0.borderWidth = 2; $0.borderColor = "ink"; $0.textColor = "ink"
                }
            }
            return Self.s {
                $0.shape = "underline"; $0.fill = "none"; $0.border = "solid"; $0.borderWidth = sub ? 1.5 : 3
                $0.borderColor = "branch"; $0.textColor = "ink"; $0.shadow = "none"
                if !sub { $0.fontWeight = "semibold" }
            }
        case .capsule:
            if root { return Self.s { $0.shape = "pill" } }
            return Self.s {
                $0.shape = "pill"; $0.fill = "solid"; $0.fillColor = sub ? "mainBg" : "branch@0.1"
                $0.border = "solid"; $0.borderWidth = sub ? 1 : 1.5; $0.borderColor = sub ? "branch@0.5" : "branch@0.6"
                $0.textColor = "ink"; $0.shadow = "none"
            }
        case .sketch:
            if root {
                return Self.s {
                    $0.fill = "solid"; $0.fillColor = "#FFF4C2"; $0.textColor = "#17171C"; $0.border = "hand"
                    $0.borderWidth = 2.5; $0.borderColor = "#17171C"; $0.font = "hand"; $0.fontWeight = "bold"
                    $0.cornerRadius = 14
                }
            }
            if sub {
                return Self.s {
                    $0.fill = "none"; $0.border = "none"; $0.font = "hand"; $0.fontSize = 15; $0.textColor = "ink"
                }
            }
            return Self.s {
                $0.fill = "solid"; $0.fillColor = "mainBg"; $0.border = "hand"; $0.borderWidth = 2
                $0.borderColor = "branch"; $0.font = "hand"; $0.fontWeight = "bold"; $0.fontSize = 16
                $0.textColor = "ink"; $0.shadow = "none"
            }
        case .brutal:
            if root {
                return Self.s {
                    $0.fill = "solid"; $0.fillColor = "#FFE14D"; $0.textColor = "#17171C"; $0.border = "solid"
                    $0.borderWidth = 2.5; $0.borderColor = "#17171C"; $0.cornerRadius = 6; $0.shadow = "hard"
                    $0.shadowColor = "#17171C"; $0.fontWeight = "heavy"
                }
            }
            if sub {
                return Self.s {
                    $0.fill = "solid"; $0.fillColor = "#FFFFFF"; $0.textColor = "#17171C"; $0.border = "solid"
                    $0.borderWidth = 1.5; $0.borderColor = "#17171C"; $0.cornerRadius = 4; $0.shadow = "none"
                }
            }
            return Self.s {
                $0.fill = "solid"; $0.fillColor = "#FFFFFF"; $0.textColor = "#17171C"; $0.border = "solid"
                $0.borderWidth = 2; $0.borderColor = "#17171C"; $0.cornerRadius = 5; $0.shadow = "hard"
                $0.shadowColor = "branch"; $0.fontWeight = "bold"
            }
        case .glow:
            if root {
                return Self.s {
                    $0.shadow = "glow"; $0.shadowColor = "ring@0.45"; $0.cornerRadius = 14
                }
            }
            if sub {
                return Self.s {
                    $0.fill = "none"; $0.border = "none"; $0.textColor = "ink"; $0.shadow = "none"
                }
            }
            return Self.s {
                $0.fill = "solid"; $0.fillColor = "mainBg"; $0.border = "solid"; $0.borderWidth = 1.5
                $0.borderColor = "branch"; $0.cornerRadius = 10; $0.shadow = "glow"; $0.shadowColor = "branch@0.45"
                $0.textColor = "ink"
            }
        case .minimal:
            if root {
                return Self.s {
                    $0.fill = "none"; $0.border = "none"; $0.textColor = "ink"; $0.fontWeight = "heavy"
                    $0.shadow = "none"
                }
            }
            return Self.s {
                $0.fill = "none"; $0.border = "none"; $0.shadow = "none"; $0.textColor = sub ? "ink" : "branch"
                if !sub { $0.fontWeight = "bold" }
            }
        }
    }

    /// Branch-line character: elbow and ink for Brutal, dotted hairlines for Minimal,
    /// glowing lines for Glow.
    public var line: LineStyle {
        switch self {
        case .brutal: LineStyle(shape: "elbow", color: "#17171C", width: 2.2)
        case .minimal: LineStyle(width: 1.4, dash: "dotted")
        case .glow: LineStyle(glow: true)
        default: LineStyle()
        }
    }
}

/// Quick styles (FMT-1): Xmind's four plus four for technical work. ⌃⌥1–8 apply them.
public struct QuickStyle: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var glyph: String
    public var style: TopicStyle

    public init(id: String, name: String, glyph: String, style: TopicStyle) {
        self.id = id
        self.name = name
        self.glyph = glyph
        self.style = style
    }

    private static func q(_ id: String, _ name: String, _ glyph: String, _ build: (inout TopicStyle) -> Void)
        -> QuickStyle
    {
        var t = TopicStyle()
        build(&t)
        return QuickStyle(id: id, name: name, glyph: glyph, style: t)
    }

    public static let builtIn: [QuickStyle] = [
        q("very-important", "Very important", "!!") {
            $0.fill = "solid"; $0.fillColor = "#C62F35"; $0.textColor = "#FFFFFF"; $0.fontWeight = "bold"
            $0.border = "none"
        },
        q("important", "Important", "!") {
            $0.fill = "solid"; $0.fillColor = "#FBE7B5"; $0.textColor = "#7A5200"; $0.fontWeight = "bold"
            $0.border = "none"
        },
        q("cross-out", "Cross out", "abc") {
            $0.fill = "solid"; $0.fillColor = "#EEEEF1"; $0.textColor = "#6B6B76"; $0.strikethrough = true
            $0.border = "none"
        },
        q("default", "Default", "Aa") { _ in },
        q("decision", "Decision", "◇") {
            $0.shape = "diamond"; $0.fill = "solid"; $0.fillColor = "#FBE7B5"; $0.textColor = "#17171C"
            $0.border = "none"
        },
        q("done", "Done", "✓") {
            $0.fill = "solid"; $0.fillColor = "#2E7D4F"; $0.textColor = "#FFFFFF"; $0.border = "none"
        },
        q("risk", "Risk", "⚠") {
            $0.fill = "solid"; $0.fillColor = "#FFFFFF"; $0.border = "dashed"; $0.borderWidth = 1.5
            $0.borderColor = "#C62F35"; $0.textColor = "#C62F35"
        },
        q("question", "Question", "?") {
            $0.fill = "solid"; $0.fillColor = "#E3F0FC"; $0.textColor = "#1E6FB8"; $0.fontWeight = "bold"
            $0.border = "none"
        },
    ]

    public static func named(_ id: String, custom: [QuickStyle] = []) -> QuickStyle? {
        builtIn.first { $0.id == id } ?? custom.first { $0.id == id }
    }
}
