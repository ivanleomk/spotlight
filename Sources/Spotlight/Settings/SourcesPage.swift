import SwiftUI

struct SourcesPage: View {
    let folders: [IndexedFolder]
    let counts: [URL: Int]
    // When Local Files last finished syncing; nil if it never has.
    var lastSynced: Date? = nil

    @State private var isExpanded = false

    // nil until every folder's count has loaded.
    private var total: Int? {
        let loaded = folders.compactMap { counts[$0.url] }
        return loaded.count == folders.count ? loaded.reduce(0, +) : nil
    }

    // "Apps, files and folders on this Mac · Synced 3 minutes ago"
    static func subtitle(lastSynced: Date?) -> String {
        let base = "Apps, files and folders on this Mac"
        guard let lastSynced else { return base }
        return base + " · Synced " + lastSynced.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    var body: some View {
        SettingsSection("Sources", detail: "Where Spotlight looks for things to search.") {
            VStack(spacing: 0) {
                // The header toggles the folder list open and closed.
                Button {
                    // withAnimation animates every change caused by this state update.
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 18))
                            .frame(width: 32, height: 32)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Local Files").font(.system(size: 14, weight: .medium))
                            Text(Self.subtitle(lastSynced: lastSynced))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(total.map { "\($0.formatted()) items" } ?? "…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(folders) { folder in
                            FolderRow(folder: folder, count: counts[folder.url])
                                .padding(.vertical, 8)
                            if folder.id != folders.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}

struct FolderRow: View {
    let folder: IndexedFolder
    let count: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.url.lastPathComponent)
                Text(PathDisplay.abbreviatingHome(folder.url.path))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                // nil while still loading.
                Text(count.map { "\($0.formatted()) items" } ?? "…")
                    .monospacedDigit()
                Text(folder.readsContent ? "Names and contents" : "Names only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
