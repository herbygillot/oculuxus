import XCTest
@testable import Oculuxus

final class DocCommentTests: XCTestCase {
    func testFirstSentence() {
        XCTAssertEqual(DocComment.firstSentence("Open opens the named file. It returns an error."), "Open opens the named file.")
        // Joined across lines.
        XCTAssertEqual(DocComment.firstSentence("Reader wraps an io.Reader\nand counts bytes. More here."), "Reader wraps an io.Reader and counts bytes.")
        // No period: the first paragraph.
        XCTAssertEqual(DocComment.firstSentence("Max returns the larger\n\nSecond paragraph."), "Max returns the larger")
        // A single capital letter before the period is an initial.
        XCTAssertEqual(DocComment.firstSentence("Written by J. Smith in 2020. Second."), "Written by J. Smith in 2020.")
        // A period inside a word does not end the sentence.
        XCTAssertEqual(DocComment.firstSentence("Uses e.g.the default"), "Uses e.g.the default")
        XCTAssertEqual(DocComment.firstSentence("\n\nLeading blank lines. Then more."), "Leading blank lines.")
    }

    func testDisplay() {
        let doc = "First. Second.\n"
        XCTAssertNil(DocDisplay.none.text(for: doc, selected: true))
        XCTAssertNil(DocDisplay.full.text(for: "  \n", selected: false))
        XCTAssertEqual(DocDisplay.firstSentence.text(for: doc, selected: false), "First.")
        XCTAssertEqual(DocDisplay.firstSentence.text(for: doc, selected: true), "First. Second.")
        XCTAssertEqual(DocDisplay.full.text(for: doc, selected: false), "First. Second.")
    }

    func testReflowed() {
        let doc = "Copy copies\nfrom src to dst.\n\nFor example:\n\n\tCopy(dst,\n\t\tsrc)\n\nIt returns\nan error."
        XCTAssertEqual(DocComment.reflowed(doc), "Copy copies from src to dst.\n\nFor example:\n\n\tCopy(dst,\n\t\tsrc)\n\nIt returns an error.")
    }
}
