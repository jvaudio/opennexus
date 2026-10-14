import AppKit
import NexusFormat
import SwiftUI

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
    var thumbnails: [String: NSImage]
    var large: Bool

    public init(snapshot: WidgetSnapshot?, thumbnails: [String: NSImage], large: Bool) {
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
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10
                ) {
                    ForEach(maps, id: \.token) { m in
                        Link(destination: URL(string: "opennexus://open/\(m.token)")!) { tile(m) }
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
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(6)
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
