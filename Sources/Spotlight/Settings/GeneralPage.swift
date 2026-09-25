import SwiftUI

struct GeneralPage: View {
    let overview: IndexOverview

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
            SettingsSection("Shortcuts") {
                SettingsRow("Open search") { KeyCombo(keys: ["⌘", "Space"]) }
                SettingsRow("Open settings", detail: "From the search panel.") { KeyCombo(keys: ["⌘", ","]) }
            }
        }
    }
}
