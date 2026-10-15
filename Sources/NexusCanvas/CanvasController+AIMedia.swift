import AppKit
import NaturalLanguage
import NexusAI
import NexusCore

/// The AI+ sheets (artboard 52).
public enum AISheet: Equatable, Sendable {
    case translate
    case mask
    case sticker(NodeID)
    case record
    case removeBackground(NodeID)
}

extension CanvasController {
    public func openAISheet(_ s: AISheet) {
        if mode == .edit { commitEdit() }
        switch s {
        case .translate, .mask, .removeBackground: break
        default: guard aiCanRun() else { return }
        }
        aiSheet = s
    }

    public func closeAISheet() { aiSheet = nil }

    // MARK: Translate map

    /// The map's dominant language (NaturalLanguage).
    public var mapLanguage: Locale.Language {
        let r = NLLanguageRecognizer()
        r.processString(canvas.nodes.values.map(\.text).joined(separator: ". "))
        return Locale.Language(identifier: r.dominantLanguage?.rawValue ?? "en")
    }

    /// Writes a translated copy as a new canvas; the original stays. One step.
    public func translateMap(to target: Locale.Language, options: MapTranslator.Options) async {
        let c = canvas
        let source = mapLanguage
        do {
            let table = try await MapTranslator.translate(MapTranslator.strings(c, options), from: source, to: target)
            let name = Locale.current.localizedString(forLanguageCode: target.languageCode?.identifier ?? "") ?? ""
            let copy = MapTranslator.translatedCopy(
                c, options, translations: table, id: store.model.makeCanvasID(), language: name)
            addCanvas(copy)
            showToast("Translated to \(name) · new canvas")
        } catch {
            showToast(
                "Translation needs the language pair installed: System Settings › General › Language & Region › Translation Languages."
            )
        }
    }

    /// Adds a canvas after the current one, as one undo step, and shows it.
    func addCanvas(_ c: Canvas, actionName: String = "New Canvas") {
        var target = c.id
        store.commitDocument(actionName, focus: canvasID) { d in
            target = d.add([c], after: d.canvasOrder.firstIndex(of: canvasID))[0]
        }
        switchCanvas(to: target)
    }

    // MARK: Data masking

    public var maskHits: [Masker.Hit] { Masker.scan(canvas, options: maskOptions) }

    /// Settings › Privacy & Data › Data masking.
    public var maskOptions: Masker.Options {
        var o = Masker.Options()
        var kinds: Set<Masker.Kind> = [.custom]
        if prefs.bool("privacy.maskEmails") { kinds.insert(.emails) }
        if prefs.bool("privacy.maskPhones") { kinds.insert(.phones) }
        if prefs.bool("privacy.maskKeys") { kinds.insert(.keys) }
        if prefs.bool("privacy.maskNames") { kinds.insert(.names) }
        o.kinds = kinds
        o.custom = prefs.string("privacy.maskPatterns").split(separator: "\n").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty && (try? NSRegularExpression(pattern: $0)) != nil }
        o.glyph = prefs.string("privacy.maskGlyph")
        return o
    }

    /// A masked copy for export, Present or sharing, from the hits you kept.
    public func makeMaskedCopy(_ hits: [Masker.Hit]) {
        let copy = Masker.maskedCopy(canvas, hits: hits, id: store.model.makeCanvasID(), options: maskOptions)
        addCanvas(copy)
        showToast(Loc.n("Masked %lld item · new canvas", "Masked %lld items · new canvas", hits.count))
    }

    // MARK: Remove background (Vision)

    public func removeBackground(_ id: NodeID, replace: Bool) async {
        guard let asset = canvas.nodes[id]?.image?.asset, let data = store.model.assets[asset] else {
            showToast("This topic has no image")
            return
        }
        do {
            let png = try await SubjectLift.removeBackground(data)
            let name = storeAsset(png, ext: "png")
            perform(replace ? "Remove Background" : "Add Cut-out") { e in
                e.update(id) { n in
                    if replace {
                        n.image?.asset = name
                    } else {
                        n.attachments.append(AssetRef(asset: name, name: "Cut-out.png"))
                    }
                }
            }
        } catch {
            showToast(error.localizedDescription)
        }
    }

    // MARK: Make a sticker (Image Playground)

    /// The pick lands on the topic, with its background removed.
    public func applySticker(_ png: Data, to id: NodeID) async {
        let cut = (try? await SubjectLift.removeBackground(png)) ?? png
        let name = storeAsset(cut, ext: "png")
        perform("Make Sticker") { e in e.update(id) { $0.sticker = AssetRef(asset: name) } }
    }

    // MARK: Record to map (SpeechAnalyzer)

    /// The transcript becomes the root's note (one undo); key points arrive as ghosts.
    public func finishRecording(_ transcript: String) {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let root = canvas.root
        perform("Record to Map") { e in
            e.update(root) { n in
                let before = n.note?.text ?? ""
                n.note = Note(text: before.isEmpty ? t : before + "\n\n" + t)
            }
        }
        select(root)
        requestGhosts(.ideas, prompt: "Key points from this recording, as topics: \(t.prefix(4000))")
    }
}
