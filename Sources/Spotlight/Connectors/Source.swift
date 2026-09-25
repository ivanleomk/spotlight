import Foundation

// Anything that can put searchable items into the index: the folders on this Mac
// today; Gmail and Google Drive next. Like SearchEngine, it's a protocol, so the
// scheduler and Settings work with any source without knowing which kind it is.
protocol Source: Sendable {
    // Stable, short, stored in every row this source writes: "files", "gmail".
    var id: String { get }
    // Shown in Settings: "Local Files", "Gmail".
    var displayName: String { get }

    // Brings the index up to date. `cursor` is what the previous sync returned
    // (nil the first time); the return value is saved and handed back next time,
    // so a source can fetch only what changed since then.
    func sync(into index: SQLiteSearchEngine, since cursor: String?) async throws -> String?
}
