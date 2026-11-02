import CoreGraphics
import Foundation
import NexusCore
import NexusFormat
import NexusReplica
import NexusScene

/// File › Collaborate… (M46): which server, and what the invite link lets people do.
public struct CollabSheetState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case setup
        case working
        case failed(String)
    }

    public var server: String?
    /// The invite to hand out: editing, or view only.
    public var canEdit = true
    public var phase = Phase.setup

    public init(server: String? = nil) { self.server = server }
}

/// File › Join Session…: the pasted invite link.
public struct JoinSheetState: Equatable, Sendable {
    public var link = ""
    public var error: String?

    public init() {}
}

/// Another person's marks on this canvas: a ring on what they've selected, their name
/// tag, and an editing mark on the topic they're typing in.
public struct PresenceMark: Equatable, Sendable {
    public var member: String
    public var name: String
    public var colour: String
    public var selection: [NodeID]
    public var editing: NodeID?
}

extension CanvasController {
    public var collabSession: CollabSession? { store.collab as? CollabSession }

    // MARK: Collaborate…

    /// File › Collaborate…: the sheet, or why it can't open (the network is off, or there's
    /// no OpenNexus Server to meet on).
    public func openCollaborate() {
        if mode == .edit { commitEdit() }
        if !collabCenter.networkOn {
            collabNotice = .networkOff
            return
        }
        if collabSession == nil, collabCenter.servers.isEmpty {
            collabNotice = .noServer
            return
        }
        var s = CollabSheetState(server: collabCenter.servers.first?.id)
        if let session = collabSession {
            s.server = collabCenter.servers.first { $0.server == session.invite.server }?.id
            s.canEdit = session.invite.canEdit
        }
        collabSheet = s
    }

    public func setCollab(_ s: CollabSheetState) { collabSheet = s }

    public func closeCollab() {
        collabSheet = nil
        onRestoreFocus?()
    }

    public func closeCollabNotice() {
        collabNotice = nil
        onRestoreFocus?()
    }

    /// Start: creates the room on the chosen server and puts this document in it.
    public func startCollab() async {
        guard var s = collabSheet, collabSession == nil, let documentID = documentIDProvider?(),
            let server = collabCenter.servers.first(where: { $0.id == s.server })
        else { return }
        if mode == .edit { commitEdit() }
        s.phase = .working
        collabSheet = s
        do {
            let session = try await collabCenter.start(store: store, documentID: documentID, server: server)
            attach(session)
            collabSheet?.phase = .setup
        } catch {
            collabSheet?.phase = .failed("\(error)")
        }
    }

    /// Wires a session to this canvas (presence, announcements), then the app's part.
    public func attach(_ session: CollabSession) {
        session.announce = { [weak self] text in self?.onAnnounce?(text) }
        session.onPresenceChange = { [weak self] in self?.peopleChanged() }
        session.onRefused = { [weak self] why in self?.showToast(why) }
        session.makeView = { [weak self] in self?.collabViewBundle() ?? .object([:]) }
        onCollabAttached?(session)
        presenceDidChange()
        peopleChanged()
    }

    /// The join page's read-only view: the whole document, as Interactive HTML shows it.
    func collabViewBundle() -> JSONValue {
        var e = ExportState.remembered(.html, prefs: prefs)
        e.html.document = true
        e.image.scope = .canvas
        return ViewerBundle.build(exportModel(e), viewerOptions(e), prefs: prefs)
    }

    /// The invite to hand out: with editing (when this person may edit), or view only.
    public func inviteLink(canEdit: Bool) -> String? {
        guard let s = collabSession else { return nil }
        let invite = canEdit && s.invite.canEdit ? s.invite : s.invite.viewOnly
        return invite.link(viewer: shareCenter.viewer)
    }

    public func copyInvite(canEdit: Bool) {
        guard let link = inviteLink(canEdit: canEdit) else { return }
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        showToast(canEdit ? Loc.t("Copied the invite link") : Loc.t("Copied the view-only invite link"))
    }

    /// End Session (the host): ends it for everyone, and the server deletes what it kept.
    public func endCollab() async {
        guard let s = collabSession else { return }
        await collabCenter.end(s)
        collabEnded(Loc.t("Ended the live session · this document is yours alone again"))
    }

