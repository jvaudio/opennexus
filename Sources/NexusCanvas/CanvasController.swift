import AppKit
import NexusAI
import NexusCore
import NexusFormat
import NexusInterchange
import NexusKeys
import NexusLayout
import NexusTheme
import Observation
import os

/// The canvas's three always-visible states (brief §4). Esc always leads back to Select.
public enum CanvasMode: String, Sendable {
    case select, edit, connect
}

/// A node's text editor session.
public struct EditSession: Equatable, Sendable {
    /// The topic being edited (for element labels: the element's anchor topic).
    public var node: NodeID
    public var text: String
    /// Rich-text runs while editing.
    public var marks: [TextMark] = []
    /// Set when editing a relationship label, boundary title or zone title.
    public var element: ElementRef?
    /// Select all text when the editor opens (new topics, so typing replaces the default).
    public var selectAll: Bool
    /// Text to insert on open (typing over a selection starts with this character).
    public var pendingInput: String?
    /// After this session commits, edit this topic (a decision branch: label, then step).
    public var then: NodeID?
}

public struct Toast: Equatable, Sendable {
    public var text: String
    public var serial: Int
}

let signposter = OSSignposter(subsystem: "com.opennexus.canvas", category: .pointsOfInterest)

/// The canvas's brain: modes, selection, editing and every keyboard command, with no
/// view code, so the whole keyboard flow is testable headless.
@MainActor
@Observable
public final class CanvasController {
    public let store: DocumentStore
    public private(set) var canvasID: CanvasID
    public internal(set) var mode: CanvasMode = .select
    public internal(set) var selection: Selection
    /// A selected non-topic element (relationship, boundary, summary, callout, zone).
    public internal(set) var selectedElement: ElementRef?
    /// Connect mode state (⇧⌘L).
    public internal(set) var connect: ConnectState?
    public internal(set) var edit: EditSession?
    /// The slash menu (`/`), in Select mode or at the start of an empty topic.
    public internal(set) var slash: SlashState?
    /// The Convert picker (⌥⌘T).
    public internal(set) var convert: ConvertState?
    /// Panels on technical canvases.
    public var iconLibraryVisible = false
    public var threatTableVisible = false
    /// The DFD violation whose card is showing.
    public internal(set) var focusedViolation: String?
    // MARK: On-device AI (M6)
    /// The model behind every AI feature (Apple's on-device model by default).
    @ObservationIgnored public var ai: any AIEngine = AppleEngine() {
        didSet { aiAvailability = ai.availability }
    }
    public internal(set) var aiAvailability: AIAvailability = .ready
    /// Ghost suggestions under a topic (⌥Space).
    public internal(set) var ghosts: GhostState?
    /// The prompt bar (⇧⌘Space), anchored to a topic.
    public internal(set) var promptBar: PromptBarState?
    public var aiPanelVisible = false
    public internal(set) var activeChat: String?
    public internal(set) var aiBusy: String?
    /// An answer streaming into the panel.
    public internal(set) var aiStreaming: String?
    /// A plan previewed on the canvas (drawn as ghosts).
    public internal(set) var previewPlan: ChangePlan?
    /// "Apple Intelligence is off…": shown in place when an entry point can't run.
    public internal(set) var aiNotice: String?
    /// Time from ⌥Space to the first ghost, for the performance budget.
    public internal(set) var lastGhostLatency: TimeInterval?
    @ObservationIgnored var aiTask: Task<Void, Never>?
    @ObservationIgnored var idleSuggestion: Task<Void, Never>?
    /// Export scope: only these topics are drawn (offscreen exporters set it).
    @ObservationIgnored public var isolate: Set<NodeID>?
    /// Zone-scoped exports: this zone is drawn with what `isolate` keeps.
    @ObservationIgnored public var isolateZone: String?
    /// An AI+ sheet (translate, mask, sticker, record, remove background).
    public internal(set) var aiSheet: AISheet?
    // Files, import and export (M7).
    public internal(set) var exportState: ExportState?
    public internal(set) var mapShot: MapShotState? {
        didSet { if oldValue != mapShot { onSceneChange?(true) } }
    }
    public internal(set) var printState: PrintLayout.Options?
    public internal(set) var mergeState: MergeState?
    /// Pictures the merge sheet is reading, by name (D191).
    @ObservationIgnored var mergeReads: [String: Task<Void, Never>] = [:]
    public internal(set) var importReport: ImportReport?
    /// File › Set Password… sheet (the app encrypts on save).
    public var passwordSheet = false
    public var documentEncrypted = false
    @ObservationIgnored public var onSetPassword: ((String, String?, Bool) -> Void)?
    @ObservationIgnored public var onRemovePassword: (() -> Void)?
    /// File › Revert To › Browse Recovery Snapshots…
    public var snapshots: [RecoverySnapshot]?
    @ObservationIgnored public var onRestoreSnapshot: ((RecoverySnapshot) -> Void)?
    /// Merge sheet › + Add… (the app shows an open panel, then calls `addMergeSource`).
    @ObservationIgnored public var onChooseMergeFiles: (() -> Void)?
    /// The first-run tour, while it runs (M8).
    public var tour: TourController?
    @ObservationIgnored public var onTourEnded: ((TourController) -> Void)?
    /// The third time a command is run with the mouse, this suggests its key (M8 tips).
    @ObservationIgnored var mouseUses: [CommandID: Int] = [:]
    public var tip: Tip?
    /// ZEN's "Today" focus timer (Settings › Appearance › ZEN & chrome).
    @ObservationIgnored var zenStarted: Date?
    /// Forces the system appearance for "Follow system light / dark" (tests).
    @ObservationIgnored public var systemIsDark: Bool?
    /// The canvas's counts, cached per document revision: the status bar re-renders on
    /// every zoom step, and counting 5,000 topics each time cost a frame (M10).
    public var canvasCounts: CanvasCounts {
        let key = (store.revision, canvasID)
        if let c = countsCache, c.0 == key.0, c.1 == key.1 { return c.2 }
        let counts = CanvasCounts(canvas)
        countsCache = (key.0, key.1, counts)
        return counts
    }
    @ObservationIgnored private var countsCache: (Int, CanvasID, CanvasCounts)?

