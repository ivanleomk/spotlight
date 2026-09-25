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
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 610),
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

// A titled group of results, like "Applications" or "Files & Folders".
struct ResultSection: Identifiable {
    let title: String
    let items: [SearchResult]
    var id: String { title }
}

struct SearchView: View {
    let engine: any SearchEngine

    @State private var query = ""
    @State private var sections: [ResultSection] = []
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    // Every row in on-screen order, so arrow keys can move across sections.
    private var allItems: [SearchResult] { sections.flatMap(\.items) }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !sections.isEmpty {
                Divider()
                resultsList
                Divider()
                footer
            }
        }
        .frame(width: 750)
        .panelBackground(cornerRadius: 14)
        // Room for the shadow to fade out fully. Anything drawn past the window's
        // edge is cut off, and a cut-off shadow shows up as a faint rectangle.
        .padding(50)
        // Pin everything to the top of the (taller, transparent) window.
        .frame(width: 850, height: 610, alignment: .top)
        // Runs whenever `query` changes. SwiftUI cancels the previous run first,
        // so a slow search for "sa" can't overwrite the results for "saf".
        .task(id: query) {
            // `async let` starts both searches at once instead of one after the other.
            async let apps = engine.search(SearchQuery(text: query, limit: 3, kinds: [.app]))
            async let files = engine.search(
                SearchQuery(text: query, limit: 5, kinds: [.file, .folder]))
            let found = [
                ResultSection(title: "Applications", items: (try? await apps) ?? []),
                ResultSection(title: "Files & Folders", items: (try? await files) ?? []),
            ].filter { !$0.items.isEmpty }
            guard !Task.isCancelled else { return }
            sections = found
        }
        .onAppear { isFocused = true }
        // The window may not be key yet at onAppear, so focus again once it is.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            isFocused = true
        }
    }

    private var searchBar: some View {
        TextField("Search for apps and files...", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 20))
            .focused($isFocused)
            .padding(.horizontal, 20)
            .frame(height: 58)
            // New query, so the highlight goes back to the first result.
            .onChange(of: query) { selection = 0 }
            // .handled = "I dealt with this key, don't pass it on".
            .onKeyPress(.downArrow) {
                selection = min(selection + 1, max(allItems.count - 1, 0))
                return .handled
            }
            .onKeyPress(.upArrow) {
                selection = max(selection - 1, 0)
                return .handled
            }
            .onSubmit { open(at: selection) }
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                Text(section.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                ForEach(section.items) { item in
                    // Rows are numbered across all sections, not per section.
                    let index = allItems.firstIndex { $0.id == item.id } ?? 0
                    ResultRow(item: item, isSelected: index == selection)
                        // Makes the whole row clickable, not just the text and icon.
                        .contentShape(Rectangle())
                        .onTapGesture { open(at: index) }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // Raycast-style bar that names what Return will do to the selected row.
    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            Spacer()
            if allItems.indices.contains(selection) {
                Text(Self.actionName(for: allItems[selection].kind))
                    .font(.system(size: 12, weight: .medium))
                KeyCap(symbol: "return")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private static func actionName(for kind: DocumentKind) -> String {
        switch kind {
        case .app: "Open Application"
        case .folder: "Open Folder"
        case .file: "Open File"
        }
    }

    // Opens a row as if double-clicked in Finder. The app that opens takes
    // focus, so our panel hides itself (see resignKey above).
    private func open(at index: Int) {
        guard allItems.indices.contains(index), let path = allItems[index].subtitle else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// One line in the results list: icon, name, where it lives, and its kind.
struct ResultRow: View {
    let item: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .resizable()
                .frame(width: 22, height: 22)
            Text(item.title)
                .font(.system(size: 14))
                .layoutPriority(1)  // when space runs out, shorten the folder first
            if item.kind != .app, let folder {
                Text(folder)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    // Long paths lose their middle, keeping the start and the end.
                    .truncationMode(.middle)
            }
            Spacer(minLength: 16)
            Text(Self.label(for: item.kind))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(
            isSelected ? Color.primary.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
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

    // The folder the item sits in, e.g. "~/Documents/coding". The name is
    // already shown, so repeating it at the end of the path would be noise.
    private var folder: String? {
        guard let path = item.subtitle else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    private static func label(for kind: DocumentKind) -> String {
        switch kind {
        case .app: "Application"
        case .folder: "Folder"
        case .file: "File"
        }
    }
}

// A small rounded key, like the ↩ hints in Raycast's footer.
struct KeyCap: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 20)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}

// The panel's frosted, nearly solid background. Raycast keeps it opaque enough
// that whatever is behind never competes with the text, so we use a thick
// material rather than the very see-through Liquid Glass.
struct PanelBackground: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.thickMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
            .clipShape(shape)
            .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
    }
}

extension View {
    func panelBackground(cornerRadius: CGFloat) -> some View {
        modifier(PanelBackground(cornerRadius: cornerRadius))
    }
}
