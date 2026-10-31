import Foundation
import NexusCanvas
import NexusFormat
import NexusReplica
import Testing

@testable import NexusTouch
@testable import OpenNexus

extension HostedTests {
    /// A10 on the iPad: every network switch is off on a fresh install, and the app's one
    /// adapter (`InProcessNetwork`) reaches only the hosts a job or an invite names.
    @MainActor
    @Suite(.serialized) struct NetworkTests {
        @Test func everySwitchIsOffOnAFreshInstall() {
            let rows = SettingsSchema.allRows.map(\.2).filter { $0.key.hasPrefix("network.") }
            #expect(!rows.isEmpty)
            for r in rows { #expect(r.defaultValue == .bool(false), "\(r.key)") }
            let prefs = Preferences.isolated()
            #expect(!prefs.bool("network.enabled") && !prefs.bool("network.sharing"))
        }

        /// A job whose destination isn't on its own list is refused before anything is sent.
        @Test func theTransportRefusesHostsTheJobDoesNotAllow() async {
            var d = ShareDestination(id: "b", kind: .s3, name: "Bucket")
            d.endpoint = "https://s3.eu-west-1.amazonaws.com"
            d.region = "eu-west-1"
            d.bucket = "maps"
            d.accessKey = "AKIDEXAMPLE"
            let job = NetJob(action: .create, purpose: "Share link", destination: d, secret: "s3cret", allowedHosts: [])
            let reply = await InProcessNetwork().transport().perform(job, body: Data("x".utf8))
            #expect(!reply.ok)
            #expect(reply.error?.contains("s3.eu-west-1.amazonaws.com") == true, "\(reply.error ?? "")")
        }

        /// A session's socket opens only TLS to the invite's own server (or this device).
        @Test func theConnectorRefusesPlainSocketsToOtherHosts() async {
            let log = NetworkLog(file: nil)
            let connector = InProcessNetwork().connector(purpose: "Live session", log: log)
            let closed = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
                let once = Once()
                _ = connector.open(URL(string: "ws://relay.example.org/room/abc")!) { e in
                    if case .closed(let why) = e, once.first() { done.resume(returning: why) }
                }
            }
            #expect(closed?.contains("relay.example.org") == true, "\(closed ?? "")")
        }

        /// Open in OpenNexus (M47d, D441): `opennexus://view#…` waits for both switches, and
        /// says so, before anything reaches the network.
        @Test func aShareLinkWaitsForTheNetwork() {
            let center = ShareCenter.shared
            let saved = center.prefs
            center.prefs = Preferences.isolated()
            defer { center.prefs = saved }
            let scene = TouchScene()
            scene.handle(URL(string: "opennexus://view#1.u.aHR0cHM6Ly9tYXBzLmV4YW1wbGUub3JnL2Eub254.AAAA")!)
            #expect(scene.error?.hasPrefix("Opening a share link uses the network") == true, "\(scene.error ?? "")")
            #expect(scene.document == nil)
        }

        /// A link is read only from its own host, over TLS (or from this device).
        @Test func theTransportReadsALinkOnlyFromItsHost() async {
            let code = ShareLinkCode(
                source: .url, locator: "http://maps.example.org/a.onx", key: Data(repeating: 1, count: 32))
            let (reply, body) = await InProcessNetwork().transport().exchange(
                NetJob.read(code, purpose: "Open share link"), body: Data())
            #expect(!reply.ok && reply.log.isEmpty && body.isEmpty)
        }

        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func first() -> Bool {
                lock.withLock {
                    defer { done = true }; return !done
                }
            }
        }
    }
}