    /// Bumped on every scene rebuild (caches keyed on the scene, like the minimap's).
    @ObservationIgnored public private(set) var sceneRevision = 0
    /// Offscreen exports and previews draw the canvas's own theme, whatever the
    /// appearance of the Mac that made them (D119).
    @ObservationIgnored public var rendersThemeAsNamed = false
    /// Set by the first key press; the empty-canvas hints fade then.
    public internal(set) var hasPressedKey = false
    /// The clipboard (tests use a private pasteboard).
    @ObservationIgnored public var pasteboard: NSPasteboard = .general
    /// The app's save panel: data and a suggested file name.
    @ObservationIgnored public var onSaveFile: ((Data, String) -> Void)?
    /// Choose a folder, then write these files (split by branch).
    @ObservationIgnored public var onSaveFolder: (([(String, Data)]) -> Void)?
    /// Map Shot: saved to the folder from Settings › Export.
    @ObservationIgnored public var onSaveMapShot: ((Data, String) -> Void)?
    @ObservationIgnored public var onPrintPDF: ((Data, String) -> Void)?
    @ObservationIgnored public var onSaveDocument: ((DocumentModel, String) -> Void)?
    /// "Use a local model" and ⌘, open Settings › AI.
    @ObservationIgnored public var onOpenAISettings: (() -> Void)?
    /// Opens Settings › Shortcuts, recording a new key for the command (the palette's
    /// "Shortcuts › …" row).
    @ObservationIgnored public var onRebind: ((CommandID) -> Void)?
    /// Give keyboard focus back to the canvas (after the prompt bar or a panel field).
    @ObservationIgnored public var onRestoreFocus: (() -> Void)?

