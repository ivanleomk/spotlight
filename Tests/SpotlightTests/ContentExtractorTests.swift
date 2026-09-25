import AppKit
import Testing
import UniformTypeIdentifiers

@testable import Spotlight

@Suite struct ContentExtractorTests {
    // Reads a real file's type and size the same way the crawler does.
    private func extract(_ url: URL) throws -> String? {
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        return ContentExtractor.text(of: url, type: values.contentType, size: values.fileSize ?? 0)
    }

    @Test func readsMarkdownAndCode() throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }

        #expect(try extract(folder.write("# Plan", to: "plan.md")) == "# Plan")
        #expect(try extract(folder.write("let x = 1", to: "main.swift")) == "let x = 1")
        #expect(try extract(folder.write(#"{"a": 1}"#, to: "data.json")) == #"{"a": 1}"#)
    }

    @Test func readsTypeScriptEvenThoughMacOSCallsItVideo() throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let file = try folder.write("export const a = 1", to: "index.ts")

        #expect(UTType(filenameExtension: "ts")?.conforms(to: .text) != true)
        #expect(try extract(file) == "export const a = 1")
    }

    @Test func skipsLockfiles() throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }

        #expect(try extract(folder.write("{}", to: "package-lock.json")) == nil)
        #expect(try extract(folder.write("x", to: "pnpm-lock.yaml")) == nil)
    }

    @Test func skipsFilesThatAreNotValidUTF8() throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let file = try folder.write(Data([0xFF, 0xFE, 0x00, 0xC3]), to: "binary.txt")

        #expect(try extract(file) == nil)
    }

    @Test func skipsNonTextFiles() throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let file = try folder.write(Data([0x89, 0x50, 0x4E, 0x47]), to: "photo.png")

        #expect(try extract(file) == nil)
    }

    @Test func skipsTextFilesOverTheSizeLimit() throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let file = try folder.write("small", to: "notes.txt")

        // The size check trusts the size it's given, so no need to write 2 MB.
        #expect(ContentExtractor.text(of: file, type: .plainText, size: 3_000_000) == nil)
    }

    @Test func keepsOnlyTheStartOfLongFiles() throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        let long = String(repeating: "a", count: ContentExtractor.maxCharacters + 500)
        let file = try folder.write(long, to: "long.txt")

        #expect(try extract(file)?.count == ContentExtractor.maxCharacters)
    }

    // Views must be created on the main thread, hence @MainActor.
    @MainActor
    @Test func readsTextFromPDFs() throws {
        let folder = try TemporaryFolder()
        defer { folder.delete() }
        // Draw some text into a view and save that view as a PDF.
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        view.string = "Zeppelin maintenance manual"
        let file = try folder.write(view.dataWithPDF(inside: view.bounds), to: "manual.pdf")

        let text = try #require(try extract(file))

        #expect(text.contains("Zeppelin maintenance manual"))
    }
}
