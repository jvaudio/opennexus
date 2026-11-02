import AppKit
import Foundation
import NexusFormat
import NexusKeys
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusReplica
@testable import NexusScene

/// Creates and ends rooms on the in-memory relay, as `OpenNexusNet.xpc` does on a server.
struct RelayTransport: ShareTransport {
    let relay: MemoryRelay

    func perform(_ job: NetJob, body: Data) async -> NetReply {
        switch job.action {
        case .createRoom:
            guard case .object(let o)? = try? CanonicalJSON.parse(body), case .string(let read)? = o["read"],
                case .string(let write)? = o["write"]
            else { return .failed("bad body") }
            return NetReply(ok: true, object: relay.createRoom(digests: read, write))
        case .endRoom:
            relay.end(job.object ?? "")
            return NetReply(ok: true)
        default:
            return .failed("unexpected \(job.action)")
        }
    }
}

/// One Mac in a live session: its settings, Keychain, container and an open document.
@MainActor
final class CollabMac {
    static let server: ShareDestination = {
        var d = ShareDestination(id: "server", kind: .server, name: "Our server")
        d.server = "https://relay.example/"
        return d
    }()

    let name: String
    let prefs = Preferences.isolated()
    let share: ShareCenter
    let center: CollabCenter
    var harness: CanvasHarness?
    var documentID = UUID().uuidString
    var announcements: [String] = []

    convenience init(_ name: String, relay: MemoryRelay) {
        self.init(
            name, transport: RelayTransport(relay: relay), connector: relay, server: Self.server, token: "upload-token")
    }

    init(
        _ name: String, transport: any ShareTransport, connector: any RoomConnector, server: ShareDestination,
        token: String
    ) {
        self.name = name
        prefs.set("network.enabled", true)
        prefs.set("network.collab", true)
        prefs.set("editing.commentAuthor", name)
        share = ShareCenter(
            store: ShareStore(file: nil), log: NetworkLog(file: nil), secrets: MemorySecrets(), transport: transport,
            prefs: prefs)
        share.saveDestination(server, secret: token)
        center = CollabCenter(
            directory: FileManager.default.temporaryDirectory.appending(path: "collab-\(UUID().uuidString)"),
            share: share, prefs: prefs)
        center.connector = connector
        center.saveDelay = .milliseconds(5)
    }

    var controller: CanvasController { harness!.controller }
    var store: DocumentStore { harness!.store }
    var session: CollabSession? { controller.collabSession }

    /// Opens `model` in a window, as the app does (the document id comes with it).
    func open(_ model: DocumentModel) {
        let h = CanvasHarness(model: model)
        h.controller.prefs = prefs
        h.controller.shareCenter = share
        h.controller.collabCenter = center
        if case .string(let id)? = model.manifestExtra["documentID"] { documentID = id }
        h.controller.documentIDProvider = { [unowned self] in documentID }
        h.controller.onAnnounce = { [unowned self] in announcements.append($0) }
        harness = h
    }

    /// File › Collaborate… › Start.
    func start(canEdit: Bool = true) async throws -> CollabSession {
        controller.openCollaborate()
        var s = try #require(controller.collabSheet)
        s.canEdit = canEdit
        controller.setCollab(s)
        await controller.startCollab()
        let session = try #require(controller.collabSession)
        session.viewDelay = .milliseconds(20)
        return session
    }

    /// An invite link: the session's copy opens here once it arrives.
    func join(_ link: String) async throws {
        let s = try center.join(link)
        s.onReady = { [unowned self] model in
            open(model)
            if let bound = center.resume(store: store, documentID: documentID) { controller.attach(bound) }
        }
        try await waitUntil("\(name) opened the session's copy") { self.harness != nil }
    }

    /// Typing a topic's new text, as the editor commits it.
    func rename(_ id: NodeID, _ text: String) {
        controller.beginEditing(id)
        controller.editorTextDidChange(text)
        controller.commitEdit()
    }

