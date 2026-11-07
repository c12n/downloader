import SwiftUI
import UIKit

/// Hands the background-session completion handler from the app
/// delegate to the download manager's engine, whichever of them
/// comes up first.
final class BackgroundSessionRelay {
    static let shared = BackgroundSessionRelay()
    var pendingHandler: (() -> Void)?
    weak var engine: BackgroundDownloadEngine?
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if let engine = BackgroundSessionRelay.shared.engine {
            engine.backgroundCompletionHandler = completionHandler
        } else {
            BackgroundSessionRelay.shared.pendingHandler = completionHandler
        }
    }
}

@main
struct DownloaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = DownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onOpenURL { _ in manager.drainSharedLinks() }
        }
    }
}
