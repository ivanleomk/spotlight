import Foundation

// One Gmail account's mail, kept in sync with Gmail's own change log:
//
//   First sync: list message ids from the last `lookback` (skipping Promotions,
//   Social, spam and trash), fetch each message, index it. Remember Gmail's
//   `historyId` from just before we started.
//   Later syncs: ask Gmail's history "what was added or deleted since that
//   historyId?" and apply just those changes. If Gmail says the bookmark is too
//   old (it only keeps about a week), fall back to a first sync.
struct GmailSource: Source {
    let api: GoogleAPI
    var lookback = "2y"
    var maxMessages = 20_000
    // Gentle on purpose: the first sync runs in the background and should never
    // compete with you (or hit Gmail's rate limit).
    var parallelFetches = 4

    var id: String { GoogleService.gmail.sourceID(for: api.email) }
    var displayName: String { "Gmail (\(api.email))" }

    static let base = "https://gmail.googleapis.com/gmail/v1/users/me"
    // Labels whose messages we don't index.
    static let skippedLabels: Set<String> = ["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "SPAM", "TRASH", "DRAFT"]

    func sync(into index: SQLiteSearchEngine, since cursor: String?) async throws -> String? {
        if let cursor {
            do {
                return try await applyHistory(into: index, since: cursor)
            } catch GoogleAPIError.notFound {
                NSLog("Gmail history for \(api.email) expired; doing a full sync")
            }
        }
        return try await fullSync(into: index)
    }

    // MARK: - First (full) sync

    private func fullSync(into index: SQLiteSearchEngine) async throws -> String? {
        // Taken *before* listing, so anything arriving while we work is caught by
        // the next history sync instead of slipping through the gap.
        let profile: Profile = try await api.get("\(Self.base)/profile")

        var ids: [String] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "q", value: "newer_than:\(lookback) -category:promotions -category:social"),
                URLQueryItem(name: "maxResults", value: "500"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: MessageList = try await api.get("\(Self.base)/messages", query)
            ids += (page.messages ?? []).map(\.id)
            pageToken = page.nextPageToken
        } while pageToken != nil && ids.count < maxMessages
        ids = Array(ids.prefix(maxMessages))

        // Skip messages an earlier, interrupted sync already fetched.
        let indexed = try await index.paths(from: id)
        let missing = ids.filter { !indexed.contains(Self.link(messageID: $0, account: api.email)) }
        try await fetchAndIndex(missing, into: index)

        // Mail that's gone (deleted, or now older than `lookback`) comes out.
        let wanted = Set(ids.map { Self.link(messageID: $0, account: api.email) })
        try await index.remove(paths: Array(indexed.subtracting(wanted)))
        return profile.historyId
    }

    // MARK: - Later (incremental) syncs

    private func applyHistory(into index: SQLiteSearchEngine, since cursor: String) async throws -> String? {
        var added: [String] = []
        var deleted: [String] = []
        var latest = cursor
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "startHistoryId", value: cursor),
                URLQueryItem(name: "historyTypes", value: "messageAdded"),
                URLQueryItem(name: "historyTypes", value: "messageDeleted"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: HistoryList = try await api.get("\(Self.base)/history", query)
            for record in page.history ?? [] {
                for change in record.messagesAdded ?? [] where Self.isWanted(labels: change.message.labelIds) {
                    added.append(change.message.id)
                }
                deleted += (record.messagesDeleted ?? []).map(\.message.id)
            }
            latest = page.historyId ?? latest
            pageToken = page.nextPageToken
        } while pageToken != nil

        // Added then deleted within the same window: nothing to fetch.
        let gone = Set(deleted)
        try await fetchAndIndex(added.filter { !gone.contains($0) }, into: index)
        try await index.remove(paths: deleted.map { Self.link(messageID: $0, account: api.email) })
        return latest
    }

    // MARK: - Fetching

    private func fetchAndIndex(_ ids: [String], into index: SQLiteSearchEngine) async throws {
        // In chunks, so search fills up as we go and a crash loses little.
        for start in stride(from: 0, to: ids.count, by: 100) {
            if Task.isCancelled { return }
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            let files = try await chunk.concurrentMap(width: parallelFetches) { [api] id -> IndexedFile? in
                let message: Message = try await api.get(
                    "\(Self.base)/messages/\(id)", [URLQueryItem(name: "format", value: "full")])
                return Self.indexedFile(from: message, account: api.email)
            }
            try await index.upsert(files)
        }
    }

    // MARK: - Turning a message into an index row

    static func isWanted(labels: [String]?) -> Bool {
        skippedLabels.isDisjoint(with: labels ?? [])
    }

    // Opens the message in Gmail on the web, in the right account.
    static func link(messageID: String, account: String) -> String {
        let user = account.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? account
        return "https://mail.google.com/mail/?authuser=\(user)#all/\(messageID)"
    }

    static func indexedFile(from message: Message, account: String) -> IndexedFile? {
        guard isWanted(labels: message.labelIds) else { return nil }
        let headers = message.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        let from = header("From")
        let subject = header("Subject")
        let body = GoogleText.tidy(GoogleText.removeQuotedReply(message.payload.map(bodyText) ?? message.snippet ?? ""))
        return IndexedFile(
            path: link(messageID: message.id, account: account),
            name: subject.isEmpty ? "(no subject)" : subject,
            kind: .email,
            modifiedAt: (Double(message.internalDate ?? "") ?? 0) / 1000,  // milliseconds -> seconds
            // Sender and recipients are searchable too ("email from Sarah").
            content: "From: \(from)\nTo: \(header("To"))\n\(body)",
            detail: GoogleText.displayName(fromAddress: from),
            source: GoogleService.gmail.sourceID(for: account))
    }

    // An email is a tree of parts (text, HTML, attachments). Prefer the plain
    // text part; fall back to HTML with the tags stripped.
    static func bodyText(_ part: Part) -> String {
        if let text = firstPart(part, mimeType: "text/plain") { return text }
        if let html = firstPart(part, mimeType: "text/html") { return GoogleText.stripHTML(html) }
        return ""
    }

    private static func firstPart(_ part: Part, mimeType: String) -> String? {
        if part.mimeType == mimeType, (part.filename ?? "").isEmpty,
            let data = part.body?.data.flatMap(GoogleText.decodeBase64URL)
        {
            return String(decoding: data, as: UTF8.self)
        }
        for child in part.parts ?? [] {
            if let text = firstPart(child, mimeType: mimeType) { return text }
        }
        return nil
    }

    // MARK: - Gmail's JSON (only the fields we use)

    struct Profile: Decodable { let historyId: String }
    struct MessageList: Decodable {
        struct Ref: Decodable { let id: String }
        let messages: [Ref]?
        let nextPageToken: String?
    }
    struct HistoryList: Decodable {
        struct Change: Decodable {
            struct Ref: Decodable { let id: String; let labelIds: [String]? }
            let message: Ref
        }
        struct Record: Decodable {
            let messagesAdded: [Change]?
            let messagesDeleted: [Change]?
        }
        let history: [Record]?
        let historyId: String?
        let nextPageToken: String?
    }
    struct Message: Decodable {
        let id: String
        let labelIds: [String]?
        let snippet: String?
        let internalDate: String?
        let payload: Part?
    }
    struct Part: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct Body: Decodable { let data: String? }
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?
    }
}
