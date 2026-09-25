import Foundation

// One account's Google Drive: every file you own or that's shared with you.
//
//   First sync: take Drive's "start page token" (a bookmark for *now*), then
//   list every file and index its name, owner and dates. Google Docs also get
//   their text, exported as plain text.
//   Later syncs: ask Drive's change feed for everything since the bookmark,
//   and update or remove just those files.
struct DriveSource: Source {
    let api: GoogleAPI
    // Only the most recently touched Docs have their text exported: one
    // request each, so this keeps the first sync reasonable.
    var maxExportedDocs = 1_000
    var parallelExports = 4

    var id: String { GoogleService.drive.sourceID(for: api.email) }
    var displayName: String { "Drive (\(api.email))" }

    static let base = "https://www.googleapis.com/drive/v3"
    static let fileFields = "id,name,mimeType,modifiedTime,viewedByMeTime,trashed,owners(displayName,me)"
    static let googleDoc = "application/vnd.google-apps.document"

    func sync(into index: SQLiteSearchEngine, since cursor: String?) async throws -> String? {
        if let cursor {
            do {
                return try await applyChanges(into: index, since: cursor)
            } catch GoogleAPIError.notFound {
                NSLog("Drive changes for \(api.email) expired; doing a full sync")
            }
        }
        return try await fullSync(into: index)
    }

    private func fullSync(into index: SQLiteSearchEngine) async throws -> String? {
        // Bookmark first, so edits made while we list are caught next time.
        let start: StartToken = try await api.get("\(Self.base)/changes/startPageToken")

        var files: [File] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "q", value: "trashed = false"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(Self.fileFields))"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: FileList = try await api.get("\(Self.base)/files", query)
            files += page.files ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil

        // Names first, all at once, so every file is searchable quickly...
        try await index.upsert(files.map { Self.indexedFile(from: $0, text: "", account: api.email) })
        // ...then fill in the text of the most recently touched Docs.
        let docs = files.filter { $0.mimeType == Self.googleDoc }
            .sorted { ($0.lastTouched ?? .distantPast) > ($1.lastTouched ?? .distantPast) }
            .prefix(maxExportedDocs)
        try await indexFiles(Array(docs), into: index)

        let seen = Set(files.map { Self.link(fileID: $0.id) })
        let indexed = try await index.paths(from: id)
        try await index.remove(paths: Array(indexed.subtracting(seen)))
        return start.startPageToken
    }

    private func applyChanges(into index: SQLiteSearchEngine, since cursor: String) async throws -> String? {
        var changed: [File] = []
        var removed: [String] = []
        var pageToken: String? = cursor
        var newCursor = cursor
        while let token = pageToken {
            let page: ChangeList = try await api.get(
                "\(Self.base)/changes",
                [
                    URLQueryItem(name: "pageToken", value: token),
                    URLQueryItem(name: "pageSize", value: "1000"),
                    URLQueryItem(
                        name: "fields",
                        value: "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(Self.fileFields)))"),
                ])
            for change in page.changes ?? [] {
                if change.removed == true || change.file?.trashed == true || change.file == nil {
                    removed.append(Self.link(fileID: change.fileId))
                } else if let file = change.file {
                    changed.append(file)
                }
            }
            pageToken = page.nextPageToken
            if let next = page.newStartPageToken { newCursor = next }
        }
        try await indexFiles(changed, into: index)
        try await index.remove(paths: removed)
        return newCursor
    }

    // Indexes files, exporting the text of any Google Docs among them.
    private func indexFiles(_ files: [File], into index: SQLiteSearchEngine) async throws {
        for start in stride(from: 0, to: files.count, by: 50) {
            if Task.isCancelled { return }
            let chunk = Array(files[start..<min(start + 50, files.count)])
            let rows = try await chunk.concurrentMap(width: parallelExports) { [api] file -> IndexedFile? in
                var text = ""
                if file.mimeType == Self.googleDoc {
                    let data = try? await api.data(
                        "\(Self.base)/files/\(file.id)/export", [URLQueryItem(name: "mimeType", value: "text/plain")])
                    text = GoogleText.tidy(String(decoding: data ?? Data(), as: UTF8.self))
                }
                return Self.indexedFile(from: file, text: text, account: api.email)
            }
            try await index.upsert(rows)
        }
    }

    // Built from the file id, so a deletion (which only tells us the id) can
    // find the row to remove.
    static func link(fileID: String) -> String {
        "https://drive.google.com/open?id=\(fileID)"
    }

    static func indexedFile(from file: File, text: String, account: String) -> IndexedFile {
        let owner = file.owners?.first
        return IndexedFile(
            path: link(fileID: file.id),
            name: file.name,
            kind: .driveFile,
            modifiedAt: file.lastTouched?.timeIntervalSince1970 ?? 0,
            content: text,
            detail: owner?.me == true ? "You" : (owner?.displayName ?? ""),
            source: GoogleService.drive.sourceID(for: account))
    }

    // MARK: - Drive's JSON (only the fields we use)

    struct StartToken: Decodable { let startPageToken: String }
    struct FileList: Decodable {
        let files: [File]?
        let nextPageToken: String?
    }
    struct ChangeList: Decodable {
        struct Change: Decodable {
            let fileId: String
            let removed: Bool?
            let file: File?
        }
        let changes: [Change]?
        let nextPageToken: String?
        let newStartPageToken: String?
    }
    struct File: Decodable {
        struct Owner: Decodable { let displayName: String?; let me: Bool? }
        let id: String
        let name: String
        let mimeType: String?
        let modifiedTime: String?
        let viewedByMeTime: String?
        let trashed: Bool?
        let owners: [Owner]?

        // Whichever is later: when it was last edited, or when you last opened it.
        var lastTouched: Date? {
            [modifiedTime, viewedByMeTime]
                .compactMap { $0.flatMap(GoogleText.date(fromISO8601:)) }
                .max()
        }
    }
}
