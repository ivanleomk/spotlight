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
    private let panel = SearchPanel()
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar: a background app.
        NSApp.setActivationPolicy(.accessory)

        hotKey = HotKey(keyCode: kVK_Space, modifiers: cmdKey) { [weak self] in
            self?.panel.toggle()
        }
    }
}
