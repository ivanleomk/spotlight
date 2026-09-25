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

        // Who's signed in to Google (if anyone), read from the Keychain.
        let google = GoogleAccounts(tokens: GoogleTokens(), index: engine)
        Task { await google.refresh() }

        let settings = SettingsWindow(engine: engine, google: google)
        self.settings = settings
        // [weak self]: the panel keeps this closure, and the closure would otherwise
        // keep us alive in return (a "retain cycle").
        panel = SearchPanel(
            engine: engine,
            openSettings: { [weak self] in self?.showSettings() },
            // Logged in the background, so opening the result is never delayed.
            recordSelection: { query, shown, chosen in
                Task.detached(priority: .utility) {
                    try? await engine.recordSelection(query: query, shown: shown, chosenIndex: chosen)
                }
            })

        // Only one of the two windows is ever on screen.
        hotKey = HotKey(keyCode: kVK_Space, modifiers: cmdKey) { [weak self] in
            self?.settings?.close()
            self?.panel?.toggle()
        }

        // Every place items come from: this Mac's folders, plus each ticked
        // service of each Google account.
        let tokens = google.tokens
        let scheduler = SyncScheduler(index: engine) {
            [LocalFilesSource(folders: IndexedFolder.all)] + (await GoogleAccounts.sources(tokens: tokens))
        }
        // Task.detached = run on a background thread, not the main one, so a long
        // sync never freezes the UI. Both are actors, so they're safe to share.
        Task.detached(priority: .utility) {
            // Sync now, then pick up what's new every few minutes.
            await scheduler.start(every: .seconds(5 * 60))
        }
        // Connecting an account or ticking a service syncs straight away.
        google.onChange = {
            Task.detached(priority: .utility) { await scheduler.syncAll() }
        }
    }

    func showSettings() {
        panel?.orderOut(nil)
        settings?.show()
    }
}
