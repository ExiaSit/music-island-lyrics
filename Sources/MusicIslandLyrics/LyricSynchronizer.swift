import Foundation

enum LyricSynchronizer {
    static func lineIndex(at position: TimeInterval, in lines: [LyricLine]) -> Int? {
        guard !lines.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = lines.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if lines[middle].time <= position {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return max(0, lowerBound - 1)
    }

    static func endTime(
        for index: Int,
        in lines: [LyricLine],
        trackDuration: TimeInterval
    ) -> TimeInterval {
        guard lines.indices.contains(index) else { return trackDuration }
        if lines.indices.contains(index + 1) {
            return lines[index + 1].time
        }
        return max(trackDuration, lines[index].time + 0.5)
    }

    static func progress(
        at position: TimeInterval,
        start: TimeInterval,
        end: TimeInterval
    ) -> Double {
        let duration = max(end - start, 0.1)
        return min(max((position - start) / duration, 0), 1)
    }
}
