import SwiftUI

// One line in the results list: icon, name, where it lives, and its kind.
struct ResultRow: View {
    let item: SearchResult
    let isSelected: Bool

    var body: some View {
        // Two lines when the match was inside the file: the usual row on top, and
        // the matching text underneath, lined up with the name.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                icon
                    .frame(width: 22, height: 22)
                Text(item.title)
                    .font(.system(size: 14))
                    .layoutPriority(1)  // when space runs out, shorten the folder first
                if let secondary = ResultText.secondary(for: item, now: Date()) {
                    Text(secondary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        // Long paths lose their middle, keeping the start and the end.
                        .truncationMode(.middle)
                }
                Spacer(minLength: 16)
                Text(item.kind.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if let snippet = item.snippet {
                Text(MatchMarker.attributed(snippet))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    // 22pt icon + 10pt gap, so the snippet starts under the name.
                    .padding(.leading, 32)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: item.snippet == nil ? 40 : 54)
        .background(
            isSelected ? Color.primary.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // The real Finder icon for things on this Mac; a tinted symbol for things
    // from Google (they have web links, not files, so Finder has no icon).
    @ViewBuilder private var icon: some View {
        if item.kind.isLocal, let path = item.subtitle {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: item.kind.symbolName)
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(item.kind.tint)
        }
    }
}
