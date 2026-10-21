import Foundation
import FoundationModels

// MARK: Image to mind map (M12)

@Generable(description: "Which lines of a list are headings for the lines that follow them")
struct HeadingPick {
    @Guide(
        description:
            "Numbers of the lines that name a group or category, such as 'Groceries' before 'Milk' and 'Eggs'. Leave out the title and ordinary items."
    )
    var headings: [Int]
}

/// Groups flat text read from an image with Apple's on-device model (D152). The model only
/// picks which recognised lines head the lines after them, by number; it never writes
/// text or nests anything itself, so it can't add words or scramble a structure the
/// layout already showed.
public enum ImageStructurer {
    /// More lines than this don't fit the model's context with room for the answer.
    public static let maxLines = 80

    public static var isAvailable: Bool { SystemLanguageModel.default.availability == .available }

    static let instructions = """
        You read lists of short lines taken from a picture: notes, a slide, a whiteboard. Some \
        lines are headings: each names a group, and the lines after it, up to the next heading, \
        are members of that group. Many lists have no headings at all; then answer with an \
        empty list. Answer with the numbers of the heading lines only.

        Example: 0. Fruit 1. Apples 2. Pears 3. Vegetables 4. Leeks → headings 0, 3
        Example: 0. Pros 1. Cheap 2. Fast 3. Cons 4. Noisy → headings 0, 3
        Example: 0. Call mum 1. Water plants 2. Pay rent → no headings
        Example: 0. Goals 1. Ship v1 2. Hire 3. Risks 4. Budget 5. Timing → headings 0, 3
        """

    static func prompt(title: String, lines: [String]) -> String {
        var s = "Title: \(title)\nLines:\n"
        for (i, l) in lines.enumerated() { s += "\(i). \(l)\n" }
        s += "\nWhich lines are headings?"
        return s
    }

    /// Indices of `lines` that head the lines after them.
    public static func headings(title: String, lines: [String]) async throws -> [Int] {
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let out = try await session.respond(to: prompt(title: title, lines: lines), generating: HeadingPick.self)
            .content
        return out.headings.filter { lines.indices.contains($0) }
    }
}
