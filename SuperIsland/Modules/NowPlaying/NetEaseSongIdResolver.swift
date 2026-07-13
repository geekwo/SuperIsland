import Foundation

struct NetEaseSongIdMatch: Sendable {
    let songID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval?
}

struct NetEaseSongIdResolver: Sendable {
    private let cacheDirectory: URL
    private let databaseURL: URL
    private let lookbackInterval: TimeInterval

    init(
        cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.netease.163music/Data/Library/Caches/online_play_cache"),
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.netease.163music/Data/Documents/storage/sqlite_storage.sqlite3"),
        lookbackInterval: TimeInterval = 30 * 60
    ) {
        self.cacheDirectory = cacheDirectory
        self.databaseURL = databaseURL
        self.lookbackInterval = lookbackInterval
    }

    func resolveSongID(title: String, artist: String?, duration: TimeInterval?) -> NetEaseSongIdMatch? {
        let candidates = recentSongIDCandidates()
        guard !candidates.isEmpty else { return nil }

        let scoredMatches = candidates.compactMap { candidate -> ScoredSongIDMatch? in
            guard let metadata = metadata(for: candidate.songID) else { return nil }
            let score = score(
                metadata: metadata,
                requestedTitle: title,
                requestedArtist: artist,
                requestedDuration: duration
            )
            return ScoredSongIDMatch(match: metadata, score: score, modifiedAt: candidate.modifiedAt)
        }

        let bestMatch = scoredMatches
            .filter { $0.score.isConfident || (candidates.count == 1 && $0.score.isLooseMatch) }
            .sorted {
                if $0.score.value == $1.score.value {
                    return $0.modifiedAt > $1.modifiedAt
                }
                return $0.score.value > $1.score.value
            }
            .first

        if let bestMatch {
            return bestMatch.match
        }

        #if DEBUG
        logNoConfidentMatch(scoredMatches)
        #endif

        return nil
    }