    // MARK: Task planning (M11)
    /// The Task editor (⌃⌘T), while it's open.
    public internal(set) var taskEditor: TaskEditorState?
    /// Gantt rows the user collapsed (view state, D146).
    public internal(set) var ganttCollapsed: Set<NodeID> = []
    public internal(set) var ganttScale: GanttScale = .day
    /// The Gantt view has keyboard focus (its key scope is active).
    @ObservationIgnored public var ganttFocused = false
    /// Scroll the Gantt so this day shows (Go to Today).
    @ObservationIgnored public var onGanttScroll: ((TaskDate) -> Void)?
    /// "Today" for task lines and the Gantt (tests pin it).
    @ObservationIgnored public var today: TaskDate?
    /// The legend has the keyboard: arrows move it (M21, D203).
    public internal(set) var legendSelected = false

    // MARK: Views & navigation (M5)
    /// Canvas, Outline, Split or Gantt (⌘1–4).
    public var viewMode: CanvasViewMode = .canvas {
        didSet { if viewMode != oldValue { onViewMode?(viewMode) } }
    }
    public internal(set) var palette: PaletteState?
    public internal(set) var jump: JumpState?
    /// Focus (⌘.): the branch shown as the whole map.
    public internal(set) var focusRoot: NodeID?
    public var filterBarVisible = false
    public internal(set) var filterClauses: [NodeFilter.Clause] = []
    public internal(set) var filterHides = false
    /// The navigation panel tab (1 Search … 5 To-dos), nil when hidden.
    public var navTab: Int?
    public internal(set) var search = SearchState()
    /// Bumped to move keyboard focus into the search field (⌘F).
    public internal(set) var searchFocusSerial = 0
    /// Markers and labels highlighted from the Tags tab (`marker:…`, `label:…`).
    public internal(set) var tagHighlight: Set<String> = []
    public internal(set) var zen = false
    public internal(set) var present: PresentState?
    public var countsVisible = false
    /// The camera zoom, for the zoom control.
    public internal(set) var zoom: Double = 1
    @ObservationIgnored public var onViewMode: ((CanvasViewMode) -> Void)?
    /// The outline pane has keyboard focus (its key scope is active).
    @ObservationIgnored public var outlineFocused = false
    @ObservationIgnored public var onOutlineEditChange: ((EditSession?) -> Void)?
    @ObservationIgnored public var onZen: ((Bool) -> Void)?
    @ObservationIgnored public var onPresent: ((Bool) -> Void)?
    /// Export the deck: "PDF", "PowerPoint", "Keynote" or "Video".
    @ObservationIgnored public var onExportSlides: ((String) -> Void)?
    /// P while presenting: show or hide the presenter view.
    @ObservationIgnored public var onTogglePresenter: (() -> Void)?
    /// Frames a set of topics (focus, jump, present); `stage` is the slide's aspect, if any.
    @ObservationIgnored public var onFrame: (([NodeID], Double?) -> Void)?
    /// Commands the window runs (new canvas, format panel, export …), for the palette.
    @ObservationIgnored public var externalCommands: Set<CommandID> = []
    @ObservationIgnored public var onExternalCommand: ((CommandID) -> Void)?

    /// The highlighted protocol suggestion while an architecture label is edited.
    public internal(set) var suggestionIndex: Int?
    /// Bumped when a conversion starts, so the view uses the 600 ms morph.
    public internal(set) var morphSerial = 0
    /// Adds a canvas to the document (the window wires this to an undoable insert).
    /// Saves text the user exported (CSV): suggested name and contents.
    @ObservationIgnored public var onSaveText: ((String, String) -> Void)?
    /// Replaces the live editor's text (slash menu picks clear their `/query`).
    @ObservationIgnored public var onEditorReplaceText: ((String) -> Void)?
    public private(set) var toast: Toast?
    public var cheatSheetVisible = false
    public private(set) var scene = Scene()

