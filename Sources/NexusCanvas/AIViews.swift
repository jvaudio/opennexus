import AppKit
import NexusAI
import NexusCore
import NexusTheme
import SwiftUI

extension CanvasController {
    var aiColor: Color { Color(nsColor: NSColor(cgColor: theme.ai.cgColor) ?? .systemTeal) }
}

// MARK: Ghost hints (artboard 28, under the ghosts)

struct GhostHintsView: View {
    var controller: CanvasController

    var body: some View {
        if let g = controller.ghosts {
            HStack(spacing: 8) {
                if g.loading {
                    HStack(spacing: 6) {
                        Circle().fill(controller.aiColor).frame(width: 7, height: 7)
                        Text(g.label ?? "Thinking…").foregroundStyle(.white)
                        Button("Stop") { controller.stopAI() }.buttonStyle(.plain).foregroundStyle(.red)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                }
                if !g.ideas.isEmpty {
                    Keycap(text: "⌃⇧↩")
                    Text("accept all ·").foregroundStyle(controller.aiColor)
                    Keycap(text: "↑↓")
                    Text("browse ·").foregroundStyle(controller.aiColor)
                    Keycap(text: "esc")
                    Text("dismiss · typing ignores ghosts").foregroundStyle(controller.aiColor)
                }
            }
            .font(.chrome(12.5))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(g.ideas.count) suggestions. Control Return accepts, Escape dismisses.")
        }
    }
}

/// "Apple Intelligence is off, so ghost ideas can’t run." in place (artboard 29, right).
struct AINoticeView: View {
    var controller: CanvasController

