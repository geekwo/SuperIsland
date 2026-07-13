import Foundation

struct NetEaseLyricsProvider: LyricsProvider {
    let id = "netease"
    let displayName = "NetEase Cloud Music"

    private let resolver: NetEaseSongIdResolver
    private let session: URLSession

    init(
        resolver: NetEaseSongIdResolver = NetEaseSongIdResolver(),
        session: URLSession = .shared
    ) {
        self.resolver = resolver
        self.session = session
    }

    func searchLyrics(
        title: String,
        artist: String?,
        duration: TimeInterval?
    ) async throws -> [LyricLine] {
        guard let match = resolver.resolveSongID(title: title, artist: artist, duration: duration) else {
            #if DEBUG
            print("[Lyrics][NetEase] no confident songId match, fallback to LRCLIB")
            #endif
            throw LyricsProviderError.noLyrics
        }

        #if DEBUG
        print("[Lyrics][NetEase] resolved songId=\(match.songID) title=\(match.title)")
        #endif

        for endpoint in Self.endpoints(songID: match.songID) {
            guard !Task.isCancelled else { throw LyricsProviderError.noLyrics }

            do {
                let response = try await lyricsResponse(endpoint: endpoint)
                if let lines = syncedLines(from: response, endpoint: endpoint, duration: duration) {
                    return lines
                }
            } catch {
                #if DEBUG
                print("[Lyrics][NetEase] endpoint failed endpoint=\(endpoint.name)")
                #endif
                continue
            }
        }

        #if DEBUG
        print("[Lyrics][NetEase] no usable synced lyrics, fallback to LRCLIB")
        #endif

        throw LyricsProviderError.noLyrics
    }

    private func lyricsResponse(endpoint: NetEaseLyricsEndpoint) async throws -> NetEaseLyricsResponse {
        guard let url = endpoint.url else {
            throw LyricsProviderError.invalidURL
        }

        #if DEBUG
        print("[Lyrics][NetEase] request endpoint=\(endpoint.name) songId=\(endpoint.songID)")
        #endif

        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LyricsProviderError.badResponse
        }

        return try JSONDecoder().decode(NetEaseLyricsResponse.self, from: data)
    }

    private func syncedLines(
        from response: NetEaseLyricsResponse,
        endpoint: NetEaseLyricsEndpoint,
        duration: TimeInterval?
    ) -> [LyricLine]? {
        #if DEBUG
        print(
            "[Lyrics][NetEase] response endpoint=\(endpoint.name) " +
            "lrcChars=\(response.lrc?.lyric?.count ?? 0) " +
            "yrcChars=\(response.yrc?.lyric?.count ?? 0) " +
            "klyricChars=\(response.klyric?.lyric?.count ?? 0)"
        )
        #endif

        if let lrc = response.lrc?.lyric?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lrc.isEmpty {
            let lines = LRCParser.parse(lrc)
            let usable = isUsableSyncedLyrics(lines, duration: duration)

            #if DEBUG
            print("[Lyrics][NetEase] parsed lrc lines=\(lines.count) usable=\(usable)")
            #endif

            if usable {
                #if DEBUG
                print("[Lyrics][NetEase] loaded synced lines=\(lines.count) source=lrc endpoint=\(endpoint.name)")
                #endif
                return lines
            } else if !lines.isEmpty {
                #if DEBUG
                print("[Lyrics][NetEase] ignored incomplete lyrics lines=\(lines.count)")
                #endif
            }
        }

        if let yrc = response.yrc?.lyric?.trimmingCharacters(in: .whitespacesAndNewlines),
           !yrc.isEmpty {
            let lines = YRCParser.parse(yrc)
            let usable = isUsableSyncedLyrics(lines, duration: duration)

            #if DEBUG
            print("[Lyrics][NetEase] parsed yrc lines=\(lines.count) usable=\(usable)")
            #endif

            if usable {
                #if DEBUG
                print("[Lyrics][NetEase] loaded synced lines=\(lines.count) source=yrc endpoint=\(endpoint.name)")
                #endif
                return lines
            } else if !lines.isEmpty {
                #if DEBUG
                print("[Lyrics][NetEase] ignored incomplete lyrics lines=\(lines.count)")
                #endif
            }
        }

        return nil
    }

    private func isUsableSyncedLyrics(_ lines: [LyricLine], duration: TimeInterval?) -> Bool {
        guard !lines.isEmpty else { return false }

        let duration = duration ?? 0
        if duration > 90, lines.count < 4 {
            return false
        }

        if duration > 120, let lastLineTime = lines.last?.time, lastLineTime < 30, lines.count < 8 {
            return false
        }

        let uniqueTexts = Set(lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        if duration > 90, uniqueTexts.count < 3 {
            return false
        }

        return true
    }

    private static func endpoints(songID: String) -> [NetEaseLyricsEndpoint] {
        [
            NetEaseLyricsEndpoint(
                name: "lyric/v1",
                songID: songID,
                path: "/api/song/lyric/v1",
                queryItems: [
                    URLQueryItem(name: "id", value: songID),
                    URLQueryItem(name: "cp", value: "false"),
                    URLQueryItem(name: "tv", value: "0"),
                    URLQueryItem(name: "lv", value: "0"),
                    URLQueryItem(name: "rv", value: "0"),
                    URLQueryItem(name: "kv", value: "0"),
                    URLQueryItem(name: "yv", value: "0"),
                    URLQueryItem(name: "ytv", value: "0"),
                    URLQueryItem(name: "yrv", value: "0")
                ]
            ),
            NetEaseLyricsEndpoint(
                name: "song/lyric-pc",
                songID: songID,
                path: "/api/song/lyric",
                queryItems: [
                    URLQueryItem(name: "os", value: "pc"),
                    URLQueryItem(name: "id", value: songID),
                    URLQueryItem(name: "lv", value: "-1"),
                    URLQueryItem(name: "kv", value: "-1"),
                    URLQueryItem(name: "tv", value: "-1")
                ]
            ),
            NetEaseLyricsEndpoint(
                name: "song/lyric-legacy",
                songID: songID,
                path: "/api/song/lyric",
                queryItems: [
                    URLQueryItem(name: "id", value: songID),
                    URLQueryItem(name: "lv", value: "1"),
                    URLQueryItem(name: "kv", value: "1"),
                    URLQueryItem(name: "tv", value: "-1")
                ]
            )
        ]
    }
}

private struct NetEaseLyricsEndpoint {
    let name: String
    let songID: String
    let path: String
    let queryItems: [URLQueryItem]

    var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "music.163.com"
        components.path = path
        components.queryItems = queryItems
        return components.url
    }
}

private struct NetEaseLyricsResponse: Decodable {
    let lrc: NetEaseLyricPayload?
    let klyric: NetEaseLyricPayload?
    let tlyric: NetEaseLyricPayload?
    let yrc: NetEaseLyricPayload?
    let romalrc: NetEaseLyricPayload?
}

private struct NetEaseLyricPayload: Decodable {
    let lyric: String?
}
