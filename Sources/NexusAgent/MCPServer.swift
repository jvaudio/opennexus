import Foundation
import NexusCore
import NexusFormat

/// `nexus mcp`: a Model Context Protocol server over stdio (JSON-RPC 2.0, one message per
/// line). No network port. Off unless Settings › Integrations › Local MCP server is on.
@MainActor
public final class MCPServer {
    /// Newest first; the client's version is used when it's one of these.
    public static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverVersion = "1.0"

    public enum Config {
        case enabled(AgentPolicy)
        /// Why the server won't run (shown to the client on `initialize`).
        case disabled(String)
    }

    let config: Config
    let input: () -> String?
    let output: (String) -> Void
    let log: (String) -> Void
    var clientCanElicit = false
    var requestSerial = 0
    /// Requests that arrived while waiting for an elicitation answer.
    var pending: [String] = []

    public init(
        config: Config, input: @escaping () -> String?, output: @escaping (String) -> Void,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.config = config
        self.input = input
        self.output = output
        self.log = log
    }

    /// Serves until stdin closes.
    public func run() {
        while true {
            if !pending.isEmpty {
                handle(pending.removeFirst())
                continue
            }
            guard let line = input() else { return }
            handle(line)
        }
    }

    // MARK: Messages

    static func encode(_ v: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? enc.encode(v)) ?? Data("{}".utf8), as: UTF8.self)
    }

    func send(_ v: JSONValue) { output(Self.encode(v)) }

    func reply(_ id: JSONValue, _ result: JSONValue) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

    func fail(_ id: JSONValue, _ code: Int, _ message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    public func handle(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let msg = try? CanonicalJSON.parse(Data(trimmed.utf8)), let obj = msg.objectValue else {
            fail(.null, -32700, "Parse error")
            return
        }
        guard let method = obj["method"]?.stringValue else { return }  // a stray response
        let id = obj["id"]
        let params = obj["params"]?.objectValue ?? [:]
        guard let id else { return }  // notifications (initialized, cancelled…) need no answer
        switch method {
        case "initialize": initialize(id, params)
        case "ping": reply(id, [:])
        case "tools/list":
            guard case .enabled = config else { return disabled(id) }
            reply(id, ["tools": .array(MapTools.definitions)])
        case "tools/call": callTool(id, params)
        case "resources/list": reply(id, ["resources": []])
        case "prompts/list": reply(id, ["prompts": []])
        default: fail(id, -32601, "Method not found: \(method)")
        }
    }

    func disabled(_ id: JSONValue) {
        if case .disabled(let why) = config { fail(id, -32000, why) }
    }

    func initialize(_ id: JSONValue, _ params: [String: JSONValue]) {
        guard case .enabled = config else { return disabled(id) }
        let asked = params["protocolVersion"]?.stringValue ?? Self.protocolVersions[0]
        let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
        clientCanElicit = params["capabilities"]?["elicitation"] != nil
        log("client \(params["clientInfo"]?["name"]?.stringValue ?? "?") · protocol \(version)")
        reply(
            id,
            [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "opennexus", "title": "OpenNexus", "version": .string(Self.serverVersion)],
                "instructions":
                    "Maps live in the folders the user allowed in OpenNexus. Call list_maps, then read_map for topic ids before editing. Every edit is one undo step in OpenNexus and is marked as AI-created.",
            ])
    }

    func callTool(_ id: JSONValue, _ params: [String: JSONValue]) {
        guard case .enabled(let policy) = config else { return disabled(id) }
        guard let name = params["name"]?.stringValue else { return fail(id, -32602, "Missing tool name") }
        guard MapTools.definitions.contains(where: { $0["name"]?.stringValue == name }) else {
            return fail(id, -32602, "Unknown tool: \(name)")
        }
        let tools = MapTools(policy: policy) { [weak self] q in self?.elicit(q) }
        do {
            let out = try tools.call(name, params["arguments"]?.objectValue ?? [:])
            reply(id, ["content": .array(out.content), "isError": false])
        } catch {
            reply(id, ["content": [["type": "text", "text": .string("\(error)")]], "isError": true])
        }
    }

    // MARK: Elicitation (Settings: Ask)

    /// Asks the user through the client; nil when the client can't.
    func elicit(_ question: String) -> Bool? {
        guard clientCanElicit else { return nil }
        requestSerial += 1
        let rid = JSONValue.string("opennexus-ask-\(requestSerial)")
        send([
            "jsonrpc": "2.0", "id": rid, "method": "elicitation/create",
            "params": [
                "message": .string(question),
                "requestedSchema": [
                    "type": "object",
                    "properties": ["approve": ["type": "boolean", "title": "Allow", "description": .string(question)]],
                    "required": ["approve"],
                ],
            ],
        ])
        while let line = input() {
            guard let msg = try? CanonicalJSON.parse(Data(line.utf8)), let obj = msg.objectValue else { continue }
            if obj["method"] == nil, obj["id"] == rid {
                guard let r = obj["result"]?.objectValue, r["action"]?.stringValue == "accept" else { return false }
                return r["content"]?["approve"]?.boolValue ?? false
            }
            if obj["method"]?.stringValue == "ping", let pid = obj["id"] {
                reply(pid, [:])
            } else if obj["method"] != nil {
                pending.append(line)
            }
        }
        return false
    }
}
