import SwiftUI

// A borderless floating window, like Spotlight's. NSPanel is an NSWindow
// subclass meant for auxiliary windows that float above other apps.
final class SearchPanel: NSPanel {
    // `any SearchEngine` = "some type conforming to the protocol; which one is decided by the caller".
    private let engine: any SearchEngine
    private let openSettings: @MainActor () -> Void

    init(engine: any SearchEngine, openSettings: @escaping @MainActor () -> Void) {
        // Swift requires our own properties to be set before calling super.init.
        self.engine = engine
        self.openSettings = openSettings
        super.init(
            // Tall enough for the bar plus the results; the empty area is transparent.
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Borderless windows refuse keyboard focus by default; we need it for typing.
    override var canBecomeKey: Bool { true }

    // Hide when the user clicks elsewhere.
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    // Called when Escape is pressed.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    func toggle() {
        if isVisible {
            orderOut(nil)
            return
        }

        // A fresh view each time clears the old query and re-focuses the field.
        contentView = NSHostingView(rootView: SearchView(engine: engine, openSettings: openSettings))
        centerOnActiveScreen()


        // A background app isn't "active" by default, and macOS only routes
        // typing to the active app. So make ourselves active first.
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}
