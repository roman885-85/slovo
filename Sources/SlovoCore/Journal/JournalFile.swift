import Foundation

/// Файл-журнал оригіналу: `History.ini`, `PlanDef.ini` і збережені плани
/// з теки `Plans`.
///
/// Формат один на всіх і, попри розширення `.ini`, це розмітка:
///
///     <JournalFile>
///       <Journal Name="Bible">
///         <Item Caption="Быт.- В начале сотворил Бог небо и землю."
///               Reference="Быт." Quote="1. В начале сотворил Бог небо и землю."
///               Class="0" Book="0" Chapter="0" Verse="0" .../>
///       </Journal>
///       <Journal Name="Text"/>
///       <Journal Name="Songs"/>
///     </JournalFile>
///
/// Журналів рівно три і завжди всі три, навіть порожні, — так лежить у файлах
/// користувача. Пункти розкладено за журналами, а не звалено в один список:
/// в оригіналу «План» та «Історія» ведуться окремо для кожної вкладки
/// модулів (18).
///
/// Розбір навмисно свій, а не `XMLParser`: файл пише чужа програма, і одна
/// незакрита дужка або неекранований `&` не мають коштувати користувачеві
/// всієї історії. Тут незрозумілий шматок просто пропускається.
public struct JournalFile: Sendable, Hashable {

    /// Вкладка модулів (18), якій належить журнал.
    public enum Section: String, CaseIterable, Sendable, Hashable {
        case bible = "Bible"
        case text = "Text"
        case songs = "Songs"
    }

    /// Один `<Item .../>`. Порядок атрибутів зберігаємо: файл читають очима,
    /// і переставляти в ньому стовпці без потреби нема чого.
    public struct Item: Sendable, Hashable {
        public private(set) var keys: [String] = []
        private var values: [String: String] = [:]

        public init() {}

        public init(_ pairs: [(String, String)]) {
            for pair in pairs { self[pair.0] = pair.1 }
        }

        public subscript(key: String) -> String? {
            get { values[key] }
            set {
                guard let newValue else {
                    keys.removeAll { $0 == key }
                    values[key] = nil
                    return
                }
                if values[key] == nil { keys.append(key) }
                values[key] = newValue
            }
        }

        public func string(_ key: String, default fallback: String = "") -> String {
            values[key] ?? fallback
        }

        public func int(_ key: String) -> Int? {
            guard let raw = values[key]?.trimmingCharacters(in: .whitespaces) else { return nil }
            return Int(raw)
        }

        public var isEmpty: Bool { keys.isEmpty }
    }

    /// Пункти за журналами. Порядок усередині журналу — порядок у файлі.
    public var items: [Section: [Item]] = [:]

    public init() {}

    public subscript(section: Section) -> [Item] {
        get { items[section] ?? [] }
        set { items[section] = newValue }
    }

    public var isEmpty: Bool { Section.allCases.allSatisfy { self[$0].isEmpty } }

    public var totalCount: Int { Section.allCases.reduce(0) { $0 + self[$1].count } }

    // MARK: - Читання

    public static func read(contentsOf url: URL) throws -> JournalFile {
        let data = try Data(contentsOf: url)
        // Файл пише Windows-програма: там трапляється і UTF-8 з міткою
        // порядку байтів, і «кодова сторінка» без неї. Розбір кодування вже
        // написано для модулів — беремо його, щоб кирилиця не перетворилася
        // на знаки питання.
        return parse(CodePage.decode(data, declared: nil))
    }

    /// Чи схожий вміст на журнал. Потрібно «Завантажити план»: там в одній
    /// теці можуть лежати і файли оригіналу, і наші.
    public static func looksLikeJournal(_ text: String) -> Bool {
        text.range(of: "<VisioBibleJournal", options: [.caseInsensitive]) != nil
    }

