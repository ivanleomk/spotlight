import SwiftUI

// Owns the Settings window: a normal titled window holding the SwiftUI SettingsView.
@MainActor
final class SettingsWindow {
    private let engine: SQLiteSearchEngine
    private var window: NSWindow?

    init(engine: SQLiteSearchEngine) {
        self.engine = engine
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // A fresh view each time, so the numbers are reloaded when you reopen it.
        window.contentViewController = NSHostingController(
            rootView: SettingsView(engine: engine, folders: IndexedFolder.all))
        // Size it before centering: SwiftUI would otherwise size the window a moment
        // later, after we've centered a window of the wrong size.
        window.setContentSize(SettingsView.size)
        window.centerOnActiveScreen()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        // .fullSizeContentView + a transparent, hidden title bar lets our sidebar
        // run all the way to the top edge, with the window buttons on top of it.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Spotlight Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Keep the window object around after it's closed, so we can reopen it.
        window.isReleasedWhenClosed = false
        return window
    }
}
