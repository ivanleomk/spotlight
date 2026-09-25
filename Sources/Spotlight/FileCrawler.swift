import Foundation

// Walks folders on disk and feeds what it finds into the search index.
struct FileCrawler: Sendable {
    let roots: [URL]

    // Folders we never descend into: huge, generated, and never what you're searching for.
    private static let skippedNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "__pycache__", "venv", ".venv", "Pods", ".Trash",
    ]

    static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
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
        ]
        var total = 0

        for root in roots {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: keys,
                    // Hidden files (.git, .DS_Store) are skipped. A "package" is a folder
                    // macOS treats as one item (Safari.app); we don't look inside.
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }

            var batch: [IndexedFile] = []

            // nextObject() rather than a `for` loop: Swift forbids iterating a
            // DirectoryEnumerator with `for` inside async code.
            while let url = enumerator.nextObject() as? URL {
                if Task.isCancelled { return }

                if Self.skippedNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }

                let values = try? url.resourceValues(forKeys: Set(keys))
                let kind: DocumentKind =
                    url.pathExtension == "app"
                    ? .app
                    : (values?.isDirectory == true && values?.isPackage != true ? .folder : .file)

                batch.append(
                    IndexedFile(
                        path: url.path,
                        // "Safari.app" shows as "Safari", but files keep their extension.
                        name: kind == .app
                            ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                        kind: kind,
                        size: Int64(values?.fileSize ?? 0),
                        modifiedAt: values?.contentModificationDate?.timeIntervalSince1970 ?? 0))

                // Write in chunks: one transaction per 500 files, not one per file.
                if batch.count >= 500 {
                    try? await engine.upsert(batch, indexedAt: started)
                    total += batch.count
                    batch.removeAll(keepingCapacity: true)
                }
            }

            try? await engine.upsert(batch, indexedAt: started)
            total += batch.count
            // Anything under this root we didn't just stamp has been deleted from disk.
            // The enumerator reports real paths (/var is really /private/var), so the
            // prefix must be the real path too, or prune would never match anything.
            let realRoot = (try? root.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
            try? await engine.prune(under: realRoot ?? root.path, olderThan: started)
        }

        let seconds = Date().timeIntervalSince1970 - started
        NSLog("Indexed \(total) items in \(String(format: "%.1f", seconds))s")
    }
}