    public static func parse(_ text: String) -> JournalFile {
        var journal = JournalFile()
        for section in Section.allCases { journal.items[section] = [] }

        var current: Section?
        var scanner = text.startIndex

        while let open = text[scanner...].firstIndex(of: "<") {
            guard let close = text[text.index(after: open)...].firstIndex(of: ">") else { break }
            let body = String(text[text.index(after: open)..<close])
            scanner = text.index(after: close)

            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("/") {
                // Закривальний тег. Журнал закрився — далі пункти нічиї.
                if trimmed.dropFirst().trimmingCharacters(in: .whitespaces).lowercased() == "journal" {
                    current = nil
                }
                continue
            }
            // Коментарі, оголошення XML та інша службова розмітка.
            if trimmed.hasPrefix("?") || trimmed.hasPrefix("!") { continue }

            let name = String(trimmed.prefix { !$0.isWhitespace && $0 != "/" }).lowercased()
            let item = Item(attributes(in: trimmed))
            let selfClosing = trimmed.hasSuffix("/")

            switch name {
            case "journal":
                current = Section(rawValue: item.string("Name"))
                // `<Journal Name="Text"/>` — порожній журнал, він же і закрився.
                if selfClosing { current = nil }
            case "item":
                guard let current, !item.isEmpty else { continue }
                journal.items[current, default: []].append(item)
            default:
                continue
            }
        }
        return journal
    }

    /// Пари `Ім'я="значення"` з тіла тега.
    private static func attributes(in tag: String) -> [(String, String)] {
        var result: [(String, String)] = []
        var index = tag.startIndex

        while index < tag.endIndex {
            // Ім'я атрибута — до знака рівності.
            guard let equals = tag[index...].firstIndex(of: "=") else { break }
            let rawName = tag[index..<equals]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
            // Ім'я тега стоїть перед першим атрибутом і в нього не потрапляє:
            // «Item Caption=…» — беремо останнє слово перед «=».
            let name = rawName.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""

            var value = tag.index(after: equals)
            guard value < tag.endIndex else { break }
            // Значення може стояти і в подвійних, і в одинарних лапках.
            let quote = tag[value]
            guard quote == "\"" || quote == "'" else {
                index = value
                continue
            }
            value = tag.index(after: value)
            guard let end = tag[value...].firstIndex(of: quote) else { break }

            if !name.isEmpty { result.append((name, unescape(String(tag[value..<end])))) }
            index = tag.index(after: end)
        }
        return result
    }

    // MARK: - Запис

    /// Той самий вигляд, що у файлів оригіналу: два пробіли на журнал, чотири на
    /// пункт, порожній журнал — самозакривним тегом.
    public func xml() -> String {
        var lines = ["<VisioBibleJournal>"]
        for section in Section.allCases {
            let list = self[section]
            guard !list.isEmpty else {
                lines.append("  <Journal Name=\"\(section.rawValue)\"/>")
                continue
            }
            lines.append("  <Journal Name=\"\(section.rawValue)\">")
            for item in list {
                let pairs = item.keys.map { "\($0)=\"\(Self.escape(item.string($0)))\"" }
                lines.append("    <Item \(pairs.joined(separator: " "))/>")
            }
            lines.append("  </Journal>")
        }
        lines.append("</VisioBibleJournal>")
        return lines.joined(separator: "\n") + "\n"
    }

    public func write(to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(xml().utf8).write(to: url, options: .atomic)
    }

    // MARK: - Екранування

    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            // Перенос рядка всередині значення атрибута читається по-різному
            // в різних розбирачах — пишемо його числом, так надійніше.
            case "\n": result += "&#10;"
            case "\r": result += "&#13;"
            default: result.append(character)
            }
        }
        return result
    }

    static func unescape(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        var index = value.startIndex

        while index < value.endIndex {
            guard value[index] == "&",
                  let semicolon = value[index...].firstIndex(of: ";"),
                  value.distance(from: index, to: semicolon) <= 10 else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }
            let entity = String(value[value.index(after: index)..<semicolon])
            switch entity.lowercased() {
            case "amp":  result.append("&")
            case "lt":   result.append("<")
            case "gt":   result.append(">")
            case "quot": result.append("\"")
            case "apos": result.append("'")
            default:
                if entity.hasPrefix("#"),
                   let code = Self.characterCode(entity.dropFirst()),
                   let scalar = Unicode.Scalar(code) {
                    result.append(Character(scalar))
                } else {
                    // Незрозумілий запис — лишаємо як є: краще показати
                    // «&nbsp;» у рядку, ніж втратити шматок тексту.
                    result.append(contentsOf: value[index...semicolon])
                }
            }
            index = value.index(after: semicolon)
        }
        return result
    }

    private static func characterCode(_ digits: Substring) -> UInt32? {
        if digits.first == "x" || digits.first == "X" {
            return UInt32(digits.dropFirst(), radix: 16)
        }
        return UInt32(digits)
    }
}
