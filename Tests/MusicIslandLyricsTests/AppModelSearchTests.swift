import Foundation
import Testing
@testable import MusicIslandLyrics

struct AppModelSearchTests {
    @Test @MainActor func debouncesCachesAndUpdatesPanelHeight() async throws {
        let result = searchResult(id: 1, title: "Result")
        let service = StubStoreSearching(results: ["query": [result]])
        let model = AppModel(
            searchService: service,
            searchDebounce: .milliseconds(10),
            regionCode: "us"
        )

        #expect(model.islandExtraHeight == 0)
        model.updateHovering(true)
        #expect(model.islandPresentation == .hover)
        #expect(model.islandExtraHeight == 40)

        model.openSearch()
        #expect(model.islandExtraHeight == 50)
        model.searchQuery = "query"
        #expect(model.searchStatus == .loading)
        #expect(model.islandExtraHeight == 92)

        try await Task.sleep(for: .milliseconds(80))
        #expect(model.searchStatus == .results)
        #expect(model.searchResults == [result])
        #expect(model.islandExtraHeight == 92)
        #expect(await service.callCount(for: "query") == 1)

        model.searchQuery = ""
        model.searchQuery = "query"
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.searchResults == [result])
        #expect(await service.callCount(for: "query") == 1)
    }

    @Test @MainActor func cancelsStaleSearchAndKeepsNewestResults() async throws {
        let slow = searchResult(id: 1, title: "Slow")
        let fast = searchResult(id: 2, title: "Fast")
        let service = StubStoreSearching(
            results: ["slow": [slow], "fast": [fast]],
            delays: ["slow": .milliseconds(150)]
        )
        let model = AppModel(
            searchService: service,
            searchDebounce: .milliseconds(5),
            regionCode: "CN"
        )

        model.openSearch()
        model.searchQuery = "slow"
        try await Task.sleep(for: .milliseconds(20))
        model.searchQuery = "fast"
        try await Task.sleep(for: .milliseconds(80))

        #expect(model.searchStatus == .results)
        #expect(model.searchResults == [fast])
    }

    private func searchResult(id: Int64, title: String) -> StoreSearchResult {
        StoreSearchResult(
            id: id,
            title: title,
            artist: "Artist",
            album: "Album",
            artworkURL: nil,
            storeURL: URL(string: "https://example.com/\(id)")!
        )
    }
}

private actor StubStoreSearching: StoreSearching {
    private let results: [String: [StoreSearchResult]]
    private let delays: [String: Duration]
    private var calls: [String: Int] = [:]

    init(
        results: [String: [StoreSearchResult]],
        delays: [String: Duration] = [:]
    ) {
        self.results = results
        self.delays = delays
    }

    func search(term: String, country: String, limit: Int) async throws -> [StoreSearchResult] {
        calls[term, default: 0] += 1
        if let delay = delays[term] {
            try await Task.sleep(for: delay)
        }
        return Array((results[term] ?? []).prefix(limit))
    }

    func callCount(for term: String) -> Int {
        calls[term, default: 0]
    }
}
