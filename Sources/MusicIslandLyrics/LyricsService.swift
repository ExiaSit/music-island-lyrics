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
                if isLikelyMatch(exact, for: track) {
                    return makeResult(exact)
                }
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
        guard lrcApiPayloadMatchesTrack(source, track: track) else { return nil }

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
        let primaryTitle = stripBracketedQualifiers(from: track.title)
        let title = primaryTitle.isEmpty ? track.title : primaryTitle
        var items = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: track.artist)
        ]
        if !track.album.isEmpty {
            items.append(URLQueryItem(name: "album", value: track.album))
        }
        return items
    }

    private func bestMatch(in matches: [Response], for track: TrackSnapshot) -> Response? {
        let normalizedTitles = normalizedTitleCandidates(for: track.title)
        let normalizedArtist = normalize(track.artist)

        return matches
            .filter { normalizedTitles.contains(normalize($0.trackName)) }
            .min { lhs, rhs in
                score(lhs, artist: normalizedArtist, duration: track.duration)
                    < score(rhs, artist: normalizedArtist, duration: track.duration)
            }
    }

    private func isLikelyMatch(_ candidate: Response, for track: TrackSnapshot) -> Bool {
        let titleMatches = normalizedTitleCandidates(for: track.title)
            .contains(normalize(candidate.trackName))
        let trackArtist = normalize(track.artist)
        let candidateArtist = normalize(candidate.artistName)
        let artistMatches = !trackArtist.isEmpty
            && !candidateArtist.isEmpty
            && (candidateArtist.contains(trackArtist) || trackArtist.contains(candidateArtist))
        return titleMatches && artistMatches
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

    private func normalizedTitleCandidates(for title: String) -> Set<String> {
        let normalizedTitle = normalize(title)
        let normalizedPrimaryTitle = normalize(stripBracketedQualifiers(from: title))
        return Set([normalizedTitle, normalizedPrimaryTitle].filter { !$0.isEmpty })
    }

    private func stripBracketedQualifiers(from title: String) -> String {
        title
            .replacingOccurrences(of: #"（[^）]*）"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"【[^】]*】"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func lrcApiPayloadMatchesTrack(_ source: String, track: TrackSnapshot) -> Bool {
        let metadata = lrcMetadata(in: source)
        if let metadataTitle = metadata["ti"], !metadataTitle.isEmpty {
            guard normalizedTitleCandidates(for: track.title).contains(normalize(metadataTitle))
                    || phoneticTitleCandidates(for: track.title).contains(phoneticNormalize(metadataTitle))
            else {
                return false
            }
        }
        if let metadataArtist = metadata["ar"], !metadataArtist.isEmpty {
            let trackArtist = normalize(track.artist)
            let sourceArtist = normalize(metadataArtist)
            guard !trackArtist.isEmpty,
                  !sourceArtist.isEmpty,
                  sourceArtist.contains(trackArtist) || trackArtist.contains(sourceArtist)
            else { return false }
        }
        if metadata["ti"] != nil || metadata["ar"] != nil {
            return true
        }

        // LrcApi returns only raw LRC for many songs, with no result title or artist
        // to verify. In that case, accept it only when the lyrics text itself
        // contains the current song's primary title. This is intentionally
        // conservative: showing no lyrics is better than showing the wrong song.
        let normalizedBody = normalize(source)
        if normalizedTitleCandidates(for: track.title)
            .contains(where: { title in
                title.count >= 2 && normalizedBody.contains(title)
            }) {
            return true
        }

        let phoneticBody = phoneticNormalize(source)
        return phoneticTitleCandidates(for: track.title)
            .contains(where: { title in
                title.count >= 4 && phoneticBody.contains(title)
            })
    }

    private func lrcMetadata(in source: String) -> [String: String] {
        source.components(separatedBy: .newlines)
            .reduce(into: [:]) { result, line in
                guard line.hasPrefix("["),
                      let closeIndex = line.firstIndex(of: "]")
                else { return }

                let content = String(line[line.index(after: line.startIndex)..<closeIndex])
                let parts = content.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return }

                let key = String(parts[0]).lowercased()
                guard key == "ti" || key == "ar" else { return }
                result[key] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private func phoneticTitleCandidates(for title: String) -> Set<String> {
        let normalizedTitle = phoneticNormalize(title)
        let normalizedPrimaryTitle = phoneticNormalize(stripBracketedQualifiers(from: title))
        return Set([normalizedTitle, normalizedPrimaryTitle].filter { !$0.isEmpty })
    }

    private func phoneticNormalize(_ value: String) -> String {
        let latin = value.applyingTransform(.toLatin, reverse: false) ?? value
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return plain
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression)
    }
}
