import SwiftUI

// The Google accounts on the Sources page:
//
//   [G] Google                                 [+ Add Account]
//       Email, Drive and Calendar
//   ─────────────────────────────────────────────────────────
//   (M) me@example.com                                    …
//       3 of 3 on
//       ✉  Email      Subjects, senders and message text   ◉
//       ▭  Drive      File names and Google Docs text      ◉
//       ▦  Calendar   Event titles, times and guests       ◉
struct GoogleCard: View {
    let accounts: GoogleAccounts

    var body: some View {
        SourceCard {
            SourceHeader(icon: "person.crop.circle", title: "Google", subtitle: Self.subtitle(accountCount: accounts.emails.count)) {
                if accounts.isBusy {
                    ProgressView().controlSize(.small)
                }
                // `Task { await ... }` starts async work from a button, which can't await itself.
                Button {
                    Task { await accounts.add() }
                } label: {
                    Label(accounts.emails.isEmpty ? "Connect" : "Add Account", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(accounts.isBusy)
            }
            // Fresh counts and sync times each time the page opens.
            .task { await accounts.refresh() }

            ForEach(accounts.emails, id: \.self) { email in
                Divider()
                AccountSection(accounts: accounts, email: email)
            }

            if let error = accounts.errorMessage {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(14)
            }
        }
    }

    nonisolated static func subtitle(accountCount: Int) -> String {
        switch accountCount {
        case 0: "Connect to search your email, Drive and calendar"
        case 1: "1 account"
        default: "\(accountCount) accounts"
        }
    }
}

// One signed-in account and its services.
struct AccountSection: View {
    let accounts: GoogleAccounts
    let email: String

    private var enabledCount: Int {
        GoogleService.allCases.filter { accounts.isEnabled($0, for: email) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Avatar(email: email, pictureURL: accounts.pictureURLs[email])
                VStack(alignment: .leading, spacing: 1) {
                    Text(email).font(.system(size: 13, weight: .medium))
                    Text("\(enabledCount) of \(GoogleService.allCases.count) on")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // A "…" menu keeps the destructive action out of the way.
                Menu {
                    Button("Disconnect", role: .destructive) { Task { await accounts.disconnect(email) } }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(accounts.isBusy)
            }
            .padding(.bottom, 6)

            ForEach(GoogleService.allCases) { service in
                let id = service.sourceID(for: email)
                ServiceRow(
                    service: service,
                    status: ServiceRow.status(
                        isOn: accounts.isEnabled(service, for: email),
                        count: accounts.itemCounts[id], lastSynced: accounts.lastSynced[id]),
                    // A Binding connects the switch to our state: `get` reads it,
                    // `set` runs when you flip it.
                    isOn: Binding(
                        get: { accounts.isEnabled(service, for: email) },
                        set: { isOn in Task { await accounts.setEnabled(isOn, service, for: email) } }))
            }
        }
        .padding(14)
    }
}

struct ServiceRow: View {
    let service: GoogleService
    let status: String
    @Binding var isOn: Bool

    // "1,234 items · 3 min. ago", "Syncing…", or "Off".
    nonisolated static func status(isOn: Bool, count: Int?, lastSynced: Date?) -> String {
        guard isOn else { return "Off" }
        guard let lastSynced else { return count.map { $0 > 0 ? "\($0.formatted()) so far…" : "Syncing…" } ?? "Syncing…" }
        let when = lastSynced.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return "\((count ?? 0).formatted()) items · \(when)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: service.symbolName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(service.displayName)
                .font(.system(size: 13))
                .frame(width: 70, alignment: .leading)
            Text(service.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
            Toggle(service.displayName, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 5)
        // Lines the services up under the email, past the avatar.
        .padding(.leading, 40)
    }
}

// The account's Google profile picture, or, until it loads (or if there is
// none), a circle with its first letter, tinted by a color picked from the
// email so each account keeps the same color.
struct Avatar: View {
    let email: String
    var pictureURL: URL? = nil

    nonisolated static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]

    // The same email always gives the same color. (Swift's hashValue changes
    // on every launch, so we add up the characters instead.)
    // nonisolated: SwiftUI views belong to the main thread, and so would this
    // plain calculation, which then crashes if called from anywhere else.
    nonisolated static func color(for email: String) -> Color {
        palette[email.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
    }

    var body: some View {
        // AsyncImage downloads the picture in the background; `phase` says
        // whether it's still loading, arrived, or failed.
        AsyncImage(url: pictureURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                initial
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }

    private var initial: some View {
        Text(email.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Self.color(for: email).gradient)
    }
}
