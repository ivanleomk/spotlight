import SwiftUI

// A borderless floating window, like Spotlight's. NSPanel is an NSWindow
// subclass meant for auxiliary windows that float above other apps.
final class SearchPanel: NSPanel {
    // `any SearchEngine` = "some type conforming to the protocol; which one is decided by the caller".
    private let engine: any SearchEngine

    init(engine: any SearchEngine) {
        // Swift requires our own properties to be set before calling super.init.
        self.engine = engine
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
        contentView = NSHostingView(rootView: SearchView(engine: engine))
        center()
        
        // A background app isn't "active" by default, and macOS only routes
        // typing to the active app. So make ourselves active first.
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}

struct SearchView: View {
    let engine: any SearchEngine

    @State private var query = ""
    // Now @State instead of computed: results arrive later, from an async call.
    @State private var results: [SearchResult] = []
    @State private var selection = 0
    @FocusState private var isFocused: Bool

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
        // Runs whenever `query` changes. SwiftUI cancels the previous run first,
        // so a slow search for "sa" can't overwrite the results for "saf".
        .task(id: query) {
            // 6 rows is what fits in the 400pt-tall window under the search bar.
            let found = (try? await engine.search(SearchQuery(text: query, limit: 6))) ?? []
            guard !Task.isCancelled else { return }
            results = found
        }
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
            selection = min(selection + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onSubmit {
            // Return key: open the selected item, as if double-clicked in Finder.
            // The app that opens takes focus, so our panel hides itself (resignKey).
            guard results.indices.contains(selection), let path = results[selection].subtitle
            else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private var resultsList: some View {
        VStack(spacing: 2) {
            // enumerated() gives (index, item) pairs so we know which row is selected.
            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                ResultRow(item: item)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
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

// One line in the results list: icon, name, and where it lives.
struct ResultRow: View {
    let item: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            icon
                .resizable()
                .frame(width: 28, height: 28)
            // Two lines stacked vertically, left-aligned.
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 15))
                if let subtitle = item.subtitle {
                    Text(Self.abbreviatingHome(subtitle))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        // Long paths lose their middle, keeping the start and the file name.
                        .truncationMode(.middle)
                }
            }
            .lineLimit(1)
            Spacer()
            Text(Self.label(for: item.kind))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // The real Finder icon when we have a path, otherwise a symbol per kind.
    private var icon: Image {
        if let path = item.subtitle {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: path))
        }
        // `switch` on an enum must cover every case, or it won't compile.
        switch item.kind {
        case .app: return Image(systemName: "app.dashed")
        case .folder: return Image(systemName: "folder")
        case .file: return Image(systemName: "doc")
        }
    }

    private static func label(for kind: DocumentKind) -> String {
        switch kind {
        case .app: "Application"
        case .folder: "Folder"
        case .file: "Document"
        }
    }

    // "/Users/ivan/Documents/x.pdf" -> "~/Documents/x.pdf"
    private static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
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
