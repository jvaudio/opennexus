import AppIntents
import CoreSpotlight
import NexusCore
import NexusFormat
import NexusInterchange
import NexusTouch
import Testing
import UIKit

@testable import NexusCanvas
@testable import OpenNexus

extension HostedTests {
    /// A9's app half: a capture the Share extension queues lands in the Inbox; the Shortcuts
    /// actions run; Spotlight gets one item per topic; the widgets' snapshot lists the Inbox.
    /// The extensions' own processes are checked in the simulator (M47b.md, Results). And
    /// A5's folder case without Docker: a change made elsewhere merges with an unsaved edit.
    @MainActor
    @Suite(.serialized) struct IntegrationTests {
        /// The Inbox's topics, once `text` is among them (or after `seconds`).
        func inbox(waitingFor text: String, seconds: Double = 10) async -> [String] {
            let end = Date().addingTimeInterval(seconds)
            var topics: [String] = []
            repeat {
                // The Inbox as a window shows it, or as its file says.
                let open = Integrations.shared.openDocument(TouchLibrary.inboxURL)?.document.store.model
                if let c = (open ?? (try? NexusPackage.read(from: TouchLibrary.inboxURL)))?.orderedCanvases.first {
                    topics = c.nodes[c.root]?.children.compactMap { c.nodes[$0]?.text } ?? []
                    if topics.contains(text) { return topics }
                }
                try? await Task.sleep(for: .milliseconds(100))
            } while Date() < end
            return topics
        }

        @Test func aShareCaptureLandsInTheInbox() async throws {
            let group = try #require(AppGroup.container, "the App Group's container")
            let text = "Shared \(UUID().uuidString.prefix(6))"
            try CaptureQueue.enqueue(Capture(kind: .text, text: text), in: group)
            Integrations.shared.drainCaptures()
            #expect(await inbox(waitingFor: text).contains(text))
            #expect(CaptureQueue.drain(in: group).isEmpty, "the queue is emptied")

            // The Inbox widget lists it.
            Integrations.shared.refreshWidgets()
            #expect(WidgetSnapshot.read(from: group)?.inbox.contains(text) == true)
        }

        @Test func theShortcutsActionsRun() async throws {
            #expect(Preferences.shared.bool("integrations.shortcuts"), "on by default")
            let add = AddIdeaToInbox()
            let idea = "Idea \(UUID().uuidString.prefix(6))"
            add.idea = idea
            _ = try await add.perform()
            #expect(await inbox(waitingFor: idea).contains(idea))

            let doc = nodeStyleSampleDocument(theme: "classic", style: "soft")
            let json = Data(DocumentJSON.export(doc).utf8)
            let mermaid = ConvertMapToMermaid()
            mermaid.map = IntentFile(data: json, filename: "Launch plan.nexusjson")
            let text = try await mermaid.perform().value ?? ""
            #expect(text.hasPrefix("mindmap"))
            #expect(text.contains("Pricing"))

            let png = ExportCanvasAsPNG()
            png.map = IntentFile(data: json, filename: "Launch plan.nexusjson")
            png.scale = 1
            let file = try #require(try await png.perform().value)
            #expect(file.filename == "Launch plan.png")
            #expect(UIImage(data: file.data).map { $0.size.width > 100 } == true)
        }

        @Test func theIPadLeavesOutTheMacsOwnSettings() {
            let keys = SettingsSchema.shown.flatMap { $0.sections.flatMap { $0.rows.map(\.key) } }
            #expect(!keys.contains { SettingsSchema.macOnly.contains($0) })
            #expect(SettingsSchema.pane("general")?.sections.contains { $0.title == "Updates" } == false)
            #expect(SettingsSchema.pane("integrations")?.sections.contains { $0.title == "iPadOS" } == true)
            #expect(SettingsSchema.search("updates channel").isEmpty, "search finds only what's shown")
        }

