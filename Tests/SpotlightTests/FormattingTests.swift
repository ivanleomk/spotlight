import CoreGraphics
import SwiftUI
import Testing

@testable import Spotlight

@Suite struct DocumentKindLabelTests {
    @Test func namesAndActions() {
        #expect(DocumentKind.app.displayName == "Application")
        #expect(DocumentKind.folder.displayName == "Folder")
        #expect(DocumentKind.file.displayName == "File")
        #expect(DocumentKind.app.openActionName == "Open Application")
    }
}

@Suite struct PathDisplayTests {
    private let home = "/Users/ivan"

    @Test func shortensPathsInsideHome() {
        #expect(PathDisplay.abbreviatingHome("/Users/ivan/Documents/x.pdf", home: home) == "~/Documents/x.pdf")
        #expect(PathDisplay.abbreviatingHome("/Users/ivan", home: home) == "~")
    }

    @Test func leavesLookalikeAndOutsidePathsAlone() {
        #expect(PathDisplay.abbreviatingHome("/Users/ivan2/x", home: home) == "/Users/ivan2/x")
        #expect(PathDisplay.abbreviatingHome("/Applications/Safari.app", home: home) == "/Applications/Safari.app")
        #expect(PathDisplay.abbreviatingHome("/tmp/Users/ivan/x", home: home) == "/tmp/Users/ivan/x")
    }

    @Test func parentFolderDropsTheName() {
        #expect(PathDisplay.parentFolder(of: "/Users/ivan/Documents/x.pdf", home: home) == "~/Documents")
        #expect(PathDisplay.parentFolder(of: "/Applications/Safari.app", home: home) == "/Applications")
    }
}

@Suite struct MatchMarkerTests {
    // The pieces of the text that are bold.
    private func boldParts(_ text: AttributedString) -> [String] {
        text.runs.filter { $0.font != nil }.map { String(text[$0.range].characters) }
    }

    @Test func boldsEachMatchAndRemovesTheMarkers() {
        let text = MatchMarker.attributed("buy \u{2}oat\u{3} and \u{2}milk\u{3}")

        #expect(String(text.characters) == "buy oat and milk")
        #expect(boldParts(text) == ["oat", "milk"])
    }

    @Test func flattensLineBreaks() {
        let text = MatchMarker.attributed("one\n\n  \u{2}two\u{3}\tthree")

        #expect(String(text.characters) == "one two three")
    }

    @Test func plainTextStaysPlain() {
        let text = MatchMarker.attributed("nothing matched here")

        #expect(String(text.characters) == "nothing matched here")
        #expect(boldParts(text).isEmpty)
    }

    @Test func unclosedMarkerIsKeptAsPlainText() {
        let text = MatchMarker.attributed("cut off \u{2}mid")

        #expect(boldParts(text).isEmpty)
        #expect(String(text.characters).hasSuffix("mid"))
    }
}

@Suite struct WindowPlacementTests {
    @Test func centersInsideTheArea() {
        let origin = NSWindow.centeredOrigin(
            for: CGSize(width: 800, height: 600), in: CGRect(x: 0, y: 0, width: 1600, height: 1000))

        #expect(origin == CGPoint(x: 400, y: 200))
    }

    @Test func respectsAreasThatDontStartAtZero() {
        // A second monitor to the right, below the menu bar and above the Dock.
        let origin = NSWindow.centeredOrigin(
            for: CGSize(width: 780, height: 540), in: CGRect(x: 1512, y: 80, width: 1920, height: 1000))

        #expect(origin == CGPoint(x: 2082, y: 310))
    }
}
