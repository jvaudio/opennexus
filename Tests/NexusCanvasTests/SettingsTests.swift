import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusKeys

@MainActor
@Suite struct SettingsSchemaTests {
    @Test func everyPaneInOrderWithTints() {
        #expect(
            SettingsSchema.panes.map(\.title) == [
                "General", "Editing", "Appearance", "Files & Backup", "AI", "Shortcuts", "Export", "Integrations",
                "Privacy & Data", "Accessibility",
            ])
        #expect(
            SettingsSchema.panes.map(\.tint) == [
                "#8E8E96", "#1E8BE0", "#D6408B", "#E08A00", "#0F7F7A", "#5850EC", "#C25E00", "#7A4CC2", "#17171C",
                "#1E6FB8",
            ])
    }

    @Test func keysAreUniqueAndDefaultsMatchTheirKind() {
        var seen = Set<String>()
        for (_, _, r) in SettingsSchema.allRows {
            #expect(seen.insert(r.key).inserted, "duplicate key \(r.key)")
            switch r.kind {
            case .toggle: #expect({ if case .bool? = r.defaultValue { true } else { false } }(), "\(r.key)")
            case .segmented(let o), .menu(let o):
                guard case .string(let d)? = r.defaultValue else {
                    Issue.record("\(r.key) has no string default")
                    continue
                }
                #expect(o.contains { $0.value == d }, "\(r.key) default \(d) isn't an option")
            case .number(_, let lo, let hi, _):
                guard case .number(let d)? = r.defaultValue else {
                    Issue.record("\(r.key)")
                    continue
                }
                #expect(d >= lo && d <= hi)
            default: break
            }
        }
        #expect(seen.count > 140)
    }

    /// README §10: search finds every row.
    @Test func searchFindsEveryRow() {
        for (p, s, r) in SettingsSchema.allRows {
            let q = r.title.isEmpty ? (r.keywords.first ?? s.title) : r.title
            guard !q.isEmpty else { continue }
            #expect(
                SettingsSchema.search(q).contains { $0.2.key == r.key }, "\(p.title) › \(r.title) not found for “\(q)”")
        }
        #expect(SettingsSchema.search("caps lock").first?.0.id == "shortcuts")
        #expect(SettingsSchema.search("watermark").first?.2.key == "export.watermark")
        #expect(SettingsSchema.search("zzz-nothing").isEmpty)
    }

    /// Rows that would need the network are shown off and locked (README §12).
    @Test func networkRowsAreLockedOff() {
        let locked = SettingsSchema.allRows.filter { $0.2.locked != nil }.map(\.2.key)
        #expect(
            Set(locked) == [
                "general.updatesCheck", "general.updatesInstall", "general.updatesChannel", "privacy.usageStats",
                "privacy.crashReports", "privacy.linkPreviews",
            ])
        let prefs = Preferences.isolated()
        #expect(
            !prefs.bool("general.updatesCheck") && !prefs.bool("privacy.usageStats")
                && prefs.string("privacy.crashReports") == "never")
    }

    @Test func preferencesPersistNotifyAndReset() {
        let prefs = Preferences.isolated()
        #expect(prefs.string("editing.typing") == "replace" && prefs.isDefault("editing.typing"))
        var heard: [String] = []
        let o = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: prefs, queue: nil) { n in
            heard.append(n.userInfo?["key"] as? String ?? "")
        }
        defer { NotificationCenter.default.removeObserver(o) }
        prefs.set("editing.typing", "append")
        prefs.set("editing.gridSize", 16.0)
        #expect(prefs.string("editing.typing") == "append" && prefs.number("editing.gridSize") == 16)
        #expect(Preferences(defaults: prefs.defaults).string("editing.typing") == "append", "persists in the store")
        prefs.reset("editing.typing")
        #expect(prefs.string("editing.typing") == "replace")
        #expect(heard == ["editing.typing", "editing.gridSize", "editing.typing"])
    }
}

@Suite struct KeyCustomizationTests {
    let reg = CommandRegistry.standard

