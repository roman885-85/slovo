import Foundation

/// Читання налаштувань у форматі ini — тому самому, що й у VisioBible.
///
/// Сенс не в сумісності заради сумісності: у файлі вже зібрано шрифти,
/// кольори, обведення, таймінги й порядок перекладів, вивірені на
/// проекторі. Переносити це руками — втратити половину налаштувань.
public struct IniSettings {

    public private(set) var sections: [String: [String: String]] = [:]

    public init(fileAt url: URL) throws {
        let data = try Data(contentsOf: url)
        // Файл пишеться Delphi в UTF-8 із BOM, але старі збірки клали CP1251.
        let declared: String.Encoding? = String(data: data, encoding: .utf8) != nil ? .utf8 : nil
        parse(CodePage.decode(data, declared: declared))
    }

    public init(text: String) { parse(text) }

    private mutating func parse(_ text: String) {
        var current = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                sections[current] = sections[current] ?? [:]
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            sections[current, default: [:]][key.lowercased()] = value
        }
    }

    // MARK: - Доступ до значень

    public func string(_ key: String, in section: String) -> String? {
        sections[section]?[key.lowercased()]
    }

    public func int(_ key: String, in section: String) -> Int? {
        string(key, in: section).flatMap { Int($0) }
    }

    public func bool(_ key: String, in section: String) -> Bool? {
        guard let raw = int(key, in: section) else { return nil }
        return raw != 0
    }

    /// Delphi пише дробові числа з комою — `2,70000004768372`.
    public func double(_ key: String, in section: String) -> Double? {
        guard let raw = string(key, in: section) else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    /// `TColor` у Delphi — це `0x00BBGGRR`, порядок каналів зворотний до звичного.
    public func color(_ key: String, in section: String) -> SlideStyle.RGBA? {
        guard let raw = int(key, in: section), raw >= 0 else { return nil }
        return SlideStyle.RGBA(Double(raw & 0xFF) / 255,
                               Double((raw >> 8) & 0xFF) / 255,
                               Double((raw >> 16) & 0xFF) / 255)
    }

    /// Модулі з `[BiblePath]`: рядки виду `0="Modules\rst+\"|1`,
    /// де хвіст після `|` — ознака ввімкненості.
    ///
    /// Порядок і ввімкненість повертаємо разом: в оригіналі це одне
    /// налаштування. Вимкнений модуль лишається в бібліотеці, але не займає
    /// вкладки — інакше при великій колекції смуга перекладів стає
    /// марною.
    public func moduleEntries() -> [(name: String, isEnabled: Bool)] {
        guard let paths = sections["BiblePath"] else { return [] }
        return paths
            .compactMap { key, value -> (Int, String, Bool)? in
                guard let index = Int(key) else { return nil }
                let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                let path = parts.first.map(String.init) ?? value
                let enabled = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) != "0" : true
                let cleaned = path.trimmingCharacters(in: CharacterSet(charactersIn: "\" \\"))
                guard let name = cleaned.split(separator: "\\").last.map(String.init) else { return nil }
                return (index, name, enabled)
            }
            .sorted { $0.0 < $1.0 }
            .map { (name: $0.1, isEnabled: $0.2) }
    }

    public func moduleOrder() -> [String] {
        moduleEntries().map(\.name)
    }

    /// Ім'я власного файла налаштувань. Формат — той самий ini, у якому
    /// розкладено секції `[Bible]`, `[OutScreen]`, `[BiblePath]`: під нього
    /// написані всі читачі, і міняти формат заради імені сенсу немає.
    public static let configFileName = "Slovo.ini"

    /// Де файл може лежати, за спаданням пріоритету.
    ///
    /// Спершу особиста тека програми: туди можна покласти свою копію й
    /// підправити значення без пересборки. Потім власний пакет — там лежить
    /// поставкове умовчання, і саме з ним програма стартує на новому
    /// комп'ютері. Файлів установленого VisioBible — ні в `Application
    /// Support`, ні в пляшках CrossOver — програма більше не шукає: чужі
    /// налаштування не мають переробляти її під себе.
    public static var configCandidates: [URL] {
        [
            DataHome.folder.appendingPathComponent(configFileName),
            DataHome.bundleData.appendingPathComponent(configFileName),
        ]
    }

    /// Файл налаштувань, який читає програма, або `nil`, якщо його немає
    /// в жодному зі своїх місць — тоді діють значення, зашиті в код.
    public static func locateConfig() -> URL? {
        let fm = FileManager.default
        return configCandidates.first { fm.fileExists(atPath: $0.path) }
    }
}
