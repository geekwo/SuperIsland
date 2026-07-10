import Foundation

enum LyricsProviderError: Error {
    case invalidURL
    case badResponse
    case noLyrics
}

protocol LyricsProvider: Sendable {
    var id: String { get }
    var displayName: String { get }

    func searchLyrics(
        title: String,
        artist: String?,
        duration: TimeInterval?
    ) async throws -> [LyricLine]
}

struct LRCLIBLyricsProvider: LyricsProvider {
    let id = "lrclib"
    let displayName = "LRCLIB"

    private let baseURL = URL(string: "https://lrclib.net/api/search")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func searchLyrics(
        title: String,
        artist: String?,
        duration: TimeInterval?
    ) async throws -> [LyricLine] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems(title: title, artist: artist, duration: duration)

        guard let url = components?.url else {
            throw LyricsProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("SuperIsland", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LyricsProviderError.badResponse
        }

        let results = try JSONDecoder().decode([LRCLIBSearchResult].self, from: data)
        guard let bestResult = bestResult(from: results, title: title, artist: artist, duration: duration) else {
            throw LyricsProviderError.noLyrics
        }

        if let syncedLyrics = bestResult.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !syncedLyrics.isEmpty {
            let lines = LRCParser.parse(syncedLyrics)
            if !lines.isEmpty { return lines }
        }

        if let plainLyrics = bestResult.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plainLyrics.isEmpty {
            return [LyricLine(time: 0, text: plainLyrics)]
        }

        throw LyricsProviderError.noLyrics
    }

    private func queryItems(title: String, artist: String?, duration: TimeInterval?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "track_name", value: title)]

        if let artist, !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "artist_name", value: artist))
        }

        if let duration, duration > 0 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }

        return items
    }

    private func bestResult(
        from results: [LRCLIBSearchResult],
        title: String,
        artist: String?,
        duration: TimeInterval?
    ) -> LRCLIBSearchResult? {
        results
            .filter { ($0.syncedLyrics?.isEmpty == false) || ($0.plainLyrics?.isEmpty == false) }
            .max {
                score($0, title: title, artist: artist, duration: duration) <
                score($1, title: title, artist: artist, duration: duration)
            }
    }

    private func score(
        _ result: LRCLIBSearchResult,
        title: String,
        artist: String?,
        duration: TimeInterval?
    ) -> Double {
        var score = 0.0

        if normalized(result.trackName) == normalized(title) {
            score += 4
        } else if normalized(result.trackName).contains(normalized(title)) {
            score += 1
        }

        if let artist, !artist.isEmpty {
            let normalizedArtist = normalized(artist)
            let resultArtist = normalized(result.artistName)
            if resultArtist == normalizedArtist {
                score += 3
            } else if resultArtist.contains(normalizedArtist) || normalizedArtist.contains(resultArtist) {
                score += 1
            }
        }

        if let duration, duration > 0, result.duration > 0 {
            let delta = abs(result.duration - duration)
            if delta <= 2 {
                score += 2
            } else if delta <= 5 {
                score += 1
            }
        }

        if result.syncedLyrics?.isEmpty == false {
            score += 2
        }

        return score
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct LRCLIBSearchResult: Decodable {
    let trackName: String
    let artistName: String
    let duration: TimeInterval
    let syncedLyrics: String?
    let plainLyrics: String?

    private enum CodingKeys: String, CodingKey {
        case trackName
        case artistName
        case duration
        case syncedLyrics
        case plainLyrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackName = try container.decode(String.self, forKey: .trackName)
        artistName = try container.decode(String.self, forKey: .artistName)
        syncedLyrics = try container.decodeIfPresent(String.self, forKey: .syncedLyrics)
        plainLyrics = try container.decodeIfPresent(String.self, forKey: .plainLyrics)

        if let doubleDuration = try? container.decode(Double.self, forKey: .duration) {
            duration = doubleDuration
        } else if let intDuration = try? container.decode(Int.self, forKey: .duration) {
            duration = TimeInterval(intDuration)
        } else {
            duration = 0
        }
    }
}

struct NeteaseLyricsProvider: LyricsProvider {
    let id = "netease"
    let displayName = "Netease Cloud Music"

    func searchLyrics(
        title: String,
        artist: String?,
        duration: TimeInterval?
    ) async throws -> [LyricLine] {
        throw LyricsProviderError.noLyrics
    }
}
