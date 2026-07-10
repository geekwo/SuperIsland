import Foundation

struct LyricLine: Identifiable, Hashable, Sendable {
    let time: TimeInterval
    let text: String

    var id: String {
        "\(time)-\(text)"
    }
}
