import XCTest
@testable import SuperIsland

final class LRCParserTests: XCTestCase {
    func testParsesTimestampFormatsAndSortsLines() {
        let lines = LRCParser.parse("""
        [ar:Artist]
        [03:02]Third
        [00:12.34]First
        [01:05.00]Second
        """)

        XCTAssertEqual(lines.map(\.text), ["First", "Second", "Third"])
        XCTAssertEqual(lines.map(\.time), [12.34, 65.0, 182.0])
    }

    func testParsesMultipleTimestampsOnSameLine() {
        let lines = LRCParser.parse("[00:10.00][00:20.00] repeated lyric ")

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], LyricLine(time: 10, text: "repeated lyric"))
        XCTAssertEqual(lines[1], LyricLine(time: 20, text: "repeated lyric"))
    }

    func testIgnoresEmptyMetadataAndMalformedLines() {
        let lines = LRCParser.parse("""
        [ti:Song]
        [al:Album]
        []
        [bad]Broken
        [00:01.5]
        [00:02.500] Valid
        """)

        XCTAssertEqual(lines, [LyricLine(time: 2.5, text: "Valid")])
    }
}
