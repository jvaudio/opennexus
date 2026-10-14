import Foundation
import FoundationModels

@Generable(description: "The key points of a web page, as mind-map topics")
struct PagePoints {
    @Guide(description: "Three to six key points. Each is a short statement of three to ten words.", .count(3...6))
    var points: [String]
}

/// The Safari clipper's summary (Settings › Integrations › Safari web clipper): a page's
/// key points as topics, made on this Mac. Without Apple Intelligence, the selection or
/// the first paragraphs stand in.
public enum PageSummary {
    /// The longest page text sent to the model (its context is small; the start of an
    /// article carries most of its points).
    static let maxCharacters = 6_000

    public static func keyPoints(title: String, text: String, selection: String? = nil) async -> [String] {
        let source = (selection?.isEmpty == false ? selection! : text)
        let model = SystemLanguageModel.default
        guard case .available = model.availability, source.count > 80 else { return fallback(source) }
        let session = LanguageModelSession(
            model: model,
            instructions:
                "You turn web pages into mind-map topics. Use the page's language. No numbering, no trailing punctuation."
        )
        do {
            let r = try await session.respond(
                to: "Title: \(title)\n\n\(source.prefix(maxCharacters))", generating: PagePoints.self)
            let points = r.content.points.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
                !$0.isEmpty
            }
            return points.isEmpty ? fallback(source) : points
        } catch {
            return fallback(source)
        }
    }

    /// The first few paragraphs (or sentences), shortened.
    public static func fallback(_ text: String, limit: Int = 3) -> [String] {
        let paragraphs = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 20 }
        let pieces: [String]
        if paragraphs.count >= limit {
            pieces = paragraphs
        } else {
            var sentences: [String] = []
            text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
                if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), s.count >= 12 { sentences.append(s) }
            }
            pieces = sentences.isEmpty ? paragraphs : sentences
        }
        return pieces.prefix(limit).map { $0.count > 140 ? String($0.prefix(137)) + "…" : $0 }
    }
}
