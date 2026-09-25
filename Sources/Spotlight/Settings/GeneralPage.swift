import SwiftUI

struct GeneralPage: View {
    let overview: IndexOverview
    let exportTrainingData: () async -> Void
    let clearTrainingData: () async -> Void

    private var stats: IndexStats { overview.stats }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            SettingsSection("Index") {
                SettingsRow("Items", detail: "Apps, files and folders you can search.") {
                    Text(stats.itemCount.formatted())
                }
                SettingsRow("Size on disk", detail: "The search index in Application Support.") {
                    Text(ByteCountFormatter.string(fromByteCount: overview.sizeInBytes, countStyle: .file))
                }
                SettingsRow("Last updated", detail: "The index refreshes each time the app starts.") {
                    // "2 minutes ago"
                    Text(stats.lastIndexed?.formatted(.relative(presentation: .named)) ?? "Never")
                }
            }
            SettingsSection("Training data") {
                SettingsRow(
                    "Recorded searches",
                    detail: "Each time you open a result: your query, what you opened, and what you passed over. Stored only on this Mac."
                ) {
                    Text(overview.selectionCount.formatted())
                }
                HStack {
                    Spacer()
                    Button("Clear", role: .destructive) { Task { await clearTrainingData() } }
                        .disabled(overview.selectionCount == 0)
                    Button("Export…") { Task { await exportTrainingData() } }
                        .disabled(overview.selectionCount == 0)
                }
                .padding(.top, 10)
            }
            SettingsSection("Shortcuts") {
                SettingsRow("Open search") { KeyCombo(keys: ["⌘", "Space"]) }
                SettingsRow("Open settings", detail: "From the search panel.") { KeyCombo(keys: ["⌘", ","]) }
            }
        }
    }
}