    var body: some View {
        if let notice = controller.aiNotice {
            VStack(alignment: .leading, spacing: 10) {
                (Text(notice.components(separatedBy: ",").first ?? notice).bold()
                    + Text(
                        notice.contains(",")
                            ? "," + notice.components(separatedBy: ",").dropFirst().joined(separator: ",") : ""))
                    .font(.chrome(14))
                HStack {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(AIButtonStyle(fill: .black))
                    Button("Use a local model") { controller.onOpenAISettings?() }.buttonStyle(AIButtonStyle())
                }
            }
            .padding(16)
            .frame(width: 400, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
            .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
        }
    }
}

// MARK: Prompt bar (⇧⌘Space)

/// A filled or outlined button that keeps its look in an inactive window (artboards 28, 29).
struct AIButtonStyle: ButtonStyle {
    var fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.chrome(13.5, weight: fill == nil ? .regular : .medium))
            .foregroundStyle(fill == nil ? Color.primary : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                if let fill {
                    RoundedRectangle(cornerRadius: 7).fill(fill)
                } else {
                    RoundedRectangle(cornerRadius: 7).stroke(.separator)
                }
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// The ⌃↩ chip beside the highlighted ghost (artboard 28).
struct GhostBadgeView: View {
    var color: Color

    var body: some View {
        Text("⌃↩")
            .font(.chrome(11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
            .accessibilityLabel("Control-Return accepts this suggestion")
    }
}

struct PromptBarView: View {
    var controller: CanvasController
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let bar = controller.promptBar {
            let anchor = controller.canvas.nodes[bar.anchor]?.text ?? ""
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("✦").foregroundStyle(controller.aiColor).font(.chrome(17))
                    TextField("Ask AI to change this branch…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.chrome(17))
                        .focused($focused)
                        .onSubmit {
                            controller.submitPrompt(text)
                            text = ""
                        }
                        .onExitCommand { controller.closePromptBar() }
                    Keycap(text: "↩")
                }
                HStack(spacing: 8) {
                    ForEach(CanvasController.promptChips, id: \.0) { title, action in
                        Button(title) {
                            controller.submitPrompt(text, action: action)
                            text = ""
                        }
                        .buttonStyle(.plain)
                        .font(.chrome(13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().stroke(.separator))
                    }
                }
                HStack {
                    Text("⇧⌘Space · anchored to “\(anchor)”")
                    Spacer()
                    Text("Results arrive as ghosts, never applied silently")
                }
                .font(.chrome(11.5))
                .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(width: 640)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(controller.aiColor.opacity(0.35), lineWidth: 1.5))
            .shadow(color: controller.aiColor.opacity(0.18), radius: 18, y: 6)
            .onAppear {
                text = bar.text
                focused = true
            }
        }
    }
}

// MARK: AI panel (⇧⌘J)

struct AIPanelView: View {
    var controller: CanvasController
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if controller.aiPanelVisible, !controller.zen, controller.present == nil {
            let chat = controller.currentChat
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Ask about this document").font(.chrome(15, weight: .semibold))
                    Spacer()
                    Keycap(text: "⇧⌘J")
                }
                .padding(16)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Menu("Chat: \(chat?.title ?? "New chat")") {
                            ForEach(controller.chats) { c in Button(c.title) { controller.selectChat(c.id) } }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Spacer()
                        Button("+ New chat") { controller.newChat() }.buttonStyle(.plain).foregroundStyle(
                            Color.accentColor)
                    }
                    Picker(
                        "", selection: Binding(get: { chat?.depth ?? .balanced }, set: { controller.setChatDepth($0) })
                    ) {
                        ForEach(MapContext.Depth.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Toggle(
                        "Discussion mode · never edits",
                        isOn: Binding(get: { chat?.discussion ?? false }, set: { controller.setDiscussion($0) })
                    )
                    .toggleStyle(.switch)
                    .font(.chrome(13))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array((chat?.messages ?? []).enumerated()), id: \.offset) { i, m in
                                message(m, index: i, chat: chat?.id ?? "")
                            }
                            if let s = controller.aiStreaming {
                                Text(s).font(.chrome(14))
                            }
                            if let busy = controller.aiBusy {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(busy + "…").foregroundStyle(.secondary)
                                    Button("Stop") { controller.stopAI() }.buttonStyle(.plain).foregroundStyle(.red)
                                }
                                .font(.chrome(13))
                            }
                            actions
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                    }
                    .onChange(of: chat?.messages.count) { _, _ in proxy.scrollTo("end") }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Ask, or type @ to reference a node…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.chrome(14))
                        .lineLimit(1...4)
                        .focused($focused)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).stroke(.separator))
                        .onSubmit {
                            controller.ask(draft)
                            draft = ""
                        }
                        .onExitCommand { controller.onRestoreFocus?() }
                    if let partial = mentionQuery {
                        mentionSuggestions(partial)
                    }
                    HStack {
                        Circle().fill(controller.aiAvailability.canRun ? Color.green : .secondary).frame(
                            width: 7, height: 7)
                        Text(
                            controller.aiAvailability.canRun ? "Apple on-device model" : controller.aiAvailability.chip)
                        Spacer()
                        Text("Nothing leaves this Mac")
                    }
                    .font(.chrome(12))
                    .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .frame(width: 380)
            .frame(maxHeight: .infinity)
            .background(.background)
            .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
        }
    }

    /// The `@` being typed, if any.
    var mentionQuery: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let tail = draft[draft.index(after: at)...]
        return tail.contains(" ") && tail.count > 24 ? nil : String(tail)
    }

    func mentionSuggestions(_ q: String) -> some View {
        let c = controller.canvas
        let hits = c.nodes.values.map(\.text).filter { q.isEmpty || $0.lowercased().hasPrefix(q.lowercased()) }.sorted()
            .prefix(5)
        return HStack {
            ForEach(Array(hits), id: \.self) { t in
                Button("@" + t) {
                    if let at = draft.lastIndex(of: "@") { draft = String(draft[..<at]) + "@" + t + " " }
                }
                .buttonStyle(.plain)
                .font(.chrome(12))
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    func message(_ m: AIMessage, index: Int, chat: String) -> some View {
        if m.role == "user" {
            Text(highlightRefs(m.text))
                .font(.chrome(14.5))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
                .padding(.leading, 40)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(highlightTopics(m.text)).font(.chrome(14.5))
                if let plan = m.plan { planCard(plan, chat: chat, index: index, applied: m.applied) }
            }
        }
    }

    func planCard(_ plan: ChangePlan, chat: String, index: Int, applied: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROPOSED CHANGE").font(.chrome(11.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(plan.counts()).font(.chrome(12, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.lines(in: controller.canvas).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.chrome(12.5, design: .monospaced))
                        .foregroundStyle(line.hasPrefix("+") ? Color.green : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            Divider()
            HStack {
                Spacer()
                if applied {
                    Text("Applied · ⌘Z undoes").font(.chrome(12.5)).foregroundStyle(.secondary)
                } else {
                    Button(controller.previewPlan == plan ? "Hide preview" : "Preview on canvas") {
                        controller.previewPlan(plan)
                    }
                    .buttonStyle(AIButtonStyle())
                    Button("Apply · one undo") { controller.applyPlan(plan, chat: chat, message: index) }
                        .buttonStyle(AIButtonStyle(fill: controller.aiColor))
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIONS · ALSO IN ⌘K").font(.chrome(11.5, weight: .semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(AIAction.panel, id: \.self) { a in
                    Button(a.title == "Rewrite shorter" ? "Rewrite" : a.title) { controller.runAction(a) }
                        .buttonStyle(.plain)
                        .font(.chrome(13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().stroke(.separator))
                }
            }
        }
    }

    /// `@Churn` in the user's question shows as a topic chip colour.
    func highlightRefs(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        for id in MapContext.references(in: s, canvas: controller.canvas) {
            guard let t = controller.canvas.nodes[id]?.text, let r = a.range(of: "@" + t) else { continue }
            a[r].foregroundColor = .accentColor
        }
        return a
    }

    /// Topic names in an answer pick up the topic's emphasis.
    func highlightTopics(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        // The first topic the answer names gets a pill (artboard 28); longer names win ties.
        let names = controller.canvas.nodes.values.map(\.text).filter { $0.count > 2 }.sorted { $0.count > $1.count }
        let first = names.compactMap { n in a.range(of: n) }.min { $0.lowerBound < $1.lowerBound }
        if let r = first {
            a[r].foregroundColor = Color(red: 0.8, green: 0.27, blue: 0.13)
            a[r].backgroundColor = Color.orange.opacity(0.14)
        }
        return a
    }
}

// MARK: AI+ sheets (artboard 52)

struct AISheetView: View {
    var controller: CanvasController

    var body: some View {
        if let sheet = controller.aiSheet {
            Group {
                switch sheet {
                case .translate: TranslateSheet(controller: controller)
                case .mask: MaskSheet(controller: controller)
                case .sticker(let id): StickerSheet(controller: controller, node: id)
                case .record: RecordSheet(controller: controller)
                case .removeBackground(let id): RemoveBackgroundSheet(controller: controller, node: id)
                }
            }
            .padding(22)
            .frame(width: 460)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            .onExitCommand { controller.closeAISheet() }
        }
    }
}

private struct SheetHeader: View {
    let title: String
    let hint: String
    let framework: String
    var close: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.chrome(17, weight: .semibold))
            Spacer()
            Text(hint).font(.chrome(11, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        Text(framework).font(.chrome(11, design: .monospaced)).foregroundStyle(.teal)
    }
}

struct TranslateSheet: View {
    var controller: CanvasController
    @State private var target = "es"
    @State private var options = MapTranslator.Options()
    @State private var busy = false
    @State private var preview: [String: String] = [:]
    @State private var previewFailed = false

    static let languages: [(String, String)] = [
        ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("it", "Italiano"), ("pt", "Português"),
        ("ja", "日本語"), ("zh", "中文"), ("ko", "한국어"), ("nl", "Nederlands"), ("en", "English"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Translate map", hint: "⌘K › Translate", framework: "Translation framework") {
                controller.closeAISheet()
            }
            HStack {
                Text(
                    Locale.current.localizedString(
                        forLanguageCode: controller.mapLanguage.languageCode?.identifier ?? "en") ?? ""
                )
                .padding(8).background(RoundedRectangle(cornerRadius: 7).stroke(.separator))
                Image(systemName: "arrow.right")
                Picker("", selection: $target) {
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            previewColumns
            Toggle("Topics & labels", isOn: $options.topicsAndLabels)
            Toggle("Notes", isOn: $options.notes)
            Toggle("Keep code blocks as is", isOn: $options.keepCode)
            Text("Writes a new canvas, structure and styles untouched; the original stays.")
                .font(.chrome(12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Translate") {
                    busy = true
                    Task {
                        await controller.translateMap(to: Locale.Language(identifier: target), options: options)
                        busy = false
                        controller.closeAISheet()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
        .task(id: target) {
            previewFailed = false
            do {
                preview = try await MapTranslator.translate(
                    sample, from: controller.mapLanguage, to: Locale.Language(identifier: target))
            } catch {
                preview = [:]
                previewFailed = true
            }
        }
    }

    /// The root and its first three branches, translated live as a preview (artboard 52).
    var sample: [String] {
        let c = controller.canvas
        return Array(([c.root] + (c.nodes[c.root]?.children ?? [])).prefix(4).compactMap { c.nodes[$0]?.text })
    }

    var previewColumns: some View {
        HStack(alignment: .top, spacing: 10) {
            column(sample)
            if previewFailed {
                Text(
                    "Install this language pair in System Settings › General › Language & Region › Translation Languages to preview."
                )
                .font(.chrome(12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            } else {
                column(sample.map { preview[$0] ?? "…" }).background(
                    RoundedRectangle(cornerRadius: 8).fill(controller.aiColor.opacity(0.07)))
            }
        }
    }

    func column(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, t in
                Text(t).font(.chrome(13, weight: i == 0 ? .semibold : .regular)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }
}

struct MaskSheet: View {
    var controller: CanvasController
    @State private var excluded: Set<String> = []

    var body: some View {
        let hits = controller.maskHits
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "Data masking", hint: "⌘K › Mask", framework: "Natural Language") {
                controller.closeAISheet()
            }
            if let h = hits.first(where: { !excluded.contains($0.id) }) { maskPreview(h) }
            HStack(spacing: 6) {
                ForEach(Masker.counts(hits), id: \.0) { k, n in
                    Text("\(k.title) \(n)")
                        .font(.chrome(12))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(n > 0 ? Color.white : .secondary)
                        .background(Capsule().fill(n > 0 ? Color.black : Color.secondary.opacity(0.12)))
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if hits.isEmpty { Text("Nothing to mask on this canvas.").foregroundStyle(.secondary) }
                    ForEach(hits) { h in
                        Toggle(
                            isOn: Binding(
                                get: { !excluded.contains(h.id) },
                                set: { on in
                                    if on { excluded.remove(h.id) } else { excluded.insert(h.id) }
                                })
                        ) {
                            HStack {
                                Text(h.text).font(.chrome(13, design: .monospaced))
                                Spacer()
                                Text(h.kind.title).font(.chrome(11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            Text("Makes a masked copy for export, Present or sharing. You review each hit before anything is written.")
                .font(.chrome(12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Make masked copy") {
                    controller.makeMaskedCopy(hits.filter { !excluded.contains($0.id) })
                    controller.closeAISheet()
                }
                .buttonStyle(.borderedProminent)
                .disabled(hits.isEmpty)
            }
        }
    }

    /// The first kept hit in context, before and after (artboard 52).
    func maskPreview(_ h: Masker.Hit) -> some View {
        let c = controller.canvas
        let field = { (c: NexusCore.Canvas) in
            (h.field == "note" ? c.nodes[h.node]?.note?.text : c.nodes[h.node]?.text) ?? ""
        }
        let after = field(Masker.maskedCopy(c, hits: [h], id: c.id))
        return VStack(spacing: 6) {
            Text(field(c)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
            Image(systemName: "arrow.down").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(after).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
        }
        .font(.chrome(14))
        .lineLimit(2)
    }
}

struct RemoveBackgroundSheet: View {
    var controller: CanvasController
    let node: NodeID
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Remove background", hint: "right-click image", framework: "Vision") {
                controller.closeAISheet()
            }
            if let asset = controller.canvas.nodes[node]?.image?.asset, let data = controller.store.model.assets[asset],
                let img = NSImage(data: data)
            {
                Image(nsImage: img).resizable().scaledToFit().frame(height: 160).frame(maxWidth: .infinity)
            } else {
                Text("Select a topic with an image (drag one onto a topic).").foregroundStyle(.secondary)
            }
            Text("Subject lift in under a second.").font(.chrome(12)).foregroundStyle(.secondary)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Keep both") { run(replace: false) }
                Button("Replace original") { run(replace: true) }.buttonStyle(.borderedProminent)
            }
            .disabled(busy || controller.canvas.nodes[node]?.image == nil)
        }
    }

    func run(replace: Bool) {
        busy = true
        Task {
            await controller.removeBackground(node, replace: replace)
            busy = false
            controller.closeAISheet()
        }
    }
}

struct StickerSheet: View {
    var controller: CanvasController
    let node: NodeID
    @State private var prompt = ""
    @State private var style = StickerMaker.Style.animation
    @State private var images: [Data] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Make a sticker", hint: "right-click › Make Image", framework: "Image Playground") {
                controller.closeAISheet()
            }
            TextField("Describe the sticker", text: $prompt)
                .textFieldStyle(.roundedBorder)
                .onSubmit(make)
            Picker("", selection: $style) {
                ForEach(StickerMaker.Style.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, d in
                    if let img = NSImage(data: d) {
                        Button {
                            Task {
                                await controller.applySticker(d, to: node)
                                controller.closeAISheet()
                            }
                        } label: {
                            Image(nsImage: img).resizable().scaledToFit().frame(width: 120, height: 120)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if busy { ProgressView() }
            }
            if let error { Text(error).font(.chrome(12)).foregroundStyle(.red) }
            Text(
                "Prompt is pre-filled from the topic and its branch. The pick lands on the topic with its background removed."
            )
            .font(.chrome(12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(images.isEmpty ? "Make" : "Make more", action: make).buttonStyle(.borderedProminent).disabled(
                    busy)
            }
        }
        .onAppear { prompt = StickerMaker.prompt(for: node, in: controller.canvas) }
    }

    func make() {
        busy = true
        error = nil
        Task {
            do {
                images = try await StickerMaker.make(prompt, style: style)
            } catch {
                self.error = "Image Playground isn’t available: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}

struct RecordSheet: View {
    var controller: CanvasController
    @State private var recorder = MapRecorder()
    @State private var text = ""
    @State private var running = false
    @State private var paused = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Record to map", hint: "⌘K › Record", framework: "SpeechAnalyzer") {
                Task {
                    _ = await recorder.stop()
                    controller.closeAISheet()
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle().fill(running && !paused ? Color.red : Color.gray).frame(width: 12, height: 12)
                        let s = Int(recorder.elapsed)
                        Text(String(format: "%02d:%02d", s / 60, s % 60))
                            .font(.chrome(17, weight: .semibold, design: .monospaced))
                        Spacer()
                        if running {
                            Button(paused ? "Resume" : "Pause") {
                                if paused { try? recorder.resume() } else { recorder.pause() }
                                paused.toggle()
                            }
                            .buttonStyle(.plain)
                            Text("·").foregroundStyle(.secondary)
                            Button("Stop") { stop() }.buttonStyle(.plain)
                        }
                    }
                    Text(text.isEmpty ? (running ? "Listening…" : "Press Record to start.") : "“…\(text.suffix(180))”")
                        .font(.chrome(14))
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.88)))
            }
            if let error { Text(error).font(.chrome(12)).foregroundStyle(.red) }
            Text("Live transcript; key points become ghosts and the full transcript goes into the root’s note.")
                .font(.chrome(12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if !running {
                    Button("Record") { start() }.buttonStyle(.borderedProminent).tint(.red)
                }
            }
        }
    }

    func start() {
        error = nil
        recorder.onUpdate = { text = $0 }
        running = true
        Task {
            do {
                try await recorder.start()
            } catch {
                self.error = "Couldn’t start recording: \(error.localizedDescription)"
                running = false
            }
        }
    }

    func stop() {
        Task {
            let t = await recorder.stop()
            running = false
            controller.closeAISheet()
            controller.finishRecording(t)
        }
    }
}
