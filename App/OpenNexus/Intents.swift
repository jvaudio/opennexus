import AppIntents
import AppKit
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import NexusKeys
import UniformTypeIdentifiers

// Shortcuts and Siri (artboard 33; Settings › Integrations › Shortcuts & Siri actions).
// Run OpenNexus Command takes its commands from the registry, so every command is an
// action without new code (README §7).

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case off
    case noText
    case unreadable(String)
    case noDocument

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .off: "Shortcuts actions are turned off in OpenNexus › Settings › Integrations."
        case .noText: "There's no text on the clipboard."
        case .unreadable(let why): "OpenNexus couldn't read that map: \(why)"
        case .noDocument: "Open a map in OpenNexus first."
        }
    }
}

@MainActor
func checkIntentsEnabled() throws {
    guard Preferences.shared.bool("integrations.shortcuts") else { throw IntentFailure.off }
}

/// A map handed to an action (a `.nexus` package, a single-JSON `.nexusjson`, or a zip).
@MainActor
func readMap(_ file: IntentFile) throws -> (DocumentModel, String) {
    let name = file.filename
    let base = (name as NSString).deletingPathExtension
    if let url = file.fileURL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            do { return (try NexusPackage.read(from: url), base) } catch { throw IntentFailure.unreadable("\(error)") }
        }
    }
    let data = file.data
    do {
        if name.lowercased().hasSuffix(".nexusjson") || data.first == UInt8(ascii: "{") {
            return (try DocumentJSON.parse(data, name: name), base)
        }
        return (try NexusPackage.read(files: try Zip.read(data)), base)
    } catch {
        throw IntentFailure.unreadable("\(error)")
    }
}

struct CreateMapFromClipboard: AppIntent {
    static let title: LocalizedStringResource = "Create Mind Map from Clipboard"
    static let description = IntentDescription(
        "Turns the text on the clipboard into a new mind map. Markdown, outlines and indented lists keep their hierarchy."
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try checkIntentsEnabled()
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { throw IntentFailure.noText }
        if let (ic, _) = Interchange.parsePasted(text, title: "Clipboard") {
            var report = ImportReport(source: "Clipboard", format: "Text")
            NewDocument.make(model: DocumentModel(canvases: CanvasBuilder.build([ic], report: &report)))
        } else {
            var c = Canvas(id: "c1", title: "", rootText: text)
            CanvasController.applyDefaults(&c, prefs: .shared)
            NewDocument.make(model: DocumentModel(canvases: [c]))
        }
        return .result()
    }
}

struct AddIdeaToInbox: AppIntent {
    static let title: LocalizedStringResource = "Add Idea to Inbox Map"
    static let description = IntentDescription("Adds a topic to your Inbox map without opening OpenNexus.")

    @Parameter(title: "Idea", inputOptions: String.IntentInputOptions(multiline: true))
    var idea: String

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$idea) to the Inbox map") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try checkIntentsEnabled()
        guard let r = CaptureComposer.compose(idea, multiline: "items") else { throw IntentFailure.noText }
        Integrations.shared.add(r, to: Inbox.url)
        return .result(dialog: "Added to your Inbox map.")
    }
}

struct ExportCanvasAsPNG: AppIntent {
    static let title: LocalizedStringResource = "Export Canvas as PNG"
    static let description = IntentDescription(
        "Renders a map's canvas as a PNG image, exactly as it looks in OpenNexus.")

    @Parameter(
        title: "Map",
        supportedContentTypes: [UTType("com.opennexus.document")!, UTType("com.opennexus.json-document")!])
    var map: IntentFile

    @Parameter(title: "Canvas", description: "The canvas title or id (default: the first).")
    var canvas: String?

    @Parameter(title: "Scale", default: 2, inclusiveRange: (1, 4))
    var scale: Double

    static var parameterSummary: some ParameterSummary { Summary("Export \(\.$map) as PNG") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        try checkIntentsEnabled()
        let (doc, base) = try readMap(map)
        let id =
            canvas.flatMap { ref in
                doc.orderedCanvases.first {
                    $0.id.rawValue == ref || $0.title.caseInsensitiveCompare(ref) == .orderedSame
                }?.id
            } ?? doc.canvasOrder.first
        guard let data = HeadlessExport.data(doc, canvas: id, format: .png, scale: scale) else {
            throw IntentFailure.unreadable("nothing to render")
        }
        return .result(value: IntentFile(data: data, filename: "\(base).png", type: .png))
    }
}

