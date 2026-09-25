import Carbon.HIToolbox
import SwiftUI

// Starts everything up: the index, the background crawl, the hotkey, and the
// two windows (search panel and Settings).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Optional because creating it can fail (the database might not open).
    private var panel: SearchPanel?
    private var settings: SettingsWindow?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar: a background app.
        NSApp.setActivationPolicy(.accessory)

        let engine: SQLiteSearchEngine
        do {
            // The one place that decides which engine the app uses.
            engine = try SQLiteSearchEngine(path: SQLiteSearchEngine.defaultDatabasePath())
        } catch {
            NSLog("Could not open the search index: \(error)")
            NSApp.terminate(nil)
            return
        }

        let settings = SettingsWindow(engine: engine)
        self.settings = settings
        // [weak self]: the panel keeps this closure, and the closure would otherwise
        // keep us alive in return (a "retain cycle").
        panel = SearchPanel(engine: engine) { [weak self] in self?.showSettings() }

        // Only one of the two windows is ever on screen.
        hotKey = HotKey(keyCode: kVK_Space, modifiers: cmdKey) { [weak self] in
            self?.settings?.close()
            self?.panel?.toggle()
        }

        // Every place items come from. Gmail and Drive will be added to this list.
        let scheduler = SyncScheduler(
            index: engine, sources: [LocalFilesSource(folders: IndexedFolder.all)])
        // Task.detached = run on a background thread, not the main one, so a long
        // sync never freezes the UI. Both are actors, so they're safe to share.
        Task.detached(priority: .utility) {
            await scheduler.syncAll()
        }
    }

    func showSettings() {
        panel?.orderOut(nil)
        settings?.show()
    }
}
