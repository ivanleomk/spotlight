import SwiftUI

// The pages in the Settings sidebar. `CaseIterable` gives us `allCases`, so
// adding a page is one new `case` here.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case sources = "Sources"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .sources: "square.stack.3d.up"
        }
    }
}

// Settings window: a sidebar of pages on the left, the chosen page on the right.
struct SettingsView: View {
    static let size = CGSize(width: 780, height: 540)

    let engine: SQLiteSearchEngine
    let folders: [IndexedFolder]
    let google: GoogleAccounts

    @State private var page = SettingsPage.general
    // Loaded once here and handed to both pages.
    @State private var overview = IndexOverview()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                Group {
                    switch page {
                    case .general:
                        GeneralPage(
                            overview: overview,
                            exportTrainingData: { await exportTrainingData() },
                            clearTrainingData: {
                                try? await engine.clearSelections()
                                overview.selectionCount = 0
                            })
                    case .sources:
                        SourcesPage(
                            folders: folders, counts: overview.counts,
                            lastSynced: overview.lastSynced[LocalFilesSource.sourceID],
                            google: google)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 44)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Runs once when the view appears; loads the numbers from the database.
        .task {
            overview = await IndexOverview.load(
                from: engine, folders: folders,
                databasePath: try? SQLiteSearchEngine.defaultDatabasePath())
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ForEach(SettingsPage.allCases) { item in
                SidebarItem(page: item, isSelected: item == page) { page = item }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        // Leaves room for the window's close/minimize buttons, which sit on top.
        .padding(.top, 48)
        .frame(width: 210)
        .background(Color.primary.opacity(0.03))
    }
}

extension SettingsView {
    // Asks where to save, then writes every example as JSON Lines.
    func exportTrainingData() async {
        guard let examples = try? await engine.trainingExamples(),
            let data = try? TrainingExample.jsonLines(examples)
        else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "spotlight-training-\(Date().formatted(.iso8601.year().month().day())).jsonl"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

struct SidebarItem: View {
    let page: SettingsPage
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .frame(width: 20)
                Text(page.rawValue)
                Spacer()
            }
            .font(.system(size: 14))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                isSelected ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// The numbers Settings shows. Loading them is a plain async function rather
// than code inside a view, so tests can call it.
struct IndexOverview {
    var stats = IndexStats()
    var counts: [URL: Int] = [:]
    var sizeInBytes: Int64 = 0
    // Source id -> when it last finished syncing.
    var lastSynced: [String: Date] = [:]
    // How many times you've opened a result (each one is a training example).
    var selectionCount = 0

    static func load(
        from engine: SQLiteSearchEngine, folders: [IndexedFolder], databasePath: String?
    ) async -> IndexOverview {
        var overview = IndexOverview()
        overview.stats = (try? await engine.stats()) ?? IndexStats()
        overview.selectionCount = (try? await engine.selectionCount()) ?? 0
        if let state = try? await engine.syncState(for: LocalFilesSource.sourceID) {
            overview.lastSynced[LocalFilesSource.sourceID] = state.syncedAt
        }
        for folder in folders {
            // The index stores real paths (with symlinks resolved), so look up by those.
            let realPath =
                (try? folder.url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
                ?? folder.url.path
            overview.counts[folder.url] = try? await engine.count(under: realPath)
        }
        // The database is a main file plus a "-wal" file of recent writes.
        if let databasePath {
            overview.sizeInBytes = [databasePath, databasePath + "-wal"].reduce(0) { total, file in
                let size = (try? FileManager.default.attributesOfItem(atPath: file)[.size]) as? Int64
                return total + (size ?? 0)
            }
        }
        return overview
    }
}
