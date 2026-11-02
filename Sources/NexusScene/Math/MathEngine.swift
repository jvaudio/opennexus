import Foundation
import JavaScriptCore

/// TeX typesetting (M48, D420): MathJax, vendored as one script, runs in a JavaScriptCore
/// context on its own queue, started the first time a formula is needed. Results are cached
/// by source and display mode, in ems, so size and colour apply when drawn.
///
/// On the app's canvases (`defersOnMainThread`), a formula that isn't cached yet is typeset
/// in the background and its source shows until `didTypeset`, so typing never waits.
/// Everything else (exports, the CLI, extensions, tests, other threads) waits for it.
public final class MathEngine: @unchecked Sendable {
    public static let shared = MathEngine()

    public enum Result: Sendable, Hashable {
        case glyphs(MathGlyphs)
        /// MathJax's message: the formula shows its source in the error colour.
        case error(String)

        public var glyphs: MathGlyphs? {
            if case .glyphs(let g) = self { g } else { nil }
        }
    }

    public struct Key: Hashable, Sendable {
        public var source: String
        public var display: Bool

        public init(_ source: String, display: Bool) {
            self.source = source
            self.display = display
        }
    }

    /// Posted on the main thread when formulas typeset in the background are ready.
    public static let didTypeset = Notification.Name("OpenNexusMathDidTypeset")

    /// Set by the app: main-thread lookups that miss the cache typeset in the background.
    nonisolated(unsafe) public static var defersOnMainThread = false
    /// Exports in progress on the main thread (`waiting`): they need every formula now.
    nonisolated(unsafe) private static var waitDepth = 0

    /// Runs `body` with every lookup on this thread waiting for its formula: an export or a
    /// print made while the app's canvases defer.
    public static func waiting<T>(_ body: () throws -> T) rethrows -> T {
        guard Thread.isMainThread else { return try body() }
        waitDepth += 1
        defer { waitDepth -= 1 }
        return try body()
    }

    /// Whether a lookup now may defer.
    static var defers: Bool { defersOnMainThread && Thread.isMainThread && waitDepth == 0 }

    private let queue = DispatchQueue(label: "OpenNexus.math", qos: .userInitiated)
    // The context and its function are used on `queue` only.
    private var context: JSContext?
    private var typesetFunction: JSValue?
    private var failure: String?

    private let lock = NSLock()
    private var cache: [Key: (result: Result, used: UInt64)] = [:]
    private var tick: UInt64 = 0
    private var pending: Set<Key> = []
    private var notifyScheduled = false
    private var generationValue = 0
    private var versionValue: String?
    /// Formulas kept; older ones are typeset again if they come back.
    let capacity = 4_000

    init() {}

    /// Bumped each time background results land, so measurements made with a formula's
    /// source give way to ones made with the formula.
    public var generation: Int { lock.withLock { generationValue } }

    /// MathJax's version ("4.1.3"), once the engine has started.
    public var version: String? { lock.withLock { versionValue } }

    /// Starts the engine in the background, so the first formula doesn't wait for it.
    public func warmUp() {
        queue.async { _ = self.engine() }
    }

    /// A cached result, if any (never typesets).
    public func cached(_ key: Key) -> Result? {
        lock.withLock {
            guard let hit = cache[key] else { return nil }
            tick += 1
            cache[key] = (hit.result, tick)
            return hit.result
        }
    }

    /// The formula's result: cached, typeset now, or nil while it's typeset in the
    /// background (on the app's canvases only).
    public func result(_ source: String, display: Bool) -> Result? {
        let key = Key(source, display: display)
        if let hit = cached(key) { return hit }
        if Self.defers {
            request(key)
            return nil
        }
        return typeset(key)
    }

    /// Typesets now, waiting for the engine (cached).
    public func typeset(_ source: String, display: Bool) -> Result {
        typeset(Key(source, display: display))
    }

    func typeset(_ key: Key) -> Result {
        if let hit = cached(key) { return hit }
        let r = queue.sync { run(key) }
        store(key, r)
        return r
    }

    /// Typesets several formulas in one trip to the engine (an export's, before drawing).
    public func prepare(_ keys: [Key]) {
        let missing = keys.filter { cached($0) == nil }
        guard !missing.isEmpty else { return }
        let results = queue.sync { missing.map { ($0, run($0)) } }
        for (k, r) in results { store(k, r) }
    }

    /// Queues a formula for the background; `didTypeset` follows.
    public func request(_ key: Key) {
        let start = lock.withLock { pending.insert(key).inserted }
        guard start else { return }
        queue.async {
            let r = self.run(key)
            self.store(key, r)
            let schedule = self.lock.withLock {
                self.pending.remove(key)
                defer { self.notifyScheduled = true }
                return !self.notifyScheduled
            }
            // One notice per batch: results arriving together redraw once.
            if schedule {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    self.lock.withLock {
                        self.notifyScheduled = false
                        self.generationValue += 1
                    }
                    NotificationCenter.default.post(name: Self.didTypeset, object: self)
                }
            }
        }
    }

    private func store(_ key: Key, _ r: Result) {
        lock.withLock {
            tick += 1
            cache[key] = (r, tick)
            if cache.count > capacity {
                // Drop the least recently used quarter.
                let old = cache.sorted { $0.value.used < $1.value.used }.prefix(capacity / 4)
                for (k, _) in old { cache[k] = nil }
            }
        }
    }

    /// Forgets every result (tests).
    public func clearCache() {
        lock.withLock { cache.removeAll() }
    }

    // MARK: The engine (on `queue`)

    private func engine() -> JSValue? {
        if let typesetFunction { return typesetFunction }
        if failure != nil { return nil }
        guard let url = Bundle.module.url(forResource: "nexus-math", withExtension: "js", subdirectory: "MathJax"),
            let script = try? String(contentsOf: url, encoding: .utf8), let ctx = JSContext()
        else {
            failure = "The math engine is missing"
            return nil
        }
        ctx.name = "OpenNexus math"
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        // MathJax and mhchem log through console, which JavaScriptCore doesn't provide.
        ctx.evaluateScript("var console = { log() {}, info() {}, warn() {}, error() {}, debug() {} };")
        ctx.evaluateScript(script, withSourceURL: url)
        guard thrown == nil, let math = ctx.objectForKeyedSubscript("NexusMath"), !math.isUndefined,
            let fn = math.objectForKeyedSubscript("typeset"), !fn.isUndefined
        else {
            failure = thrown ?? "The math engine didn't start"
            return nil
        }
        ctx.exceptionHandler = nil
        context = ctx
        typesetFunction = fn
        let v = math.objectForKeyedSubscript("version")?.toString()
        lock.withLock { versionValue = v }
        return fn
    }

    private func run(_ key: Key) -> Result {
        guard let fn = engine() else { return .error(failure ?? "The math engine didn't start") }
        guard let out = fn.call(withArguments: [key.source, key.display]), out.isObject else {
            return .error("This formula can't be typeset")
        }
        if let e = out.objectForKeyedSubscript("error"), !e.isUndefined, let message = e.toString() {
            return .error(message)
        }
        guard let svg = out.objectForKeyedSubscript("svg")?.toString(), let g = MathSVGReader.read(svg) else {
            return .error("This formula can't be typeset")
        }
        return .glyphs(g)
    }
}