    @ObservationIgnored public internal(set) var registry: CommandRegistry
    @ObservationIgnored let baseRegistry: CommandRegistry
    /// App preferences (Settings). Tests inject an isolated store.
    @ObservationIgnored public var prefs: Preferences = .shared {
        didSet { observePreferences() }
    }
    @ObservationIgnored var prefsObserver: (any NSObjectProtocol)?
    /// Bumps when preferences change (overlays read it).
    public internal(set) var prefsRevision = 0
    @ObservationIgnored public var profile: KeyProfile = .openNexus {
        didSet { rebuildLookup() }
    }
    @ObservationIgnored public var customBindings: [CommandID: [KeyChord]] = [:] {
        didSet { rebuildLookup() }
    }
    @ObservationIgnored private var lookup: [Scope: [KeyChord: CommandID]] = [:]
    @ObservationIgnored let builder: SceneBuilder
    @ObservationIgnored private var toastSerial = 0
    @ObservationIgnored private var committingOwnPatch = false
    /// ⌥⌘C / ⌥⌘V style clipboard.
    @ObservationIgnored var styleClipboard: (style: TopicStyle, quick: String?)?
    /// Asks the view to morph node looks on the next update (node style changes).
    @ObservationIgnored public var onMorph: (() -> Void)?
    /// Asks the host to present a popover or sheet (note, link, labels, markers…).
    @ObservationIgnored public var onRequest: ((CanvasRequest) -> Void)?
    /// Opens a web or file URL (the app routes it to NSWorkspace).
    @ObservationIgnored public var onOpenURL: ((URL) -> Void)?
    /// Topic-link history for ⌘[ (fly back).
    @ObservationIgnored var linkHistory: [(CanvasID, NodeID)] = []

    /// Called after the scene changes. `animated` is false for edits that must not move
    /// anything (typing into the edited node still reflows, but without delay).
    @ObservationIgnored public var onSceneChange: ((_ animated: Bool) -> Void)?
    /// Asks the view to bring a node into view.
    @ObservationIgnored public var onReveal: ((NodeID) -> Void)?
    /// Asks the view to start or stop the text editor.
    @ObservationIgnored public var onEditChange: ((EditSession?) -> Void)?
    /// View-level commands (zoom, fit) the view handles itself.
    @ObservationIgnored public var viewCommandHandler: ((CommandID) -> Bool)?
    @ObservationIgnored public var viewCommandValidator: ((CommandID) -> Bool)?
    /// Where a new floating topic goes when created from the keyboard.
    @ObservationIgnored public var floatingPlacement: (() -> CGPoint)?
    /// Where the empty-canvas menu's Add Floating Topic puts the topic (M17).
    @ObservationIgnored var menuFloatingPoint: CGPoint?

    public init(
        store: DocumentStore, canvasID: CanvasID? = nil, registry: CommandRegistry = .standard,
        measurer: NodeMeasurer = NodeMeasurer()
    ) {
        self.store = store
        let id = canvasID ?? store.model.canvasOrder.first ?? "c1"
        self.canvasID = id
        self.registry = registry
        self.baseRegistry = registry
        self.builder = SceneBuilder(measurer: measurer)
        self.selection = Selection(store.model.canvases[id]?.root ?? "n1")
        rebuildLookup()
        rebuildScene()
        store.addObserver(self) { [weak self] patch in self?.storeDidApply(patch) }
        observePreferences()
    }

    // MARK: Model access

    public var canvas: Canvas {
        store.canvas(canvasID) ?? Canvas(id: canvasID, title: "")
    }

    /// Custom themes, colour themes and quick styles saved in the document (`theme.json`).
    public var library: StyleLibrary { StyleLibrary(json: store.model.theme) }

    public var theme: Theme { Theme.named(canvas.style.theme, custom: library.themes) }

    public var styleEnvironment: StyleEnvironment {
        let lib = library
        var theme = Theme.named(canvas.style.theme, custom: lib.themes)
        // Present mode's slide theme swaps to the theme's dark or light counterpart.
        if present != nil {
            switch canvas.presentation.theme {
            case "dark" where !theme.isDark: theme = Theme.named(theme.counterpart ?? "graphite", custom: lib.themes)
            case "light" where theme.isDark: theme = Theme.named(theme.counterpart ?? "classic", custom: lib.themes)
            default: break
            }
        }
        theme = contrastTheme(zenTheme(followSystemTheme(theme)))
        var env = StyleEnvironment(
            theme: theme, canvasStyle: canvas.style,
            customPalettes: lib.palettes, customQuickStyles: lib.quickStyles)
        env.adaptText = prefs.bool("appearance.adaptText")
        return env
    }

