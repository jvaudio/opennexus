import AppKit
import NexusKeys
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Shortcuts (artboard 08): profiles, the Hyper key, a searchable table of every
/// command, and a recorder that checks conflicts against OpenNexus, the menu bar and macOS.
struct ShortcutsPane: View {
    var prefs: Preferences
    @State private var query = ""
    @State private var scope: Scope?
    @State private var recording: CommandID?
    @State private var pending: (id: CommandID, chord: KeyChord, other: CommandID)?
    @State private var systemClash: String?
    @State private var monitor: Any?
    @State private var hyperPrompt = false

    var customization: KeyCustomization {
        var c = prefs.data("shortcuts.custom").flatMap(KeyCustomization.decode) ?? KeyCustomization()
        c.profile = prefs.string("shortcuts.profile")
        return c
    }

    func save(_ c: KeyCustomization) {
        prefs.setData("shortcuts.custom", c.json)
    }

    var body: some View {
        let _ = prefs.revision
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Shortcuts").font(.chrome(30, weight: .bold))
                Spacer()
                Button("Import profile…") { importProfile() }
                Button("Export JSON") { exportProfile() }
                Button("Restore Defaults") {
                    prefs.setData("shortcuts.custom", nil)
                    prefs.reset("shortcuts.profile")
                }
            }
            HStack(alignment: .top, spacing: 18) {
                profiles
                hyperCard
            }
            HStack(spacing: 10) {
                TextField("Search shortcuts", text: $query).textFieldStyle(.roundedBorder).controlSize(.large)
                    .accessibilityLabel("Search shortcuts")
                Picker("", selection: $scope) {
                    Text("All scopes").tag(Scope?.none)
                    Text("Select").tag(Scope?.some(.canvas))
                    Text("Edit").tag(Scope?.some(.editor))
                    Text("Outline").tag(Scope?.some(.outline))
                    Text("Connect").tag(Scope?.some(.connect))
                    Text("Command").tag(Scope?.some(.global))
                }
                .labelsHidden()
                .frame(width: 150)
            }
            table
        }
        .onDisappear { stopRecording() }
    }

    // MARK: Profiles and Hyper

    var profiles: some View {
        let current = prefs.string("shortcuts.profile")
        return VStack(alignment: .leading, spacing: 12) {
            Text("Profile").font(.chrome(15, weight: .semibold))
            HStack(spacing: 10) {
                ForEach(
                    [
                        ("opennexus", "OpenNexus", Loc.t("Xmind-compatible · default")),
                        ("hyper", "Hyper-first", Loc.t("✦ is primary everywhere")),
                        ("vim", "Vim-style", Loc.t("h j k l · o / O · dd")),
                        ("outliner", Loc.t("Outliner"), Loc.t("⇥ indents · ⌥↩ child")),
                    ],
                    id: \.0
                ) { id, name, detail in
                    Button {
                        prefs.set("shortcuts.profile", id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name).font(.chrome(15, weight: .semibold))
                            Text(detail).font(.chrome(12.5)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10).fill(
                                current == id
                                    ? Color(hex: "#5850EC").opacity(0.08) : Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(
                                current == id ? Color(hex: "#5850EC") : Color.secondary.opacity(0.25),
                                lineWidth: current == id ? 2 : 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(current == id ? .isSelected : [])
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .frame(maxWidth: .infinity)
    }

    var hyperCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("✦").font(.chrome(26)).foregroundStyle(.yellow)
                .frame(width: 58, height: 58).background(
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hyper key").font(.chrome(16, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { prefs.bool("shortcuts.hyper") },
                            set: { on in
                                prefs.set("shortcuts.hyper", on)
                                if on && prefs.string("shortcuts.hyperKey") == "capsLock" { hyperPrompt = true }
                            })
                    )
                    .toggleStyle(.switch).tint(.green).labelsHidden()
                    .accessibilityLabel("Hyper key")
                }
                Text(
                    Loc.f(
                        "%@ acts as ⌃⌥⇧⌘ pressed together, giving OpenNexus a clash-free namespace. Tap alone: %@.",
                        prefs.string("shortcuts.hyperKey") == "rightOption"
                            ? Loc.t("Right Option") : Loc.t("Caps Lock"),
                        prefs.string("shortcuts.hyperTap") == "esc" ? Loc.t("Esc") : Loc.t("nothing"))
                )
                .font(.chrome(13)).foregroundStyle(.white.opacity(0.7)).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.1)))
        .popover(isPresented: $hyperPrompt, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("SHOWN ONCE, WHEN HYPER IS TURNED ON").font(.chrome(11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Let OpenNexus read Caps Lock").font(.chrome(16, weight: .semibold))
                Text(
                    "To turn Caps Lock into Hyper, macOS needs to allow Input Monitoring. OpenNexus only remaps that one key and never records what you type."
                )
                .font(.chrome(13)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Use Right Option") {
                        prefs.set("shortcuts.hyperKey", "rightOption")
                        hyperPrompt = false
                    }
                    Button("Open System Settings") {
                        if let u = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                        {
                            NSWorkspace.shared.open(u)
                        }
                        hyperPrompt = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
            .frame(width: 400)
        }
    }

    // MARK: Table

    var rows: [CommandDescriptor] {
        let reg = customization.apply(to: .standard)
        let q = query.lowercased()
        return reg.commands.filter { c in
            (scope == nil || c.scope == scope)
                && (q.isEmpty || c.title.lowercased().contains(q) || c.id.rawValue.contains(q))
                && c.scope != .find
        }
    }

    static func scopeName(_ s: Scope) -> String {
        switch s {
        case .global: Loc.t("All")
        case .canvas: Loc.t("Select")
        case .editor: Loc.t("Edit")
        case .outline: Loc.t("Outline")
        case .connect: Loc.t("Connect")
        default: s.rawValue.capitalized
        }
    }

    var table: some View {
        let c = customization
        let reg = c.apply(to: .standard)
        return VStack(spacing: 0) {
            HStack {
                Text("Command").frame(maxWidth: .infinity, alignment: .leading)
                Text("Scope").frame(width: 120, alignment: .leading)
                Text("Standard").frame(width: 260, alignment: .leading)
                Text("Hyper").frame(width: 110, alignment: .leading)
            }
            .font(.chrome(13, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.id) { cmd in
                    let keys = reg.bindings(for: cmd.id, profile: c.keyProfile, custom: c.custom)
                    let standard = keys.filter { !$0.isHyper }
                    let hyper = keys.first(where: \.isHyper)
                    HStack {
                        Text(Loc.t(cmd.title)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.scopeName(cmd.scope)).foregroundStyle(.secondary).frame(
                            width: 120, alignment: .leading)
                        HStack(spacing: 6) {
                            if recording == cmd.id {
                                Text("Recording…").foregroundStyle(.red)
                                Button("Cancel") { stopRecording() }.buttonStyle(.link)
                            } else {
                                Button {
                                    startRecording(cmd.id)
                                } label: {
                                    HStack(spacing: 4) {
                                        if standard.isEmpty { cap("—", hyper: false) }
                                        ForEach(standard.prefix(2), id: \.self) { cap($0.glyphs, hyper: false) }
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("Click to record a new shortcut")
                                .accessibilityLabel(
                                    Loc.f(
                                        "%@ shortcut %@. Record", cmd.title,
                                        standard.first?.glyphs ?? Loc.t("none")))
                                if c.chords[cmd.id.rawValue] != nil || c.scopes[cmd.id.rawValue] != nil {
                                    Button("Reset") {
                                        var x = c
                                        x.reset(cmd.id)
                                        save(x)
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                        }
                        .frame(width: 260, alignment: .leading)
                        Group {
                            if let hyper { cap("✦ " + hyper.key.glyph, hyper: true) } else { Text("") }
                        }
                        .frame(width: 110, alignment: .leading)
                    }
                    .font(.chrome(14))
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(recording == cmd.id ? Color.red.opacity(0.06) : .clear)
                    .popover(
                        isPresented: Binding(get: { pending?.id == cmd.id }, set: { if !$0 { pending = nil } }),
                        arrowEdge: .top
                    ) { conflictCard }
                    Divider()
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.6)))
        .overlay(alignment: .top) {
            if let s = systemClash {
                Text(s).padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
                    .padding(.top, 44)
            }
        }
    }

    func cap(_ s: String, hyper: Bool) -> some View {
        Text(s).font(.chrome(12.5, weight: .medium, design: .monospaced))
            .foregroundStyle(hyper ? Color.white : .primary)
            .padding(.horizontal, 8).frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(hyper ? Color.black : Color(nsColor: .textBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    @ViewBuilder var conflictCard: some View {
        if let p = pending, let other = CommandRegistry.standard[p.other] {
            let mine = customization.apply(to: .standard)[p.id]
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("!").font(.chrome(13, weight: .bold)).foregroundStyle(.red)
                        .frame(width: 22, height: 22).background(
                            RoundedRectangle(cornerRadius: 5).fill(Color.red.opacity(0.12)))
                    cap(p.chord.glyphs, hyper: false)
                    Text("is already taken").font(.chrome(15, weight: .semibold))
                }
                Text(  // a String key renders its **bold** as Markdown
                    LocalizedStringKey(
                        Loc.f(
                            "OpenNexus uses it for **%@** (%@ scope). You’re assigning it to **%@**.", other.title,
                            Self.scopeName(other.scope), mine?.title ?? ""))
                )
                .font(.chrome(13.5)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Swap") { resolve(.swap) }
                    Button("Reassign") { resolve(.reassign) }
                    if let s = KeyCustomization.narrowing(mine?.scope ?? .global, avoiding: other.scope) {
                        Button(Loc.f("Scope to %@", Self.scopeName(s))) { resolve(.scope(s)) }.buttonStyle(
                            .borderedProminent)
                    }
                }
                Text("Conflicts are checked against OpenNexus, the menu bar and macOS system shortcuts.")
                    .font(.chrome(12.5)).foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(width: 520)
        }
    }

    // MARK: Recording

    func startRecording(_ id: CommandID) {
        stopRecording()
        recording = id
        systemClash = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard let chord = KeyChord(event: e) else { return e }
            MainActor.assumeIsolated {
                if chord.key == .escape && chord.modifiers.isEmpty {
                    stopRecording()
                } else {
                    record(id, chord)
                }
            }
            return nil
        }
    }

    func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
    }

    func record(_ id: CommandID, _ chord: KeyChord) {
        stopRecording()
        if let name = SystemShortcuts.reserved[chord] {
            systemClash = Loc.f("%@ is a macOS shortcut (%@); choose another.", chord.glyphs, name)
            return
        }
        var c = customization
        if let other = c.conflict(for: id, chord: chord, registry: .standard) {
            pending = (id, chord, other)
            return
        }
        c.record(id, chord: chord, registry: .standard)
        save(c)
    }

    func resolve(_ r: KeyCustomization.Resolution) {
        guard let p = pending else { return }
        var c = customization
        c.record(p.id, chord: p.chord, registry: .standard, resolution: r)
        save(c)
        pending = nil
    }

    // MARK: Import and export

    func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "OpenNexus shortcuts.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { try? customization.json.write(to: url) }
    }

    func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let d = try? Data(contentsOf: url),
            let c = KeyCustomization.decode(d)
        else { return }
        prefs.set("shortcuts.profile", c.profile)
        save(c)
    }
}
