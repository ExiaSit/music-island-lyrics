import Foundation
import Testing
@testable import MusicIslandLyrics

struct LyricsServiceTests {
    @Test func fallsBackToLrcApiWhenLrclibHasNoMatch() async throws {
        let loader = StubLyricsLoader { request in
            let url = try #require(request.url)
            if url.host == "lrclib.net", url.path == "/api/get" {
                return (Data(), httpResponse(url: url, statusCode: 404))
            }
            if url.host == "lrclib.net", url.path == "/api/search" {
                return (Data("[]".utf8), httpResponse(url: url))
            }

            #expect(url.host == "api.lrc.cx")
            #expect(url.path == "/lyrics")
            let query = url.queryItems
            #expect(query["title"] == "我们的歌")
            #expect(query["artist"] == "王力宏")
            #expect(query["album"] == "改变自己")

            let lrc = """
            [00:14.66]已经听了一百遍
            [01:09.55]情人总分分合合
            """
            return (Data(lrc.utf8), httpResponse(url: url))
        }

        let service = LyricsService(loader: loader)
        let result = try await service.fetch(for: TrackSnapshot(
            title: "我们的歌",
            artist: "王力宏",
            album: "改变自己",
            duration: 245,
            position: 0,
            isPlaying: true,
            capturedAt: Date()
        ))

        guard case .synced(let lines) = result else {
            Issue.record("Expected synced lyrics")
            return
        }
        #expect(lines == [
            LyricLine(time: 14.66, text: "已经听了一百遍"),
            LyricLine(time: 69.55, text: "情人总分分合合")
        ])
    }

    @Test func ignoresLrcApiErrorPayloads() async throws {
        let loader = StubLyricsLoader { request in
            let url = try #require(request.url)
            if url.host == "lrclib.net", url.path == "/api/get" {
                return (Data(), httpResponse(url: url, statusCode: 404))
            }
            if url.host == "lrclib.net", url.path == "/api/search" {
                return (Data("[]".utf8), httpResponse(url: url))
            }
            return (Data(#"{"detail":"Not Found"}"#.utf8), httpResponse(url: url))
        }

        let service = LyricsService(loader: loader)
        let result = try await service.fetch(for: TrackSnapshot(
            title: "Missing",
            artist: "Nobody",
            album: "",
            duration: 0,
            position: 0,
            isPlaying: true,
            capturedAt: Date()
        ))

        #expect(result == .notFound)
    }

    @Test func ignoresLrcApiNetworkFailuresWhenLrclibHasNoMatch() async throws {
        let loader = StubLyricsLoader { request in
            let url = try #require(request.url)
            if url.host == "lrclib.net", url.path == "/api/get" {
                return (Data(), httpResponse(url: url, statusCode: 404))
            }
            if url.host == "lrclib.net", url.path == "/api/search" {
                return (Data("[]".utf8), httpResponse(url: url))
            }
            throw URLError(.secureConnectionFailed)
        }

        let service = LyricsService(loader: loader)
        let result = try await service.fetch(for: TrackSnapshot(
            title: "Missing",
            artist: "Nobody",
            album: "",
            duration: 0,
            position: 0,
            isPlaying: true,
            capturedAt: Date()
        ))

        #expect(result == .notFound)
    }

    @Test func reportsLrclibFailureWhenBothSourcesFail() async throws {
        let loader = StubLyricsLoader { request in
            let url = try #require(request.url)
            if url.host == "lrclib.net" {
                throw LyricsServiceError.server(503)
            }
            throw URLError(.secureConnectionFailed)
        }

        let service = LyricsService(loader: loader)
        await #expect(throws: LyricsServiceError.server(503)) {
            try await service.fetch(for: TrackSnapshot(
                title: "Song",
                artist: "Artist",
                album: "",
                duration: 0,
                position: 0,
                isPlaying: true,
                capturedAt: Date()
            ))
        }
    }

    @Test func keepsLrclibExactMatchFirst() async throws {
        let loader = StubLyricsLoader { request in
            let url = try #require(request.url)
            #expect(url.host == "lrclib.net")
            let body = """
            {
              "trackName": "Song",
              "artistName": "Artist",
              "duration": 120,
              "instrumental": false,
              "plainLyrics": null,
              "syncedLyrics": "[00:01.00]From LRCLIB"
            }
            """
            return (Data(body.utf8), httpResponse(url: url))
        }

        let service = LyricsService(loader: loader)
        let result = try await service.fetch(for: TrackSnapshot(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 120,
            position: 0,
            isPlaying: true,
            capturedAt: Date()
        ))

        #expect(result == .synced([LyricLine(time: 1, text: "From LRCLIB")]))
    }

    @Test func rejectsWrongExactMatchAndUsesPrimaryTitleMatch() async throws {
        let loader = StubLyricsLoader { request in
            let url = try #require(request.url)
            if url.host == "lrclib.net", url.path == "/api/get" {
                let wrongBody = """
                {
                  "trackName": "婚礼的祝福",
                  "artistName": "陈奕迅",
                  "duration": 260,
                  "instrumental": false,
                  "plainLyrics": null,
                  "syncedLyrics": "[00:01.00]Wrong song"
                }
                """
                return (Data(wrongBody.utf8), httpResponse(url: url))
            }
            if url.host == "lrclib.net", url.path == "/api/search" {
                let searchBody = """
                [
                  {
                    "trackName": "婚礼的祝福",
                    "artistName": "陈奕迅",
                    "duration": 260,
                    "instrumental": false,
                    "plainLyrics": null,
                    "syncedLyrics": "[00:01.00]Wrong song"
                  },
                  {
                    "trackName": "贵得可以",
                    "artistName": "苏慧伦",
                    "duration": 210,
                    "instrumental": false,
                    "plainLyrics": null,
                    "syncedLyrics": "[00:02.00]Right song"
                  }
                ]
                """
                return (Data(searchBody.utf8), httpResponse(url: url))
            }
            return (Data(#"{"detail":"Not Found"}"#.utf8), httpResponse(url: url))
        }

        let service = LyricsService(loader: loader)
        let result = try await service.fetch(for: TrackSnapshot(
            title: "贵得可以（影集《欠妳的那场婚礼》插曲）",
            artist: "苏慧伦",
            album: "",
            duration: 210,
            position: 0,
            isPlaying: true,
            capturedAt: Date()
        ))

        #expect(result == .synced([LyricLine(time: 2, text: "Right song")]))
    }

    @Test func sendsPrimaryTitleToLrcApiFallback() async throws {
        let loader = StubLyricsLoader { request in
            let url = try #require(request.url)
            if url.host == "lrclib.net", url.path == "/api/get" {
                return (Data(), httpResponse(url: url, statusCode: 404))
            }
            if url.host == "lrclib.net", url.path == "/api/search" {
                return (Data("[]".utf8), httpResponse(url: url))
            }

            #expect(url.host == "api.lrc.cx")
            let query = url.queryItems
            #expect(query["title"] == "贵得可以")
            #expect(query["artist"] == "苏慧伦")
            #expect(query["title"]?.contains("婚礼") == false)
            return (Data("[00:02.00]Right fallback".utf8), httpResponse(url: url))
        }

        let service = LyricsService(loader: loader)
        let result = try await service.fetch(for: TrackSnapshot(
            title: "贵得可以（影集《欠妳的那场婚礼》插曲）",
            artist: "苏慧伦",
            album: "",
            duration: 210,
            position: 0,
            isPlaying: true,
            capturedAt: Date()
        ))

        #expect(result == .synced([LyricLine(time: 2, text: "Right fallback")]))
    }
}

private struct StubLyricsLoader: LyricsDataLoading {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    func loadData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

private func httpResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}

private extension URL {
    var queryItems: [String: String] {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [:]) { result, item in
                result[item.name] = item.value
            } ?? [:]
    }
}