    func text(_ id: NodeID) -> String? { store.model.canvases["c1"]?.nodes[id]?.text }
}

@MainActor
func waitUntil(_ what: String, seconds: Double = 2, _ check: @MainActor () -> Bool) async throws {
    for _ in 0..<Int(seconds * 200) where !check() { try await Task.sleep(for: .milliseconds(5)) }
    #expect(check(), "timed out: \(what)")
    if !check() { throw CancellationError() }
}

/// The shared part of a document as canonical bytes (canvases, tab order, theme, asset names).
func sharedCanonical(_ doc: DocumentModel) -> String {
    var out = "order: \(doc.canvasOrder.map(\.rawValue))\n"
    for id in doc.canvasOrder {
        if let c = doc.canvases[id] { out += CanonicalJSON.string(c.json) }
    }
    out += CanonicalJSON.string(doc.theme)
    return out + "assets: \(doc.assets.keys.sorted())\n"
}

@MainActor
@Suite(.serialized) struct CollabTests {
    let relay = MemoryRelay()

    /// Two Macs in one session: Ana hosts the launch plan, Ben joins from the invite.
    func pair() async throws -> (CollabMac, CollabMac) {
        let a = CollabMac("Ana", relay: relay)
        a.open(launchPlanDocument())
        let s = try await a.start()
        let link = try #require(a.controller.inviteLink(canEdit: true))
        #expect(link.hasPrefix(ShareCenter.defaultViewer + "join/#2."))
        let b = CollabMac("Ben", relay: relay)
        try await b.join(link)
        try await waitUntil("Ben sees Ana") { b.session?.people.count == 1 && s.people.count == 1 }
        return (a, b)
    }

    func topic(_ m: CollabMac, _ text: String) throws -> NodeID {
        try #require(m.store.model.canvases["c1"]?.nodes.first { $0.value.text == text }?.key)
    }

    // MARK: Editing together

    @Test func aJoinerGetsTheDocumentAndEditsFlowBothWays() async throws {
        let (a, b) = try await pair()
        #expect(sharedCanonical(a.store.model) == sharedCanonical(b.store.model))
        // The copy knows its session; a new topic's id carries its replica's suffix.
        #expect(b.store.model.idSuffix == b.session?.client.replica.idSuffix)
        let pricing = try topic(a, "Pricing")
        b.rename(pricing, "Pricing v2")
        try await waitUntil("Ana sees Ben's rename") { a.text(pricing) == "Pricing v2" }
        a.controller.select(pricing)
        a.controller.addChild()
        a.controller.editorTextDidChange("Annual plan")
        a.controller.commitEdit()
        try await waitUntil("Ben sees Ana's topic") { sharedCanonical(a.store.model) == sharedCanonical(b.store.model) }
        let added = try topic(b, "Annual plan")
        #expect(added.rawValue.hasSuffix(a.session!.client.replica.idSuffix))
        // The Collaborate sheet redraws as people come and go: its QR code is made once.
        let invite = try #require(a.controller.inviteLink(canEdit: true))
        let qr = try #require(QRCode.image(invite))
        #expect(QRCode.image(invite) === qr)
        // The join page's view: the host's viewer bundle, sealed with the session's key.
        let session = try #require(a.session)
        let current = a.controller.collabViewBundle()
        try await waitUntil("the view catches up") {
            relay.room(session.invite.room)?.view.flatMap {
                try? Sealed.openBundle($0, key: session.invite.symmetricKey).bundle
            } == current
        }
    }