    public func switchCanvas(to id: CanvasID) {
        guard store.canvas(id) != nil, id != canvasID else { return }
        if mode == .edit { commitEdit() }
        canvasID = id
        selection = Selection(canvas.root)
        mode = .select
        rebuildScene()
        onSceneChange?(false)
        onReveal?(selection.primary)
    }

    /// Runs an edit against the current canvas and commits it as one undo step.
    @discardableResult
    func perform<T>(
        _ actionName: String, refresh: Bool = true, selectionAfter: ((T) -> Selection)? = nil,
        _ body: (inout CanvasEditor) throws -> T
    ) -> T? {
        var editor = CanvasEditor(canvas)
        do {
            let result = try body(&editor)
            let after = selectionAfter?(result) ?? selection
            let patch = editor.patch(actionName: actionName, selectionBefore: selection, selectionAfter: after)
            selection = after
            if !patch.isEmpty {
                committingOwnPatch = true
                store.commit(patch)
                committingOwnPatch = false
            }
            if refresh {
                rebuildScene()
                onSceneChange?(true)
            }
            return result
        } catch let refusal as TreeOperationRefusal {
            showToast(refusal.description)
        } catch {
            showToast(String(describing: error))
        }
        return nil
    }

    private func storeDidApply(_ patch: Patch) {
        defer { tour?.didChange() }
        // Canvas added or removed (merge, import, delete, or their undo): stay on a canvas
        // that exists, preferring the one the change is about.
        if patch.changesCanvasSet {
            if store.canvas(canvasID) == nil || (patch.canvases[patch.canvasID]?.after != nil && !committingOwnPatch) {
                let target = store.canvas(patch.canvasID) != nil ? patch.canvasID : store.model.canvasOrder.first
                if let target, target != canvasID {
                    canvasID = target
                    selection = Selection(canvas.root)
                    edit = nil
                    mode = .select
                    rebuildScene()
                    onSceneChange?(false)
                    return
                }
            }
        }
        guard patch.canvasID == canvasID, !committingOwnPatch else { return }
        if let s = patch.selectionAfter {
            let c = canvas
            let valid = s.nodes.filter { c.nodes[$0] != nil }
            if c.nodes[s.primary] != nil {
                selection = Selection(primary: s.primary, nodes: valid)
            } else if let first = valid.first {
                selection = Selection(primary: first, nodes: valid)
            }
        }
        if canvas.nodes[selection.primary] == nil { selection = Selection(canvas.root) }
        if case .zone(let z)? = selectedElement, !canvas.zones.contains(where: { $0.id == z }) { selectedElement = nil }
        if let e = edit, canvas.nodes[e.node] == nil {
            edit = nil
            mode = .select
            onEditChange?(nil)
        }
        rebuildScene()
        onSceneChange?(true)
        onReveal?(selection.primary)
    }

    func rebuildScene() {
        sceneRevision &+= 1
        // Element sessions (labels, titles) carry their source node for context only; the
        // topic itself isn't being edited.
        let state: SceneBuilder.EditingState? = edit.flatMap {
            $0.element == nil ? .init(node: $0.node, text: $0.text) : nil
        }
        let s = signposter.beginInterval("scene")
        scene = builder.build(canvas, env: styleEnvironment, editing: state, view: currentViewState())
        // A relationship label grows with the live text while it's edited.
        if let e = edit, case .relationship(let id) = e.element,
            let i = scene.relationships.firstIndex(where: { $0.relationship.id == id })
        {
            scene.relationships[i].relationship.label = e.text
        }
        signposter.endInterval("scene", s)
    }

    // MARK: Selection

