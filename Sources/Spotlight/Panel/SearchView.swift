import SwiftUI

// A titled group of results, like "Applications" or "Mail".
struct ResultSection: Identifiable {
    let title: String
    var items: [SearchResult]
    var id: String { title }

    // The sections of the panel, in order, and how many rows each may ask for.
    struct Group {
        let title: String
        let kinds: [DocumentKind]
        let limit: Int

        static let apps = Group(title: "Applications", kinds: [.app], limit: 3)
        static let mail = Group(title: "Mail", kinds: [.email], limit: 3)
        static let calendar = Group(title: "Calendar", kinds: [.event], limit: 3)
        static let drive = Group(title: "Drive", kinds: [.driveFile], limit: 3)
        static let files = Group(title: "Files & Folders", kinds: [.file, .folder], limit: 4)

        // Top to bottom.
        static let all = [apps, mail, calendar, drive, files]
    }

    // Drops empty sections, then trims rows until everything fits in `maxRows`:
    // always from whichever section is longest (the last one on a tie), so every
    // section that found something keeps at least its best result.
    static func fitting(_ sections: [ResultSection], maxRows: Int) -> [ResultSection] {
        var sections = sections.filter { !$0.items.isEmpty }
        while sections.reduce(0, { $0 + $1.items.count }) > maxRows {
            guard let longest = sections.indices.max(by: { sections[$0].items.count <= sections[$1].items.count }),
                sections[longest].items.count > 1
            else { break }
            sections[longest].items.removeLast()
        }
        return sections
    }
}

struct SearchView: View {
    let engine: any SearchEngine
    let openSettings: @MainActor () -> Void
    // Told what you searched for, everything on screen, and which one you
    // opened; the app logs it as training data.
    typealias SelectionHandler = @MainActor (_ query: String, _ shown: [SearchResult], _ chosenIndex: Int) -> Void
    let recordSelection: SelectionHandler
    // Hides the panel.
    let dismiss: @MainActor () -> Void

    @State private var query = ""
    @State private var sections: [ResultSection] = []
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    // How many result rows fit in the panel.
    static let maxRows = 10

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
        .frame(width: 850, height: SearchPanel.height, alignment: .top)
        // Runs whenever `query` changes. SwiftUI cancels the previous run first,
        // so a slow search for "sa" can't overwrite the results for "saf".
        .task(id: query) {
            // Wait a moment first: if another key arrives within 40 ms, SwiftUI
            // cancels this task and starts a new one, so we never search for
            // text you've already typed past.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }

            // Every section in one call, so the engine ranks the matches once.
            let groups = ResultSection.Group.all
            let started = ContinuousClock.now
            let results = (try? await engine.search(groups.map {
                SearchQuery(text: query, limit: $0.limit, kinds: $0.kinds)
            })) ?? []
            guard !Task.isCancelled else { return }
            let elapsed = ContinuousClock.now - started
            if elapsed > .milliseconds(50) { NSLog("Slow search \"\(query)\": \(elapsed)") }

            sections = ResultSection.fitting(
                zip(groups, results).map { ResultSection(title: $0.title, items: $1) }, maxRows: Self.maxRows)
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

    // Opens a row as if double-clicked in Finder, then gets out of the way.
    private func open(at index: Int) {
        guard allItems.indices.contains(index), let url = allItems[index].openURL else { return }
        recordSelection(query, allItems, index)
        NSWorkspace.shared.open(url)
        dismiss()
    }
}
