import AppKit
import NexusFormat
import NexusWidgetsUI
import SwiftUI
import WidgetKit

/// Desktop widgets (artboard 33): the Inbox map's newest items, and recent maps with
/// their Quick Look previews. OpenNexus writes what they show to the App Group; links
/// carry a token, never a path.
@main
struct OpenNexusWidgets: WidgetBundle {
    var body: some Widget {
        InboxWidget()
        RecentMapsWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
    var thumbnails: [String: NSImage]
}

struct SnapshotProvider: TimelineProvider {
    static let sample = WidgetSnapshot(
        inbox: ["A/B pricing page", "Webhook retries", "Annual plan copy"], inboxCount: 7,
        recents: [
            .init(token: "", title: "Checkout DFD", detail: "Data Flow · 18 topics", thumbnail: nil),
            .init(token: "", title: "Q1 roadmap", detail: "Timeline · 48 topics", thumbnail: nil),
        ])

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: Self.sample, thumbnails: [:])
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Self.entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app reloads timelines when the inbox or recents change; this is a fallback.
        completion(Timeline(entries: [Self.entry()], policy: .after(Date().addingTimeInterval(3600))))
    }

    static func entry() -> SnapshotEntry {
        guard let group = AppGroup.container, let snap = WidgetSnapshot.read(from: group) else {
            return SnapshotEntry(date: Date(), snapshot: nil, thumbnails: [:])
        }
        let dir = WidgetSnapshot.directory(in: group)
        var thumbs: [String: NSImage] = [:]
        for m in snap.recents {
            if let t = m.thumbnail, let img = NSImage(contentsOf: dir.appending(path: t)) { thumbs[m.token] = img }
        }
        return SnapshotEntry(date: snap.updated, snapshot: snap, thumbnails: thumbs)
    }
}

struct InboxWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.opennexus.inbox", provider: SnapshotProvider()) { e in InboxView(entry: e) }
            .configurationDisplayName("Inbox")
            .description("The newest ideas in your Inbox map.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct InboxView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        InboxWidgetView(snapshot: entry.snapshot, compact: family == .systemSmall)
            .containerBackground(InboxWidgetView.background, for: .widget)
            .widgetURL(URL(string: "opennexus://inbox"))
    }
}

struct RecentMapsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.opennexus.recents", provider: SnapshotProvider()) { e in RecentMapsView(entry: e)
        }
        .configurationDisplayName("Recent Maps")
        .description("Jump back into the maps you opened last.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct RecentMapsView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        RecentMapsWidgetView(snapshot: entry.snapshot, thumbnails: entry.thumbnails, large: family == .systemLarge)
            .containerBackground(RecentMapsWidgetView.background, for: .widget)
    }
}
