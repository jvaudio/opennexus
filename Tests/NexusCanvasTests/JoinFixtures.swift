import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusReplica
@testable import NexusScene

/// M46: invites for the join page's browser tests (`web/e2e/join.spec.ts`), made by a real
/// session on the in-memory relay: the link, the host's sealed view as the server would
/// answer it, and what the page should show. Build products (git-ignored), made by
/// `npm run fixtures` in web/.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NEXUS_WRITE_VIEWER_FIXTURES"] == "1"))
struct JoinFixtures {
    @Test func writeJoinFixtures() async throws {
        let relay = MemoryRelay()
        let host = CollabMac("Ana", relay: relay)
        host.prefs.set("sharing.viewerAddress", ShareCases.viewer)
        host.open(launchPlanDocument())
        let session = try await host.start()
        try await waitUntil("the view is up") { relay.room(session.invite.room)?.view != nil }
        let view = try #require(relay.room(session.invite.room)?.view)
        let bundle = try Sealed.openBundle(view, key: session.invite.symmetricKey).bundle
        let edit = try #require(host.controller.inviteLink(canEdit: true))
        let watch = try #require(host.controller.inviteLink(canEdit: false))
        let address = "https://relay.example/v1/rooms/\(session.invite.room)/view"
        let files = ["view.onx": view, "bundle.json": Data(CanonicalJSON.compact(bundle).utf8)]
        let cases: [ShareCases.Case] = [
            .init(
                name: "an invite opens the app and shows the view", link: edit, expect: "ready",
                bundle: "bundle.json", routes: [.init(url: address, file: "view.onx")]),
            .init(
                name: "a view-only invite before the host shares a view", link: watch, expect: "none",
                routes: [.init(url: address, status: 404)]),
            .init(
                name: "an invite the session no longer takes", link: edit, expect: "refused",
                routes: [.init(url: address, status: 403)]),
            .init(
                name: "a damaged invite", link: ShareCases.viewer + "join/#2.broken", expect: "damaged", routes: []),
        ]
        try ShareCases.write(cases, files: files, to: ShareCases.web.appending(path: "join"))
        host.controller.leaveCollab()
    }
}
