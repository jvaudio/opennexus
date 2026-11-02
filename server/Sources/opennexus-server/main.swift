import AsyncHTTPClient
import Foundation
import OpenNexusServer

// `opennexus-server` serves; `opennexus-server healthcheck` asks a running one (Docker's
// HEALTHCHECK, which has no curl in the image).
let config: ServerConfig
do {
    config = try ServerConfig.fromEnvironment()
} catch {
    FileHandle.standardError.write(Data("opennexus-server: \(error)\n".utf8))
    exit(64)
}

if CommandLine.arguments.dropFirst().first == "healthcheck" {
    let r = try? await HTTPClient.shared.execute(
        HTTPClientRequest(url: "http://127.0.0.1:\(config.port)/v1/health"), timeout: .seconds(5))
    exit(r?.status == .ok ? 0 : 1)
}

let app = try buildApplication(config)
try await app.runService()