    public func select(_ id: NodeID, extend: Bool = false) {
        guard canvas.nodes[id] != nil else { return }
        if mode == .edit { commitEdit() }
        selection = extend ? selection.extended(with: id) : Selection(id)
        selectedElement = nil
        legendSelected = false
        onSceneChange?(false)
        onReveal?(id)
    }

    public func setSelection(_ s: Selection) {
        selection = s
        legendSelected = false
        onSceneChange?(false)
    }

    func navigate(_ dir: NavigationDirection, extend: Bool) {
        let centers = scene.nodes.mapValues(\.frame.center)
        guard let next = SpatialNavigation.next(from: selection.primary, direction: dir, centers: centers) else {
            return
        }
        select(next, extend: extend)
    }

    // MARK: Editing

    /// Space: edit keeping the text, caret at the end.
    public func beginEditing(_ id: NodeID? = nil, selectAll: Bool = false) {
        let id = id ?? selection.primary
        guard let node = canvas.nodes[id] else { return }
        selection = Selection(id)
        selectedElement = nil
        var session = EditSession(node: id, text: node.text, selectAll: selectAll)
        session.marks = node.marks
        edit = session
        mode = .edit
        onEditChange?(edit)
        onReveal?(id)
    }

    /// Typing over a selected node replaces its text, starting with `input`.
    public func beginEditing(replacingWith input: String) {
        let id = selection.primary
        guard canvas.nodes[id] != nil else { return }
        selection = Selection(id)
        edit = EditSession(node: id, text: "", selectAll: false, pendingInput: input)
        mode = .edit
        rebuildScene()
        onSceneChange?(false)
        onEditChange?(edit)
    }

    /// The editor reports every text change; the node grows live and the map reflows.
    public func editorTextDidChange(_ text: String, marks: [TextMark]? = nil) {
        guard var e = edit, e.text != text || (marks != nil && marks != e.marks) else { return }
        e.text = text
        if let marks { e.marks = marks }
        e.pendingInput = nil
        edit = e
        updateSlashFromEditor(text)
        rebuildScene()
        onSceneChange?(true)
    }

    /// Return / Esc: commit and return to Select on the same node.
    public func commitEdit() {
        guard let e = edit else { return }
        // A new topic (its default text was selected) may get ideas after a pause.
        defer { if e.selectAll && e.element == nil { scheduleIdleSuggestion(for: e.node) } }
        edit = nil
        mode = .select
        if let element = e.element {
            commitElementText(element, e.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let next = e.then {
                selectedElement = nil
                beginEditing(next, selectAll: true)
            }
            return
        }
        var text = e.text
        while let last = text.last, last.isWhitespace { text.removeLast() }
        if umlAutoFormat { text = Self.formatUMLMember(text) }
        let old = canvas.nodes[e.node]?.text ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallback =
                e.node == canvas.root
                ? "Central Topic" : defaultTopicText(type: canvas.type, depth: canvas.depth(of: e.node))
            text = old.isEmpty ? fallback : old
        }
        selection = Selection(e.node)
        onEditChange?(nil)
        let marks = e.marks.filter { !$0.isPlain && $0.length > 0 && $0.start + $0.length <= (text as NSString).length }
        let oldMarks = canvas.nodes[e.node]?.marks ?? []
        slash = nil
        if text != old || marks != oldMarks {
            let protocolLabel = defaultProtocolLabel(for: e.node, text: text)
            perform("Typing") {
                $0.setText(e.node, text)
                $0.update(e.node) {
                    $0.marks = marks
                    if let protocolLabel { $0.edgeLabel = protocolLabel }
                }
            }
        } else {
            rebuildScene()
            onSceneChange?(true)
        }
    }

    // MARK: Keyboard

    func rebuildLookup() {
        lookup = registry.lookupTable(profile: profile, custom: customBindings)
    }

    public var activeScope: Scope {
        switch mode {
        case .select:
            viewMode == .gantt && ganttFocused ? .gantt : outlineFocused ? .outline : legendActive ? .legend : .canvas
        case .edit: .editor
        case .connect: .connect
        }
    }

