import Foundation

// Walks folders on disk and feeds what it finds into the search index.
struct FileCrawler: Sendable {
    // Folders whose files are indexed by name and content.
    let roots: [URL]
    // Folders whose files are indexed by name only (apps, cloud drives).
    var nameOnlyRoots: [URL] = []

    // Folders we never descend into: huge, generated, and never what you're searching for.
    private static let skippedNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "__pycache__", "venv", ".venv", "Pods", ".Trash",
    ]

    // What gets indexed until you change it in Settings.
    static var defaultFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
        ]
    }

    // Indexed by name only: what's inside apps and SDKs installed here (like
    // google-cloud-sdk's 27,000 files) is never what you're searching for, and
    // reading it tripled the size of the index.
    static var applicationRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            // Safari lives here. /Applications/Safari.app is only a link to it, and that
            // link is flagged hidden, so .skipsHiddenFiles would never show it to us.
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"),
        ]
    }

    func crawl(into engine: SQLiteSearchEngine) async {
        let started = Date().timeIntervalSince1970
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
            .contentTypeKey,
        ]
        var total = 0
        var read = 0

        for root in roots + nameOnlyRoots {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys,
                    // Hidden files (.git, .DS_Store) are skipped. A "package" is a folder
                    // macOS treats as one item (Safari.app); we don't look inside.
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            // The enumerator reports real paths (/var is really /private/var), so we
            // need the real root path too, or the lookups below would never match.
            let realRoot =
                (try? root.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath ?? root.path

            // What the last crawl saw. A file with the same modification date as last
            // time hasn't changed, so there's no need to read it again.
            let known = (try? await engine.modificationDates(under: realRoot)) ?? [:]

            var batch: [IndexedFile] = []
            var unchanged: [String] = []
            let readsContent = !nameOnlyRoots.contains(root)

            // nextObject() rather than a `for` loop: Swift forbids iterating a
            // DirectoryEnumerator with `for` inside async code.
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { return }

                if Self.skippedNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }

                let values = try? url.resourceValues(forKeys: Set(keys))
                let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

                if known[url.path] == modifiedAt {
                    unchanged.append(url.path)
                    if unchanged.count >= 5000 {
                        try? await engine.touch(unchanged, indexedAt: started)
                        total += unchanged.count
                        unchanged.removeAll(keepingCapacity: true)
                    }
                    continue
                }

                let kind: DocumentKind =
                    url.pathExtension == "app"
                    ? .app
                    : (values?.isDirectory == true && values?.isPackage != true ? .folder : .file)

                var file = IndexedFile(
                    path: url.path,
                    // "Safari.app" shows as "Safari", but files keep their extension.
                    name: kind == .app
                        ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                    kind: kind,
                    size: Int64(values?.fileSize ?? 0),
                    modifiedAt: modifiedAt)
                if readsContent, kind == .file,
                    let text = ContentExtractor.text(
                        of: url, type: values?.contentType, size: values?.fileSize ?? 0)
                {
                    file.content = text
                    read += 1
                }
                batch.append(file)

                // Write in chunks: one transaction per 500 files, not one per file.
                if batch.count >= 500 {
                    try? await engine.upsert(batch, indexedAt: started)
                    total += batch.count
                    batch.removeAll(keepingCapacity: true)
                }
            }

            try? await engine.upsert(batch, indexedAt: started)
            try? await engine.touch(unchanged, indexedAt: started)
            total += batch.count + unchanged.count
            // Anything under this root we didn't just stamp has been deleted from disk.
            try? await engine.prune(under: realRoot, olderThan: started)
        }

        let seconds = Date().timeIntervalSince1970 - started
        NSLog("Indexed \(total) items (read \(read) new or changed files) in \(String(format: "%.1f", seconds))s")
    }
}
