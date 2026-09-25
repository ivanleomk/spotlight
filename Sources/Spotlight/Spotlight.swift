import Carbon.HIToolbox
import SwiftUI

@main
struct SpotlightApp: App {
    // SwiftUI's App has no hook for "app finished launching", so we attach an
    // AppKit delegate to get one.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // We don't want a normal window at launch; the panel is shown on demand.
    // A Scene is still required, so this is an empty settings scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Optional because creating it can fail (the database might not open).
    private var panel: SearchPanel?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar: a background app.
        NSApp.setActivationPolicy(.accessory)

        do {
            // The one place that decides which engine the app uses.
            let engine = try SQLiteSearchEngine(path: SQLiteSearchEngine.defaultDatabasePath())
            panel = SearchPanel(engine: engine)
            // Task.detached = run on a background thread, not the main one, so a long
            // crawl never freezes the UI. The engine is an actor, so it's safe to share.
            Task.detached(priority: .utility) {
                await FileCrawler(roots: FileCrawler.defaultRoots).crawl(into: engine)
            }
        } catch {
            NSLog("Could not open the search index: \(error)")
            NSApp.terminate(nil)
            return
        }

        hotKey = HotKey(keyCode: kVK_Space, modifiers: cmdKey) { [weak self] in
            self?.panel?.toggle()
        }
    }
}