        /// Home lists the folders of recent maps, but not the app's own folder, where the
        /// Inbox lives: Files can't show it.
        @Test func theInboxFolderIsntALocation() throws {
            TouchLibrary.ensureInbox()
            let other = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString).nexus")
            try NexusPackage.write(nodeStyleSampleDocument(theme: "classic", style: "soft"), to: other)
            let m = HomeModel()
            m.load([TouchLibrary.inboxURL, other])
            #expect(m.recents.count == 2)
            #expect(
                m.locations.map(\.standardizedFileURL.path) == [
                    other.deletingLastPathComponent().standardizedFileURL.path
                ])
        }

        /// A synced folder replaces a map that's open with an edit not yet saved: the change
        /// merges, the edit stays, and both are saved. `UIDocument` would revert to the file
        /// once the writer is done (D409); `LiveTests` does this with the Mac's own save.
        @Test func aChangeMadeElsewhereMergesWithAnUnsavedEdit() async throws {
            let dir = FileManager.default.temporaryDirectory.appending(path: "merge-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: "Plan.nexus")
            let model = nodeStyleSampleDocument(theme: "classic", style: "soft")
            try await TouchDocument.create(at: url, model: model).close()
            // Elsewhere, a topic under Pricing.
            var other = model
            var e = CanvasEditor(other.canvases["c1"]!)
            let pricing = try #require(e.canvas.nodes.first { $0.value.text == "Pricing" }?.key)
            try e.addChild(of: pricing, text: "Elsewhere idea")
            other.canvases["c1"] = e.canvas
            let copy = dir.appending(path: "elsewhere.nexus")
            try NexusPackage.directoryWrapper(from: NexusPackage.files(for: other)).write(
                to: copy, options: .atomic, originalContentsURL: nil)

            let doc = TouchDocument(fileURL: url)
            #expect(await doc.open())
            let controller = CanvasController(store: doc.store)
            controller.host = MemoryCanvasHost()
            var merged: [String]?
            doc.onMerged = { merged = $0 }
            let channels = doc.store.model.canvases["c1"]?.nodes.first { $0.value.text == "Channels" }?.key
            controller.select(try #require(channels))
            controller.addChild()
            controller.editorTextDidChange("Unsaved idea")
            controller.commitEdit()
            try await LiveTests.waitFor("the edit marks the document changed", seconds: 5) { doc.hasUnsavedChanges }

            // The folder's copy lands from another thread, as a sync process writes it.
            let error = await Task.detached { () -> String? in
                var error: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(
                    writingItemAt: url, options: .forReplacing, error: &error
                ) { u in
                    _ = try? FileManager.default.replaceItemAt(u, withItemAt: copy)
                }
                return error?.localizedDescription
            }.value
            #expect(error == nil)
            try await LiveTests.waitFor("the change merges", seconds: 10) { merged != nil }
            // `UIDocument` asks to revert once the writer is done; wait for it to be handled.
            let written = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let end = ContinuousClock.now + .seconds(3)
            while doc.fileModificationDate != written, ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(20))
            }
            let both: Set = ["Unsaved idea", "Elsewhere idea"]
            #expect(Set(doc.store.model.canvases["c1"]!.nodes.values.map(\.text)).isSuperset(of: both))
            #expect(await doc.save(to: url, for: .forOverwriting))
            await doc.close()
            let saved = try NexusPackage.read(from: url)
            #expect(Set(saved.canvases["c1"]!.nodes.values.map(\.text)).isSuperset(of: both))
        }

        @Test func spotlightGetsAnItemPerTopic() {
            let doc = nodeStyleSampleDocument(theme: "classic", style: "soft")
            let url = URL(fileURLWithPath: "/tmp/Launch plan.nexus")
            let items = Integrations.searchableItems(doc, url: url)
            let c = doc.orderedCanvases[0]
            #expect(items.count == c.nodes.count)
            let pricing = items.first { $0.attributeSet.title == "Pricing" }
            // The file, then the canvas and the topics above.
            #expect(pricing?.attributeSet.contentDescription == "Launch plan.nexus › Launch plan")
            let free = items.first { $0.attributeSet.title == "Free" }
            #expect(free?.attributeSet.contentDescription == "Launch plan.nexus › Launch plan › Pricing")
            let domain = Integrations.token(url)
            #expect(
                items.allSatisfy { $0.domainIdentifier == domain && $0.uniqueIdentifier.hasPrefix("\(domain)|c1|") })
        }
    }
}
