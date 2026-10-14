import AppKit
import NexusCore
import NexusFormat
import SwiftUI
import UniformTypeIdentifiers

/// The Share extension and Safari clipper (artboard 33, Settings › Integrations): text,
/// links, images and Safari pages go to the Inbox or a recent map. The capture is queued
/// in the App Group and OpenNexus picks it up; this extension never edits a file itself.
final class ShareViewController: NSViewController {
    let model = ShareModel()

    override func loadView() {
        let host = NSHostingView(rootView: ShareView(model: model))
        host.frame.size = CGSize(width: 440, height: 280)
        view = host
        preferredContentSize = host.fittingSize
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onCancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        model.onAdd = { [weak self] capture in
            ShareModel.send(capture)
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        Task { await model.load(extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }
}

@MainActor
@Observable
final class ShareModel {
    var title = ""
    var text = ""
    var url: String?
    var pageText: String?
    var image: Data?
    var kind: Capture.Kind = .text
    var targets: [(String, String?)] = [("Inbox map", nil)]
    var target = 0
    var settings = ExtensionSettings()
    var onAdd: (Capture) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init() {
        if let group = AppGroup.container {
            settings = ExtensionSettings.read(from: group)
            targets += (WidgetSnapshot.read(from: group)?.recents ?? []).map { ($0.title, $0.token) }
        }
    }

    func load(_ items: [NSExtensionItem]) async {
        for item in items {
            if let t = item.attributedContentText?.string, !t.isEmpty, text.isEmpty { text = t }
            for p in item.attachments ?? [] {
                if p.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                    let dict = try? await p.loadItem(forTypeIdentifier: UTType.propertyList.identifier)
                        as? NSDictionary,
                    let r = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
                {
                    kind = settings.clipper ? .page : .link
                    title = r["title"] as? String ?? title
                    url = r["url"] as? String
                    let sel = (r["selection"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sel.isEmpty { text = sel }
                    pageText = r["text"] as? String
                } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                    let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
                {
                    if kind == .text { kind = .link }
                    url = url ?? u.absoluteString
                    if title.isEmpty { title = item.attributedTitle?.string ?? u.host() ?? u.absoluteString }
                } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                    let item = try? await p.loadItem(forTypeIdentifier: UTType.image.identifier),
                    let png = Self.png(item)
                {
                    kind = .image
                    image = png
                } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                    let t = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                    text.isEmpty
                {
                    text = t
                }
            }
        }
    }

    /// Shared images arrive as a file URL, data or an image.
    static func png(_ item: any NSSecureCoding) -> Data? {
        let img: NSImage?
        switch item {
        case let u as URL: img = NSImage(contentsOf: u)
        case let d as Data: img = NSImage(data: d)
        case let i as NSImage: img = i
        default: img = nil
        }
        guard let tiff = img?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    var capture: Capture {
        Capture(
            kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), title: title.isEmpty ? nil : title,
            url: url,
            pageText: pageText, image: image, target: targets[target].1)
    }

    /// Queued in the App Group; in an unsigned build, on a private pasteboard. Then
    /// OpenNexus is told to look.
    static func send(_ c: Capture) {
        if let group = AppGroup.container, (try? CaptureQueue.enqueue(c, in: group)) != nil {
        } else {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let pb = NSPasteboard(name: .init("com.opennexus.capture"))
            pb.clearContents()
            pb.setData(try? enc.encode([c]), forType: .init("com.opennexus.capture"))
        }
        NSWorkspace.shared.open(URL(string: "opennexus://capture")!)
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(model.kind == .page ? "Clip to OpenNexus" : "Add to OpenNexus").font(
                    .system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: $model.target) {
                    ForEach(model.targets.indices, id: \.self) { i in Text(model.targets[i].0).tag(i) }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            if !model.settings.share {
                Text("Sharing to OpenNexus is turned off in OpenNexus › Settings › Integrations.")
                    .foregroundStyle(.secondary)
            } else {
                if model.kind == .link || model.kind == .page {
                    TextField("Title", text: $model.title).textFieldStyle(.roundedBorder)
                }
                TextEditor(text: $model.text)
                    .font(.system(size: 13))
                    .frame(minHeight: 70, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                if model.kind == .page {
                    Label("Summarised on this Mac into a branch with the link", systemImage: "sparkles")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else if let u = model.url {
                    Text(u).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else if model.image != nil {
                    Label("The image is added to the topic", systemImage: "photo").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.onCancel() }.keyboardShortcut(.cancelAction)
                Button(model.kind == .page ? "Clip" : "Add") { model.onAdd(model.capture) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        !model.settings.share || (model.text.isEmpty && model.title.isEmpty && model.image == nil))
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}
