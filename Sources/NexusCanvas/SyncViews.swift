import AppKit
import CoreImage.CIFilterBuiltins
import NexusCore
import NexusFormat
import NexusSync
import SwiftUI

// MARK: Settings › Sync › Libraries

struct SyncLibrariesCard: View {
    var center: SyncCenter
    @State private var editing: SyncLibrary?
    @State private var showingKey: SyncLibrary?
    @State private var deletedFor: SyncLibrary?
    @State private var results: [String: NetReply] = [:]
    @State private var working: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if center.libraries.isEmpty {
                Text(
                    "A library is a folder of documents kept the same on each Mac through an S3-compatible bucket you own (AWS, Cloudflare R2, Backblaze B2, MinIO…). It’s encrypted on this Mac first, unless you turn that off."
                )
                .font(.chrome(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            }
            ForEach(center.libraries) { lib in
                row(lib)
                Divider()
            }
            HStack {
                Button("Add Library…") {
                    editing = SyncLibrary(name: Loc.t("Library"), folder: "", bucket: SyncLibrary.newBucket())
                }
                Spacer()
                if !center.networkOn {
                    Text("Turn on “Sync libraries” in Privacy & Data to sync.")
                        .font(.chrome(12)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
        }
        .sheet(item: $editing) { lib in
            LibraryEditor(center: center, library: lib, isNew: center.library(lib.id) == nil) { editing = nil }
        }
        .sheet(item: $showingKey) { lib in
            RecoveryKeySheet(name: lib.name, key: center.recoveryKey(lib.id) ?? "") { showingKey = nil }
        }
        .sheet(item: $deletedFor) { lib in
            DeletedDocumentsSheet(center: center, library: lib) { deletedFor = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Libraries")
    }

    func row(_ lib: SyncLibrary) -> some View {
        let s = center.status[lib.id] ?? .off
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lib.name).font(.chrome(14, weight: .medium))
                    Text(
                        verbatim:
                            "\((lib.folder as NSString).abbreviatingWithTildeInPath) ⇄ \(lib.bucket.bucket)/\(lib.bucket.prefix)"
                    )
                    .font(.chrome(12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "\(s.glyph) \(s.label)" + (lib.encrypted ? "" : " · " + Loc.t("Not encrypted")))
                        .font(.chrome(12)).foregroundStyle(isProblem(s) ? Color.orange : .secondary)
                }
                Spacer()
                if working == lib.id || s == .syncing { ProgressView().controlSize(.small) }
                Button("Sync Now") { Task { await center.syncNow(lib.id) } }
                    .disabled(!center.networkOn || s == .syncing)
                Button("Test") { test(lib) }.disabled(!center.networkOn || working != nil)
                Menu("More") {
                    Button("Edit…") { editing = lib }
                    if lib.encrypted {
                        Button("Show Recovery Key…") { showingKey = lib }
                        Button("Enter Recovery Key…") { editing = lib }
                    }
                    Button("Deleted Documents…") { deletedFor = lib }.disabled(!center.networkOn)
                    Divider()
                    Button("Reset Sync State") { Task { await center.resetState(lib.id) } }
                    Button("Remove Library", role: .destructive) { center.remove(lib.id) }
                }
                .fixedSize()
            }
            if let r = results[lib.id] {
                Text(r.ok ? (r.detail ?? Loc.t("Works.")) : (r.error ?? Loc.t("Didn’t work.")))
                    .font(.chrome(12.5)).foregroundStyle(r.ok ? Color.green : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .offline(let why) = s {
                Text(why).font(.chrome(12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if center.credential(lib) == nil {
                Text("No secret key saved").font(.chrome(12)).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(lib.name)
    }

    func isProblem(_ s: SyncStatus) -> Bool { HomeView.problem(s) }

    func test(_ lib: SyncLibrary) {
        working = lib.id
        results[lib.id] = nil
        Task {
            results[lib.id] = await center.test(lib.id)
            working = nil
        }
    }
}

private struct LibraryEditor: View {
    var center: SyncCenter
    @State var library: SyncLibrary
    let isNew: Bool
    var onClose: () -> Void
    @State private var secret = ""
    @State private var recovery = ""
    @State private var error: String?

    init(center: SyncCenter, library: SyncLibrary, isNew: Bool, onClose: @escaping () -> Void) {
        self.center = center
        self._library = State(initialValue: library)
        self.isNew = isNew
        self.onClose = onClose
    }

    var hasSecret: Bool { center.credential(library) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? Loc.t("Add Library") : Loc.f("Edit %@", library.name))
                .font(.chrome(17, weight: .semibold))
                .padding(18)
            Divider()
            Form {
                TextField("Name", text: $library.name)
                HStack {
                    Text(
                        library.folder.isEmpty
                            ? Loc.t("No folder chosen") : (library.folder as NSString).abbreviatingWithTildeInPath
                    )
                    .foregroundStyle(library.folder.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose Folder…") { chooseFolder() }
                }
                TextField(
                    "Endpoint", text: $library.bucket.endpoint, prompt: Text(verbatim: "https://s3.amazonaws.com"))
                TextField("Region", text: $library.bucket.region)
                TextField("Bucket", text: $library.bucket.bucket)
                TextField("Folder in the bucket", text: $library.bucket.prefix)
                TextField("Access key ID", text: $library.bucket.accessKey)
                SecureField(
                    "Secret access key", text: $secret, prompt: Text(hasSecret ? Loc.t("Saved in the Keychain") : ""))
                Toggle("Path-style addresses", isOn: $library.bucket.pathStyle)
                Toggle("Encrypt on this Mac", isOn: $library.encrypted)
                    .disabled(!isNew)
                if library.encrypted {
                    TextField(
                        "Recovery key (to join from another Mac)", text: $recovery,
                        prompt: Text(
                            isNew
                                ? Loc.t("Leave empty to make a new library")
                                : Loc.t("Leave empty to keep this Mac’s key")))
                }
                Text(
                    library.encrypted
                        ? "The bucket holds only sealed files with meaningless names. The key stays in this Mac’s Keychain; Show Recovery Key… sets up another Mac."
                        : "Without encryption, anyone who can read the bucket can read your documents."
                )
                .font(.chrome(12)).foregroundStyle(library.encrypted ? Color.secondary : Color.orange)
            }
            .formStyle(.grouped)
            .frame(minHeight: 480)
            Divider()
            HStack {
                if let error {
                    Text(error).font(.chrome(12)).foregroundStyle(.red)
                } else if library.bucket.hasInsecureAddress {
                    Text("Use an https:// address; http:// works only for this Mac.").font(.chrome(12))
                        .foregroundStyle(.secondary)
                } else if !library.isComplete {
                    Text("Choose a folder and fill in the bucket first.").font(.chrome(12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try center.save(library, secret: secret.isEmpty ? nil : secret, recoveryKey: recovery)
                        onClose()
                    } catch {
                        self.error = Loc.t("That isn’t a recovery key: check it for typos.")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!library.isComplete || (isNew && secret.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 540)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = Loc.t("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.folder = url.path(percentEncoded: false)
        library.bookmark = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        if library.name == Loc.t("Library") || library.name.isEmpty { library.name = url.lastPathComponent }
    }
}

/// Show Recovery Key…: the key as text and a QR code, to set up another Mac.
struct RecoveryKeySheet: View {
    var name: String
    var key: String
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Loc.f("Recovery key for %@", name)).font(.chrome(17, weight: .semibold)).padding(18)
            Divider()
            HStack(alignment: .top, spacing: 18) {
                if let qr = Self.qr(key) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                        .accessibilityLabel("QR code of the recovery key")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: key).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        "Enter it when you add this library on another Mac. Anyone with it and access to the bucket can read the library, so keep it somewhere safe, like a password manager."
                    )
                    .font(.chrome(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            Divider()
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560)
    }

    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// Deleted Documents…: the library's trash, with Restore.
private struct DeletedDocumentsSheet: View {
    var center: SyncCenter
    var library: SyncLibrary
    var onClose: () -> Void
    @State private var items: [DeletedDocument] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Loc.f("Deleted from %@", library.name)).font(.chrome(17, weight: .semibold)).padding(18)
            Divider()
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else if let error {
                    Text(error).foregroundStyle(.red).padding(20)
                } else if items.isEmpty {
                    Text("Nothing deleted.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List(items) { d in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(verbatim: (d.path as NSString).lastPathComponent)
                                Text(
                                    Loc.f(
                                        "Deleted %@ on %@", d.date.formatted(date: .abbreviated, time: .shortened),
                                        d.device)
                                )
                                .font(.chrome(12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                Task {
                                    await center.restore(d, in: library.id)
                                    await load()
                                }
                            }
                        }
                    }
                    .frame(minHeight: 200)
                }
            }
            Divider()
            HStack {
                Text(Loc.f("Kept for %@ days after deleting", center.prefs.string("sync.keepDeleted")))
                    .font(.chrome(12)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
        .task { await load() }
    }

    func load() async {
        do {
            items = try await center.deleted(library.id)
        } catch {
            self.error = String(describing: error)
        }
        loading = false
    }
}

// MARK: Settings › Sync › Sync log

struct SyncLogCard: View {
    var center: SyncCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if center.log.isEmpty {
                Text("Nothing synced yet.").font(.chrome(13)).foregroundStyle(.secondary)
            }
            ForEach(center.log.prefix(40)) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.date.formatted(date: .omitted, time: .shortened))
                        .font(.chrome(12, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Text(verbatim: line.library).font(.chrome(12, weight: .medium)).frame(
                        width: 110, alignment: .leading
                    )
                    .lineLimit(1)
                    Text(verbatim: line.text).font(.chrome(12.5))
                        .foregroundStyle(line.problem ? Color.orange : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !center.log.isEmpty {
                HStack {
                    Spacer()
                    Button("Clear Log") { center.clearLog() }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sync log")
    }
}

// MARK: Resolve Conflicts

struct ResolveConflictsView: View {
    var controller: CanvasController

    var body: some View {
        if let s = controller.resolveState {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolve Conflicts").font(.chrome(18, weight: .semibold))
                    Text(
                        Loc.f(
                            "%@ · both sides changed %@. This Mac’s version is in the document until you choose.",
                            s.title, Loc.n("%lld thing", "%lld things", s.clashes.count))
                    )
                    .font(.chrome(12.5)).foregroundStyle(.secondary)
                }
                .padding(18)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(s.clashes) { c in
                            clashRow(c, s)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .frame(minHeight: 120, maxHeight: 420)
                Divider()
                HStack {
                    Button("All Mine") { controller.chooseAll(.mine) }
                    Button("All Theirs") { controller.chooseAll(.theirs) }
                    Spacer()
                    Button("Later") { controller.closeResolve() }.keyboardShortcut(.cancelAction)
                        .buttonStyle(FileButtonStyle())
                    Button("Apply") { controller.applyResolution() }.keyboardShortcut(.defaultAction)
                        .buttonStyle(FileButtonStyle(prominent: true))
                }
                .padding(16)
            }
            .frame(width: 680)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Resolve Conflicts")
        }
    }

    func clashRow(_ c: MergeClash, _ s: ResolveState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.where(c)).font(.chrome(13, weight: .medium))
                Spacer()
                Picker(
                    "", selection: Binding(get: { s.choice(c) }, set: { controller.choose($0, for: c) })
                ) {
                    Text("Mine").tag(MergeClash.Choice.mine)
                    Text("Theirs").tag(MergeClash.Choice.theirs)
                    Text("Keep Both").tag(MergeClash.Choice.both)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityLabel(Loc.f("Keep for %@", c.label))
            }
            HStack(alignment: .top, spacing: 14) {
                side(Loc.t("This Mac"), c.mine, c.mineChanges)
                side(s.copySuffix.isEmpty ? Loc.t("Other") : s.title, c.theirs, c.theirsChanges)
            }
        }
        .padding(.vertical, 10)
    }

    func side(_ title: String, _ text: String?, _ changes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
            Text(text.map { "“\($0)”" } ?? Loc.t("Deleted")).font(.chrome(13))
                .foregroundStyle(text == nil ? .secondary : .primary)
            if !changes.isEmpty {
                Text(changes.map(Self.change).joined(separator: ", ")).font(.chrome(11.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func `where`(_ c: MergeClash) -> String {
        switch c.kind {
        case .topic: Loc.f("%@ on “%@”", c.label, c.canvasTitle)
        case .settings: Loc.f("Canvas settings of “%@”", c.canvasTitle)
        case .canvas: Loc.f("The canvas “%@”", c.canvasTitle)
        }
    }

    static func change(_ s: String) -> String {
        switch s {
        case "text": Loc.t("text")
        case "note": Loc.t("note")
        case "task": Loc.t("task")
        case "subtopics": Loc.t("subtopics")
        case "comments": Loc.t("comments")
        case "markers": Loc.t("markers")
        case "style": Loc.t("style")
        case "links": Loc.t("links")
        default: Loc.t("details")
        }
    }
}

// MARK: Sync History…

struct SyncHistoryView: View {
    var controller: CanvasController

    var body: some View {
        if let h = controller.syncHistory {
            VStack(alignment: .leading, spacing: 0) {
                Text("Sync History").font(.chrome(18, weight: .semibold)).padding(18)
                Divider()
                Group {
                    if h.loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 140)
                    } else if let e = h.error {
                        Text(e).foregroundStyle(.red).padding(20)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(h.items.enumerated()), id: \.element.revision) { i, r in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(r.date.formatted(date: .abbreviated, time: .shortened))
                                                .font(.chrome(13, weight: i == 0 ? .semibold : .regular))
                                            Text(
                                                r.device
                                                    + (r.parents.count > 1 ? " · " + Loc.t("merged") : "")
                                                    + (r.clashes.map {
                                                        " · " + Loc.n("%lld conflict", "%lld conflicts", $0)
                                                    }
                                                        ?? "")
                                            )
                                            .font(.chrome(12)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if h.restoring == r.revision { ProgressView().controlSize(.small) }
                                        if i == 0 {
                                            Text("Current").font(.chrome(12)).foregroundStyle(.secondary)
                                        } else {
                                            Button("Restore") { controller.restoreRevision(r) }
                                                .disabled(h.restoring != nil)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    Divider()
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                        .frame(minHeight: 140, maxHeight: 420)
                    }
                }
                Divider()
                HStack {
                    Text("Restoring puts that version in the document as one undo step.")
                        .font(.chrome(12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { controller.closeSyncHistory() }
                        .buttonStyle(FileButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    Button("") { controller.closeSyncHistory() }.keyboardShortcut(.cancelAction).hidden()
                }
                .padding(16)
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sync History")
        }
    }
}

// MARK: Merge Conflicting Copies…

struct ConflictCopiesNotice: View {
    var controller: CanvasController

    var body: some View {
        let copies = controller.conflictCopies
        if !copies.isEmpty, controller.resolveState == nil {
            VStack(alignment: .leading, spacing: 0) {
                Text(
                    Loc.n(
                        "%lld conflicting copy of this document", "%lld conflicting copies of this document",
                        copies.count)
                )
                .font(.chrome(18, weight: .semibold)).padding(18)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Another app’s sync couldn’t combine changes, so it kept them apart. OpenNexus can merge them in topic by topic; where both changed the same thing, you choose."
                    )
                    .font(.chrome(13)).fixedSize(horizontal: false, vertical: true)
                    ForEach(copies) { c in
                        Text(
                            verbatim: "• " + c.label
                                + (c.modified.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                        )
                        .font(.chrome(12.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                Divider()
                HStack {
                    Text("Merged copies go to the Trash.").font(.chrome(12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Not Now") { controller.dismissConflictCopies() }.buttonStyle(FileButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button("Merge") { controller.mergeConflictCopies() }
                        .buttonStyle(FileButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
                .padding(16)
            }
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Merge Conflicting Copies")
        }
    }
}
