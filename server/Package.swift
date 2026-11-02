// swift-tools-version: 6.0
import PackageDescription

// The OpenNexus Server (M44): stores sealed share links for people who'd rather host them
// than use a bucket or a gist. It never sees a key. A separate package from the app (D329),
// so it builds on Linux in Docker.
let package = Package(
    name: "opennexus-server",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "opennexus-server", targets: ["opennexus-server"])],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.20.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.6.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.30.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "OpenNexusServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]),
        .executableTarget(name: "opennexus-server", dependencies: ["OpenNexusServer"]),
        .testTarget(
            name: "OpenNexusServerTests",
            dependencies: [
                "OpenNexusServer", .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWSClient", package: "hummingbird-websocket"),
            ]),
    ]
)
