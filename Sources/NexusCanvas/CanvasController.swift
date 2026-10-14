import AppKit
import NexusCore
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
    public private(set) var toast: Toast?
    public var cheatSheetVisible = false
    public private(set) var scene = Scene()

    @ObservationIgnored public let registry: CommandRegistry
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

    public init(
        store: DocumentStore, canvasID: CanvasID? = nil, registry: CommandRegistry = .standard,
        measurer: NodeMeasurer = NodeMeasurer()
    ) {
        self.store = store
        let id = canvasID ?? store.model.canvasOrder.first ?? "c1"
        self.canvasID = id
        self.registry = registry
        self.builder = SceneBuilder(measurer: measurer)
        self.selection = Selection(store.model.canvases[id]?.root ?? "n1")
        rebuildLookup()
        rebuildScene()
        store.addObserver(self) { [weak self] patch in self?.storeDidApply(patch) }
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
        return StyleEnvironment(
            theme: Theme.named(canvas.style.theme, custom: lib.themes), canvasStyle: canvas.style,
            customPalettes: lib.palettes, customQuickStyles: lib.quickStyles)
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
            showToast("\(error)")
        }
        return nil
    }

    private func storeDidApply(_ patch: Patch) {
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
        // Element sessions (labels, titles) carry their source node for context only; the
        // topic itself isn't being edited.
        let state: SceneBuilder.EditingState? = edit.flatMap {
            $0.element == nil ? .init(node: $0.node, text: $0.text) : nil
        }
        let s = signposter.beginInterval("scene")
        scene = builder.build(canvas, env: styleEnvironment, editing: state)
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
        onSceneChange?(false)
        onReveal?(id)
    }

    public func setSelection(_ s: Selection) {
        selection = s
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
        rebuildScene()
        onSceneChange?(true)
    }

    /// Return / Esc: commit and return to Select on the same node.
    public func commitEdit() {
        guard let e = edit else { return }
        edit = nil
        mode = .select
        if let element = e.element {
            commitElementText(element, e.text.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        var text = e.text
        while let last = text.last, last.isWhitespace { text.removeLast() }
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
        if text != old || marks != oldMarks {
            perform("Typing") {
                $0.setText(e.node, text)
                $0.update(e.node) { $0.marks = marks }
            }
        } else {
            rebuildScene()
            onSceneChange?(true)
        }
    }

    // MARK: Keyboard

    private func rebuildLookup() {
        lookup = registry.lookupTable(profile: profile, custom: customBindings)
    }

    public var activeScope: Scope {
        switch mode {
        case .select: .canvas
        case .edit: .editor
        case .connect: .connect
        }
    }

    /// Resolves a chord in the current mode.
    public func command(for chord: KeyChord) -> CommandID? {
        lookup[activeScope]?[chord] ?? lookup[.global]?[chord]
    }

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
        if mode == .connect { return handleConnectKey(chord, characters: characters) ? .handled : .ignored }
        if selectedElement != nil, let r = handleElementKey(chord) { return r }
        if let id = command(for: chord) {
            if perform(id) { return .handled }
            if canPerform(id) == false, registry[id]?.standardAction != nil { return .ignored }
        }
        let typed = chord.modifiers.subtracting(.shift).isEmpty
        if mode == .select, typed, profile.typingReplacesSelection, let c = characters, !c.isEmpty,
            c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
            !c.unicodeScalars.contains(where: { $0.value >= 0xF700 && $0.value <= 0xF8FF })
        {
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
