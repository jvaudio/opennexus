import Foundation
import NexusCore
import NexusFormat

/// AI chats kept on this device rather than in the document (Settings › Privacy & Data).
/// Moved here from the Mac app in M47b so the iPad keeps them the same way.
public enum ChatStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(
            path: "OpenNexus/Chats")
    }

    public static func url(_ id: String) -> URL { directory.appending(path: "\(id).json") }

    public static func save(_ chats: [AIChat], documentID: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? CanonicalJSON.data(.object(["chats": .array(chats.map(\.json))])).write(
            to: url(documentID), options: .atomic)
    }

    public static func load(documentID: String) -> [AIChat] {
        guard let d = try? Data(contentsOf: url(documentID)), let v = try? CanonicalJSON.parse(d),
            var r = try? ObjectReader(v, path: "chats"),
            let list = try? r.array("chats")
        else { return [] }
        return list.enumerated().compactMap { try? AIChat(json: $1, path: "chats[\($0)]") }
    }

    public static func clearAll() { try? FileManager.default.removeItem(at: directory) }
}
