import SwiftUI

struct SourcesPage: View {
    let folders: [IndexedFolder]
    let counts: [URL: Int]
    // When Local Files last finished syncing; nil if it never has.
    var lastSynced: Date? = nil
    let google: GoogleAccounts

    @State private var isExpanded = false

    // nil until every folder's count has loaded.
    private var total: Int? {
        let loaded = folders.compactMap { counts[$0.url] }
        return loaded.count == folders.count ? loaded.reduce(0, +) : nil
    }

    // "Synced 8 sec. ago", short enough to sit under the item count.
    nonisolated static func syncedLabel(_ lastSynced: Date?) -> String {
        guard let lastSynced else { return "Not synced yet" }
        return "Synced " + lastSynced.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    var body: some View {
        SettingsSection("Sources", detail: "Where Spotlight looks for things to search.") {
            VStack(spacing: 12) {
                localFiles
                GoogleCard(accounts: google)
            }
        }
    }

    private var localFiles: some View {
        SourceCard {
            // The header toggles the folder list open and closed.
            Button {
                // withAnimation animates every change caused by this state update.
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                SourceHeader(icon: "internaldrive", title: "Local Files", subtitle: "Apps, files and folders on this Mac") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(total.map { "\($0.formatted()) items" } ?? "…")
                            .font(.system(size: 13))
                            .monospacedDigit()
                        Text(Self.syncedLabel(lastSynced))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
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
    }
}

// MARK: - Shared pieces for source cards

// A rounded, outlined box holding one source.
struct SourceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Color.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

// The top line of a source card: icon tile, name, one-line description, and
// whatever the source wants on the right (counts, buttons).
struct SourceHeader<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 34, height: 34)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(14)
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