    private func recentSongIDCandidates() -> [SongIDCandidate] {
        let cutoff = Date().addingTimeInterval(-lookbackInterval)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { url -> SongIDCandidate? in
            guard url.pathExtension == "info" else { return nil }
            guard let songID = Self.songID(from: url.lastPathComponent) else { return nil }

            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= cutoff else {
                return nil
            }

            return SongIDCandidate(songID: songID, modifiedAt: modifiedAt)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func songID(from fileName: String) -> String? {
        let parts = fileName.components(separatedBy: "-_-_")
        guard parts.count >= 3,
              parts[0].allSatisfy(\.isNumber),
              parts[2].hasSuffix(".info") else {
            return nil
        }

        return parts[0]
    }

    private func metadata(for songID: String) -> NetEaseSongIdMatch? {
        guard databaseURL.isFileURL,
              FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        if let json = queryJSON(table: "dbTrack", songID: songID),
           let metadata = parseMetadata(songID: songID, json: json) {
            return metadata
        }

        if let json = queryJSON(table: "historyTracks", songID: songID),
           let metadata = parseMetadata(songID: songID, json: json) {
            return metadata
        }

        if let json = queryJSON(table: "offlineTrack", songID: songID),
           let metadata = parseMetadata(songID: songID, json: json) {
            return metadata
        }

        return nil
    }

    private func queryJSON(table: String, songID: String) -> String? {
        let column = table == "dbTrack" ? "jsonStr" : "jsonStr"
        let sql = "SELECT \(column) FROM \(table) WHERE id = '\(Self.sqlEscaped(songID))' LIMIT 1;"
        let output = runSQLite(arguments: ["-readonly", "-noheader", databaseURL.path, sql])
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func runSQLite(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func parseMetadata(songID: String, json: String) -> NetEaseSongIdMatch? {
        guard let data = json.data(using: .utf8) else { return nil }

        if let track = try? JSONDecoder().decode(NetEaseTrack.self, from: data) {
            return NetEaseSongIdMatch(
                songID: songID,
                title: track.name.trimmingCharacters(in: .whitespacesAndNewlines),
                artist: track.artists.map(\.name).joined(separator: ", "),
                album: track.album?.name ?? "",
                duration: track.duration.map { TimeInterval($0) / 1000 }
            )
        }

        if let history = try? JSONDecoder().decode(NetEaseHistoryTrack.self, from: data) {
            return NetEaseSongIdMatch(
                songID: songID,
                title: history.name.trimmingCharacters(in: .whitespacesAndNewlines),
                artist: history.artists.map(\.name).joined(separator: ", "),
                album: history.album?.name ?? "",
                duration: history.duration.map { TimeInterval($0) / 1000 }
            )
        }

        return nil
    }

    private func score(
        metadata: NetEaseSongIdMatch,
        requestedTitle: String,
        requestedArtist: String?,
        requestedDuration: TimeInterval?
    ) -> SongIDMatchScore {
        let titleScore = titleScore(metadata.title, requestedTitle)
        let artistScore = artistScore(metadata.artist, requestedArtist)
        let durationScore = durationScore(metadata.duration, requestedDuration)
        let value = titleScore + artistScore + durationScore

        let titleMatched = titleScore >= 3
        let artistMatched = artistScore >= 2
        let durationMatched = durationScore >= 1
        let noRequestedArtist = requestedArtist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false

        return SongIDMatchScore(
            value: value,
            titleScore: titleScore,
            artistScore: artistScore,
            durationScore: durationScore,
            isConfident: titleMatched && (artistMatched || durationMatched || noRequestedArtist),
            isLooseMatch: titleMatched && (artistMatched || durationMatched || noRequestedArtist)
        )
    }

    private func titleScore(_ lhs: String, _ rhs: String) -> Int {
        let left = Self.normalized(lhs)
        let right = Self.normalized(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 5 }
        if left.contains(right) || right.contains(left) { return 3 }

        let looseLeft = Self.looseNormalizedTitle(lhs)
        let looseRight = Self.looseNormalizedTitle(rhs)
        guard !looseLeft.isEmpty, !looseRight.isEmpty else { return 0 }
        if looseLeft == looseRight { return 4 }
        if looseLeft.contains(looseRight) || looseRight.contains(looseLeft) { return 3 }

        return 0
    }

    private func artistScore(_ lhs: String, _ rhs: String?) -> Int {
        guard let rhs, !rhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }

        let leftTokens = Self.artistTokens(lhs)
        let rightTokens = Self.artistTokens(rhs)

        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return 0 }

        for left in leftTokens {
            for right in rightTokens where left == right {
                return 3
            }
        }

        for left in leftTokens {
            for right in rightTokens where left.contains(right) || right.contains(left) {
                return 2
            }
        }

        return 0
    }

    private func durationScore(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> Int {
        guard let lhs, let rhs, lhs > 0, rhs > 0 else { return 0 }
        let delta = abs(lhs - rhs)
        if delta <= 3 { return 3 }
        if delta <= 8 { return 2 }
        if delta <= 15 { return 1 }
        return 0
    }

    #if DEBUG
    private func logNoConfidentMatch(_ matches: [ScoredSongIDMatch]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        matches
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(8)
            .forEach { item in
                let duration = item.match.duration.map { String(format: "%.1f", $0) } ?? "nil"
                print(
                    "[Lyrics][NetEase][Resolver] candidate songId=\(item.match.songID) " +
                    "title=\(item.match.title) artist=\(item.match.artist) duration=\(duration) " +
                    "score=\(item.score.value) titleScore=\(item.score.titleScore) " +
                    "artistScore=\(item.score.artistScore) durationScore=\(item.score.durationScore) " +
                    "modifiedAt=\(formatter.string(from: item.modifiedAt))"
                )
            }
    }
    #endif

    private static func normalized(_ value: String) -> String {
        let folded = value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        let allowed = CharacterSet.letters.union(.decimalDigits)
        return String(folded.unicodeScalars.filter { allowed.contains($0) })
    }

    private static func looseNormalizedTitle(_ value: String) -> String {
        var title = value.replacingOccurrences(of: "\u{00a0}", with: " ")
        title = title.replacingOccurrences(
            of: #"\([^)]*\)|（[^）]*）|\[[^\]]*\]|【[^】]*】"#,
            with: " ",
            options: .regularExpression
        )

        let suffixes = [
            "sped up",
            "slowed",
            "explicit",
            "instrumental",
            "live",
            "remix",
            "edit",
            "version",
            "cover",
            "伴奏",
            "翻唱",
            "纯音乐"
        ]

        var changed = true
        while changed {
            changed = false
            title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_()（）[]【】")))
            let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            for suffix in suffixes where folded.hasSuffix(suffix) {
                title.removeLast(suffix.count)
                changed = true
                break
            }
        }

        return normalized(title)
    }

    private static func artistTokens(_ value: String) -> [String] {
        var text = value.replacingOccurrences(of: "\u{00a0}", with: " ")
        text = text.replacingOccurrences(of: "×", with: ",")
        text = text.replacingOccurrences(
            of: #"(?i)\b(feat\.?|ft\.?|x)\b"#,
            with: ",",
            options: .regularExpression
        )

        return text
            .components(separatedBy: CharacterSet(charactersIn: "/,&，、;；,"))
            .map { normalized($0) }
            .filter { !$0.isEmpty }
    }
}

private struct SongIDCandidate {
    let songID: String
    let modifiedAt: Date
}

private struct ScoredSongIDMatch {
    let match: NetEaseSongIdMatch
    let score: SongIDMatchScore
    let modifiedAt: Date
}

private struct SongIDMatchScore {
    let value: Int
    let titleScore: Int
    let artistScore: Int
    let durationScore: Int
    let isConfident: Bool
    let isLooseMatch: Bool
}

private struct NetEaseTrack: Decodable {
    let name: String
    let duration: Int?
    let artists: [NetEaseArtist]
    let album: NetEaseAlbum?
}

private struct NetEaseHistoryTrack: Decodable {
    let name: String
    let duration: Int?
    let artists: [NetEaseArtist]
    let album: NetEaseAlbum?
}

private struct NetEaseArtist: Decodable {
    let name: String
}

private struct NetEaseAlbum: Decodable {
    let name: String
}