struct ConvertMapToMermaid: AppIntent {
    static let title: LocalizedStringResource = "Convert Map to Mermaid"
    static let description = IntentDescription(
        "Returns a canvas as Mermaid text: mindmap, flowchart, sequence or class, from its diagram type.")

    @Parameter(
        title: "Map",
        supportedContentTypes: [UTType("com.opennexus.document")!, UTType("com.opennexus.json-document")!])
    var map: IntentFile

    static var parameterSummary: some ParameterSummary { Summary("Convert \(\.$map) to Mermaid") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try checkIntentsEnabled()
        let (doc, _) = try readMap(map)
        guard let c = doc.orderedCanvases.first else { throw IntentFailure.unreadable("no canvases") }
        return .result(value: MermaidFormat.export(c))
    }
}

struct OpenQuickCapture: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Capture"
    static let description = IntentDescription("Shows the Quick Capture panel over any app (✦N).")

    @MainActor
    func perform() async throws -> some IntentResult {
        try checkIntentsEnabled()
        QuickCapture.shared.show()
        return .result()
    }
}

/// A command from the registry, as a Shortcuts parameter.
struct CommandEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "OpenNexus Command"
    static let defaultQuery = CommandQuery()

    var id: String
    var title: String
    var category: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(category)")
    }
}

struct CommandQuery: EntityStringQuery {
    @MainActor
    static var all: [CommandEntity] {
        CommandRegistry.standard.commands.filter { $0.scope == .global || $0.scope == .canvas }.map {
            CommandEntity(id: $0.id.rawValue, title: $0.title, category: $0.category.rawValue)
        }
    }

    func entities(for identifiers: [String]) async throws -> [CommandEntity] {
        await MainActor.run { Self.all.filter { identifiers.contains($0.id) } }
    }

    func entities(matching string: String) async throws -> [CommandEntity] {
        await MainActor.run { Self.all.filter { $0.title.localizedCaseInsensitiveContains(string) } }
    }

    func suggestedEntities() async throws -> [CommandEntity] { await MainActor.run { Self.all } }
}

struct RunCommand: AppIntent {
    static let title: LocalizedStringResource = "Run OpenNexus Command"
    static let description = IntentDescription(
        "Runs any OpenNexus command on the front map, as if you'd pressed its shortcut.")
    static let openAppWhenRun = true

    @Parameter(title: "Command")
    var command: CommandEntity

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$command)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try checkIntentsEnabled()
        guard let (_, wc) = AppPreferences.shared.frontDocument else { throw IntentFailure.noDocument }
        let id = CommandID(rawValue: command.id)
        if !wc.controller.perform(id) { wc.runWindowCommand(id) }
        return .result()
    }
}

struct OpenNexusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateMapFromClipboard(),
            phrases: [
                "Create a mind map from the clipboard in \(.applicationName)",
                "New \(.applicationName) map from clipboard",
            ],
            shortTitle: "Map from Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(
            intent: AddIdeaToInbox(),
            phrases: ["Add an idea to \(.applicationName)", "Capture an idea in \(.applicationName)"],
            shortTitle: "Add to Inbox", systemImageName: "tray.and.arrow.down")
        AppShortcut(
            intent: ExportCanvasAsPNG(), phrases: ["Export a map as PNG with \(.applicationName)"],
            shortTitle: "Export as PNG", systemImageName: "photo")
        AppShortcut(
            intent: ConvertMapToMermaid(), phrases: ["Convert a map to Mermaid with \(.applicationName)"],
            shortTitle: "Convert to Mermaid", systemImageName: "chevron.left.forwardslash.chevron.right")
        AppShortcut(
            intent: OpenQuickCapture(),
            phrases: ["Open Quick Capture in \(.applicationName)", "Quick capture with \(.applicationName)"],
            shortTitle: "Quick Capture", systemImageName: "bolt")
    }

    static let shortcutTileColor: ShortcutTileColor = .purple
}
