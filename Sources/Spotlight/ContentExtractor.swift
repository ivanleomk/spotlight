import Foundation
import PDFKit
import UniformTypeIdentifiers

// Pulls searchable text out of a file, if it's a kind we know how to read.
// An enum with no cases is a common Swift trick for "a namespace of static
// functions": nobody can accidentally create an instance of it.
enum ContentExtractor {
    // Only the start of each file is indexed: enough to find a file by what it's
    // about, without the index growing to gigabytes.
    static let maxCharacters = 10_000

    private static let maxTextFileSize = 2_000_000  // bytes
    private static let maxPDFSize = 50_000_000

    // Huge machine-written files that would match nearly every search.
    private static let skippedNames: Set<String> = [
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Package.resolved", "Cargo.lock",
        "poetry.lock", "uv.lock",
    ]

    // Text formats macOS doesn't recognize as text. ".ts" is the worst offender:
    // macOS thinks it's an MPEG video, not TypeScript.
    private static let extraTextExtensions: Set<String> = [
        "ts", "tsx", "mts", "cts", "jsx", "vue", "svelte", "toml", "ini", "env", "gradle",
    ]

    // `type` is the file's Uniform Type (UTType): macOS's name for what a file
    // is, e.g. "public.plain-text" or "com.adobe.pdf". Types form a family tree,
    // so `conforms(to: .text)` is true for Markdown, Swift, JSON, HTML, ...
    static func text(of url: URL, type: UTType?, size: Int) -> String? {
        guard !skippedNames.contains(url.lastPathComponent) else { return nil }

        if type?.conforms(to: .pdf) == true {
            return size <= maxPDFSize ? pdfText(url) : nil
        }

        let isText =
            type?.conforms(to: .text) == true
            || extraTextExtensions.contains(url.pathExtension.lowercased())
        guard isText, size <= maxTextFileSize else { return nil }

        // Files that aren't valid UTF-8 (usually binary files misnamed as text) fail
        // here, and `try?` turns the failure into nil.
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return String(text.prefix(maxCharacters))
    }

    private static func pdfText(_ url: URL) -> String? {
        // PDFKit creates lots of temporary objects that are only freed when the
        // surrounding "autorelease pool" ends. Our crawl loop never ends one, so
        // without this, reading thousands of PDFs would slowly eat all the memory.
        autoreleasepool {
            guard let document = PDFDocument(url: url) else { return nil }
            var text = ""
            for index in 0..<document.pageCount {
                text += (document.page(at: index)?.string ?? "") + "\n"
                if text.utf8.count >= maxCharacters { break }
            }
            return String(text.prefix(maxCharacters))
        }
    }
}
