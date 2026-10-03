import XCTest
@testable import ThisJellyFixCore

final class SRTParserTests: XCTestCase {
    func testParsesSimpleCue() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello world

        2
        00:00:05,500 --> 00:00:07,000
        Second line
        continues
        """
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 4.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Hello world")
        XCTAssertEqual(cues[1].text, "Second line\ncontinues")
    }

    func testParsesDotMillisecondsAndCRLF() throws {
        let srt = "1\r\n00:00:01.250 --> 00:00:02.750\r\nDotted\r\n\r\n"
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].start, 1.25, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 2.75, accuracy: 0.001)
    }

    func testSkipsMalformedBlocks() throws {
        let srt = """
        1
        not-a-timestamp --> nope
        Broken

        2
        00:00:03,000 --> 00:00:04,000
        Good
        """
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Good")
    }

    func testCueLookupBinarySearch() throws {
        let cues = [
            SubtitleCue(start: 0, end: 2, text: "a"),
            SubtitleCue(start: 3, end: 5, text: "b"),
            SubtitleCue(start: 10, end: 12, text: "c"),
        ]
        XCTAssertEqual(SRTParser.cue(at: 1, in: cues)?.text, "a")
        XCTAssertNil(SRTParser.cue(at: 2.5, in: cues))
        XCTAssertEqual(SRTParser.cue(at: 4.9, in: cues)?.text, "b")
        XCTAssertEqual(SRTParser.cue(at: 11, in: cues)?.text, "c")
        XCTAssertNil(SRTParser.cue(at: 99, in: cues))
    }
}
