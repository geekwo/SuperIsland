import Combine
import Foundation

enum LyricsLoadState: Equatable {
    case idle
    case loading
    case loaded
    case noLyrics
    case unavailable(String)
}

struct LyricsWindow: Equatable {
    let previous: LyricLine?
    let current: LyricLine?
    let next: LyricLine?
}

@MainActor
final class LyricsManager: ObservableObject {
    static let shared = LyricsManager()

    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plainTextLines: [String] = []
    @Published private(set) var state: LyricsLoadState = .idle

    private let providers: [any LyricsProvider]
    private var cache: [LyricsCacheKey: LyricsCacheEntry] = [:]
    private var currentKey: LyricsCacheKey?
    private var lastExcludedSignature: String?
    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(providers: [any LyricsProvider] = [LRCLIBLyricsProvider(), NeteaseLyricsProvider()]) {
        self.providers = providers
        observeNowPlaying()
    }

    func currentLine(for elapsedTime: TimeInterval) -> LyricLine? {
        guard let index = currentLineIndex(for: elapsedTime) else { return nil }
        return lines[index]
    }

    func surroundingLines(for elapsedTime: TimeInterval) -> LyricsWindow {
        guard let index = currentLineIndex(for: elapsedTime) else {
            return LyricsWindow(previous: nil, current: nil, next: lines.first)
        }

        return LyricsWindow(
            previous: index > 0 ? lines[index - 1] : nil,
            current: lines[index],
            next: index + 1 < lines.count ? lines[index + 1] : nil
        )
    }

    func refreshCurrentTrack() {
        let nowPlaying = NowPlayingManager.shared
        updateTrack(
            title: nowPlaying.title,
            artist: nowPlaying.artist,
            duration: nowPlaying.duration,
            sourceEvaluation: nowPlaying.lyricsSourceEvaluation
        )
    }

    private func observeNowPlaying() {
        let nowPlaying = NowPlayingManager.shared

        nowPlaying.$title
            .combineLatest(nowPlaying.$artist)
            .combineLatest(nowPlaying.$duration)
            .combineLatest(nowPlaying.$sourceName)
            .debounce(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] combined, _ in
                guard let self else { return }
                let ((title, artist), duration) = combined
                self.updateTrack(
                    title: title,
                    artist: artist,
                    duration: duration,
                    sourceEvaluation: nowPlaying.lyricsSourceEvaluation
                )
            }
            .store(in: &cancellables)
    }

    private func updateTrack(
        title: String,
        artist: String,
        duration: TimeInterval,
        sourceEvaluation: LyricsSourceEvaluation
    ) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedTitle.isEmpty else {
            resetLyricsState(.idle)
            return
        }

        guard sourceEvaluation.isMusicSource else {
            let signature = "\(normalizedTitle)|\(normalizedArtist)|\(sourceEvaluation.sourceDescription)|\(sourceEvaluation.reason)"
            if lastExcludedSignature != signature {
                #if DEBUG
                print("[Lyrics] source excluded: \(sourceEvaluation.reason), source=\(sourceEvaluation.sourceDescription)")
                #endif
                lastExcludedSignature = signature
            }
            resetLyricsState(.idle)
            return
        }

        let key = LyricsCacheKey(
            title: normalizedTitle,
            artist: normalizedArtist,
            duration: duration
        )
        guard key != currentKey else { return }
        currentKey = key
        lastExcludedSignature = nil

        if let cached = cache[key] {
            apply(cached)
            return
        }

        loadTask?.cancel()
        lines = []
        plainTextLines = []
        state = .loading

        let providers = providers
        let requestedDuration = duration > 0 ? duration : nil

        #if DEBUG
        print("[Lyrics] request title=\(normalizedTitle), artist=\(normalizedArtist), source=\(sourceEvaluation.sourceDescription)")
        #endif

        loadTask = Task { [weak self] in
            let entry = await Self.fetchLyrics(
                providers: providers,
                title: normalizedTitle,
                artist: normalizedArtist.isEmpty ? nil : normalizedArtist,
                duration: requestedDuration
            )

            await MainActor.run {
                guard let self, self.currentKey == key else { return }
                self.cache[key] = entry
                self.apply(entry)
            }
        }
    }

    private static func fetchLyrics(
        providers: [any LyricsProvider],
        title: String,
        artist: String?,
        duration: TimeInterval?
    ) async -> LyricsCacheEntry {
        var lastError: Error?

        for provider in providers {
            guard !Task.isCancelled else {
                return .unavailable("Lyrics request cancelled.")
            }

            do {
                let lines = try await provider.searchLyrics(
                    title: title,
                    artist: artist,
                    duration: duration
                )
                if lines.isEmpty {
                    continue
                }
                return .loaded(lines)
            } catch LyricsProviderError.noLyrics {
                continue
            } catch {
                lastError = error
                continue
            }
        }

        if lastError != nil {
            return .unavailable("Lyrics unavailable.")
        }

        return .noLyrics
    }

    private func apply(_ entry: LyricsCacheEntry) {
        switch entry {
        case .loaded(let lines):
            let separated = Self.separateSyncedAndPlainLines(lines)
            self.lines = separated.synced
            plainTextLines = separated.plain
            state = .loaded
            #if DEBUG
            print("[Lyrics] loaded synced lines=\(separated.synced.count), plain lines=\(separated.plain.count)")
            #endif
        case .noLyrics:
            lines = []
            plainTextLines = []
            state = .noLyrics
            #if DEBUG
            print("[Lyrics] no lyrics")
            #endif
        case .unavailable(let message):
            lines = []
            plainTextLines = []
            state = .unavailable(message)
            #if DEBUG
            print("[Lyrics] no lyrics: \(message)")
            #endif
        }
    }

    private func resetLyricsState(_ nextState: LyricsLoadState) {
        loadTask?.cancel()
        currentKey = nil
        lines = []
        plainTextLines = []
        state = nextState
    }

    private static func separateSyncedAndPlainLines(_ lines: [LyricLine]) -> (synced: [LyricLine], plain: [String]) {
        guard lines.count == 1,
              lines[0].time == 0,
              lines[0].text.contains("\n") else {
            return (lines, [])
        }

        let plainLines = lines[0].text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return ([], plainLines)
    }

    private func currentLineIndex(for elapsedTime: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = lines.count

        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lines[middle].time <= elapsedTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        let index = lowerBound - 1
        return index >= 0 ? index : nil
    }
}

private struct LyricsCacheKey: Hashable {
    let title: String
    let artist: String
    let duration: Int?

    init(title: String, artist: String, duration: TimeInterval) {
        self.title = Self.normalize(title)
        self.artist = Self.normalize(artist)
        self.duration = duration > 0 ? Int(duration.rounded()) : nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum LyricsCacheEntry {
    case loaded([LyricLine])
    case noLyrics
    case unavailable(String)
}
