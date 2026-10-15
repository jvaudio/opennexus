import Foundation
import NexusCore
import NexusKeys
import NexusTheme

/// Update Style scopes (FMT-1 › Update style).
public enum UpdateStyleScope: Sendable {
    case siblings, sameLevel, subtopics
}

/// Styling: the Format panel, node styles, quick styles, copy / paste / reset style.
/// Every change is one undo step.
@MainActor
extension CanvasController {
    // MARK: Selection styles

    /// The merged style of the primary selection (what the Style tab shows).
    public var selectionStyle: TopicStyle {
        let id = selection.primary
        let c = canvas
        let depth = c.depth(of: id)
        let role: NodeRoleStyle = depth == 0 ? (id == c.root ? .root : .floating) : depth == 1 ? .main : .sub
        return StyleResolver.merged(role: role, depth: depth, node: c.nodes[id], env: styleEnvironment)
    }

    /// The node-level override of the primary selection.
    public var selectionOverride: TopicStyle { canvas.nodes[selection.primary]?.style ?? TopicStyle() }

    /// Changes the node-level style of every selected topic.
    public func updateSelectionStyle(_ name: String = "Change Style", _ body: (inout TopicStyle) -> Void) {
        let targets = selection.nodes
        perform(name) { e in
            for t in targets {
                e.update(t) { n in
                    var s = n.style ?? TopicStyle()
                    body(&s)
                    n.style = s.isEmpty ? nil : s
                }
            }
        }
    }

    public func copyStyle() {
        let n = canvas.nodes[selection.primary]
        styleClipboard = (n?.style ?? TopicStyle(), n?.quickStyle)
        showToast(Loc.t("Style copied"))
    }

    public func pasteStyle() {
        guard let clip = styleClipboard else {
            showToast(Loc.t("Copy a style first (⌥⌘C)"))
            return
        }
        let targets = selection.nodes
        perform("Paste Style") { e in
            for t in targets {
                e.update(t) {
                    $0.style = clip.style.isEmpty ? nil : clip.style
                    $0.quickStyle = clip.quick
                }
            }
        }
    }

    /// Reset Style returns topics to their skeleton, colour theme and theme.
    public func resetStyle() {
        let targets = selection.nodes
        perform("Reset Style") { e in
            for t in targets {
                e.update(t) {
                    $0.style = nil
                    $0.quickStyle = nil
                }
            }
        }
    }

    /// ⌃⌥1–8 and the Quick Style grid. "Default" clears the quick style.
    public func applyQuickStyle(_ id: String) {
        let targets = selection.nodes
        let value: String? = id == "default" ? nil : id
        perform("Quick Style") { e in
            for t in targets { e.update(t) { $0.quickStyle = $0.quickStyle == value ? nil : value } }
        }
    }

    public func applyQuickStyle(index n: Int) {
        let all = styleEnvironment.quickStyles
        guard all.indices.contains(n - 1) else { return }
        applyQuickStyle(all[n - 1].id)
    }

    /// Update Style: copy the primary topic's style to its siblings, every topic at its
    /// level, or all subtopics of its branch.
    public func updateStyle(_ scope: UpdateStyleScope) {
        let id = selection.primary
        let c = canvas
        guard let src = c.nodes[id] else { return }
        let style = src.style
        let quick = src.quickStyle
        switch scope {
        case .siblings:
            guard let p = c.parent(of: id), let kids = c.nodes[p]?.children else { return }
            perform("Apply Style to Siblings") { e in
                for k in kids where k != id {
                    e.update(k) {
                        $0.style = style
                        $0.quickStyle = quick
                    }
                }
            }
        case .sameLevel:
            let depth = c.depth(of: id)
            perform(Loc.f("Apply Style to Level %lld", depth + 1)) { e in
                e.updateMeta { $0.style.levels[depth] = style ?? TopicStyle() }
                // The level style now carries it; clear per-topic copies at this level.
                let parents = e.canvas.parentMap()
                for (nid, _) in e.canvas.nodes where e.canvas.depth(of: nid, parents: parents) == depth && nid != id {
                    e.update(nid) { $0.style = nil }
                }
            }
        case .subtopics:
            let ids = c.subtree(id).dropFirst()
            perform("Apply Style to Subtopics") { e in
                for k in ids {
                    e.update(k) {
                        $0.style = style
                        $0.quickStyle = quick
                    }
                }
            }
        }
    }