    @Test func recordSwapReassignAndScope() throws {
        var c = KeyCustomization()
        let chord = try #require(KeyChord("shift+cmd+k"))
        // ⇧⌘K is Insert Hyperlink (Select scope); Quick Jump wants it.
        let jump = CommandID.quickJump
        let owner = try #require(c.conflict(for: jump, chord: chord, registry: reg))
        let jumpOld = reg.bindings(for: jump).first { !$0.isHyper }
        // Swap: the owner takes Quick Jump's old chord.
        var swap = c
        swap.record(jump, chord: chord, registry: reg, resolution: .swap)
        #expect(swap.apply(to: reg).bindings(for: jump, custom: swap.custom).first == chord)
        #expect(swap.apply(to: reg).bindings(for: owner, custom: swap.custom).contains(jumpOld!))
        #expect(swap.conflict(for: jump, chord: chord, registry: reg) == nil)
        // Reassign: the owner loses it.
        var re = c
        re.record(jump, chord: chord, registry: reg, resolution: .reassign)
        #expect(!re.apply(to: reg).bindings(for: owner, custom: re.custom).contains(chord))
        // Scope: Quick Jump only in Edit, where ⇧⌘K is free.
        c.record(jump, chord: chord, registry: reg, resolution: .scope(.editor))
        #expect(c.apply(to: reg)[jump]?.scope == .editor)
        #expect(c.apply(to: reg).conflicts(custom: c.custom).isEmpty)
        // JSON round trip (Export JSON / Import profile…).
        #expect(KeyCustomization.decode(c.json) == c)
    }

    @Test func hyperBindingSurvivesRecording() throws {
        var c = KeyCustomization()
        let id = CommandID("ai.panel")
        let hyper = reg.bindings(for: id).first(where: \.isHyper)
        c.record(id, chord: try #require(KeyChord("ctrl+opt+j")), registry: reg)
        let after = c.apply(to: reg).bindings(for: id, custom: c.custom)
        #expect(after.first == KeyChord("ctrl+opt+j") && after.contains(hyper!))
    }
}

@MainActor
@Suite struct TemplateTests {
    @Test func everyTemplateIsAValidDocumentAndRolesFilterTheShelf() {
        #expect(TemplateLibrary.all.count == 25)
        for t in TemplateLibrary.all {
            let d = t.document()
            let c = d.orderedCanvases[0]
            #expect(c.validate().isEmpty, "\(t.title): \(c.validate())")
            #expect(c.nodes.count >= 4, "\(t.title)")
            #expect(c.type == t.type, "\(t.title)")
        }
        for cat in MapTemplate.Category.allCases { #expect(TemplateLibrary.shelf(cat).count == 5) }
        #expect(Role.engineer.shelf == .engineering && Role.security.tourConversion == .dfd)
        #expect(TemplateLibrary.shelf(.engineering).map(\.title).prefix(2) == ["System context", "API request flow"])
    }
}

@MainActor
@Suite struct HomeModelTests {
    @Test func recentsSearchLocationsAndFilters() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var a = TemplateLibrary.all.first { $0.id == "threat" }!.document()
        a.canvases["c1"]!.filters = [NodeFilter(name: "Open threats · High")]
        let ua = dir.appending(path: "Payments threat model.nexus")
        try NexusPackage.write(a, to: ua)
        let ub = dir.appending(path: "Reading.nexus")
        try NexusPackage.write(TemplateLibrary.all.first { $0.id == "bookNotes" }!.document(), to: ub)
        let m = HomeModel()
        m.load([ua, ub, dir.appending(path: "missing.nexus")])
        #expect(m.recents.map(\.title) == ["Payments threat model", "Reading"])
        #expect(m.recents[0].detail.hasPrefix("Threat Model ·") && m.recents[1].detail == "Mind Map · 6 topics")
        #expect(m.locations.map(\.standardizedFileURL.path) == [dir.standardizedFileURL.path])
        #expect(m.savedFilters.map(\.1) == ["Open threats · High"])
        m.query = "feedback"
        #expect(m.results.map(\.0.title) == ["Reading"] && m.results[0].1 == ["feedback loops"])
        m.query = "payments"
        #expect(m.results.first?.0.title == "Payments threat model")
    }
}
