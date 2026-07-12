import SwiftUI

struct LyricsScrollerView: View {
    let lines: [LyricLine]
    let currentTime: TimeInterval
    let isMusicSource: Bool
    let plainTextLines: [String]
    let state: LyricsLoadState

    private var currentIndex: Int? {
        guard !lines.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = lines.count

        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lines[middle].time <= currentTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        let index = lowerBound - 1
        return index >= 0 ? index : nil
    }

    var body: some View {
        Group {
            if isMusicSource, !lines.isEmpty {
                syncedLyricsView
            } else if isMusicSource, !plainTextLines.isEmpty {
                plainLyricsView
            } else if isMusicSource, let statusText {
                statusView(statusText)
            } else {
                EmptyView()
            }
        }
        .clipped()
    }

    private var syncedLyricsView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        Text(line.text)
                            .font(font(for: index))
                            .foregroundStyle(Color.white.opacity(opacity(for: index)))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity)
                            .scaleEffect(index == currentIndex ? 1.015 : 1.0)
                            .animation(.easeInOut(duration: 0.22), value: currentIndex)
                    }
                }
                .padding(.vertical, 36)
            }
            .scrollDisabled(true)
            .onAppear {
                scrollToCurrentLine(proxy)
            }
            .onChange(of: currentIndex) { _, _ in
                scrollToCurrentLine(proxy)
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 0.82),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var plainLyricsView: some View {
        VStack(spacing: 6) {
            ForEach(Array(plainTextLines.prefix(5).enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 ? .system(size: 13, weight: .semibold) : .system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(index == 0 ? 0.9 : 0.64))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var statusText: String? {
        switch state {
        case .loading:
            return "正在加载歌词..."
        case .noLyrics, .unavailable:
            return "暂无歌词"
        case .idle, .loaded:
            return nil
        }
    }

    private func statusView(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.42))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func scrollToCurrentLine(_ proxy: ScrollViewProxy) {
        guard let currentIndex else { return }

        withAnimation(.easeInOut(duration: 0.32)) {
            proxy.scrollTo(lines[currentIndex].id, anchor: .center)
        }
    }

    private func font(for index: Int) -> Font {
        guard let currentIndex else { return .system(size: 11, weight: .regular) }

        switch abs(index - currentIndex) {
        case 0:
            return .system(size: 14, weight: .semibold)
        case 1:
            return .system(size: 12, weight: .regular)
        default:
            return .system(size: 11, weight: .regular)
        }
    }

    private func opacity(for index: Int) -> Double {
        guard let currentIndex else { return 0.5 }

        switch abs(index - currentIndex) {
        case 0:
            return 0.95
        case 1:
            return 0.66
        case 2:
            return 0.38
        default:
            return 0.24
        }
    }
}
