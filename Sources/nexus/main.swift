import Foundation
import NexusCore
import NexusFormat

/// `nexus` command-line tool. M0 ships `validate`; `export` and `mcp` arrive in M9.
let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: nexus validate <file.nexus>\n".utf8))
    exit(64)
}

guard let command = args.first else { usage() }

switch command {
case "validate":
    guard args.count == 2 else { usage() }
    let url = URL(fileURLWithPath: args[1])
    do {
        let wrapper = try FileWrapper(url: url, options: [.immediate])
        let doc = try NexusPackage.read(from: wrapper)
        var issues = SchemaValidator.bundled.validate(package: NexusPackage.files(for: doc)).map(\.description)
        for canvas in doc.orderedCanvases {
            issues += canvas.validate().map { "canvases/\(canvas.id).json: \($0)" }
        }
        if issues.isEmpty {
            print("\(url.lastPathComponent): valid (\(doc.canvases.count) canvases, \(doc.topicCount) topics)")
        } else {
            issues.forEach { print($0) }
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("\(url.lastPathComponent): \(error)\n".utf8))
        exit(1)
    }
default:
    usage()
}