    /// Leave Session: the session goes on without this person; the document stays as it is.
    public func leaveCollab() {
        guard let s = collabSession else { return }
        collabCenter.leave(s)
        collabEnded(Loc.t("Left the live session · this copy stays as it is"))
    }

    /// The session is over here (ended, left or refused): its undo history goes too.
    public func collabEnded(_ why: String) {
        collabSheet = nil
        following = nil
        announcedEditors = []
        onCollabEnded?()
        showToast(why)
        presenceSerial += 1
        onPresence?()
    }

    // MARK: Join Session…

    public func openJoinSession() {
        if mode == .edit { commitEdit() }
        if !collabCenter.networkOn {
            collabNotice = .networkOff
            return
        }
        joinSheet = JoinSheetState()
    }

    public func setJoin(_ s: JoinSheetState) { joinSheet = s }

    public func closeJoin() {
        joinSheet = nil
        onRestoreFocus?()
    }

    /// Joins from a pasted invite link: the app opens the session's copy.
    public func joinSession() {
        guard var s = joinSheet else { return }
        let link = s.link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Invite(link: link) != nil else {
            s.error = CollabCenter.Failure.badInvite.description
            joinSheet = s
            return
        }
        joinSheet = nil
        onJoinSession?(link)
    }

    // MARK: Presence

    /// Everyone else's marks on this canvas.
    public var presenceMarks: [PresenceMark] {
        guard let session = collabSession else { return [] }
        return session.people.compactMap { p in
            guard let pr = p.presence, pr.canvas == canvasID.rawValue else { return nil }
            return PresenceMark(
                member: p.id, name: p.name, colour: p.colour, selection: pr.selection.map { NodeID($0) },
                editing: pr.editing.map { NodeID($0) })
        }
    }

    /// The people editing `node` now (not this person).
    public func editors(of node: NodeID) -> [String] {
        collabSession?.editors(of: node, on: canvasID).map(\.name) ?? []
    }

    /// Tells the session where this person is: canvas, selection, the topic being typed in, and the view.
    func presenceDidChange() {
        guard let s = collabSession else { return }
        s.setPresence(canvas: canvasID, selection: selection.nodes, editing: edit?.node, viewport: viewport)
    }

    /// Typing in a topic someone else is typing in: a gentle hint (the later edit wins).
    func editingDidChange() {
        presenceDidChange()
        guard let node = edit?.node else { return }
        let others = editors(of: node)
        if !others.isEmpty {
            showToast(Loc.f("%@ is editing this topic too", ListFormatter.localizedString(byJoining: others)))
        }
    }

    /// Someone's presence changed: marks redraw, a followed view moves, and VoiceOver hears
    /// who is now editing the focused topic.
    func peopleChanged() {
        presenceSerial += 1
        if let f = following, collabSession?.people.contains(where: { $0.id == f }) != true { following = nil }
        if let f = following, let p = collabSession?.people.first(where: { $0.id == f })?.presence,
            let c = p.canvas.map({ CanvasID($0) }), c != canvasID, store.canvas(c) != nil
        {
            switchCanvas(to: c)
        }
        let now = editors(of: selection.primary)
        let added = now.filter { !announcedEditors.contains($0) }
        announcedEditors = now
        if !added.isEmpty {
            onAnnounce?(
                Loc.f("%@ is editing the focused topic", ListFormatter.localizedString(byJoining: added)))
        }
        onPresence?()
    }

    /// Clicking an avatar: this view follows that person's until you scroll or click.
    public func follow(_ member: String?) {
        following = member == following ? nil : member
        if let m = following, let name = collabSession?.people.first(where: { $0.id == m })?.name {
            showToast(Loc.f("Following %@ · scroll or click to stop", name))
        }
        peopleChanged()
    }

    public func stopFollowing() {
        guard following != nil else { return }
        following = nil
    }

    /// The followed person's view on this canvas, in canvas coordinates.
    public var followedViewport: CGRect? {
        guard let f = following, let p = collabSession?.people.first(where: { $0.id == f })?.presence,
            p.canvas == canvasID.rawValue, let v = p.viewport, v.count == 4, v[2] > 0, v[3] > 0
        else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
}
