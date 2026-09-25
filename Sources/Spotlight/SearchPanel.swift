import SwiftUI

// A borderless floating window, like Spotlight's. NSPanel is an NSWindow
// subclass meant for auxiliary windows that float above other apps.
final class SearchPanel: NSPanel {
    init() {
        super.init(
            // Tall enough for the bar plus the results; the empty area is transparent.
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
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
        contentView = NSHostingView(rootView: SearchView())
        center()
        
        // A background app isn't "active" by default, and macOS only routes
        // typing to the active app. So make ourselves active first.
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}

// One thing that can show up in the results.
// Identifiable = "has a stable `id`", which SwiftUI needs to tell list rows apart.
struct SearchItem: Identifiable {
    let title: String
    var id: String { title }
}

struct SearchView: View {
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    // Fake data for now; BM25 over real documents replaces this later.
    private let items = [
        "Safari", "Xcode", "Terminal", "Notes", "Mail", "Calendar",
        "Photos", "Music", "System Settings", "Finder", "Messages",
    ].map { SearchItem(title: $0) }

    // A computed property: recalculated from `query` every time it's read.
    private var results: [SearchItem] {
        guard !query.isEmpty else { return [] }
        return items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            searchBar
            if !results.isEmpty {
                resultsList
            }
        }
        // Breathing room so the shadows aren't clipped by the window edge.
        .padding(.horizontal, 30)
        .padding(.top, 20)
        // Pin everything to the top of the (taller, transparent) window.
        .frame(width: 700, height: 400, alignment: .top)
        .onAppear { isFocused = true }
        // The window may not be key yet at onAppear, so focus again once it is.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isFocused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .focused($isFocused)
            // A hint that Return confirms, like in your reference.
            Image(systemName: "return")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .glassBackground(cornerRadius: 20)
        // New query, so the highlight goes back to the first result.
        .onChange(of: query) { selection = 0 }
        // .handled = "I dealt with this key, don't pass it on".
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, results.count - 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onSubmit {
            // Return key. Just logs for now; opening things comes later.
            if results.indices.contains(selection) {
                print("Selected:", results[selection].title)
            }
        }
    }

    private var resultsList: some View {
        VStack(spacing: 2) {
            // enumerated() gives (index, item) pairs so we know which row is selected.
            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 12) {
                    Image(systemName: "app.fill")
                        .foregroundStyle(.secondary)
                    Text(item.title)
                }
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(
                    index == selection ? Color.accentColor.opacity(0.35) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
        }
        .padding(8)
        .glassBackground(cornerRadius: 20)
    }
}

// Gives a view a rounded, see-through "glass" background.
// A ViewModifier is a reusable bundle of styling; `.glassBackground(...)` below
// lets us apply it like any built-in modifier, to both the bar and the list.
struct GlassBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        // #available checks the macOS version at runtime. Liquid Glass only
        // exists on macOS 26+, but our app still supports macOS 14+.
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        }
    }
}

extension View {
    func glassBackground(cornerRadius: CGFloat) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}
