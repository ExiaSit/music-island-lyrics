import Foundation

enum LRCParser {
    private static let timestampRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
    )

    static func parse(_ source: String) -> [LyricLine] {
        var parsed: [LyricLine] = []

        for rawLine in source.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = timestampRegex.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }

            let lyric = timestampRegex
                .stringByReplacingMatches(in: rawLine, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !lyric.isEmpty else { continue }

            for match in matches {
                guard
                    let minuteRange = Range(match.range(at: 1), in: rawLine),
                    let secondRange = Range(match.range(at: 2), in: rawLine),
                    let minutes = Double(rawLine[minuteRange]),
                    let seconds = Double(rawLine[secondRange])
                else { continue }

                var fraction = 0.0
                if let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let digits = String(rawLine[fractionRange])
                    if let value = Double(digits) {
                        fraction = value / pow(10.0, Double(digits.count))
                    }
                }

                parsed.append(LyricLine(
                    time: minutes * 60 + seconds + fraction,
                    text: lyric
                ))
            }
        }

        return parsed.sorted {
            if $0.time == $1.time { return $0.text < $1.text }
            return $0.time < $1.time
        }
    }
}
