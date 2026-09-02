import Testing
@testable import MusicIslandLyrics

struct LRCParserTests {
    @Test func parsesAndSortsTimestamps() {
        let source = """
        [00:12.34]Second line
        [00:01.5][00:02.050]First line
        [ar:Artist]
        """

        let lines = LRCParser.parse(source)

        #expect(lines.count == 3)
        #expect(lines[0] == LyricLine(time: 1.5, text: "First line"))
        #expect(lines[1] == LyricLine(time: 2.05, text: "First line"))
        #expect(lines[2] == LyricLine(time: 12.34, text: "Second line"))
    }

    @Test func skipsEmptyAndMetadataLines() {
        let source = """
        [ti:Example]
        [00:01.00]
        [00:02.00]  Hello  
        """

        #expect(LRCParser.parse(source) == [LyricLine(time: 2, text: "Hello")])
    }
}
