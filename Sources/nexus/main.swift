import Foundation
import NexusAgent
import Security

/// `nexus`: validate, export, new, import, and the MCP server (`nexus mcp`). The work is
/// in NexusAgent, so it's tested in-process; this file only wires up the real process.

/// The team that signed this binary: it shares OpenNexus's App Group, where the app
/// keeps the agent settings.
func signingTeam() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess
    else { return nil }
    return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
}

setvbuf(stdout, nil, _IOLBF, 0)
let io = NexusCLI.IO(
    out: { FileHandle.standardOutput.write($0) },
    err: { FileHandle.standardError.write(Data($0.utf8)) },
    readLine: { Swift.readLine(strippingNewline: true) },
    stdoutIsTerminal: isatty(STDOUT_FILENO) == 1)
let env = NexusCLI.Environment(
    cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    home: FileManager.default.homeDirectoryForCurrentUser,
    variables: ProcessInfo.processInfo.environment,
    team: signingTeam())
let status = MainActor.assumeIsolated { NexusCLI.run(Array(CommandLine.arguments.dropFirst()), io: io, env: env) }
exit(status)
