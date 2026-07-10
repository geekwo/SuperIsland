import Foundation

@MainActor
enum ExtensionLocalization {
    private static var cache: [String: [String: String]] = [:]

    static func localized(_ value: String, extensionID: String) -> String {
        guard !value.isEmpty else { return value }
        return table(for: extensionID)[value] ?? localizedDynamicValue(value) ?? value
    }

    static func localized(_ value: String, manifest: ExtensionManifest) -> String {
        guard !value.isEmpty else { return value }
        return table(for: manifest)[value] ?? localizedDynamicValue(value) ?? value
    }

    static func table(for extensionID: String) -> [String: String] {
        if let cached = cache[extensionID] {
            return cached
        }
        guard let manifest = ExtensionManager.shared.installed.first(where: { $0.id == extensionID }) else {
            cache[extensionID] = [:]
            return [:]
        }
        return table(for: manifest)
    }

    static func table(for manifest: ExtensionManifest) -> [String: String] {
        if let cached = cache[manifest.id] {
            return cached
        }

        let localeCode = preferredLocaleCode()
        let url = manifest.bundleURL
            .appendingPathComponent("locales", isDirectory: true)
            .appendingPathComponent("\(localeCode).json")

        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            cache[manifest.id] = [:]
            return [:]
        }

        cache[manifest.id] = decoded
        return decoded
    }

    static func resetCache() {
        cache.removeAll()
    }

    private static func preferredLocaleCode() -> String {
        let identifiers = Locale.preferredLanguages
        if identifiers.contains(where: { $0.hasPrefix("zh-Hans") || $0 == "zh-CN" || $0 == "zh-SG" }) {
            return "zh-Hans"
        }
        return "en"
    }

    private static func localizedDynamicValue(_ value: String) -> String? {
        guard preferredLocaleCode() == "zh-Hans" else { return nil }

        if let minutes = numericPrefix(in: value, suffix: "m left") {
            return "剩余 \(minutes) 分钟"
        }

        if let hours = numericPrefix(in: value, suffix: "h left") {
            return "剩余 \(hours) 小时"
        }

        return nil
    }

    private static func numericPrefix(in value: String, suffix: String) -> String? {
        guard value.hasSuffix(suffix) else { return nil }
        let prefix = value.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        return String(prefix)
    }
}
