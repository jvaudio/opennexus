import CoreGraphics
import CoreText
import Foundation

/// The colours that follow the system's appearance (light, dark, more contrast) and so
/// can only be resolved by the platform, at draw time.
public enum SystemColor: String, Sendable, CaseIterable {
    case label, secondaryLabel, accent, teal, red, gray, white, clear
}

/// How text is laid out when measured or drawn in a rect (TextKit's string drawing options).
public struct TextOptions: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Wrap to the rect's width and stack lines from its top.
    public static let lineFragmentOrigin = TextOptions(rawValue: 1 << 0)
    /// Use the font's leading in line heights.
    public static let fontLeading = TextOptions(rawValue: 1 << 1)
    /// End the last line that fits with an ellipsis.
    public static let truncatesLastLine = TextOptions(rawValue: 1 << 2)
}

/// What only the platform can do for a scene: measure and draw text with its own engine,
/// resolve system colours, and decode images. The Mac installs its TextKit engine (and
/// the iPad UIKit's), so a map measures and draws exactly as the system's text does;
/// `CoreTextGraphics` is the engine everywhere else.
///
/// Text is a `StyledText` (an attributed string with `TextKey` attributes). Every call
/// mirrors one of `NSAttributedString`'s string-drawing calls, so code moved off AppKit
/// keeps its geometry. `flipped` says the context's y axis points down.
public protocol PlatformGraphics: Sendable {
    /// `boundingRect(with:options:)`.
    func boundingRect(_ text: NSAttributedString, size: CGSize, options: TextOptions) -> CGRect
    /// `size()`: one line, unwrapped.
    func size(_ text: NSAttributedString) -> CGSize
    /// `draw(with:options:)`.
    func draw(_ text: NSAttributedString, with rect: CGRect, options: TextOptions, in ctx: CGContext, flipped: Bool)
    /// `draw(in:)`.
    func draw(_ text: NSAttributedString, in rect: CGRect, context ctx: CGContext, flipped: Bool)
    /// `draw(at:)`.
    func draw(_ text: NSAttributedString, at point: CGPoint, in ctx: CGContext, flipped: Bool)
    /// The member of a font family nearest a weight on `NSFontManager`'s 0–15 scale.
    func font(family: String, weight: Int, size: CGFloat) -> CTFont?
    /// The font with a symbolic trait (bold, italic) added, or the font itself if its
    /// family has no such face.
    func font(_ f: CTFont, adding trait: CTFontSymbolicTraits) -> CTFont
    /// The text in the attributes this engine hands CoreText (AppKit's on the Mac), for
    /// code that lays text out with CoreText itself, such as the SVG writer. Runs keep
    /// the source's ranges, so their styles can be read back from the source.
    func coreTextString(_ text: NSAttributedString) -> NSAttributedString
    /// A system colour in the appearance current where it's drawn.
    func color(_ c: SystemColor) -> CGColor
    /// Decodes an image asset (PNG, JPEG, HEIC, GIF, PDF where the platform can).
    func image(_ data: Data) -> CGImage?
    /// Draws a small picture (an icon) into `rect` the way the platform draws an image
    /// made by a drawing closure: the Mac caches it as an `NSImage` at the destination's
    /// resolution. `draw` gets a context with y up and the picture's own rect.
    func drawPicture(
        size: CGSize, in rect: CGRect, context ctx: CGContext, flipped: Bool,
        _ draw: @escaping (CGContext, CGRect) -> Void)
}

/// A platform's engine, found by its Objective-C name `OpenNexusPlatformGraphics`, so
/// every process that links a platform's canvas (the app, its extensions, the CLI, the
/// tests) measures and draws with that engine without having to install it first.
public protocol PlatformGraphicsProvider: AnyObject {
    static var platformGraphics: any PlatformGraphics { get }
}

public enum Graphics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed: (any PlatformGraphics)?
    nonisolated(unsafe) private static var searched = false

    /// The platform's engine: the one installed, else the one found by name, else CoreText.
    public static var platform: any PlatformGraphics {
        lock.withLock {
            if let installed { return installed }
            if !searched {
                searched = true
                if let p = NSClassFromString("OpenNexusPlatformGraphics") as? any PlatformGraphicsProvider.Type {
                    installed = p.platformGraphics
                }
            }
            return installed ?? CoreTextGraphics.shared
        }
    }

    /// Installs an engine for every scene in this process (later calls replace it).
    public static func install(_ g: any PlatformGraphics) {
        lock.withLock { installed = g }
    }

    /// Whether a platform engine is installed or was found.
    public static var hasPlatform: Bool {
        _ = platform
        return lock.withLock { installed != nil }
    }
}
