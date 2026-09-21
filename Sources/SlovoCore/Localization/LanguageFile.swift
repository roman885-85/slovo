import Foundation

/// Розбір файла перекладу інтерфейсу старої програми (`Language/*.lng`).
///
/// Формат: секція на форму, рядок на елемент керування.
///     N24=~&Показать слайд~
///     BBOk=&Ок,~Применить настройки~
///     CTSTuning->Item0=,~Настройки шрифтов~
/// Значення — це «підпис,підказка»; будь-яка з частин може бути порожньою і
/// може бути обгорнута в `~…~`, щоб зберегти крайові пробіли та коми.
/// `&` перед літерою — акселератор Windows, на macOS він не потрібен.
public struct LanguageFile: Sendable {

    public struct Entry: Sendable, Hashable {
        public let caption: String
        public let hint: String?
    }

    public let code: String            // ru, uk, en…
    public let displayName: String     // «Русский», «Українська»
    public private(set) var forms: [String: [String: Entry]] = [:]

    public init(fileAt url: URL) throws {
        let data = try Data(contentsOf: url)
        let declared: String.Encoding? = String(data: data, encoding: .utf8) != nil ? .utf8 : nil
        let text = CodePage.decode(data, declared: declared)

        code = url.deletingPathExtension().lastPathComponent
        var forms: [String: [String: Entry]] = [:]
        var current = ""

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("//") { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                forms[current] = forms[current] ?? [:]
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let parts = Self.splitValue(String(line[line.index(after: eq)...]))
            forms[current, default: [:]][key] = Entry(caption: parts.caption, hint: parts.hint)
        }

        self.forms = forms
        displayName = forms["_info_"]?["lang"]?.caption ?? code
    }

    public func entry(_ key: String, form: String) -> Entry? { forms[form]?[key] }

    public func caption(_ key: String, form: String, default fallback: String = "") -> String {
        let text = forms[form]?[key]?.caption ?? fallback
        return text.isEmpty ? fallback : text
    }

    public func hint(_ key: String, form: String) -> String? { forms[form]?[key]?.hint }

    // MARK: -

    /// Ділить «підпис,підказка», поважаючи обгортку `~…~`: усередині неї кома —
    /// частина тексту, а не роздільник.
    static func splitValue(_ raw: String) -> (caption: String, hint: String?) {
        var fields: [String] = []
        var buffer = ""
        var inTilde = false

        for character in raw {
            switch character {
            case "~":
                inTilde.toggle()
            case "," where !inTilde:
                fields.append(buffer)
                buffer = ""
            default:
                buffer.append(character)
            }
        }
        fields.append(buffer)

        let caption = clean(fields.first ?? "")
        let hint = fields.count > 1 ? clean(fields[1]) : ""
        return (caption, hint.isEmpty ? nil : hint)
    }

    private static func clean(_ text: String) -> String {
        // Акселератори Windows: «&Файл» -> «Файл», «&&» -> «&».
        var out = ""
        var iterator = text.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "&" else { out.append(character); continue }
            if let next = iterator.next() {
                out.append(next == "&" ? "&" : next)
            }
        }
        // Перенос рядка автор записує двома знаками — «Показать\\nслайд».
        // Без цієї заміни зворотна скісна з літерою «n» доїжджала до підказки і
        // показувалася людині просто посеред слова, на найпомітнішій кнопці
        // програми.
        out = out.replacingOccurrences(of: "\\n", with: "\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Усі переклади інтерфейсу, що лежать у теці `Language`.
public struct LanguageCatalog: Sendable {
    public let languages: [LanguageFile]

    public init(directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        languages = files
            .filter { $0.pathExtension.lowercased() == "lng" }
            .compactMap { try? LanguageFile(fileAt: $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func language(code: String) -> LanguageFile? {
        languages.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }
}
