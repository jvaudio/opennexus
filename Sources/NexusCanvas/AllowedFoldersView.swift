import AppKit
import SwiftUI

/// Settings › Integrations › Allowed folders: the only places `nexus mcp` may read,
/// edit or write.
public struct AllowedFoldersView: View {
    var prefs: Preferences
    var onDone: () -> Void
    @State private var folders: [String] = []
    @State private var selection: String?

    public init(prefs: Preferences, onDone: @escaping () -> Void) {
        self.prefs = prefs
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agents can read and edit maps only in these folders, and in the folders inside them.")
                .font(.chrome(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(folders, id: \.self) { f in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((f as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    }
                    .tag(f)
                }
            }
            .frame(minHeight: 160)
            .overlay {
                if folders.isEmpty { Text("No folders yet").foregroundStyle(.secondary) }
            }
            HStack {
                Button {
                    add()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Folder")
                Button {
                    if let s = selection { save(folders.filter { $0 != s }) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .accessibilityLabel("Remove Folder")
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear { folders = AgentFolders.list(prefs) }
    }

    func add() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Allow"
        p.message = "Agents can read and edit maps only in the folders you allow."
        guard p.runModal() == .OK else { return }
        save(folders + p.urls.map(\.path))
    }

    func save(_ list: [String]) {
        AgentFolders.set(list, prefs)
        folders = AgentFolders.list(prefs)
        selection = nil
    }
}