    /// Someone else's edit is drawn without moving this person's canvas, selection or camera,
    /// and never lands in their undo.
    @Test func remoteEditsStayOutOfUndoAndLeaveTheViewAlone() async throws {
        let (a, b) = try await pair()
        let harness = try #require(a.harness)
        let pricing = try topic(a, "Pricing")
        let launch = a.store.model.canvases["c1"]!.root
        a.controller.select(launch)
        let undoBefore = harness.undo.stack.canUndo
        let camera = harness.host.canvasView.camera
        b.rename(pricing, "Pricing (Ben)")
        try await waitUntil("Ana sees the rename") { a.text(pricing) == "Pricing (Ben)" }
        #expect(harness.undo.stack.canUndo == undoBefore)
        #expect(a.controller.selection.primary == launch && a.controller.canvasID == "c1")
        #expect(harness.host.canvasView.camera == camera)
        // A canvas Ben adds doesn't take Ana there.
        b.controller.addCanvas(Canvas(id: b.store.model.makeCanvasID(), title: "Ben's notes"))
        try await waitUntil("Ana gets the canvas") { a.store.model.canvasOrder.count == 2 }
        #expect(a.controller.canvasID == "c1")
    }

    /// ⌘Z in a session is selective: Ana's undo puts back her own change, but not where Ben
    /// changed the same thing since.
    @Test func undoNeverRevertsSomeoneElsesLaterChange() async throws {
        let (a, b) = try await pair()
        let pricing = try topic(a, "Pricing")
        let goals = try topic(a, "Channels")
        a.rename(pricing, "Pricing (Ana)")
        a.rename(goals, "Channels (Ana)")
        try await waitUntil("Ben has both") { b.text(goals) == "Channels (Ana)" }
        b.rename(pricing, "Pricing (Ben)")
        try await waitUntil("Ana has Ben's") { a.text(pricing) == "Pricing (Ben)" }
        let session = try #require(a.session)
        #expect(session.undo())  // Goals
        #expect(a.text(goals) == "Channels")
        #expect(session.undo())  // Pricing: Ben's later change stays
        #expect(a.text(pricing) == "Pricing (Ben)")
        try await waitUntil("Ben sees the undo") { b.text(goals) == "Channels" }
        #expect(b.text(pricing) == "Pricing (Ben)")
        #expect(session.redo())
        #expect(session.redo())
        #expect(a.text(goals) == "Channels (Ana)")
        try await waitUntil("converged") { sharedCanonical(a.store.model) == sharedCanonical(b.store.model) }
    }

    @Test func viewOnlyInvitesTurnEditsAway() async throws {
        let a = CollabMac("Ana", relay: relay)
        a.open(launchPlanDocument())
        _ = try await a.start()
        let link = try #require(a.controller.inviteLink(canEdit: false))
        #expect(Invite(link: link)?.write == nil)
        let v = CollabMac("Vic", relay: relay)
        try await v.join(link)
        let session = try #require(v.session)
        #expect(!session.canEdit)
        let pricing = try topic(v, "Pricing")
        let before = sharedCanonical(v.store.model)
        v.rename(pricing, "Nope")
        #expect(sharedCanonical(v.store.model) == before)
        #expect(v.controller.toast?.text == "This session is view only: your changes aren’t kept")
        // The relay would refuse them too.
        session.client.send([Op(Stamp(time: 1, count: 0, replica: "x"), .set(.canvas("c1", "title"), .string("Nope")))])
        try await waitUntil("refused") { session.refusal != nil }
        #expect(a.text(pricing) == "Pricing")
    }

    // MARK: Presence and accessibility (A7)

