import AVFoundation
import AppKit
import NexusCore
import NexusTheme
import SwiftUI
import UniformTypeIdentifiers

/// Presents the canvas's popovers next to a topic (note, link, labels, markers & stickers,
/// comments, audio), on the canvas or on the topic's outline row, and handles image /
/// attachment requests.
@MainActor
final class CanvasPopovers: NSObject, NSPopoverDelegate {
    weak var view: CanvasView?
    private var popover: NSPopover?
    /// The view the popover hangs from (the canvas, or an outline row's view), which gets
    /// focus back when it closes.
    private weak var anchorView: NSView?
    private var player: AVAudioPlayer?

    init(view: CanvasView) {
        self.view = view
    }

    func handle(_ r: CanvasRequest) {
        guard let view else { return }
        let c = view.controller
        switch r {
        case .note(let id):
            show(NotePopover(controller: c, node: id, close: close), at: id, size: CGSize(width: 380, height: 320))
        case .comments(let id):
            show(CommentsPopover(controller: c, node: id, close: close), at: id, size: CGSize(width: 380, height: 440))
        case .legend:
            let content = LegendPopover(controller: c, close: close)
            let size = CGSize(width: 380, height: 460)
            if let r = view.controller.scene.legend?.rect {
                show(content, rect: view.camera.toView(r), size: size)
            } else {
                show(content, at: c.selection.primary, size: size)
            }
        case .link(let id):
            show(LinkPopover(controller: c, node: id, close: close), at: id, size: CGSize(width: 380, height: 420))
        case .labels(let id):
            show(LabelPopover(controller: c, node: id, close: close), at: id, size: CGSize(width: 320, height: 300))
        case .markers(let id), .stickers(let id):
            show(MarkerPopover(controller: c, node: id, close: close), at: id, size: CGSize(width: 340, height: 420))
        case .audio(let id):
            if let a = c.canvas.nodes[id]?.audio, let data = c.store.model.assets[a.asset] {
                player = try? AVAudioPlayer(data: data)
                player?.play()
                c.showToast(Loc.f("Playing audio note · %lld s", Int(a.duration)))
            } else {
                show(AudioPopover(controller: c, node: id, close: close), at: id, size: CGSize(width: 300, height: 170))
            }
        case .image(let id):
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            let size = NSImage(data: data)?.size
            c.setImage(
                data, ext: url.pathExtension.isEmpty ? "png" : url.pathExtension, size: size, on: id, source: url)
        case .attachment(let id, let index):
            guard let n = c.canvas.nodes[id], n.attachments.indices.contains(index),
                let data = c.store.model.assets[n.attachments[index].asset]
            else { return }
            let name = n.attachments[index].name ?? n.attachments[index].asset
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try? data.write(to: url)
            NSWorkspace.shared.open(url)
        }
    }

    private func show(_ content: some View, at id: NodeID, size: CGSize) {
        guard let (anchor, f) = anchor(for: id) else { return }
        show(content, rect: f, in: anchor, size: size)
    }

    /// Where a topic's popover hangs: its row in the outline or the Gantt while that view
    /// has focus or the canvas is hidden, else the topic on the canvas (D254).
    func anchor(for id: NodeID) -> (NSView, CGRect)? {
        guard let view else { return nil }
        let c = view.controller
        let canvasShown = view.window != nil && !view.isHiddenOrHasHiddenAncestor
        if c.outlineFocused, let row = c.outlineAnchor?(id) { return row }
        if c.ganttFocused, let row = c.ganttAnchor?(id) { return row }
        if !canvasShown, let row = c.outlineAnchor?(id) ?? c.ganttAnchor?(id) { return row }
        return view.viewRect(of: id).map { (view, $0) }
    }

    /// Shows the popover (tests record it instead: there's no screen to show it on).
    lazy var present: (NSPopover, CGRect, NSView) -> Void = { p, rect, view in
        p.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }

    private func show(_ content: some View, rect f: CGRect, in anchor: NSView? = nil, size: CGSize) {
        guard let view else { return }
        let anchor = anchor ?? view
        anchorView = anchor
        close()
        let p = NSPopover()
        p.behavior = .transient
        p.contentSize = size
        p.contentViewController = NSHostingController(rootView: content.frame(width: size.width, height: size.height))
        p.delegate = self
        present(p, f, anchor)
        popover = p
    }

    /// Closes the popover and gives focus back to the view it hung from.
    func close() {
        popover?.performClose(nil)
        popover = nil
        restoreFocus()
    }

    private func restoreFocus() {
        guard let v = anchorView ?? view else { return }
        v.window?.makeFirstResponder(v)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover = nil
            restoreFocus()
        }
    }
}

