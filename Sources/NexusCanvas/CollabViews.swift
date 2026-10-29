#if os(macOS)
import AppKit
import NexusCore
import NexusReplica
import NexusScene
import NexusTheme
import QuartzCore
import SwiftUI

// MARK: Collaborate… sheet (⌃⌘L, M46)

struct CollabSheetView: View {
    var controller: CanvasController

    var body: some View {
        if let s = controller.collabSheet {
            CollabSheet(controller: controller, state: s, session: controller.collabSession)
        }
    }
}

private struct CollabSheet: View {
    var controller: CanvasController
    let state: CollabSheetState
    var session: CollabSession?

    func set(_ body: (inout CollabSheetState) -> Void) {
        var s = state
        body(&s)
        controller.setCollab(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Collaborate").font(.chrome(18, weight: .semibold))
                Text("Labs").font(.chrome(11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().stroke(.separator))
                Spacer()
                Text("File › Collaborate… ⌃⌘L").font(.chrome(12, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            if let session {
                live(session)
            } else {
                setup
            }
        }
        .frame(width: 600)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Collaborate")
    }

    var access: some View {
        FileSegments(
            items: [(true, Loc.t("Can edit")), (false, Loc.t("Can view"))],
            selection: Binding(get: { state.canEdit }, set: { v in set { $0.canEdit = v } })
        )
        .frame(width: 240)
        .accessibilityLabel("People with the link")
    }

    // MARK: Before the session

    var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Edit this document with others at the same time. Changes travel sealed through your OpenNexus Server, which can’t read them."
                )
                .font(.chrome(13.5))
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 24) {
                    labelled(Loc.t("Server")) {
                        Picker(
                            "", selection: Binding(get: { state.server ?? "" }, set: { v in set { $0.server = v } })
                        ) {
                            ForEach(controller.collabCenter.servers) { d in Text(d.name).tag(d.id) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .accessibilityLabel("Server")
                    }
                    labelled(Loc.t("People with the link")) { access }
                }
                if case .failed(let why) = state.phase {
                    Text(why).font(.chrome(12.5)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            Divider()
            HStack(spacing: 10) {
                if state.phase == .working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { controller.closeCollab() }.buttonStyle(FileButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Start") { Task { await controller.startCollab() } }
                    .buttonStyle(FileButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.server == nil || state.phase == .working)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    // MARK: During the session

    func live(_ session: CollabSession) -> some View {
        let link = controller.inviteLink(canEdit: state.canEdit) ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                if let qr = QRCode.image(link) {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                        .frame(width: 148, height: 148)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                        .accessibilityLabel("QR code of the invite link")
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        CollabStatusPill(session: session)
                        Spacer()
                        if session.invite.canEdit { access }
                    }
                    Text(link)
                        .font(.chrome(12, design: .monospaced))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .accessibilityLabel("Invite link")
                    Text(
                        state.canEdit && session.invite.canEdit
                            ? Loc.t("Anyone with this link can edit while the session lasts.")
                            : Loc.t("Anyone with this link can watch while the session lasts.")
                    )
                    .font(.chrome(12.5)).foregroundStyle(.secondary)
                    people(session)
                }
            }
            .padding(20)
            Divider()
            HStack(spacing: 10) {
                if let url = URL(string: link) {
                    ShareLink(item: url) { Text("Share…") }.buttonStyle(FileButtonStyle())
                }
                Button("Copy Link") { controller.copyInvite(canEdit: state.canEdit) }.buttonStyle(FileButtonStyle())
                Spacer()
                if session.isHost {
                    Button("End Session") { Task { await controller.endCollab() } }.buttonStyle(FileButtonStyle())
                } else {
                    Button("Leave Session") { controller.leaveCollab() }.buttonStyle(FileButtonStyle())
                }
                Button("Done") { controller.closeCollab() }
                    .buttonStyle(FileButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    func people(_ session: CollabSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Here now").font(.chrome(13, weight: .medium))
            HStack(spacing: 8) {
                PersonDot(name: controller.collabCenter.myName, colour: Presence.colour(for: session.client.replica.id))
                Text(Loc.f("%@ (you)", controller.collabCenter.myName)).font(.chrome(12.5))
            }
            ForEach(session.people) { p in
                HStack(spacing: 8) {
                    PersonDot(name: p.name, colour: p.colour)
                    Text(p.name).font(.chrome(12.5))
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    func labelled(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.chrome(14, weight: .medium))
            content()
        }
    }
}

// MARK: Join Session…

struct JoinSheetView: View {
    var controller: CanvasController

    var body: some View {
        if let s = controller.joinSheet {
            VStack(alignment: .leading, spacing: 0) {
                Text("Join Session").font(.chrome(18, weight: .semibold)).padding(18)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Paste the invite link someone sent you.").font(.chrome(13.5))
                    TextField(
                        "https://…/join/#2.…",
                        text: Binding(
                            get: { s.link },
                            set: { v in
                                var n = s
                                n.link = v
                                n.error = nil
                                controller.setJoin(n)
                            })
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.chrome(12.5, design: .monospaced))
                    .accessibilityLabel("Invite link")
                    if let e = s.error {
                        Text(e).font(.chrome(12.5)).foregroundStyle(.red)
                    }
                }
                .padding(20)
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { controller.closeJoin() }.buttonStyle(FileButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Join") { controller.joinSession() }
                        .buttonStyle(FileButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(s.link.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(16)
            }
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Join Session")
        }
    }
}

/// Why Collaborate… or Join Session… can't open.
struct CollabNoticeView: View {
    var controller: CanvasController

    var body: some View {
        if let n = controller.collabNotice {
            VStack(alignment: .leading, spacing: 0) {
                Text(n == .networkOff ? Loc.t("Live sessions use the network") : Loc.t("No server to meet on yet"))
                    .font(.chrome(18, weight: .semibold))
                    .padding(18)
                Divider()
                Text(
                    n == .networkOff
                        ? Loc.t(
                            "OpenNexus doesn’t use the network unless you turn it on. Turn on “Use the network” and “Live co-editing” in Settings › Privacy & Data."
                        )
                        : Loc.t(
                            "Live sessions meet on your own OpenNexus Server. Add one in Settings › Sharing; what you edit is sealed before it leaves this Mac."
                        )
                )
                .font(.chrome(14))
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { controller.closeCollabNotice() }.buttonStyle(FileButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Open Settings…") {
                        controller.closeCollabNotice()
                        controller.onOpenSettings?(n == .networkOff ? "privacy" : "sharing")
                    }
                    .buttonStyle(FileButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
            .frame(width: 500)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Collaborate")
        }
    }
}

// MARK: The toolbar's avatars and status

/// The window toolbar's live-session item: who's here (click to follow) and the status pill.
/// Empty when the document isn't in a session.
public struct CollabToolbarView: View {
    var controller: CanvasController

    public init(controller: CanvasController) { self.controller = controller }

    public var body: some View {
        let _ = controller.presenceSerial
        if let session = controller.collabSession {
            HStack(spacing: 6) {
                HStack(spacing: -6) {
                    ForEach(session.people.prefix(5)) { p in
                        Button {
                            controller.follow(p.id)
                        } label: {
                            PersonDot(name: p.name, colour: p.colour, ring: controller.following == p.id)
                        }
                        .buttonStyle(.plain)
                        .help(Loc.f("Follow %@", p.name))
                        .accessibilityLabel(Loc.f("Follow %@", p.name))
                    }
                }
                Button {
                    controller.openCollaborate()
                } label: {
                    CollabStatusPill(session: session)
                }
                .buttonStyle(.plain)
                .help(Loc.t("Collaborate…"))
            }
        }
    }
}

/// "Live · 3 people", "Reconnecting…", "Offline · changes wait".
struct CollabStatusPill: View {
    var session: CollabSession

    var colour: Color {
        switch session.status {
        case .live: .green
        case .connecting, .reconnecting: .orange
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(session.statusText).font(.chrome(12, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(Capsule().stroke(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Loc.f("Live session: %@", session.statusText))
    }
}

/// A person's initial in their colour.
struct PersonDot: View {
    var name: String
    var colour: String
    var ring = false

    var body: some View {
        Text(String(name.first ?? "?").uppercased())
            .font(.chrome(11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color(cgColor: RGBA(hex: colour).cgColor)))
            .overlay(Circle().stroke(ring ? Color.primary : Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            .accessibilityLabel(name)
    }
}

// MARK: Marks on the canvas

/// Other people's selection rings, name tags and editing marks, in canvas coordinates (a
/// layer of the canvas's world, so they move with it). Tags keep their size at any zoom.
final class PresenceLayer: CALayer {
    override init() {
        super.init()
        actions = NodeLayer.noActions
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { sublayers?.isEmpty ?? true }

    func update(_ marks: [PresenceMark], frame: (NodeID) -> CGRect?, zoom: CGFloat, scale: CGFloat) {
        sublayers?.forEach { $0.removeFromSuperlayer() }
        let k = 1 / max(zoom, 0.05)
        // Two people on one topic: rings stack outwards.
        var depth: [NodeID: Int] = [:]
        for m in marks {
            let colour = RGBA(hex: m.colour)
            for id in m.selection {
                guard let r = frame(id) else { continue }
                let d = depth[id, default: 0]
                depth[id] = d + 1
                let ring = CAShapeLayer()
                ring.actions = NodeLayer.noActions
                let pad = (4 + CGFloat(d) * 4) * k
                ring.path = CGPath(
                    roundedRect: r.insetBy(dx: -pad, dy: -pad), cornerWidth: 8 * k, cornerHeight: 8 * k,
                    transform: nil)
                ring.fillColor = nil
                ring.strokeColor = colour.cgColor
                ring.lineWidth = 2 * k
                if m.editing == id {
                    ring.lineDashPattern = [NSNumber(value: Double(6 * k)), NSNumber(value: Double(4 * k))]
                }
                addSublayer(ring)
            }
            guard let anchor = m.editing ?? m.selection.first, let r = frame(anchor) else { continue }
            let tag = CATextLayer()
            tag.actions = NodeLayer.noActions
            let text = m.editing != nil ? "\(m.name) ✎" : m.name
            let font = NSFont.chrome(11, weight: .semibold)
            let w = (text as NSString).size(withAttributes: [.font: font]).width + 12
            tag.string = NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
            tag.alignmentMode = .center
            tag.contentsScale = scale * max(1, zoom)
            tag.backgroundColor = colour.cgColor
            tag.cornerRadius = 4
            tag.bounds = CGRect(x: 0, y: 0, width: w, height: 17)
            tag.anchorPoint = CGPoint(x: 0, y: 1)
            let pad = 4 * k
            tag.position = CGPoint(x: r.minX - pad, y: r.minY - pad - 2 * k)
            tag.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
            addSublayer(tag)
        }
    }
}
#endif
