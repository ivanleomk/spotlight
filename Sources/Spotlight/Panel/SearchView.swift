import SwiftUI

// A titled group of results, like "Applications" or "Files & Folders".
struct ResultSection: Identifiable {
    let title: String
    let items: [SearchResult]
    var id: String { title }
}

struct SearchView: View {
    let engine: any SearchEngine
    let openSettings: @MainActor () -> Void

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
        .frame(width: 850, height: 680, alignment: .top)
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
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            Spacer()
            if allItems.indices.contains(selection) {
                Text(allItems[selection].kind.openActionName)
                    .font(.system(size: 12, weight: .medium))
                KeyCap(symbol: "return")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    // Opens a row as if double-clicked in Finder. The app that opens takes
    // focus, so our panel hides itself (see SearchPanel.resignKey).
    private func open(at index: Int) {
        guard allItems.indices.contains(index), let path = allItems[index].subtitle else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
