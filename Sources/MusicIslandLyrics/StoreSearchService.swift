import Foundation

protocol StoreSearchDataLoading: Sendable {
    func loadData(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: StoreSearchDataLoading {
    func loadData(from url: URL) async throws -> (Data, URLResponse) {
        try await data(from: url)
    }
}

protocol StoreSearching: Sendable {
    func search(term: String, country: String, limit: Int) async throws -> [StoreSearchResult]
}

enum StoreSearchError: LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "无法创建搜索请求。"
        case .invalidResponse:
            return "音乐商店返回了无法识别的数据。"
        case .server(let statusCode):
            return "音乐商店暂时不可用（HTTP \(statusCode)）。"
        }
    }
}

struct StoreSearchService: StoreSearching, Sendable {
    private let loader: any StoreSearchDataLoading

    init(loader: any StoreSearchDataLoading = URLSession.shared) {
        self.loader = loader
    }

    func search(term: String, country: String, limit: Int = 6) async throws -> [StoreSearchResult] {
        let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTerm.isEmpty else { return [] }

        let resultLimit = min(max(limit, 1), 6)
        guard let url = Self.searchURL(
            term: normalizedTerm,
            country: country,
            limit: resultLimit
        ) else {
            throw StoreSearchError.invalidRequest
        }

        let (data, rawResponse) = try await loader.loadData(from: url)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw StoreSearchError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw StoreSearchError.server(response.statusCode)
        }

        let payload: SearchResponse
        do {
            payload = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw StoreSearchError.invalidResponse
        }

        var seenIDs = Set<Int64>()
        return payload.results.compactMap { item in
            guard
                item.kind == "song",
                let id = item.trackId,
                let title = item.trackName?.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty,
                let artist = item.artistName?.trimmingCharacters(in: .whitespacesAndNewlines),
                !artist.isEmpty,
                let storeURL = item.trackViewUrl,
                seenIDs.insert(id).inserted
            else {
                return nil
            }

            return StoreSearchResult(
                id: id,
                title: title,
                artist: artist,
                album: item.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                artworkURL: item.artworkUrl100,
                storeURL: storeURL
            )
        }
        .prefix(resultLimit)
        .map { $0 }
    }

    static func searchURL(term: String, country: String, limit: Int) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: normalizedCountry(country)),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 6)))
        ]
        return components?.url
    }

    static func normalizedCountry(_ country: String) -> String {
        let normalized = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 2, normalized.allSatisfy(\.isLetter) else { return "CN" }
        return normalized
    }
}

private struct SearchResponse: Decodable {
    let results: [SearchItem]
}

private struct SearchItem: Decodable {
    let kind: String?
    let trackId: Int64?
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let artworkUrl100: URL?
    let trackViewUrl: URL?
}
