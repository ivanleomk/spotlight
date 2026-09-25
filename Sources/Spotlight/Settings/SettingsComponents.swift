import SwiftUI

// A bold heading with rows underneath, like "General" in Claude's settings.
struct SettingsSection<Content: View>: View {
    let title: String
    var detail: String? = nil
    // @ViewBuilder lets callers pass several views in a trailing closure,
    // the same way VStack { ... } works.
    @ViewBuilder let content: Content

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            content
        }
    }
}

// One setting: name and explanation on the left, its value on the right,
// with a hairline underneath.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                trailing
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            Divider()
        }
    }
}

// Keys drawn as small caps, like "⌘" "Space".
struct KeyCombo: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 7)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