    /// Save as Quick Style…: adds the primary topic's merged override to the document library.
    public func saveAsQuickStyle(named name: String) {
        let style = selectionOverride
        var lib = library
        let base = name.lowercased().replacingOccurrences(of: " ", with: "-")
        var qid = "custom-\(base)"
        var i = 2
        while lib.quickStyles.contains(where: { $0.id == qid }) {
            qid = "custom-\(base)-\(i)"
            i += 1
        }
        lib.quickStyles.append(QuickStyle(id: qid, name: name, glyph: "★", style: style))
        updateLibrary("Save Quick Style", lib)
    }

    /// Select topics with this style.
    public func selectTopicsWithSameStyle() {
        let c = canvas
        guard let src = c.nodes[selection.primary] else { return }
        let matches = c.visibleNodes().filter {
            c.nodes[$0]?.style == src.style && c.nodes[$0]?.quickStyle == src.quickStyle
        }
        setSelection(Selection(primary: selection.primary, nodes: matches))
    }

    // MARK: Map

    public func updateCanvasStyle(
        _ name: String = "Change Map Style", morph: Bool = false,
        _ body: (inout CanvasStyle) -> Void
    ) {
        if morph { onMorph?() }
        perform(name) { e in e.updateMeta { body(&$0.style) } }
    }

    public func updateLayout(_ name: String = "Change Layout", _ body: (inout CanvasLayout) -> Void) {
        perform(name) { e in e.updateMeta { body(&$0.layout) } }
        onReveal?(selection.primary)
    }

    public func setNodeStyle(_ style: NodeStyle) {
        guard canvas.style.nodeStyle != style.rawValue else { return }
        updateCanvasStyle("Node Style", morph: true) { $0.nodeStyle = style.rawValue }
        showToast(Loc.f("Node style: %@", style.name))
    }

    /// ⌥⌘S: the next of the nine node styles, with a 300 ms morph.
    public func cycleNodeStyle() {
        setNodeStyle(NodeStyle.named(canvas.style.nodeStyle).next)
    }

    /// Writes the document's style library (custom themes, colours, quick styles) as one
    /// undoable step.
    public func updateLibrary(_ name: String, _ lib: StyleLibrary) {
        var p = Patch(canvasID: canvasID, selectionBefore: selection, selectionAfter: selection, actionName: name)
        p.themeBefore = store.model.theme
        p.themeAfter = lib.json
        guard p.themeBefore != p.themeAfter else { return }
        store.commit(p)
    }

    /// Saves the current look (theme + node style + palette) as a custom theme and switches to it.
    @discardableResult
    public func saveCurrentAsTheme(named name: String, base: Theme? = nil) -> Theme {
        var t = base ?? theme
        var lib = library
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "-")
        var tid = "custom-\(slug)"
        var i = 2
        while lib.themes.contains(where: { $0.id == tid }) || Theme.builtIn.contains(where: { $0.id == tid }) {
            tid = "custom-\(slug)-\(i)"
            i += 1
        }
        t.id = tid
        t.name = name
        if base == nil { t.palette = styleEnvironment.palette }
        lib.themes.append(t)
        updateLibrary("Save Theme", lib)
        setTheme(tid)
        return t
    }

    public func saveTheme(_ t: Theme) {
        var lib = library
        if let i = lib.themes.firstIndex(where: { $0.id == t.id }) { lib.themes[i] = t } else { lib.themes.append(t) }
        updateLibrary("Save Theme", lib)
    }

    public func deleteTheme(_ id: String) {
        var lib = library
        lib.themes.removeAll { $0.id == id }
        updateLibrary("Delete Theme", lib)
        if canvas.style.theme == id { setTheme("classic") }
    }

    /// A skeleton sets structure, node style and branch line in one step.
    public func applySkeleton(_ s: Skeleton) {
        onMorph?()
        perform("Skeleton") { e in
            e.updateMeta {
                $0.layout.structure = s.structure
                $0.style.nodeStyle = s.nodeStyle.rawValue
                $0.style.lineShape = s.line
            }
        }
        onReveal?(selection.primary)
    }

    /// Preview applies the colours (undoable) without closing the editor.
    public func previewPalette(_ p: ColorPalette) {
        var q = p
        if q.id.isEmpty { q.id = "custom-preview" }
        savePalette(q)
    }

    public func savePalette(_ p: ColorPalette) {
        var lib = library
        if let i = lib.palettes.firstIndex(where: { $0.id == p.id }) {
            lib.palettes[i] = p
        } else {
            lib.palettes.append(p)
        }
        updateLibrary("Save Colour Theme", lib)
        updateCanvasStyle("Colour Theme") { $0.palette = p.id }
    }
}
