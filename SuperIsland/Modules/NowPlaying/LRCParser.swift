import Foundation

enum LRCParser {
    private static let timestampPattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#
    private static let timestampRegex = try? NSRegularExpression(pattern: timestampPattern)

    static func parse(_ lrc: String) -> [LyricLine] {
        guard let timestampRegex else { return [] }

        var lines: [LyricLine] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = timestampRegex.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { continue }

            let textStart = matches.reduce(0) { max($0, $1.range.upperBound) }
            let text = nsLine.substring(from: textStart).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let time = parseTimestamp(match: match, in: nsLine) else { continue }
                lines.append(LyricLine(time: time, text: text))
            }
        }

        return lines.sorted {
            if $0.time == $1.time {
                return $0.text.localizedStandardCompare($1.text) == .orderedAscending
            }
            return $0.time < $1.time
        }
    }

    private static func parseTimestamp(match: NSTextCheckingResult, in line: NSString) -> TimeInterval? {
        guard match.numberOfRanges >= 3 else { return nil }
        guard let minutes = Int(line.substring(with: match.range(at: 1))) else { return nil }
        guard let seconds = Double(line.substring(with: match.range(at: 2))) else { return nil }

        var fraction = 0.0
        if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
            let fractionString = line.substring(with: match.range(at: 3))
            guard let fractionValue = Double(fractionString) else { return nil }
            fraction = fractionValue / pow(10, Double(fractionString.count))
        }

        return TimeInterval(minutes * 60) + seconds + fraction
    }
}
