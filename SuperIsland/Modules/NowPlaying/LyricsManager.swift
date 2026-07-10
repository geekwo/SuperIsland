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
    @Published private(set) var state: LyricsLoadState = .idle

    private let providers: [any LyricsProvider]
    private var cache: [LyricsCacheKey: LyricsCacheEntry] = [:]
    private var currentKey: LyricsCacheKey?
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
            duration: nowPlaying.duration
        )
    }

    private func observeNowPlaying() {
        let nowPlaying = NowPlayingManager.shared

        nowPlaying.$title
            .combineLatest(nowPlaying.$artist)
            .debounce(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] title, artist in
                guard let self else { return }
                self.updateTrack(
                    title: title,
                    artist: artist,
                    duration: nowPlaying.duration
                )
            }
            .store(in: &cancellables)
    }

    private func updateTrack(title: String, artist: String, duration: TimeInterval) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedTitle.isEmpty else {
            loadTask?.cancel()
            currentKey = nil
            lines = []
            state = .idle
            return
        }

        let key = LyricsCacheKey(title: normalizedTitle, artist: normalizedArtist)
        guard key != currentKey else { return }
        currentKey = key

        if let cached = cache[key] {
            apply(cached)
            return
        }

        loadTask?.cancel()
        lines = []
        state = .loading

        let providers = providers
        let requestedDuration = duration > 0 ? duration : nil

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
            self.lines = lines
            state = .loaded
        case .noLyrics:
            lines = []
            state = .noLyrics
        case .unavailable(let message):
            lines = []
            state = .unavailable(message)
        }
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

    init(title: String, artist: String) {
        self.title = Self.normalize(title)
        self.artist = Self.normalize(artist)
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