// MARK: - Note

struct NotePopover: View {
    var controller: CanvasController
    let node: NodeID
    var close: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Note").font(.headline)
                Text(controller.canvas.nodes[node]?.text ?? "").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Done") { save() }.keyboardShortcut(.defaultAction)
            }
            TextEditor(text: $text)
                .font(.chrome(13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            Text("Markdown: # headings, - lists, ``` code, | tables |").font(.chrome(11)).foregroundStyle(
                .secondary)
        }
        .padding(14)
        .onAppear { text = controller.canvas.nodes[node]?.note?.text ?? "" }
        .onDisappear { save(closing: false) }
    }

    func save(closing: Bool = true) {
        if text != (controller.canvas.nodes[node]?.note?.text ?? "") { controller.setNote(text, on: node) }
        if closing { close() }
    }
}

// MARK: - Link

struct LinkPopover: View {
    var controller: CanvasController
    let node: NodeID
    var close: () -> Void
    @State private var kind = "web"
    @State private var url = ""
    @State private var query = ""

    var topics: [(CanvasID, NodeID, String, String)] {
        var out: [(CanvasID, NodeID, String, String)] = []
        for c in controller.store.model.orderedCanvases {
            for (id, n) in c.nodes where !(c.id == controller.canvasID && id == node) {
                if query.isEmpty || n.text.localizedCaseInsensitiveContains(query) {
                    out.append((c.id, id, n.text, c.title))
                }
            }
        }
        return out.sorted { $0.2 < $1.2 }.prefix(40).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link").font(.headline)
            Picker("", selection: $kind) {
                Text("↗ Web page").tag("web")
                Text("⤳ Topic or canvas").tag("topic")
                Text("▤ File").tag("file")
                Text("▱ Folder").tag("folder")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch kind {
            case "topic":
                TextField("Search topics", text: $query).textFieldStyle(.roundedBorder)
                List(topics, id: \.1) { t in
                    Button {
                        controller.setLink(TopicLink.make(canvas: t.0, node: t.1), on: node)
                        close()
                    } label: {
                        HStack {
                            Text(t.2)
                            Spacer()
                            Text(t.3).foregroundStyle(.secondary).font(.chrome(11))
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 160)
            case "file", "folder":
                Button(kind == "file" ? Loc.t("Choose File…") : Loc.t("Choose Folder…")) {
                    let p = NSOpenPanel()
                    p.canChooseFiles = kind == "file"
                    p.canChooseDirectories = kind == "folder"
                    if p.runModal() == .OK, let u = p.url {
                        controller.setLink(u.absoluteString, on: node)
                        close()
                    }
                }
                Text("Links keep the file where it is; the file itself is not copied into the document.")
                    .font(.chrome(11)).foregroundStyle(.secondary)
            default:
                TextField("https://", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveWeb)
                HStack {
                    Spacer()
                    Button("Link", action: saveWeb).keyboardShortcut(.defaultAction)
                }
            }
            if controller.canvas.nodes[node]?.link != nil {
                Button("Remove Link", role: .destructive) {
                    controller.setLink(nil, on: node)
                    close()
                }
            }
            let back = controller.backlinks(to: node)
            if !back.isEmpty {
                Divider()
                Text(Loc.n("LINKED FROM %lld TOPIC", "LINKED FROM %lld TOPICS", back.count))
                    .font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(back, id: \.node) { b in
                    Text("⤳ \(b.text) · \(b.canvasTitle)").font(.chrome(12))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .onAppear {
            let l = controller.canvas.nodes[node]?.link ?? ""
            if TopicLink.parse(l) != nil {
                kind = "topic"
            } else if l.hasPrefix("file:") {
                kind = "file"
            } else {
                url = l
            }
        }
    }

    func saveWeb() {
        var u = url.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty, !u.contains("://"), !u.hasPrefix("mailto:") { u = "https://" + u }
        controller.setLink(u.isEmpty ? nil : u, on: node)
        close()
    }
}

// MARK: - Labels

struct LabelPopover: View {
    var controller: CanvasController
    let node: NodeID
    var close: () -> Void
    @State private var text = ""
    @State private var sort = false

    var current: [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var fragment: String {
        text.split(separator: ",", omittingEmptySubsequences: false).last.map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? ""
    }

    var suggestions: [(label: String, count: Int)] {
        controller.labelUsage.filter { s in
            !current.dropLast(fragment.isEmpty ? 0 : 1).contains(s.label)
                && (fragment.isEmpty || s.label.localizedCaseInsensitiveContains(fragment))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Labels").font(.headline)
            TextField("Comma separates labels", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions.prefix(8), id: \.label) { s in
                        Button {
                            pick(s.label)
                        } label: {
                            HStack {
                                Text(s.label)
                                Spacer()
                                Text(Loc.f("used %lld×", s.count)).foregroundStyle(.secondary).font(.chrome(11))
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !fragment.isEmpty, !controller.labelUsage.contains(where: { $0.label == fragment }) {
                        Text(Loc.f("Create “%@”", fragment)).foregroundStyle(Color.accentColor).font(.chrome(13))
                    }
                }
            }
            .accessibilityLabel(Loc.t("Label suggestions"))
            Toggle("Auto sort A–Z", isOn: $sort).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Done", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { text = (controller.canvas.nodes[node]?.labels ?? []).joined(separator: ", ") }
    }

    func pick(_ l: String) {
        var parts = current
        if !fragment.isEmpty { parts.removeLast() }
        parts.append(l)
        text = parts.joined(separator: ", ") + ", "
    }

    func save() {
        var labels = current
        if sort { labels.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
        var seen = Set<String>()
        controller.setLabels(labels.filter { seen.insert($0).inserted })
        close()
    }
}

// MARK: - Markers and stickers

struct MarkerPopover: View {
    var controller: CanvasController
    let node: NodeID
    var close: () -> Void
    @State private var tab = "markers"
    @State private var category = Loc.t("Tech")

    var markers: [String] { controller.canvas.nodes[node]?.markers ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text("Markers").tag("markers")
                Text("Stickers").tag("stickers")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if tab == "markers" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(MarkerLibrary.groups) { g in
                            Text(g.name.uppercased()).font(.chrome(11, weight: .semibold)).foregroundStyle(
                                .secondary)
                            HStack(spacing: 6) {
                                ForEach(g.markers) { m in
                                    Button {
                                        controller.toggleMarker(m.id)
                                    } label: {
                                        Group {
                                            if let pie = m.pie {
                                                ProgressPie(fraction: pie).frame(width: 11, height: 11)
                                            } else {
                                                Text(m.glyph).font(.chrome(12, weight: .bold))
                                            }
                                        }
                                        .foregroundStyle(.white)
                                        .frame(width: 24, height: 24)
                                        .background(RGBA(hex: m.color).color, in: Circle())
                                        .overlay(
                                            Circle().strokeBorder(
                                                markers.contains(m.id) ? Color.primary : .clear, lineWidth: 2
                                            ).padding(-3))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(m.id)
                                }
                            }
                        }
                        Text("Picking from the same group replaces; another group adds.")
                            .font(.chrome(11)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(Loc.t("Markers"))
            } else {
                Picker("", selection: $category) {
                    ForEach(StickerLibrary.categories, id: \.0) { Text($0.0).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                let stickers = StickerLibrary.categories.first { $0.0 == category }?.1 ?? []
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                    ForEach(stickers, id: \.self) { s in
                        Button {
                            controller.setSticker("emoji:\(s)", on: node)
                            close()
                        } label: {
                            Text(s).font(.chrome(26))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Stickers")
                if controller.canvas.nodes[node]?.sticker != nil {
                    Button("Remove Sticker") {
                        controller.setSticker(nil, on: node)
                        close()
                    }
                }
                Text("✦ Make a sticker with Image Playground arrives with on-device AI.")
                    .font(.chrome(11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

// MARK: - Audio

@MainActor
@Observable
final class AudioRecorderModel {
    var recording = false
    var elapsed: Double = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "opennexus-note-\(UUID().uuidString).m4a")

    func start() {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        guard recorder?.record() == true else { return }
        recording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsed = self?.recorder?.currentTime ?? 0 }
        }
    }

    func stop() -> (Data, Double)? {
        let d = recorder?.currentTime ?? elapsed
        recorder?.stop()
        timer?.invalidate()
        recording = false
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return (data, d)
    }
}

struct AudioPopover: View {
    var controller: CanvasController
    let node: NodeID
    var close: () -> Void
    @State private var model = AudioRecorderModel()

    var body: some View {
        VStack(spacing: 12) {
            Text("Audio note").font(.headline)
            Text(String(format: "%02d:%02d", Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                .font(.chrome(28, weight: .semibold, design: .monospaced))
            Button(model.recording ? Loc.t("Stop and Save") : Loc.t("Record")) {
                if model.recording {
                    if let (data, d) = model.stop() { controller.setAudio(data, duration: d, on: node) }
                    close()
                } else {
                    model.start()
                }
            }
            .keyboardShortcut(.defaultAction)
            Text("Recorded on this Mac. Transcription runs on-device (AI, M6).")
                .font(.chrome(11)).foregroundStyle(.secondary)
        }
        .padding(14)
    }
}
