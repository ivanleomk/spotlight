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
            .commands {
                // Every SwiftUI app gets a built-in "Settings…" command bound to ⌘,,
                // which would open the empty scene above. Replace it with ours, so ⌘,
                // always goes through AppDelegate.showSettings (which also hides the panel).
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
