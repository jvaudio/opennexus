import NexusCore
import NexusScene
import SwiftUI
import UniformTypeIdentifiers

/// A starter file or pack to save (Export Starter…, Export All…; M50).
struct StarterExport: FileDocument {
    /// `.nexusstarter` and `.nexusstarters`, declared by the app; dynamic types elsewhere.
    static let starter = UTType(exportedAs: "com.opennexus.starter", conformingTo: .json)
    static let pack = UTType(exportedAs: "com.opennexus.starters", conformingTo: .json)
    static let types: [UTType] = [starter, pack]
    static var readableContentTypes: [UTType] { types }

    var data: Data
    var type: UTType
    var name: String

    init(_ starters: [Starter]) {
        if starters.count == 1 {
            data = StarterFile.data(starters[0])
            type = Self.starter
            name = "\(starters[0].name).\(MyStarters.fileExtension)"
        } else {
            data = StarterFile.pack(starters)
            type = Self.pack
            name = "\(Loc.t("My Starters")).\(MyStarters.packExtension)"
        }
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = configuration.contentType
        name = configuration.file.filename ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension MyStarters {
    /// `.nexusstarter` and `.nexusstarters`, for open panels.
    public static var contentTypes: [UTType] { StarterExport.types }

    /// A starter file or pack, by its extension.
    public static func isStarterFile(_ url: URL) -> Bool {
        [fileExtension, packExtension].contains(url.pathExtension.lowercased())
    }
}

/// A starter's name, summary, search words and collection: Save Canvas as Starter… and
/// Edit Details… (M50).
public struct StarterDetailsForm: View {
    public struct Values: Equatable {
        public var name = ""
        public var summary = ""
        /// Search words, separated by commas.
        public var aliases = ""
        public var collection: StarterCollection?

        public init(name: String = "", summary: String = "", aliases: String = "", collection: StarterCollection? = nil)
        {
            self.name = name
            self.summary = summary
            self.aliases = aliases
            self.collection = collection
        }

        init(_ s: Starter) {
            self.init(
                name: s.name, summary: s.summary, aliases: s.aliases.joined(separator: ", "), collection: s.collection)
        }

        public var aliasList: [String] {
            var seen = Set<String>()
            return aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }

        public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

        public func apply(to s: inout Starter) {
            s.name = trimmedName
            s.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            s.aliases = aliasList
            s.collection = collection
        }
    }

    let title: String
    let action: String
    @State var values: Values
    let onDone: (Values?) -> Void
    @FocusState private var nameFocused: Bool

    public init(title: String, action: String, values: Values, onDone: @escaping (Values?) -> Void) {
        self.title = title
        self.action = action
        _values = State(initialValue: values)
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.chrome(15, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Name", text: $values.name).focused($nameFocused)
                }
                GridRow {
                    Text("Summary")
                    TextField("Summary", text: $values.summary, prompt: Text("One line on the card"))
                }
                GridRow {
                    Text("Search words")
                    TextField("Search words", text: $values.aliases, prompt: Text("Separated by commas"))
                }
                GridRow {
                    Text("Collection")
                    Picker("Collection", selection: $values.collection) {
                        Text("None").tag(StarterCollection?.none)
                        ForEach(StarterCollection.allCases, id: \.self) { c in
                            Text(Loc.t(c.title)).tag(Optional(c))
                        }
                    }
                    .labelsHidden()
                }
            }
            .font(.chrome(13))
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(action) { onDone(values) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(values.trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { nameFocused = true }
    }
}

/// What a file holds, before it's installed (M50): its starters, and Replace or Keep Both
/// for any you already have.
public struct StarterInstallView: View {
    let install: StarterGallery.Install
    let onDone: (MyStarters.Clash?) -> Void

    public init(install: StarterGallery.Install, onDone: @escaping (MyStarters.Clash?) -> Void) {
        self.install = install
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                install.starters.count == 1
                    ? Loc.f("Install “%@”?", install.starters[0].name)
                    : Loc.n("Install %lld starter?", "Install %lld starters?", install.starters.count)
            )
            .font(.chrome(15, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(install.starters, id: \.id) { s in
                        HStack(alignment: .top, spacing: 12) {
                            StarterCard(starter: s, selected: false, prefs: .isolated()).frame(width: 220)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(HomeView.typeName(s.type)).font(.chrome(12)).foregroundStyle(.chromeSecondary)
                                Text(
                                    Loc.n(
                                        "%lld topic", "%lld topics",
                                        s.saved?.topicCount
                                            ?? s.outline.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                                            .count)
                                )
                                .font(.chrome(12)).foregroundStyle(.chromeSecondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            if !install.clashes.isEmpty {
                Text(
                    Loc.f(
                        "You already have %@. Replace yours, or keep both?",
                        install.clashes.map { "“\($0.name)”" }.joined(separator: ", "))
                )
                .font(.chrome(13)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Starters are data: installing one adds it to My Starters and runs nothing.")
                .font(.chrome(12)).foregroundStyle(.chromeSecondary)
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                if install.clashes.isEmpty {
                    Button("Install") { onDone(.keepBoth) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Replace") { onDone(.replace) }
                    Button("Keep Both") { onDone(.keepBoth) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Install from URL… (M50): an https address, read by the network service.
struct StarterURLForm: View {
    let onDone: (URL?) -> Void
    @State private var text = ""

    var url: URL? {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespaces)), u.scheme == "https", u.host() != nil
        else { return nil }
        return u
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install from URL").font(.chrome(15, weight: .semibold))
            TextField("URL", text: $text, prompt: Text("https://…/plan.nexusstarter"))
                .textFieldStyle(.roundedBorder).font(.chrome(13))
            Text("OpenNexus reads the file through its network service and shows it before installing.")
                .font(.chrome(12)).foregroundStyle(.chromeSecondary)
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Read") { onDone(url) }.keyboardShortcut(.defaultAction).disabled(url == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
