import AVFoundation
import AppKit
import CoreImage
import Foundation
import ImagePlayground
import NexusCore
import Speech
import Translation
import Vision

// MARK: Remove background (Vision subject lift)

public enum SubjectLift {
    public struct NoSubject: LocalizedError {
        public var errorDescription: String? { "No subject found in the image." }
    }

    /// The image with everything but its subject made transparent (PNG data).
    public static func removeBackground(_ data: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { throw NoSubject() }
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            guard let obs = request.results?.first, !obs.allInstances.isEmpty else { throw NoSubject() }
            let buffer = try obs.generateMaskedImage(
                ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
            let ci = CIImage(cvPixelBuffer: buffer)
            let ctx = CIContext()
            guard let out = ctx.createCGImage(ci, from: ci.extent),
                let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
            else { throw NoSubject() }
            return png
        }.value
    }
}

// MARK: Make a sticker (Image Playground)

public enum StickerMaker {
    public enum Style: String, CaseIterable, Sendable {
        case animation, illustration, sketch
        public var title: String { rawValue.capitalized }
        var playground: ImagePlaygroundStyle {
            switch self {
            case .animation: .animation
            case .illustration: .illustration
            case .sketch: .sketch
            }
        }
    }

    /// Prompt pre-filled from the topic and its branch.
    public static func prompt(for id: NodeID, in c: Canvas) -> String {
        let text = c.nodes[id]?.text ?? ""
        let parent = c.parent(of: id).flatMap { c.nodes[$0]?.text }
        return parent.map { "\(text.lowercased()) for \($0.lowercased())" } ?? text.lowercased()
    }

    /// Up to three images (PNG), made on this Mac.
    public static func make(_ prompt: String, style: Style, limit: Int = 3) async throws -> [Data] {
        let creator = try await ImageCreator()
        var out: [Data] = []
        for try await img in creator.images(for: [.text(prompt)], style: style.playground, limit: limit) {
            if let png = NSBitmapImageRep(cgImage: img.cgImage).representation(using: .png, properties: [:]) {
                out.append(png)
            }
        }
        return out
    }
}

// MARK: Translate map (Translation framework)

public enum MapTranslator {
    public struct Options: Sendable {
        public var topicsAndLabels = true
        public var notes = true
        public var keepCode = false
        public init() {}
    }

    /// The strings a translation needs, in a stable order.
    public static func strings(_ c: Canvas, _ o: Options) -> [String] {
        var out: [String] = []
        for id in c.tops.flatMap({ c.subtree($0) }) {
            guard let n = c.nodes[id] else { continue }
            if o.topicsAndLabels && !(o.keepCode && n.textFormat == "code") {
                out.append(n.text)
                out += n.labels
            }
            if o.notes, let note = n.note?.text, !note.isEmpty { out.append(note) }
        }
        return out
    }

    /// A new canvas with the translated strings; structure and styles untouched.
    public static func translatedCopy(
        _ c: Canvas, _ o: Options, translations: [String: String], id: CanvasID, language: String
    ) -> Canvas {
        var copy = c
        copy.id = id
        copy.title = (translations[c.title] ?? c.title) + (c.title.isEmpty ? "" : " (\(language))")
        for id in c.tops.flatMap({ c.subtree($0) }) {
            guard var n = copy.nodes[id] else { continue }
            if o.topicsAndLabels && !(o.keepCode && n.textFormat == "code") {
                n.text = translations[n.text] ?? n.text
                n.labels = n.labels.map { translations[$0] ?? $0 }
                n.marks = []
            }
            if o.notes, let note = n.note?.text { n.note?.text = translations[note] ?? note }
            copy.nodes[id] = n
        }
        return copy
    }

    /// Translates with an installed language pair (download pairs in System Settings ›
    /// General › Language & Region › Translation Languages).
    public static func translate(_ strings: [String], from: Locale.Language, to: Locale.Language) async throws
        -> [String: String]
    {
        let session = TranslationSession(installedSource: from, target: to)
        let unique = Array(Set(strings.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }))
        let requests = unique.enumerated().map {
            TranslationSession.Request(sourceText: $1, clientIdentifier: "\($0)")
        }
        var out: [String: String] = [:]
        for r in try await session.translations(from: requests) {
            out[r.sourceText] = r.targetText
        }
        return out
    }

    public static func status(from: Locale.Language, to: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: from, to: to)
    }
}

// MARK: Record to map (SpeechAnalyzer)

/// Live transcription from the microphone, on this Mac.
@MainActor
public final class MapRecorder {
    public private(set) var transcript = ""
    public private(set) var volatile = ""
    public var onUpdate: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    public private(set) var started: Date?

    public init() {}

    public var elapsed: TimeInterval { started.map { Date().timeIntervalSince($0) } ?? 0 }

    public func start(locale: Locale = .current) async throws {
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = builder
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        let converter = format.flatMap { AVAudioConverter(from: hw, to: $0) }
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { buffer, _ in
            guard let converter, let format else {
                builder.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = format.sampleRate / hw.sampleRate
            guard
                let out = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1))
            else { return }
            var given = false
            _ = converter.convert(to: out, error: nil) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            builder.yield(AnalyzerInput(buffer: out))
        }
        engine.prepare()
        try engine.start()
        started = Date()
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    let text = String(r.text.characters)
                    if r.isFinal {
                        self.transcript += (self.transcript.isEmpty ? "" : " ") + text
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                    self.onUpdate?(self.transcript + (self.volatile.isEmpty ? "" : " " + self.volatile))
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
    }

    public func pause() {
        engine.pause()
    }

    public func resume() throws {
        try engine.start()
    }

    /// Stops and returns the final transcript.
    public func stop() async -> String {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        let t = (transcript + (volatile.isEmpty ? "" : " " + volatile)).trimmingCharacters(in: .whitespaces)
        started = nil
        return t
    }
}
