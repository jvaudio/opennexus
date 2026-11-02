import Foundation

/// The third-party software in OpenNexus and its licences, for Settings › About ›
/// Acknowledgements (M48): MathJax's NOTICE and its Apache licence.
public enum Acknowledgements {
    public static var text: String {
        func read(_ name: String) -> String {
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "MathJax")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return read("NOTICE") + "\n\n" + read("LICENSE") + "\n"
    }
}
