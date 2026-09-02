import Combine
import Foundation
import AppKit

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var track: TrackSnapshot?
    @Published private(set) var lyrics: LyricsResult = .notFound
    @Published private(set) var artwork: NSImage?
    @Published private(set) var status: DisplayStatus = .waitingForMusic
    @Published var overlayVisible = true
    @Published private(set) var islandPresentation: IslandPresentation = .compact
    @Published var compactIslandHeight: CGFloat = 38
    @Published var searchQuery = ""
    @Published private(set) var searchResults: [StoreSearchResult] = []
    @Published private(set) var searchStatus: StoreSearchStatus = .idle
    @Published private(set) var seekPreviewPosition: TimeInterval?

    private let reader = MusicReader()
    private let lyricsService = LyricsService()
    private let searchService: any StoreSearching
    private let searchDebounce: Duration
    private let searchCountry: String
    private var monitorTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchQueryCancellable: AnyCancellable?
    private var loadedTrackIdentity: String?
    private var searchCache: [SearchCacheKey: [StoreSearchResult]] = [:]

    init(
        searchService: any StoreSearching = StoreSearchService(),
        searchDebounce: Duration = .milliseconds(600),
        regionCode: String? = nil
    ) {
        self.searchService = searchService
        self.searchDebounce = searchDebounce
        self.searchCountry = StoreSearchService.normalizedCountry(
            regionCode ?? Locale.current.region?.identifier ?? "CN"
        )

        searchQueryCancellable = $searchQuery
            .removeDuplicates()
            .sink { [weak self] query in
                self?.scheduleSearch(for: query)
            }
    }

    func start() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    func retryLyrics() {
        guard let track else { return }
        loadedTrackIdentity = nil
        loadLyricsIfNeeded(for: track)
    }

    func togglePlayback() {
        do {
            try reader.togglePlayback()
            Task { await refresh() }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func playNext() {
        do {
            try reader.nextTrack()
            loadedTrackIdentity = nil
            seekPreviewPosition = nil
            Task { await refresh() }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func updateSeekPreview(_ position: TimeInterval) {
        let duration = max(track?.duration ?? 0, 0)
        seekPreviewPosition = min(max(position, 0), duration)
    }

    func finishSeeking() {
        guard let position = seekPreviewPosition else { return }
        seekPreviewPosition = nil

        do {
            try reader.seek(to: position)
            Task { await refresh() }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func activateMusicApp() {
        let musicAppURL = URL(fileURLWithPath: "/System/Applications/Music.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.openApplication(
            at: musicAppURL,
            configuration: configuration
        ) { [weak self] application, error in
            Task { @MainActor in
                if error != nil || application == nil {
                    self?.status = .error("无法打开 Music。")
                }
            }
        }
    }

    func updateHovering(_ hovering: Bool) {
        guard islandPresentation != .search else { return }
        islandPresentation = hovering ? .hover : .compact
    }

    func openSearch() {
        islandPresentation = .search
    }

    func closeSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
        searchStatus = .idle
        islandPresentation = .compact
    }

    func openSearchResult(_ result: StoreSearchResult) {
        let musicAppURL = URL(fileURLWithPath: "/System/Applications/Music.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.open(
            [result.storeURL],
            withApplicationAt: musicAppURL,
            configuration: configuration
        ) { [weak self] application, error in
            Task { @MainActor in
                guard let self else { return }
                if error == nil, application != nil {
                    self.closeSearch()
                } else if NSWorkspace.shared.open(result.storeURL) {
                    self.closeSearch()
                } else {
                    self.searchStatus = .failure("无法在 Music 或浏览器中打开这首歌。")
                }
            }
        }
    }

    var searchPanelRowCount: Int {
        switch searchStatus {
        case .idle:
            return 0
        case .loading, .empty, .failure:
            return 1
        case .results:
            return min(searchResults.count, 6)
        }
    }

    var islandExtraHeight: CGFloat {
        switch islandPresentation {
        case .compact:
            return 0
        case .hover:
            return 40
        case .search:
            return 50 + CGFloat(searchPanelRowCount * 42)
        }
    }

    var currentLineIndex: Int? {
        guard let track, case .synced(let lines) = lyrics, !lines.isEmpty else { return nil }
        return LyricSynchronizer.lineIndex(at: track.position + 0.08, in: lines)
    }

    var currentLyric: String {
        if case .error(let message) = status {
            return message
        }
        switch lyrics {
        case .synced(let lines):
            guard let index = currentLineIndex, lines.indices.contains(index) else {
                return "等待歌词开始…"
            }
            return lines[index].text
        case .plain(let text):
            return text.components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                ?? "已获取普通歌词"
        case .instrumental:
            return "纯音乐 · 请享受旋律"
        case .notFound:
            return "暂未找到歌词"
        }
    }

    var nextLyric: String? {
        guard
            case .synced(let lines) = lyrics,
            let index = currentLineIndex,
            lines.indices.contains(index + 1)
        else { return nil }
        return lines[index + 1].text
    }

    var displayPlaybackPosition: TimeInterval {
        if let seekPreviewPosition { return seekPreviewPosition }
        guard let track else { return 0 }
        return track.estimatedPosition(at: Date())
    }

    private func refresh() async {
        do {
            guard let snapshot = try reader.currentTrack() else {
                track = nil
                artwork = nil
                artworkTask?.cancel()
                seekPreviewPosition = nil
                status = .waitingForMusic
                loadedTrackIdentity = nil
                return
            }

            track = snapshot
            loadLyricsIfNeeded(for: snapshot)
        } catch let error as MusicReaderError {
            track = nil
            switch error {
            case .automationDenied:
                status = .permissionRequired(error.localizedDescription)
            case .script:
                status = .error(error.localizedDescription)
            }
        } catch {
            track = nil
            status = .error(error.localizedDescription)
        }
    }

    private func loadLyricsIfNeeded(for snapshot: TrackSnapshot) {
        guard loadedTrackIdentity != snapshot.identity else { return }
        loadedTrackIdentity = snapshot.identity
        lyricsTask?.cancel()
        artworkTask?.cancel()
        seekPreviewPosition = nil
        artwork = nil
        loadArtwork(for: snapshot)
        lyrics = .notFound
        status = .loadingLyrics

        lyricsTask = Task { [weak self, lyricsService] in
            do {
                let result = try await lyricsService.fetch(for: snapshot)
                guard !Task.isCancelled, self?.track?.identity == snapshot.identity else { return }
                self?.lyrics = result
                switch result {
                case .synced, .plain:
                    self?.status = .showingLyrics
                case .instrumental:
                    self?.status = .instrumental
                case .notFound:
                    self?.status = .lyricsNotFound
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self?.track?.identity == snapshot.identity else { return }
                self?.lyrics = .notFound
                self?.status = .error(error.localizedDescription)
            }
        }
    }

    private func loadArtwork(for snapshot: TrackSnapshot) {
        let query = "\(snapshot.title) \(snapshot.artist)"
        let primaryCountry = searchCountry
        artworkTask = Task { [weak self, searchService] in
            let retryDelays: [Duration] = [
                .zero,
                .milliseconds(600),
                .milliseconds(1_500),
                .seconds(3),
                .seconds(6),
                .seconds(10)
            ]

            do {
                // Phase 1: Try to read embedded artwork from Music.app
                for delay in retryDelays {
                    if delay > .zero {
                        try await Task.sleep(for: delay)
                    }
                    try Task.checkCancellation()

                    let image = try await MainActor.run { [weak self] in
                        try self?.reader.currentArtwork(for: snapshot)
                    }
                    if let image {
                        await MainActor.run {
                            guard self?.track?.identity == snapshot.identity else { return }
                            self?.artwork = image
                        }
                        return
                    }
                }

                // Phase 2: iTunes Search API fallback with multi-region retry
                let countries = Self.searchCountries(for: snapshot, primary: primaryCountry)
                for country in countries {
                    try Task.checkCancellation()
                    let results = try await searchService.search(
                        term: query,
                        country: country,
                        limit: 5
                    )
                    guard
                        !Task.isCancelled,
                        let artworkURL = Self.matchingArtworkURL(in: results, for: snapshot)
                    else { continue }

                    let resolvedURL = Self.upgradeArtworkURL(artworkURL)
                    let (data, _) = try await URLSession.shared.data(from: resolvedURL)
                    try Task.checkCancellation()

                    await MainActor.run {
                        guard
                            self?.track?.identity == snapshot.identity,
                            self?.artwork == nil,
                            let image = NSImage(data: data)
                        else { return }
                        self?.artwork = image
                    }
                    return
                }
            } catch {
                return
            }
        }
    }

    private nonisolated static func matchingArtworkURL(
        in results: [StoreSearchResult],
        for snapshot: TrackSnapshot
    ) -> URL? {
        let trackTitle = normalizeForMatching(snapshot.title)
        let trackArtist = normalizeForMatching(snapshot.artist)
        let trackAlbum = normalizeForMatching(snapshot.album)

        // Pass 1: strict match (title exact + artist contains + album exact)
        if let url = results.first(where: { result in
            let resultTitle = normalizeForMatching(result.title)
            let resultArtist = normalizeForMatching(result.artist)
            let resultAlbum = normalizeForMatching(result.album)

            let titleMatches = resultTitle == trackTitle
            let artistMatches = resultArtist.contains(trackArtist)
                || trackArtist.contains(resultArtist)
            let albumMatches = trackAlbum.isEmpty
                || resultAlbum.isEmpty
                || resultAlbum == trackAlbum

            return titleMatches && artistMatches && albumMatches
        })?.artworkURL {
            return url
        }

        // Pass 2: relaxed match (stripped title + artist contains)
        let strippedTrackTitle = stripTitleSuffixes(trackTitle)
        if let url = results.first(where: { result in
            let strippedResultTitle = stripTitleSuffixes(normalizeForMatching(result.title))
            let resultArtist = normalizeForMatching(result.artist)

            let titleMatches = !strippedTrackTitle.isEmpty
                && (strippedResultTitle == strippedTrackTitle
                    || strippedResultTitle.contains(strippedTrackTitle)
                    || strippedTrackTitle.contains(strippedResultTitle))
            let artistMatches = resultArtist.contains(trackArtist)
                || trackArtist.contains(resultArtist)

            return titleMatches && artistMatches
        })?.artworkURL {
            return url
        }

        // Pass 3: first result with any artwork URL
        return results.first { $0.artworkURL != nil }?.artworkURL
    }

    private nonisolated static func normalizeForMatching(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression)
    }

    /// Remove common suffixes like "remastered", "deluxe", "bonus track" etc.
    private nonisolated static func stripTitleSuffixes(_ value: String) -> String {
        var result = value
        let suffixes = [
            "remastered", "remaster", "deluxe", "bonus", "live",
            "acoustic", "version", "edit", "radio", "single",
            "explicit", "clean"
        ]
        for suffix in suffixes {
            if result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Upgrade artwork URL to higher resolution (600x600).
    private nonisolated static func upgradeArtworkURL(_ url: URL) -> URL {
        var path = url.absoluteString
        // Check "100x100bb" first since "100x100" is a substring of it
        if path.contains("/100x100bb") {
            path = path.replacingOccurrences(of: "/100x100bb", with: "/600x600bb")
            return URL(string: path) ?? url
        }
        if path.contains("/100x100") {
            path = path.replacingOccurrences(of: "/100x100", with: "/600x600")
            return URL(string: path) ?? url
        }
        return url
    }

    /// Determine the list of countries to search, primary first.
    private nonisolated static func searchCountries(
        for snapshot: TrackSnapshot,
        primary: String
    ) -> [String] {
        var countries: [String] = [primary]
        // Always add US as fallback (largest catalog)
        if primary != "US" {
            countries.append("US")
        }
        // For CJK artists, also try JP and KR
        let artist = snapshot.artist
        let isCJK = artist.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)    // CJK
                || (0x3040...0x30FF).contains(scalar.value) // Japanese
                || (0xAC00...0xD7AF).contains(scalar.value) // Korean
        }
        if isCJK {
            let extra = ["JP", "KR", "TW"]
            for c in extra where c != primary {
                countries.append(c)
            }
        }
        // Deduplicate preserving order
        var seen = Set<String>()
        return countries.filter { seen.insert($0).inserted }
    }

    private func scheduleSearch(for rawQuery: String) {
        searchTask?.cancel()

        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            searchStatus = .idle
            return
        }

        let cacheKey = SearchCacheKey(query: query, country: searchCountry)
        if let cached = searchCache[cacheKey] {
            searchResults = cached
            searchStatus = cached.isEmpty ? .empty : .results
            return
        }

        searchResults = []
        searchStatus = .loading
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: searchDebounce)
                try Task.checkCancellation()
                let results = try await searchService.search(
                    term: query,
                    country: searchCountry,
                    limit: 6
                )
                try Task.checkCancellation()
                guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }
                searchCache[cacheKey] = results
                searchResults = results
                searchStatus = results.isEmpty ? .empty : .results
            } catch is CancellationError {
                return
            } catch {
                guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }
                searchResults = []
                searchStatus = .failure(error.localizedDescription)
            }
        }
    }
}

private struct SearchCacheKey: Hashable {
    let query: String
    let country: String

    init(query: String, country: String) {
        self.query = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        self.country = country
    }
}
