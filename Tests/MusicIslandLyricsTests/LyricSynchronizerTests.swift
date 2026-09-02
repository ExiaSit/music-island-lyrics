import Foundation
import Testing
@testable import MusicIslandLyrics

struct LyricSynchronizerTests {
    private let lines = [
        LyricLine(time: 1, text: "one"),
        LyricLine(time: 4.5, text: "two"),
        LyricLine(time: 8, text: "three")
    ]

    @Test func selectsLineFromPlaybackPosition() {
        #expect(LyricSynchronizer.lineIndex(at: 0, in: lines) == 0)
        #expect(LyricSynchronizer.lineIndex(at: 1, in: lines) == 0)
        #expect(LyricSynchronizer.lineIndex(at: 4.49, in: lines) == 0)
        #expect(LyricSynchronizer.lineIndex(at: 4.5, in: lines) == 1)
        #expect(LyricSynchronizer.lineIndex(at: 20, in: lines) == 2)
    }

    @Test func usesNextTimestampAsLineEnd() {
        #expect(LyricSynchronizer.endTime(for: 0, in: lines, trackDuration: 12) == 4.5)
        #expect(LyricSynchronizer.endTime(for: 1, in: lines, trackDuration: 12) == 8)
        #expect(LyricSynchronizer.endTime(for: 2, in: lines, trackDuration: 12) == 12)
    }

    @Test func clampsLineProgress() {
        #expect(LyricSynchronizer.progress(at: 0, start: 1, end: 5) == 0)
        #expect(LyricSynchronizer.progress(at: 3, start: 1, end: 5) == 0.5)
        #expect(LyricSynchronizer.progress(at: 7, start: 1, end: 5) == 1)
    }

    @Test func estimatesPlayingButNotPausedPosition() {
        let now = Date()
        let playing = TrackSnapshot(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 100,
            position: 20,
            isPlaying: true,
            capturedAt: now
        )
        let paused = TrackSnapshot(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 100,
            position: 20,
            isPlaying: false,
            capturedAt: now
        )

        #expect(playing.estimatedPosition(at: now.addingTimeInterval(2)) == 22)
        #expect(paused.estimatedPosition(at: now.addingTimeInterval(2)) == 20)
    }
}
