import AppKit

extension NSWindow {
    // Puts the window in the exact middle of the screen the mouse is on.
    // (AppKit's own center() deliberately sits a little above the middle.)
    func centerOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return center() }
        setFrameOrigin(Self.centeredOrigin(for: frame.size, in: area))
    }

    // The bottom-left corner that centers a window of `size` inside `area`.
    // (macOS measures windows from the bottom-left, not the top-left.)
    static func centeredOrigin(for size: CGSize, in area: CGRect) -> CGPoint {
        CGPoint(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded())
    }
}
