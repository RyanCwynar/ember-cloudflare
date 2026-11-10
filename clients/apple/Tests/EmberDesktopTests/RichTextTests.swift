import SwiftUI
import XCTest
@testable import EmberDesktop

final class RichTextTests: XCTestCase {
    private let renderer = RichTextRenderer(name: { $0 == "0123456789abcdef" ? "Ann" : nil }, server: URL(string: "https://chat.example.com"))

    private func text(_ block: RichBlock?) -> String? {
        guard case let .paragraph(t) = block else { return nil }
        return String(t.characters)
    }

    func testParagraphsFormattingAndBreaks() {
        let blocks = renderer.blocks("<p>Hi <strong>there</strong><br>second &amp; line</p><p>next</p>")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(text(blocks.first), "Hi there\nsecond & line")
        XCTAssertEqual(text(blocks.last), "next")
    }

    func testMentionsShowCurrentNames() {
        let html = #"<p>Hey <action-text-attachment content-type="application/vnd.campfire.mention" sgid="0123456789abcdef"></action-text-attachment>!</p>"#
        XCTAssertEqual(text(renderer.blocks(html).first), "Hey @Ann!")
    }

    func testCodeQuotesAndLists() {
        let blocks = renderer.blocks("<pre>let x = 1\nlet y = 2</pre><blockquote>quoted</blockquote><ul><li>a</li><li>b</li></ul>")
        XCTAssertEqual(blocks.count, 3)
        if case let .code(code) = blocks[0] { XCTAssertEqual(code, "let x = 1\nlet y = 2") } else { XCTFail() }
        if case let .quote(inner) = blocks[1] { XCTAssertEqual(text(inner.first), "quoted") } else { XCTFail() }
        if case let .list(ordered, items) = blocks[2] { XCTAssertFalse(ordered); XCTAssertEqual(items.count, 2) } else { XCTFail() }
    }

    func testBareLinksAreLinked() throws {
        guard case let .paragraph(t) = renderer.blocks("<p>see https://example.com now</p>").first else { return XCTFail() }
        XCTAssertTrue(t.runs.contains { $0.link?.host == "example.com" })
    }

    func testComposerMarkup() {
        let ann = ComposerMarkup.Mention(id: "0123456789abcdef", name: "Ann")
        XCTAssertEqual(ComposerMarkup.markup(from: "hi", mentions: []), "<p>hi</p>")
        XCTAssertEqual(ComposerMarkup.markup(from: "**bold** and *it* and `a<b`", mentions: []),
                       "<p><strong>bold</strong> and <em>it</em> and <code>a&lt;b</code></p>")
        XCTAssertEqual(ComposerMarkup.markup(from: "hey @Ann", mentions: [ann]),
                       #"<p>hey <action-text-attachment content-type="application/vnd.campfire.mention" sgid="0123456789abcdef"></action-text-attachment></p>"#)
        XCTAssertEqual(ComposerMarkup.markup(from: "- one\n- two", mentions: []), "<ul><li>one</li><li>two</li></ul>")
        XCTAssertEqual(ComposerMarkup.markup(from: "```\nx < y\n```", mentions: []), "<pre>x &lt; y</pre>")
        XCTAssertEqual(ComposerMarkup.markup(from: "snake_case_name", mentions: []), "<p>snake_case_name</p>")
    }

    func testEditableTextRoundTrips() {
        let ann = ComposerMarkup.Mention(id: "0123456789abcdef", name: "Ann")
        let original = "**hi** @Ann\nsecond"
        let markup = ComposerMarkup.markup(from: original, mentions: [ann])
        let (text, mentions) = ComposerMarkup.editableText(from: markup) { $0 == ann.id ? "Ann" : nil }
        XCTAssertEqual(text, original)
        XCTAssertEqual(mentions, [ann])
    }
}