    /// Resolves a chord in the current mode.
    public func command(for chord: KeyChord) -> CommandID? {
        // The outline's own keys win there; everything else works as on the canvas.
        if activeScope == .outline, let id = lookup[.outline]?[chord] ?? lookup[.canvas]?[chord] { return id }
        // The Gantt's own keys win; a few topic commands (to-do, priority, delete, palette,
        // Task…) work there too. Canvas navigation and creation don't.
        if activeScope == .gantt {
            if let id = lookup[.gantt]?[chord] { return id }
            if let id = lookup[.canvas]?[chord], Self.ganttPassThrough.contains(id) { return id }
            return lookup[.global]?[chord]
        }
        // The selected legend's keys win; everything else works as on the canvas.
        if activeScope == .legend {
            return lookup[.legend]?[chord] ?? lookup[.canvas]?[chord] ?? lookup[.global]?[chord]
        }
        return lookup[activeScope]?[chord] ?? lookup[.global]?[chord]
    }

    /// A Gantt-scope command bound to this chord (the Gantt claims these before the menus).
    public func ganttCommand(for chord: KeyChord) -> CommandID? { lookup[.gantt]?[chord] }

    /// Bindings as resolved under the current profile (for menus, hints, cheat sheet).
    public func bindings(for id: CommandID) -> [KeyChord] {
        registry.bindings(for: id, profile: profile, custom: customBindings)
    }

    public enum KeyResult: Equatable {
        case handled
        /// Not a command; start editing and feed this key to the editor.
        case beginTyping
        case ignored
    }

    /// Select-mode key handling. The view calls this for every key down.
    public func handleKey(_ chord: KeyChord, characters: String?) -> KeyResult {
        if !hasPressedKey { hasPressedKey = true }
        if tip != nil { tip = nil }
        if palette != nil { return handlePaletteKey(chord, characters: characters) ? .handled : .ignored }
        if jump != nil { return handleJumpKey(chord, characters: characters) ? .handled : .ignored }
        if present != nil, mode == .select {
            // ⌘-chords (⌘Z, ⌘S …) still work while presenting.
            if chord.modifiers.contains(.command), let id = command(for: chord), perform(id) { return .handled }
            return handlePresentKey(chord, characters: characters) ? .handled : .ignored
        }
        if convert != nil { return handleConvertKey(chord, characters: characters) ? .handled : .ignored }
        if mapShot != nil { return handleMapShotKey(chord) ? .handled : .ignored }
        aiNotice = nil
        if ghosts != nil, handleGhostKey(chord) { return .handled }
        // Esc climbs out of Focus, then leaves ZEN, before collapsing the selection.
        if chord.key == .escape, chord.modifiers.isEmpty, mode == .select, selectedElement == nil, slash == nil,
            !legendActive
        {
            if focusRoot != nil {
                climbFocus()
                return .handled
            }
            if zen {
                toggleZen()
                return .handled
            }
        }
        if let s = slash, !s.inEditor { return handleSlashKey(chord, characters: characters) ? .handled : .ignored }
        if mode == .connect { return handleConnectKey(chord, characters: characters) ? .handled : .ignored }
        if selectedElement != nil, let r = handleElementKey(chord) { return r }
        if let id = command(for: chord) {
            // A topic command takes the keyboard back from the legend.
            if legendActive, registry[id]?.scope == .canvas { deselectLegend() }
            if perform(id) { return .handled }
            if canPerform(id) == false, registry[id]?.standardAction != nil { return .ignored }
        }
        let typed = chord.modifiers.subtracting(.shift).isEmpty
        if mode == .select, typed, profile.typingReplacesSelection, let c = characters, !c.isEmpty,
            c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            !c.unicodeScalars.contains(where: { $0.value >= 0xF700 && $0.value <= 0xF8FF })
        {
            if legendActive { deselectLegend() }
            return .beginTyping
        }
        return .ignored
    }

    // MARK: Toasts

    public func showToast(_ text: String) {
        toastSerial += 1
        toast = Toast(text: text, serial: toastSerial)
        let serial = toastSerial
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            if self?.toast?.serial == serial { self?.toast = nil }
        }
    }
}
