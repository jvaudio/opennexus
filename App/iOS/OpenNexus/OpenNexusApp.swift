import CoreSpotlight
import NexusAI
import NexusCanvas
import NexusCore
import NexusTouch
import SwiftUI
import UIKit

// Only the engine: NexusScene's `Scene` would hide SwiftUI's.
import class NexusScene.MathEngine

/// OpenNexus for iPad (M47b): one window per scene, each showing Home or a document.
/// A second display shows the presentation while the iPad shows the presenter view.
@main
struct OpenNexusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .commands { TouchSceneCommands() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        MainActor.assumeIsolated { Launch.start() }
        return true
    }

    /// The external display gets its own scene: the presentation, full screen.
    func application(
        _ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if session.role == .windowExternalDisplayNonInteractive {
            let c = UISceneConfiguration(name: "External Display", sessionRole: session.role)
            c.delegateClass = ExternalDisplaySceneDelegate.self
            return c
        }
        return UISceneConfiguration(name: "Default Configuration", sessionRole: session.role)
    }
}

@MainActor
enum Launch {
    static func start() {
        TouchCanvasHost.install()
        // Formulas typeset in the background on the canvas; the engine starts now (M48).
        MathEngine.defersOnMainThread = true
        MathEngine.shared.warmUp()
        PlatformNetwork.provider = InProcessNetwork()
        let library = TouchLibrary.shared
        library.aiAvailability = { AppleEngine().availability }
        library.settingsAction = { SettingsActions.run($0) }
        UITestSupport.prepare(library)
        Integrations.shared.start()
        // Links past their expiry date are deleted where they're stored (when sharing is on).
        Task { await ShareCenter.shared.sweepExpired() }
        // Sync libraries (M45): at launch, then on the schedule (when the network is on).
        SyncCenter.shared.start()
    }
}

/// One window: Home or a document, and the links, files and Spotlight results sent to it.
struct RootView: View {
    @State private var scene = TouchScene()

    var body: some View {
        TouchSceneView(scene: scene)
            .onAppear {
                Integrations.shared.attach(scene)
                UITestSupport.open(in: scene)
            }
            .onOpenURL { url in
                if url.scheme == "opennexus", url.host() == "capture" {
                    Integrations.shared.drainCaptures()
                } else {
                    scene.handle(url) { Integrations.shared.url(forToken: $0) }
                }
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                Integrations.shared.continueSpotlight(activity, in: scene)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { scene.handle(url) }
            }
    }
}
