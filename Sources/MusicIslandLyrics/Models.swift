import Foundation

struct TrackSnapshot: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let position: TimeInterval
    let isPlaying: Bool
    let capturedAt: Date

    var identity: String {
        [title, artist, album, String(Int(duration.rounded()))]
            .joined(separator: "\u{1F}")
    }

    func estimatedPosition(at date: Date) -> TimeInterval {
        let elapsed = isPlaying ? max(0, date.timeIntervalSince(capturedAt)) : 0
        return min(max(position + elapsed, 0), duration)
    }
}

struct LyricLine: Equatable, Sendable {
    let time: TimeInterval
    let text: String
}

enum LyricsResult: Equatable, Sendable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
}

enum DisplayStatus: Equatable {
    case waitingForMusic
    case loadingLyrics
    case showingLyrics
    case instrumental
    case lyricsNotFound
    case permissionRequired(String)
    case error(String)
}

enum IslandPresentation: Equatable, Sendable {
    case compact
    case hover
    case search
}

struct StoreSearchResult: Identifiable, Equatable, Sendable {
    let id: Int64
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let storeURL: URL
}

enum StoreSearchStatus: Equatable, Sendable {
    case idle
    case loading
    case results
    case empty
    case failure(String)
}