    @Test func presenceShowsRingsNameTagsAndEditingMarks() async throws {
        let (a, b) = try await pair()
        let pricing = try topic(a, "Pricing")
        // "Joined" lists Ben; his presence, which announces him, follows it.
        try await waitUntil("Ana hears Ben join") { a.announcements.contains("Ben joined") }
        a.controller.select(pricing)
        b.controller.select(pricing)
        b.controller.beginEditing(pricing)
        try await waitUntil("Ana sees Ben editing") { a.controller.presenceMarks.first?.editing == pricing }
        let mark = try #require(a.controller.presenceMarks.first)
        #expect(mark.name == "Ben" && mark.selection == [pricing])
        #expect(mark.colour == Presence.colour(for: b.session!.client.replica.id))
        // A dashed ring and a "Ben ✎" tag on the canvas.
        let layers = a.harness!.host.canvasView.presence.sublayers ?? []
        let ring = try #require(layers.compactMap { $0 as? CAShapeLayer }.first)
        #expect(ring.lineDashPattern != nil)
        let tag = try #require(layers.compactMap { $0 as? CATextLayer }.first)
        #expect((tag.string as? NSAttributedString)?.string == "Ben ✎")
        // VoiceOver hears who is editing the focused topic, and the toolbar's avatars show.
        #expect(a.announcements.contains("Ben is editing the focused topic"))
        #expect(a.controller.editors(of: pricing) == ["Ben"])
        // Typing in the same topic: a gentle hint.
        a.controller.beginEditing(pricing)
        #expect(a.controller.toast?.text == "Ben is editing this topic too")
        a.controller.commitEdit()
        b.controller.commitEdit()
        try await waitUntil("the editing mark goes") { a.controller.presenceMarks.first?.editing == nil }
        // Ben leaves: announced, and his marks go.
        b.controller.leaveCollab()
        try await waitUntil("Ana hears Ben leave") { a.announcements.contains("Ben left") }
        #expect(a.controller.presenceMarks.isEmpty)
        #expect(b.store.collab == nil && b.store.model.idSuffix.isEmpty)
    }

    @Test func clickingAnAvatarFollowsThatView() async throws {
        let (a, b) = try await pair()
        let ben = try #require(a.session?.people.first?.id)
        a.controller.follow(ben)
        b.harness!.host.canvasView.setCamera(Camera(offset: CGPoint(x: -400, y: -300), zoom: 1.5), animated: false)
        try await waitUntil("Ana's view follows") { a.controller.followedViewport == b.controller.viewport }
        try await waitUntil("Ana's camera moved") { a.harness!.host.canvasView.camera.zoom == 1.5 }
        a.controller.stopFollowing()
        #expect(a.controller.following == nil)
    }

