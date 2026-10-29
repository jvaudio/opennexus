import Foundation
import NexusCore

/// Marker groups (EN): picking from the same group replaces; another group adds.
public enum MarkerLibrary {
    public struct Marker: Sendable, Identifiable, Equatable {
        public var id: String
        /// The white glyph on the marker's disc; for a pie marker, the text it's named by
        /// where only text fits (◔, ⅛).
        public var glyph: String
        public var color: String
        /// A progress marker drawn as a pie this full (D247). No glyph shows eighths, and
        /// the font draws ◔ and ◕ smaller than ◑, so every part-done marker is a pie.
        public var pie: Double? = nil
    }

    public struct Group: Sendable, Identifiable {
        public var id: String
        public var name: String
        public var markers: [Marker]
    }

    public static let groups: [Group] = [
        Group(
            id: "priority", name: Loc.t("Priority"),
            markers: (1...9).map {
                Marker(
                    id: "priority-\($0)", glyph: "\($0)",
                    color: [
                        "#C62F35", "#C25E00", "#1E6FB8", "#2E7D4F", "#7A4CC2", "#4A4A55", "#4A4A55", "#4A4A55",
                        "#4A4A55",
                    ][$0 - 1])
            }),
        Group(
            id: "progress", name: Loc.t("Progress"),
            markers: [
                Marker(id: "progress-0", glyph: "○", color: "#4A4A55"),
                Marker(id: "progress-13", glyph: "⅛", color: "#1E6FB8", pie: 0.125),
                Marker(id: "progress-25", glyph: "◔", color: "#1E6FB8", pie: 0.25),
                Marker(id: "progress-38", glyph: "⅜", color: "#1E6FB8", pie: 0.375),
                Marker(id: "progress-50", glyph: "◑", color: "#1E6FB8", pie: 0.5),
                Marker(id: "progress-63", glyph: "⅝", color: "#1E6FB8", pie: 0.625),
                Marker(id: "progress-75", glyph: "◕", color: "#1E6FB8", pie: 0.75),
                Marker(id: "progress-88", glyph: "⅞", color: "#1E6FB8", pie: 0.875),
                Marker(id: "progress-100", glyph: "✓", color: "#2E7D4F"),
            ]),
        Group(
            id: "flag", name: Loc.t("Flags"),
            markers: [
                Marker(id: "flag-red", glyph: "⚑", color: "#C62F35"),
                Marker(id: "flag-orange", glyph: "⚑", color: "#C25E00"),
                Marker(id: "flag-green", glyph: "⚑", color: "#2E7D4F"),
                Marker(id: "flag-blue", glyph: "⚑", color: "#1E6FB8"),
            ]),
        Group(
            id: "star", name: Loc.t("Stars"),
            markers: [
                Marker(id: "star-gold", glyph: "★", color: "#C08A00"),
                Marker(id: "star-red", glyph: "★", color: "#C62F35"),
                Marker(id: "star-blue", glyph: "★", color: "#1E6FB8"),
            ]),
        Group(
            id: "symbol", name: Loc.t("Symbols"),
            markers: [
                Marker(id: "symbol-question", glyph: "?", color: "#1E6FB8"),
                Marker(id: "symbol-exclaim", glyph: "!", color: "#C25E00"),
                Marker(id: "symbol-check", glyph: "✓", color: "#2E7D4F"),
                Marker(id: "symbol-cross", glyph: "✕", color: "#C62F35"),
                Marker(id: "symbol-arrow", glyph: "→", color: "#4A4A55"),
            ]),
        Group(
            id: "people", name: Loc.t("People"),
            markers: [
                Marker(id: "people-me", glyph: "◉", color: "#5850EC"),
                Marker(id: "people-team", glyph: "◎", color: "#0F9F9A"),
                Marker(id: "people-external", glyph: "◍", color: "#C25E00"),
            ]),
    ]

    public static func marker(_ id: String) -> Marker? {
        groups.lazy.flatMap(\.markers).first { $0.id == id }
    }

    public static func group(of id: String) -> String { String(id.split(separator: "-").first ?? "") }
}
