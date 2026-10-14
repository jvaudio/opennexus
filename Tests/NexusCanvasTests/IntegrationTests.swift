import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat

/// M9: the logic behind Quick Capture, Share, Spotlight, widgets and the agent settings.
@MainActor
@Suite struct IntegrationTests {
    @Test func captureComposesItemsOrAMap() throws {
        #expect(CaptureComposer.compose("   ") == nil)
        #expect(
            CaptureComposer.compose("Try a pricing page A/B test")
                == .items([.init(text: "Try a pricing page A/B test")]))
        let text = "- Webhook retries\n  - Exponential backoff\n  - Dead-letter queue\n- A/B pricing page"
        guard case .items(let items)? = CaptureComposer.compose(text) else { Issue.record("items"); return }
        #expect(items.map(\.text) == ["Webhook retries", "A/B pricing page"])
        #expect(items[0].children == ["Exponential backoff", "Dead-letter queue"])
        guard case .map(let doc)? = CaptureComposer.compose(text, multiline: "map", title: "Ideas") else {
            Issue.record("map")
            return
        }
        let c = doc.orderedCanvases[0]
        #expect(c.validate().isEmpty && c.nodes[c.root]?.text == "Ideas" && c.nodes.count == 5)
    }

    @Test func inboxAppendIsOneUndoStep() throws {
        let store = DocumentStore(model: DocumentModel(canvases: [Canvas(id: "c1", title: "Inbox", rootText: "Inbox")]))
        let undo = StackUndoRegistrar()
        store.undoRegistrar = undo
        let clip = CaptureComposer.clip(
            title: "Pricing experiments", points: ["Anchor on annual", "Test the free tier limit"],
            url: "https://example.com/p")
        let patch = try #require(
            CaptureComposer.patch(adding: [.init(text: "Webhook retries"), clip], to: store.model.canvases["c1"]!))
        store.commit(patch)
        let c = store.model.canvases["c1"]!
        #expect(c.nodes[c.root]!.children.map { c.nodes[$0]!.text } == ["Webhook retries", "Pricing experiments"])
        let page = c.nodes[c.nodes[c.root]!.children[1]]!
        #expect(page.link == "https://example.com/p" && page.children.count == 2)
        #expect(undo.stack.undoStack.count == 1)
        undo.undo(store)
        #expect(store.model.canvases["c1"]!.nodes.count == 1)
    }

    @Test func targetsCycleThroughInboxAndRecents() {
        var t = CaptureTargets(recents: [
            URL(fileURLWithPath: "/m/Product ideas.nexus"), URL(fileURLWithPath: "/m/Q1.nexus"),
        ])
        #expect(t.current.title == "Inbox map" && t.current.url == nil)
        t.next()
        #expect(t.current.title == "Product ideas")
        t.next()
        t.next()
        #expect(t.current.title == "Inbox map")
        t.previous()
        #expect(t.current.title == "Q1")
        #expect(CaptureTargets(recents: [URL(fileURLWithPath: "/m/A.nexus")], preferLast: true).current.title == "A")
    }

    @Test func spotlightTextCoversTopicsNotesAndLabels() {
        var doc = launchPlanDocument()
        let pricing = doc.canvases["c1"]!.nodes.first { $0.value.text == "Pricing" }!.key
        doc.canvases["c1"]!.nodes[pricing]!.note = Note(text: "Card tokens are stored by the processor")
        doc.canvases["c1"]!.nodes[pricing]!.labels = ["billing"]
        let s = SpotlightText(doc, fileName: "Launch plan.nexus")
        #expect(s.title == "Launch plan")
        #expect(s.content.contains("Card tokens") && s.content.contains("billing") && s.keywords.contains("billing"))
        let pro = s.topics.first { $0.text == "Pro" }!
        #expect(pro.breadcrumb.hasSuffix("Pricing"))
        #expect(
            s.topics.count == doc.canvases.values.reduce(0) { $0 + $1.nodes.values.filter { !$0.text.isEmpty }.count })
    }

    @Test func agentPolicyFollowsSettings() throws {
        let p = Preferences.isolated()
        #expect(
            AgentFolders.policy(p) == AgentPolicy(enabled: false, folders: [], read: .allow, edit: .ask, files: .ask))
        p.set("integrations.mcp", true)
        p.set("integrations.mcpEdit", "allow")
        AgentFolders.set(["/Users/x/Maps", "/Users/x/Notes", "/Users/x/Maps"], p)
        let policy = AgentFolders.policy(p)
        #expect(policy.enabled && policy.edit == .allow && policy.folders == ["/Users/x/Maps", "/Users/x/Notes"])
        #expect(
            RowView.liveDetail(SettingsSchema.allRows.first { $0.2.key == "integrations.folders" }!.2, p) == "2 folders"
        )
        let url = FileManager.default.temporaryDirectory.appending(path: "agent-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try policy.write(to: url)
        #expect(try AgentPolicy.read(from: url) == policy)
    }

    @Test func codeLinksFindFileAndLine() {
        let t = CodeLinks.target(URL(string: "file:///Users/x/app/Checkout.swift#L42")!)
        #expect(t == .init(file: URL(fileURLWithPath: "/Users/x/app/Checkout.swift"), line: 42))
        #expect(CodeLinks.target(URL(fileURLWithPath: "/Users/x/app/main.rs:7"))?.line == 7)
        #expect(CodeLinks.target(URL(fileURLWithPath: "/Users/x/Report.pdf")) == nil)
        #expect(CodeLinks.target(URL(string: "https://example.com/a.swift")!) == nil)
        let vs = CodeLinks.editorURL(t!, editor: "vscode")
        #expect(vs?.absoluteString == "vscode://file/Users/x/app/Checkout.swift:42")
        #expect(CodeLinks.editorURL(t!, editor: "xcode") == nil)
    }

    @Test func captureQueueAndWidgetSnapshotRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Capture(
            kind: .page, text: "Pricing", title: "Pricing", url: "https://example.com", pageText: "Body",
            date: Date(timeIntervalSince1970: 10))
        let b = Capture(kind: .text, text: "Second", date: Date(timeIntervalSince1970: 20))
        try CaptureQueue.enqueue(b, in: dir)
        try CaptureQueue.enqueue(a, in: dir)
        #expect(CaptureQueue.drain(in: dir).map(\.text) == ["Pricing", "Second"], "oldest first")
        #expect(CaptureQueue.drain(in: dir).isEmpty, "drained")
        let snap = WidgetSnapshot(
            inbox: ["A/B pricing page", "Webhook retries"], inboxCount: 7,
            recents: [.init(token: "t1", title: "Checkout DFD", detail: "DFD · 12 topics", thumbnail: "t1.png")])
        try snap.write(to: dir)
        #expect(WidgetSnapshot.read(from: dir)?.inbox == snap.inbox)
    }

    @Test func previewIsNeverWrittenForEncryptedDocuments() {
        var doc = launchPlanDocument()
        #expect(HeadlessExport.previewPNG(doc)?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        doc.encrypted = true
        #expect(HeadlessExport.previewPNG(doc) == nil)
        #expect(String(decoding: NexusPackage.files(for: doc)[".gitignore"]!, as: UTF8.self).contains("preview.png"))
    }
}
