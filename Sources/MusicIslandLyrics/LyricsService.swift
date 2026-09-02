import Foundation

protocol LyricsDataLoading: Sendable {
    func loadData(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: LyricsDataLoading {
    func loadData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

enum LyricsServiceError: LocalizedError, Equatable {
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "歌词服务返回了无法识别的数据。"
        case .server(let code):
            return "歌词服务暂时不可用（HTTP \(code)）。"
        }
    }
}

struct LyricsService: Sendable {
    private enum LyricsSource {
        case lrclib
        case lrcApi

        var userAgentToken: String {
            switch self {
            case .lrclib:
                return "LRCLIB"
            case .lrcApi:
                return "LrcApi"
            }
        }
    }

    private struct Response: Decodable, Sendable {
        let trackName: String
        let artistName: String
        let duration: Double
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private let loader: any LyricsDataLoading
    private let decoder = JSONDecoder()

    init(loader: any LyricsDataLoading = URLSession.shared) {
        self.loader = loader
    }

    func fetch(for track: TrackSnapshot) async throws -> LyricsResult {
        var lrclibError: Error?

        do {
            if let exact = try await requestExact(track: track) {
                return makeResult(exact)
            }

            let matches = try await search(track: track)
            if let best = bestMatch(in: matches, for: track) {
                return makeResult(best)
            }
        } catch {
            lrclibError = error
        }

        do {
            if let fallback = try await requestLrcApi(track: track) {
                return fallback
            }
        } catch {
            if let lrclibError {
                throw lrclibError
            }
        }

        if let lrclibError {
            throw lrclibError
        }
        return .notFound
    }

    private func requestExact(track: TrackSnapshot) async throws -> Response? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = queryItems(for: track, includeAlbum: true, includeDuration: true)
        let (data, response) = try await perform(url: components.url!, source: .lrclib)
        if response.statusCode == 404 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            throw LyricsServiceError.server(response.statusCode)
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func search(track: TrackSnapshot) async throws -> [Response] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = queryItems(for: track, includeAlbum: false, includeDuration: false)
        let (data, response) = try await perform(url: components.url!, source: .lrclib)
        guard (200..<300).contains(response.statusCode) else {
            throw LyricsServiceError.server(response.statusCode)
        }
        return try decoder.decode([Response].self, from: data)
    }

    private func requestLrcApi(track: TrackSnapshot) async throws -> LyricsResult? {
        var components = URLComponents(string: "https://api.lrc.cx/lyrics")!
        components.queryItems = lrcApiQueryItems(for: track)
        let (data, response) = try await perform(url: components.url!, source: .lrcApi)
        if response.statusCode == 404 || response.statusCode == 204 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            return nil
        }

        let source = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !looksLikeErrorPayload(source) else { return nil }

        let lines = LRCParser.parse(source)
        if !lines.isEmpty { return .synced(lines) }
        return source.contains("\n") ? .plain(source) : nil
    }

    private func perform(url: URL, source: LyricsSource) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("MusicIslandLyrics/0.2 (macOS; \(source.userAgentToken))", forHTTPHeaderField: "User-Agent")
        let (data, rawResponse) = try await loader.loadData(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw LyricsServiceError.invalidResponse
        }
        return (data, response)
    }

    private func queryItems(
        for track: TrackSnapshot,
        includeAlbum: Bool,
        includeDuration: Bool
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist)
        ]
        if includeAlbum, !track.album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: track.album))
        }
        if includeDuration, track.duration > 0 {
            items.append(URLQueryItem(
                name: "duration",
                value: String(Int(track.duration.rounded()))
            ))
        }
        return items
    }

    private func lrcApiQueryItems(for track: TrackSnapshot) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "title", value: track.title),
            URLQueryItem(name: "artist", value: track.artist)
        ]
        if !track.album.isEmpty {
            items.append(URLQueryItem(name: "album", value: track.album))
        }
        return items
    }

    private func bestMatch(in matches: [Response], for track: TrackSnapshot) -> Response? {
        let normalizedTitle = normalize(track.title)
        let normalizedArtist = normalize(track.artist)

        return matches
            .filter { normalize($0.trackName) == normalizedTitle }
            .min { lhs, rhs in
                score(lhs, artist: normalizedArtist, duration: track.duration)
                    < score(rhs, artist: normalizedArtist, duration: track.duration)
            }
    }

    private func score(_ candidate: Response, artist: String, duration: Double) -> Double {
        let artistPenalty = normalize(candidate.artistName).contains(artist) ? 0.0 : 1000.0
        let durationPenalty = duration > 0 ? abs(candidate.duration - duration) : 0
        return artistPenalty + durationPenalty
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression)
    }

    private func makeResult(_ response: Response) -> LyricsResult {
        if response.instrumental { return .instrumental }
        if let synced = response.syncedLyrics {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = response.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plain.isEmpty {
            return .plain(plain)
        }
        return .notFound
    }

    private func looksLikeErrorPayload(_ source: String) -> Bool {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("{\"detail\"")
            || normalized.hasPrefix("<!doctype html")
            || normalized.hasPrefix("<html")
            || normalized == "not found"
    }
}
