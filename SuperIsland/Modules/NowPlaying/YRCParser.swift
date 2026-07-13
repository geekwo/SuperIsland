import Foundation

enum YRCParser {
    private static let lineTimestampPattern = #"^\[(\d+),(\d+)\]"#
    private static let wordTimestampPattern = #"\(\d+,\d+(?:,\d+)?\)"#
    private static let lineTimestampRegex = try? NSRegularExpression(pattern: lineTimestampPattern)
    private static let wordTimestampRegex = try? NSRegularExpression(pattern: wordTimestampPattern)

    static func parse(_ yrc: String) -> [LyricLine] {
        guard let lineTimestampRegex, let wordTimestampRegex else { return [] }

        var lines: [LyricLine] = []

        for rawLine in yrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            guard let match = lineTimestampRegex.firstMatch(in: line, range: fullRange),
                  let startMilliseconds = TimeInterval(nsLine.substring(with: match.range(at: 1))) else {
                continue
            }

            let textRange = NSRange(location: match.range.upperBound, length: nsLine.length - match.range.upperBound)
            let textWithWordTimestamps = nsLine.substring(with: textRange)
            let cleaned = wordTimestampRegex
                .stringByReplacingMatches(
                    in: textWithWordTimestamps,
                    range: NSRange(location: 0, length: (textWithWordTimestamps as NSString).length),
                    withTemplate: ""
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cleaned.isEmpty else { continue }

            lines.append(LyricLine(time: startMilliseconds / 1000, text: cleaned))
        }

        return lines.sorted {
            if $0.time == $1.time {
                return $0.text.localizedStandardCompare($1.text) == .orderedAscending
            }
            return $0.time < $1.time
        }
    }
}