    /// Key press to caret while two other people type: still under a frame (A4).
    @Test func keyToCaretWithTwoPeopleTyping() async throws {
        let (a, b) = try await pair()
        let link = try #require(a.controller.inviteLink(canEdit: true))
        let c = CollabMac("Cy", relay: relay)
        try await c.join(link)
        let h = try #require(a.harness)
        let mains = h.canvas.nodes[h.canvas.root]!.children
        let typing = Task { @MainActor in
            var i = 0
            while !Task.isCancelled {
                i += 1
                b.rename(mains[0], "Ben types \(i)")
                c.rename(mains[1], "Cy types \(i)")
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { typing.cancel() }
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for i in 0..<30 {
            h.controller.select(mains[2 + i % (mains.count - 2)])
            let d = clock.measure { h.press("tab") }
            #expect(h.controller.mode == .edit && !h.host.canvasView.editor.isHidden)
            samples.append(d)
            h.press("return")
            // Let the peers' edits arrive between presses.
            try await Task.sleep(for: .milliseconds(10))
        }
        typing.cancel()
        let m = median(samples)
        print("key→caret with two people typing: median \(ms(m)) ms, max \(ms(samples.max()!)) ms")
        #expect(ms(m) < 16, "key→caret median \(ms(m)) ms")
        try await waitUntil("three converge") {
            sharedCanonical(a.store.model) == sharedCanonical(b.store.model)
                && sharedCanonical(b.store.model) == sharedCanonical(c.store.model)
        }
    }

    // MARK: Sessions across launches (A8)

    /// Closing a document keeps its session; reopening reconnects, takes what others did
    /// meanwhile, and sends what this Mac did offline.
    @Test func closingAndReopeningResumes() async throws {
        let (a, b) = try await pair()
        let pricing = try topic(a, "Pricing")
        let goals = try topic(a, "Channels")
        a.rename(goals, "Channels (Ana)")
        try await waitUntil("saved") { a.center.record(a.documentID)?.saved.outbox.isEmpty == true }
        let file = a.store.model  // what autosave wrote
        a.center.suspend(a.documentID)
        #expect(a.store.collab == nil)
        b.rename(pricing, "Pricing (while Ana was away)")
        try await waitUntil("Ben's edit is in") { relay.room(b.session!.invite.room)?.seq ?? 0 >= 3 }
        a.open(file)
        let resumed = try #require(a.center.resume(store: a.store, documentID: a.documentID))
        a.controller.attach(resumed)
        try await waitUntil("Ana caught up") { a.text(pricing) == "Pricing (while Ana was away)" }
        #expect(a.text(goals) == "Channels (Ana)")
        // Offline: the relay drops everyone; Ana's edit waits and goes when it's back.
        relay.offline = true
        relay.dropAll()
        try await waitUntil("offline") { resumed.status == .reconnecting }
        #expect(resumed.statusText == "Reconnecting…")
        a.rename(goals, "Channels (offline)")
        #expect(resumed.statusText == "Offline · changes wait")
        relay.offline = false
        try await waitUntil("Ben gets the offline edit") { b.text(goals) == "Channels (offline)" }
        #expect(sharedCanonical(a.store.model) == sharedCanonical(b.store.model))
    }

    /// The host ends the session: the server's data goes, everyone keeps their copy.
    @Test func endingTheSessionDeletesTheRoom() async throws {
        let (a, b) = try await pair()
        let room = try #require(a.session?.invite.room)
        var ended: String?
        b.session?.onEnded = { ended = $0 }
        await a.controller.endCollab()
        #expect(relay.room(room) == nil)
        #expect(a.store.collab == nil && a.center.record(a.documentID) == nil)
        try await waitUntil("Ben hears") { ended != nil }
        #expect(ended == "The host ended the live session. This copy is yours to keep.")
        #expect(b.store.collab == nil)
    }

    // MARK: Commands and settings

    @Test func theNetworkSwitchesComeFirst() throws {
        let m = CollabMac("Ana", relay: relay)
        m.prefs.set("network.collab", false)
        m.open(launchPlanDocument())
        m.controller.openCollaborate()
        #expect(m.controller.collabNotice == .networkOff && m.controller.collabSheet == nil)
        m.controller.closeCollabNotice()
        m.controller.openJoinSession()
        #expect(m.controller.collabNotice == .networkOff && m.controller.joinSheet == nil)
        #expect(throws: CollabCenter.Failure.networkOff) { try m.center.join("https://x/join/#2.a") }
        m.prefs.set("network.collab", true)
        m.controller.openJoinSession()
        var s = try #require(m.controller.joinSheet)
        s.link = "https://example.com/not-an-invite"
        m.controller.setJoin(s)
        m.controller.joinSession()
        #expect(m.controller.joinSheet?.error == "That isn’t an OpenNexus invite link.")
    }

    @Test func collaborateAndJoinAreReachable() throws {
        let c = try #require(DefaultCommands.all.first { $0.id == .collaborate })
        #expect(c.title == "Collaborate…" && c.menu == .file)
        let j = try #require(DefaultCommands.all.first { $0.id == .joinSession })
        #expect(j.title == "Join Session…" && j.menu == .file)
        for profile in KeyProfile.all {
            #expect(
                CommandRegistry.standard.bindings(for: .collaborate, profile: profile).map(\.description) == ["⌃⌘L"],
                "\(profile.name)")
        }
        #expect(SettingsSchema.search("co-edit").first?.2.key == "network.collab")
        #expect(SettingsSchema.search("collaborate").contains { $0.2.key == "network.collab" })
        #expect(SettingsSchema.defaults["network.collab"] == .bool(false))
    }
}
