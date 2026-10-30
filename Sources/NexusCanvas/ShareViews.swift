import CoreImage
import NexusCore
import NexusFormat
import NexusScene
import NexusTheme
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: Share Link sheet (⌃⌘S, M44)

struct ShareSheetView: View {
    var controller: CanvasController

    var body: some View {
        if let s = controller.shareState {
            ShareSheet(controller: controller, state: s, center: controller.shareCenter)
        }
    }
}

private struct ShareSheet: View {
    var controller: CanvasController
    let state: ShareState
    var center: ShareCenter

    func set(_ body: (inout ShareState) -> Void) {
        var s = state
        body(&s)
        controller.setShare(s)
    }

    var canCreate: Bool {
        state.destination != nil && state.phase != .working && (!state.usePassword || state.password.count >= 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Share Link").font(.chrome(18, weight: .semibold))
                Spacer()
                Text("File › Share Link… ⌃⌘S").font(.chrome(12, design: .monospaced)).foregroundStyle(.chromeSecondary)
            }
            .padding(18)
            Divider()
            if case .done(let r) = state.phase {
                ShareResult(controller: controller, record: r, link: center.link(r) ?? "")
            } else {
                form
                Divider()
                footer
            }
        }
        .fixedWidth(640)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Share Link")
    }

    var form: some View {
        let e = state.export
        return VStack(alignment: .leading, spacing: 16) {
            labelled(Loc.t("Scope")) {
                FileSegments(
                    items: [
                        ("document", Loc.t("Document")), ("canvas", Loc.t("Canvas")), ("branch", Loc.t("Branch")),
                    ] + (e.image.zone != nil ? [("zone", Loc.t("Zone"))] : []),
                    selection: Binding(
                        get: {
                            switch e.image.scope {
                            case .canvas: e.html.document ? "document" : "canvas"
                            case .selection, .branch: "branch"
                            case .zone: "zone"
                            }
                        },
                        set: { v in
                            set {
                                $0.export.html.document = v == "document"
                                $0.export.image.scope = v == "branch" ? .branch : v == "zone" ? .zone : .canvas
                            }
                        })
                )
            }
            HStack(spacing: 18) {
                Toggle("Notes", isOn: Binding(get: { e.html.notes }, set: { v in set { $0.export.html.notes = v } }))
                Toggle(
                    "Comments",
                    isOn: Binding(get: { e.html.comments }, set: { v in set { $0.export.html.comments = v } }))
                Toggle(
                    "Attachments",
                    isOn: Binding(get: { e.html.attachments }, set: { v in set { $0.export.html.attachments = v } }))
                Toggle(
                    "Every layout",
                    isOn: Binding(get: { e.html.expanded }, set: { v in set { $0.export.html.expanded = v } }))
            }
            .checkboxToggle()
            mask
            Divider()
            HStack(alignment: .top, spacing: 24) {
                labelled(Loc.t("Expires")) {
                    HStack(spacing: 8) {
                        Picker(
                            "", selection: Binding(get: { state.expiry }, set: { v in set { $0.expiry = v } })
                        ) {
                            Text("Never").tag(ShareState.Expiry.never)
                            Text("In 1 day").tag(ShareState.Expiry.day)
                            Text("In 7 days").tag(ShareState.Expiry.week)
                            Text("In 30 days").tag(ShareState.Expiry.month)
                            Text("On a date").tag(ShareState.Expiry.date)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        .accessibilityLabel("Expires")
                        if state.expiry == .date {
                            DatePicker(
                                "", selection: Binding(get: { state.date }, set: { v in set { $0.date = v } }),
                                in: Date()..., displayedComponents: .date
                            )
                            .labelsHidden()
                            .accessibilityLabel("Expiry date")
                        }
                    }
                }
                labelled(Loc.t("Store in")) {
                    Picker(
                        "",
                        selection: Binding(get: { state.destination ?? "" }, set: { v in set { $0.destination = v } })
                    ) {
                        ForEach(center.store.destinations) { d in Text(d.name).tag(d.id) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .accessibilityLabel("Store in")
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Ask for a password",
                    isOn: Binding(get: { state.usePassword }, set: { v in set { $0.usePassword = v } })
                )
                .toggleStyle(.switch)
                if state.usePassword {
                    SecureField(
                        "At least 4 characters",
                        text: Binding(get: { state.password }, set: { v in set { $0.password = v } })
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                    .accessibilityLabel("Link password")
                    Text("The password isn’t in the link. Send it another way.")
                        .font(.chrome(12.5)).foregroundStyle(.chromeSecondary)
                }
                Toggle(
                    "Update the link when I save",
                    isOn: Binding(get: { state.autoUpdate }, set: { v in set { $0.autoUpdate = v } })
                )
                .toggleStyle(.switch)
                .disabled(controller.documentPath == nil)
                if controller.documentPath == nil {
                    Text("Save the document first to keep its links up to date.")
                        .font(.chrome(12.5)).foregroundStyle(.chromeSecondary)
                }
            }
            Text(
                "Sealed on this Mac with AES-256-GCM before it leaves. The key is in the link after the #, which browsers never send, so where it’s stored can’t read it."
            )
            .font(.chrome(12.5)).foregroundStyle(.chromeSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if case .failed(let why) = state.phase {
                Text(why).font(.chrome(13)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Loc.f("Couldn’t make the link: %@", why))
            }
        }
        .padding(20)
    }

    @ViewBuilder var mask: some View {
        let hits = state.export.askMask ? controller.maskHits.count : 0
        if hits > 0 {
            Toggle(
                Loc.n(
                    "Mask %lld email, key or name in this link", "Mask %lld emails, keys or names in this link", hits),
                isOn: Binding(get: { state.export.mask }, set: { v in set { $0.export.mask = v } })
            )
            .checkboxToggle()
        } else if state.export.mask {
            Text("Emails, keys and names are masked (Settings › Export).").font(.chrome(12.5)).foregroundStyle(
                .secondary)
        }
    }

    var footer: some View {
        HStack(spacing: 10) {
            if state.phase == .working {
                ProgressView().controlSize(.small)
                Text("Sealing and uploading…").font(.chrome(13)).foregroundStyle(.chromeSecondary)
            }
            Spacer()
            Button("Cancel") { controller.closeShare() }.buttonStyle(FileButtonStyle()).keyboardShortcut(.cancelAction)
            Button("Create Link") { controller.createShareLink() }
                .buttonStyle(FileButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    func labelled(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.chrome(14, weight: .medium))
            content()
        }
    }
}

/// The link, its QR code and what to do with it.
private struct ShareResult: View {
    var controller: CanvasController
    let record: ShareRecord
    let link: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                if let qr = QRCode.image(link) {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable()
                        .frame(width: 168, height: 168)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white))
                        .accessibilityLabel("QR code of the link")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your link is ready").font(.chrome(16, weight: .semibold))
                    Text(link)
                        .font(.chrome(12, design: .monospaced))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.textBackground))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .accessibilityLabel("Link")
                    ForEach(notes, id: \.self) { n in
                        Text(n).font(.chrome(12.5)).foregroundStyle(.chromeSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            Divider()
            HStack(spacing: 10) {
                if let url = URL(string: link) {
                    ShareLink(item: url) { Text("Share…") }.buttonStyle(FileButtonStyle())
                    Button("Open in Browser") { PlatformOpen.url(url) }.buttonStyle(FileButtonStyle())
                }
                Spacer()
                Button("Copy Link") { controller.copyShareLink(record) }.buttonStyle(FileButtonStyle())
                Button("Done") { controller.closeShare() }
                    .buttonStyle(FileButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    var notes: [String] {
        var out: [String] = []
        if record.password { out.append(Loc.t("Readers need the password to open it.")) }
        if let d = record.expires {
            out.append(Loc.f("Stops working %@.", d.formatted(date: .abbreviated, time: .shortened)))
        }
        if record.autoUpdate { out.append(Loc.t("It updates each time you save this document.")) }
        out.append(Loc.t("Anyone with the link can open the map. Revoke it in File › Manage Share Links…."))
        return out
    }
}

/// A QR code for a link (Core Image, drawn sharp at any size with `.interpolation(.none)`).
@MainActor
enum QRCode {
    /// One context for every code: making a context costs far more than drawing a code.
    static let context = CIContext(options: [.useSoftwareRenderer: true])
    /// The last link's code. The Collaborate sheet redraws as people come and go (M46) while
    /// its link stays the same.
    static var last: (text: String, image: CGImage?)?

    static func image(_ text: String) -> CGImage? {
        if let last, last.text == text { return last.image }
        guard !text.isEmpty, let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 4, y: 4)) else { return nil }
        let image = context.createCGImage(out, from: out.extent)
        last = (text, image)
        return image
    }
}

// MARK: Why Share Link can't open

struct ShareNoticeView: View {
    var controller: CanvasController

    var body: some View {
        if let n = controller.shareNotice {
            VStack(alignment: .leading, spacing: 0) {
                Text(n == .networkOff ? Loc.t("Share links use the network") : Loc.t("Nowhere to store links yet"))
                    .font(.chrome(18, weight: .semibold))
                    .padding(18)
                Divider()
                Text(
                    n == .networkOff
                        ? Loc.t(
                            "OpenNexus doesn’t use the network unless you turn it on. Turn on “Use the network” and “Share links” in Settings › Privacy & Data, then add a place to store links in Settings › Sharing."
                        )
                        : Loc.t(
                            "Add a bucket, a GitHub gist or your own OpenNexus Server in Settings › Sharing. Links are sealed before they’re uploaded, so it can’t read them."
                        )
                )
                .font(.chrome(14))
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { controller.closeShareNotice() }.buttonStyle(FileButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Open Settings…") {
                        controller.closeShareNotice()
                        controller.onOpenSettings?(n == .networkOff ? "privacy" : "sharing")
                    }
                    .buttonStyle(FileButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
            .fixedWidth(500)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Share Link")
        }
    }
}

// MARK: Manage Share Links…

struct ManageLinksView: View {
    var controller: CanvasController

    var body: some View {
        if controller.manageLinks {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Share Links").font(.chrome(18, weight: .semibold))
                    Spacer()
                    Text("File › Manage Share Links…").font(.chrome(12, design: .monospaced)).foregroundStyle(
                        .secondary)
                }
                .padding(18)
                Divider()
                ShareLinkList(center: controller.shareCenter, controller: controller)
                    .frame(minHeight: 160, maxHeight: 460)
                Divider()
                HStack {
                    if !controller.shareCenter.networkOn {
                        Text("The network is off: links can be copied, not updated or revoked.")
                            .font(.chrome(12.5)).foregroundStyle(.chromeSecondary)
                    }
                    Spacer()
                    Button("Done") { controller.closeManageLinks() }
                        .buttonStyle(FileButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                    Button("") { controller.closeManageLinks() }.keyboardShortcut(.cancelAction).hidden()
                }
                .padding(16)
            }
            .fixedWidth(720)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Share Links")
        }
    }
}

/// Every link made on this Mac, newest first. With a document (`controller`), its own links
/// can be updated from it as it is now.
struct ShareLinkList: View {
    var center: ShareCenter
    var controller: CanvasController?
    @State private var confirmRevoke: String?
    @State private var working: String?
    @State private var problem: [String: String] = [:]

    var body: some View {
        let links = center.store.links
        if links.isEmpty {
            Text("No share links yet. Choose File › Share Link… to make one.")
                .font(.chrome(13.5)).foregroundStyle(.chromeSecondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(links) { r in
                        row(r)
                        Divider()
                    }
                }
            }
        }
    }

    func row(_ r: ShareRecord) -> some View {
        let mine = controller != nil && r.path != nil && r.path == controller?.documentPath
        let destination = center.store.destination(r.destination)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: r.password ? "lock.fill" : "link").foregroundStyle(.chromeSecondary)
                    .accessibilityHidden(true)
                Text(r.scope.kind == .document ? r.document : "\(r.scope.title) · \(r.document)")
                    .font(.chrome(14, weight: .medium)).lineLimit(1)
                Spacer()
                if working == r.id { ProgressView().controlSize(.small) }
                Button("Copy") { copy(r) }.disabled(center.link(r) == nil)
                if mine {
                    Button("Update") { update(r) }.disabled(!center.networkOn || working != nil)
                }
                if confirmRevoke == r.id {
                    Button("Revoke Link", role: .destructive) { revoke(r) }
                    Button("Keep") { confirmRevoke = nil }
                } else {
                    Button("Revoke…") { confirmRevoke = r.id }.disabled(!center.networkOn || working != nil)
                }
            }
            HStack(spacing: 14) {
                Text(details(r, destination)).font(.chrome(12.5)).foregroundStyle(.chromeSecondary)
                Spacer()
                if mine {
                    Toggle(
                        "Update when I save",
                        isOn: Binding(get: { r.autoUpdate }, set: { center.setAutoUpdate(r, $0) })
                    )
                    .checkboxToggle().font(.chrome(12.5))
                }
            }
            if let p = problem[r.id] {
                Text(p).font(.chrome(12.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(r.scope.kind == .document ? r.document : "\(r.scope.title) · \(r.document)")
    }

    func details(_ r: ShareRecord, _ d: ShareDestination?) -> String {
        var parts = [d?.name ?? Loc.t("Removed destination")]
        parts.append(Loc.f("updated %@", r.updated.formatted(date: .abbreviated, time: .shortened)))
        if let e = r.expires {
            parts.append(
                r.isExpired()
                    ? Loc.t("expired") : Loc.f("expires %@", e.formatted(date: .abbreviated, time: .omitted)))
        }
        return parts.joined(separator: " · ")
    }

    func copy(_ r: ShareRecord) {
        if let controller {
            controller.copyShareLink(r)
        } else if let link = center.link(r) {
            PlatformOpen.copy(link)
        }
    }

    func update(_ r: ShareRecord) {
        guard let controller, let bundle = controller.shareBundle(for: r) else {
            problem[r.id] = Loc.t("What this link shows is no longer in the document.")
            return
        }
        working = r.id
        problem[r.id] = nil
        Task {
            do {
                try await center.update(r, bundle: bundle)
                controller.showToast(Loc.t("Link updated"))
            } catch {
                problem[r.id] = String(describing: error)
            }
            working = nil
        }
    }

    func revoke(_ r: ShareRecord) {
        confirmRevoke = nil
        working = r.id
        problem[r.id] = nil
        Task {
            do {
                try await center.revoke(r)
                controller?.showToast(Loc.t("Link revoked"))
            } catch {
                problem[r.id] = String(describing: error)
            }
            working = nil
        }
    }
}

// MARK: Settings › Sharing › Destinations

struct ShareDestinationsCard: View {
    var center: ShareCenter
    @State private var editing: ShareDestination?
    @State private var results: [String: NetReply] = [:]
    @State private var working: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if center.store.destinations.isEmpty {
                Text(
                    "Links are stored where you choose: an S3-compatible bucket (AWS, Cloudflare R2, Backblaze B2, MinIO…), a secret GitHub gist, or your own OpenNexus Server."
                )
                .font(.chrome(13)).foregroundStyle(.chromeSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            }
            ForEach(center.store.destinations) { d in
                row(d)
                Divider()
            }
            HStack {
                Menu("Add Destination") {
                    Button("S3-Compatible Bucket…") { editing = ShareDestination(kind: .s3, name: "Bucket") }
                    Button("GitHub Gist…") { editing = ShareDestination(kind: .gist, name: "GitHub Gist") }
                    Button("OpenNexus Server…") { editing = ShareDestination(kind: .server, name: "My server") }
                }
                .fixedSize()
                Spacer()
                if !center.networkOn {
                    Text("Turn on the network in Privacy & Data to test or use these.")
                        .font(.chrome(12)).foregroundStyle(.chromeSecondary)
                }
            }
            .padding(.top, 10)
        }
        .sheet(item: $editing) { d in
            DestinationEditor(center: center, destination: d, isNew: center.store.destination(d.id) == nil) {
                editing = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destinations")
    }

    func row(_ d: ShareDestination) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).font(.chrome(14, weight: .medium))
                    Text("\(d.kind.title) · \(d.hosts.first ?? "")").font(.chrome(12)).foregroundStyle(.chromeSecondary)
                }
                Spacer()
                if working == d.id { ProgressView().controlSize(.small) }
                Button("Test") { run(d) { await center.test(d) } }.disabled(!center.networkOn || working != nil)
                if d.kind == .s3 {
                    Button("Set Up CORS") { run(d) { await center.setUpCORS(d) } }
                        .disabled(!center.networkOn || working != nil)
                }
                Button("Edit…") { editing = d }
                Button("Remove", role: .destructive) { center.removeDestination(d.id) }
            }
            if let r = results[d.id] {
                Text(r.ok ? (r.detail ?? Loc.t("Works.")) : (r.error ?? Loc.t("Didn’t work.")))
                    .font(.chrome(12.5)).foregroundStyle(r.ok ? Color.green : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if center.credential(d) == nil {
                Text("No credential saved").font(.chrome(12)).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(d.name)
    }

    func run(_ d: ShareDestination, _ job: @escaping @MainActor () async -> NetReply) {
        working = d.id
        results[d.id] = nil
        Task {
            results[d.id] = await job()
            working = nil
        }
    }
}

extension ShareDestination.Kind {
    var title: String {
        switch self {
        case .s3: Loc.t("S3-compatible bucket")
        case .gist: Loc.t("GitHub Gist")
        case .server: Loc.t("OpenNexus Server")
        }
    }
}

private struct DestinationEditor: View {
    var center: ShareCenter
    @State var destination: ShareDestination
    let isNew: Bool
    var onClose: () -> Void
    @State private var secret = ""

    init(center: ShareCenter, destination: ShareDestination, isNew: Bool, onClose: @escaping () -> Void) {
        self.center = center
        self._destination = State(initialValue: destination)
        self.isNew = isNew
        self.onClose = onClose
    }

    var hasSecret: Bool { center.credential(destination) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? Loc.f("Add %@", destination.kind.title) : Loc.f("Edit %@", destination.name))
                .font(.chrome(17, weight: .semibold))
                .padding(18)
            Divider()
            Form {
                TextField("Name", text: $destination.name)
                switch destination.kind {
                case .s3:
                    TextField(
                        "Endpoint", text: $destination.endpoint, prompt: Text(verbatim: "https://s3.amazonaws.com"))
                    TextField("Region", text: $destination.region)
                    TextField("Bucket", text: $destination.bucket)
                    TextField("Folder in the bucket", text: $destination.prefix)
                    TextField("Access key ID", text: $destination.accessKey)
                    SecureField(
                        "Secret access key", text: $secret,
                        prompt: Text(hasSecret ? Loc.t("Saved in the Keychain") : ""))
                    TextField(
                        "Public address (optional)", text: $destination.publicBase,
                        prompt: Text(verbatim: "https://pub-….r2.dev"))
                    Toggle("Path-style addresses", isOn: $destination.pathStyle)
                    Text(
                        "Readers fetch the sealed map from the bucket, so it needs public read for the folder and CORS for the viewer (Set Up CORS does that)."
                    )
                    .font(.chrome(12)).foregroundStyle(.chromeSecondary)
                case .gist:
                    SecureField(
                        "Token", text: $secret, prompt: Text(hasSecret ? Loc.t("Saved in the Keychain") : ""))
                    Text(
                        "A GitHub token with permission to create gists (fine-grained: Gists, read and write). Links are secret gists: unlisted, but anyone with the address can fetch the sealed file."
                    )
                    .font(.chrome(12)).foregroundStyle(.chromeSecondary)
                case .server:
                    TextField(
                        "Server address", text: $destination.server, prompt: Text(verbatim: "https://share.example.com")
                    )
                    SecureField(
                        "Upload token", text: $secret, prompt: Text(hasSecret ? Loc.t("Saved in the Keychain") : ""))
                    Text("The token set as OPENNEXUS_UPLOAD_TOKEN on your server.")
                        .font(.chrome(12)).foregroundStyle(.chromeSecondary)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: destination.kind == .s3 ? 430 : 220)
            Divider()
            HStack {
                if destination.hasInsecureAddress {
                    Text("Use an https:// address; http:// works only for this Mac.").font(.chrome(12))
                        .foregroundStyle(.chromeSecondary)
                } else if !destination.isComplete {
                    Text("Fill in the address fields first.").font(.chrome(12)).foregroundStyle(.chromeSecondary)
                }
                Spacer()
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    center.saveDestination(destination, secret: secret.isEmpty ? nil : secret)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!destination.isComplete || (isNew && secret.isEmpty))
            }
            .padding(16)
        }
        .fixedWidth(520)
    }
}

// MARK: Settings › Sharing › Links

struct ShareLinksCard: View {
    var center: ShareCenter
    var body: some View {
        ShareLinkList(center: center, controller: nil)
            .frame(maxHeight: 360)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.controlBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.6)))
    }
}
