import NexusFormat
import NexusWidgetsUI
import SwiftUI
import UIKit
import WidgetKit

/// Home Screen widgets on the iPad and iPhone (M47b, M47c; artboard 33): the Inbox map's
/// newest items with a capture button, recent maps with their Quick Look previews, and a
/// Lock Screen widget that opens Quick Capture. OpenNexus writes what they show to the App
/// Group; links carry a token, never a path.
@main
struct OpenNexusWidgets: WidgetBundle {
    var body: some Widget {
        InboxWidget()
        RecentMapsWidget()
        CaptureWidget()
    }
}

/// Quick Capture's link (`TouchScene.handle`).
let captureURL = URL(string: "opennexus://inbox/add")!

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
    var thumbnails: [String: UIImage]
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
        var thumbs: [String: UIImage] = [:]
        for m in snap.recents {
            if let t = m.thumbnail, let img = RecentMapsWidgetView.thumbnail(contentsOf: dir.appending(path: t)) {
                thumbs[m.token] = img
            }
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
        // A small widget is one link (the Inbox); the medium one has room for a button.
        InboxWidgetView(
            snapshot: entry.snapshot, compact: family == .systemSmall,
            capture: family == .systemMedium ? captureURL : nil
        )
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

/// The Lock Screen's capture widget (M47c): a tap opens Quick Capture.
struct CaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.opennexus.capture", provider: SnapshotProvider()) { e in CaptureView(entry: e) }
            .configurationDisplayName("Quick Capture")
            .description("Jot an idea into your Inbox map.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct CaptureView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                }
                .accessibilityLabel("Quick Capture")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Label("Quick Capture", systemImage: "plus.circle").font(.headline).widgetAccentable()
                    Text(inboxLine).font(.caption).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                Label("Jot an idea", systemImage: "plus")
            }
        }
        .containerBackground(.clear, for: .widget)
        .widgetURL(captureURL)
    }

    var inboxLine: String {
        guard let s = entry.snapshot else { return "Inbox map" }
        return s.inboxCount == 1 ? "Inbox map · 1 idea" : "Inbox map · \(s.inboxCount) ideas"
    }
}
