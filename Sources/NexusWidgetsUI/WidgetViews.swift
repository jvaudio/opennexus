import ImageIO
import NexusFormat
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
/// A map's Quick Look preview, as the widget shows it.
public typealias WidgetImage = NSImage
#else
public typealias WidgetImage = UIImage
#endif

/// The widgets' content (artboard 33), shared by the Widgets extension and the snapshot
/// tests. The extension adds the WidgetKit container background and links.
public struct InboxWidgetView: View {
    public static let background = Color(red: 0.13, green: 0.14, blue: 0.2)
    var snapshot: WidgetSnapshot?
    var compact: Bool

    public init(snapshot: WidgetSnapshot?, compact: Bool) {
        self.snapshot = snapshot
        self.compact = compact
    }

    public var body: some View {
        let items = snapshot?.inbox ?? []
        let shown = compact ? 3 : 5
        VStack(alignment: .leading, spacing: 9) {
            Text("INBOX").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            if snapshot == nil {
                Text("Open OpenNexus to fill this in").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
            } else if items.isEmpty {
                Text("Nothing captured yet. ✦N jots an idea from any app.").font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            ForEach(Array(items.prefix(shown).enumerated()), id: \.offset) { _, t in
                Text(t).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            }
            let more = (snapshot?.inboxCount ?? 0) - min(items.count, shown)
            if more > 0 { Text("+\(more) more").font(.system(size: 13)).foregroundStyle(.white.opacity(0.55)) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

public struct RecentMapsWidgetView: View {
    public static let background = Color(white: 0.84)
    var snapshot: WidgetSnapshot?
    var thumbnails: [String: WidgetImage]
    var large: Bool

    public init(snapshot: WidgetSnapshot?, thumbnails: [String: WidgetImage], large: Bool) {
        self.snapshot = snapshot
        self.thumbnails = thumbnails
        self.large = large
    }

    public var body: some View {
        let maps = Array((snapshot?.recents ?? []).prefix(large ? 4 : 2))
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT MAPS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.black.opacity(0.5))
            if maps.isEmpty {
                Text(snapshot == nil ? "Open OpenNexus to fill this in" : "Maps you open appear here")
                    .font(.system(size: 13)).foregroundStyle(.black.opacity(0.55))
                Spacer(minLength: 0)
            } else {
                // Rows share the height that's left, so a tall preview fits its tile rather
                // than pushing the header and titles out of the widget.
                VStack(spacing: 10) {
                    ForEach(0..<(large ? 2 : 1), id: \.self) { row in
                        HStack(spacing: 10) {
                            ForEach(row * 2..<row * 2 + 2, id: \.self) { i in
                                if i < maps.count {
                                    Link(destination: URL(string: "opennexus://open/\(maps[i].token)")!) {
                                        tile(maps[i])
                                    }
                                } else {
                                    Color.clear
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func tile(_ m: WidgetSnapshot.Map) -> some View {
        VStack(spacing: 0) {
            Group {
                if let img = thumbnails[m.token] {
                    Self.image(img).resizable().aspectRatio(contentMode: .fit).padding(6)
                } else {
                    Color.white
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
            Text(m.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.black).lineLimit(1)
                .padding(.horizontal, 8).padding(.bottom, 7).padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(m.title), \(m.detail)")
    }
}

extension RecentMapsWidgetView {
    /// A map's `preview.png`, at most `maxPixels` on its longer side. WidgetKit won't
    /// archive a timeline with the full-size preview in it, and the widget stays a
    /// placeholder; a tile is about 170 points wide.
    public nonisolated static func thumbnail(contentsOf url: URL, maxPixels: Int = 400) -> WidgetImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }

    static func image(_ img: WidgetImage) -> Image {
        #if os(macOS)
        Image(nsImage: img)
        #else
        Image(uiImage: img)
        #endif
    }
}
