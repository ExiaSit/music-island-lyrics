import Foundation
import Testing
@testable import MusicIslandLyrics

struct StoreSearchServiceTests {
    @Test func buildsEncodedSongSearchAndDecodesResults() async throws {
        let data = Data(#"""
        {
          "resultCount": 3,
          "results": [
            {
              "kind": "song",
              "trackId": 101,
              "trackName": "晴天",
              "artistName": "周杰伦",
              "collectionName": "叶惠美",
              "artworkUrl100": "https://example.com/art.jpg",
              "trackViewUrl": "https://music.apple.com/cn/album/example?i=101"
            },
            {
              "kind": "song",
              "trackId": 101,
              "trackName": "晴天（重复）",
              "artistName": "周杰伦",
              "trackViewUrl": "https://music.apple.com/cn/album/example?i=101"
            },
            {
              "kind": "music-video",
              "trackId": 202,
              "trackName": "Video",
              "artistName": "Artist",
              "trackViewUrl": "https://example.com/video"
            }
          ]
        }
        """#.utf8)
        let loader = StubStoreSearchLoader(data: data)
        let service = StoreSearchService(loader: loader)

        let results = try await service.search(term: "晴 天", country: "cn", limit: 6)
        let requestedURL = try #require(await loader.lastRequestedURL())
        let queryItems = try #require(URLComponents(url: requestedURL, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

        #expect(query["term"] == "晴 天")
        #expect(query["country"] == "CN")
        #expect(query["media"] == "music")
        #expect(query["entity"] == "song")
        #expect(query["limit"] == "6")
        #expect(results.count == 1)
        #expect(results[0].title == "晴天")
        #expect(results[0].album == "叶惠美")
        #expect(results[0].artworkURL?.absoluteString == "https://example.com/art.jpg")
    }

    @Test func toleratesMissingOptionalAlbumAndArtwork() async throws {
        let data = Data(#"""
        {
          "results": [
            {
              "kind": "song",
              "trackId": 303,
              "trackName": "Song",
              "artistName": "Artist",
              "trackViewUrl": "https://example.com/song"
            }
          ]
        }
        """#.utf8)
        let service = StoreSearchService(loader: StubStoreSearchLoader(data: data))

        let results = try await service.search(term: "Song", country: "invalid", limit: 99)

        #expect(results.count == 1)
        #expect(results[0].album.isEmpty)
        #expect(results[0].artworkURL == nil)
        #expect(StoreSearchService.normalizedCountry("invalid") == "CN")
        #expect(StoreSearchService.searchURL(term: "Song", country: "invalid", limit: 99)?
            .absoluteString.contains("limit=6") == true)
    }

    @Test func reportsHTTPFailure() async throws {
        let loader = StubStoreSearchLoader(data: Data("{}".utf8), statusCode: 429)
        let service = StoreSearchService(loader: loader)

        await #expect(throws: StoreSearchError.server(429)) {
            try await service.search(term: "Song", country: "CN", limit: 6)
        }
    }
}

private actor StubStoreSearchLoader: StoreSearchDataLoading {
    private let data: Data
    private let statusCode: Int
    private var requestedURL: URL?

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }

    func loadData(from url: URL) async throws -> (Data, URLResponse) {
        requestedURL = url
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    func lastRequestedURL() -> URL? {
        requestedURL
    }
}
