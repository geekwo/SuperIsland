import SwiftUI

struct LyricsScrollerView: View {
    let lines: [LyricLine]
    let currentTime: TimeInterval
    let isMusicSource: Bool
    let plainTextLines: [String]

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
                            .fontWeight(index == currentIndex ? .semibold : .regular)
                            .foregroundStyle(Color.white.opacity(opacity(for: index)))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity)
                            .scaleEffect(index == currentIndex ? 1.02 : 1.0)
                            .animation(.easeInOut(duration: 0.22), value: currentIndex)
                    }
                }
                .padding(.vertical, 30)
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
                    .init(color: .black, location: 0.24),
                    .init(color: .black, location: 0.76),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var plainLyricsView: some View {
        VStack(spacing: 5) {
            ForEach(Array(plainTextLines.prefix(4).enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 ? .system(size: 11, weight: .semibold) : .system(size: 10, weight: .regular))
                    .fontWeight(index == 0 ? .semibold : .regular)
                    .foregroundStyle(Color.white.opacity(index == 0 ? 0.82 : 0.52))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func scrollToCurrentLine(_ proxy: ScrollViewProxy) {
        guard let currentIndex else { return }

        withAnimation(.easeInOut(duration: 0.32)) {
            proxy.scrollTo(lines[currentIndex].id, anchor: .center)
        }
    }

    private func font(for index: Int) -> Font {
        index == currentIndex ? .system(size: 11, weight: .semibold) : .system(size: 10, weight: .regular)
    }

    private func opacity(for index: Int) -> Double {
        guard let currentIndex else { return 0.45 }

        switch abs(index - currentIndex) {
        case 0:
            return 0.92
        case 1:
            return 0.58
        case 2:
            return 0.34
        default:
            return 0.18
        }
    }
}
