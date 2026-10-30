import NexusCore
import NexusFormat
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Share extension and Safari clipper on the iPad (M47b; artboard 33): text, links,
/// images and Safari pages go to the Inbox or a recent map. The capture is queued in the
/// App Group and OpenNexus adds it when it next comes forward; this extension never edits
/// a file itself.
final class ShareViewController: UIViewController {
    let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        preferredContentSize = CGSize(width: 440, height: 300)
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
        switch item {
        case let u as URL: (try? Data(contentsOf: u)).flatMap(UIImage.init(data:))?.pngData()
        case let d as Data: UIImage(data: d)?.pngData()
        case let i as UIImage: i.pngData()
        default: nil
        }
    }

    var capture: Capture {
        Capture(
            kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines), title: title.isEmpty ? nil : title,
            url: url,
            pageText: pageText, image: image, target: targets[target].1)
    }

    /// Queued in the App Group; OpenNexus adds it when it next comes forward.
    static func send(_ c: Capture) {
        if let group = AppGroup.container { _ = try? CaptureQueue.enqueue(c, in: group) }
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
                    Label("Summarised on this iPad into a branch with the link", systemImage: "sparkles")
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
    }
}
