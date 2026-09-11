import Foundation

/// Розбір `bibleqt.ini` — опису модуля у форматі «Цитата з Біблії».
///
/// Формат плоский: `Ключ = значення`, коментарі починаються з `//` або `;`.
/// Книги не виділено секціями — вони йдуть повторюваними блоками
/// `PathName` / `FullName` / `ShortName` / `ChapterQty`, і новий `PathName`
/// означає початок наступної книги.
public enum BibleQuoteIni {

    public struct Result: Sendable {
        public let info: ModuleInfo
        public let books: [BookInfo]
    }

    public static func parse(fileAt url: URL) throws -> Result {
        let data = try Data(contentsOf: url)
        return parse(data: data)
    }

    public static func parse(data: Data) -> Result {
        // Кодування ini ми дізнаємося з нього ж, тому читаємо двічі: спершу
        // «як вийде», щоб витягти DefaultEncoding/DesiredFontCharset,
        // потім уже правильно. Ключі латинські, вони переживуть будь-який прогін.
        let probe = CodePage.decode(data, declared: nil)
        let hints = encodingHints(in: probe)
        // DefaultEncoding — пряма вказівка автора модуля, вона головніша за все.
        // Далі довіряємо самим байтам: те, що строго читається як UTF-8,
        // майже напевно UTF-8, навіть якщо DesiredFontCharset каже «204».
        let declared = hints.declared
            ?? (String(data: data, encoding: .utf8) != nil ? .utf8 : hints.fontCharset)
        let text = CodePage.decode(data, declared: declared)

        var info = ModuleInfo()
        info.encoding = declared

        var books: [BookInfo] = []
        var pending: (path: String, full: String, short: [String], chapters: Int)?

        func flush() {
            guard let p = pending, !p.path.isEmpty else { return }
            books.append(BookInfo(index: books.count,
                                  fileName: p.path,
                                  fullName: p.full.isEmpty ? p.path : p.full,
                                  shortNames: p.short,
                                  chapterCount: p.chapters))
            pending = nil
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") || line.hasPrefix(";") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }

            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "biblename":        info.name = value
            case "bibleshortname":   info.shortName = value
            case "bible":            info.isBible = isYes(value)
            case "oldtestament":     info.hasOldTestament = isYes(value)
            case "newtestament":     info.hasNewTestament = isYes(value)
            case "apocrypha":        info.hasApocrypha = isYes(value)
            case "greek":            info.isGreek = isYes(value)
            case "language":         info.language = value
            case "copyright":        info.copyright = value
            case "alphabet":         info.alphabet = value
            case "strongnumbers":    info.hasStrongNumbers = isYes(value)
            case "chapterzero":      info.chapterZero = isYes(value)
            case "showversenumbers": info.showVerseNumbers = isYes(value)
            case "lefttoright":      info.rightToLeft = !isYes(value)
            case "chaptersign":      info.chapterSign = value.lowercased()
            case "versesign":        info.verseSign = value.lowercased()
            case "htmlfilter":       info.htmlFilter = value.split(separator: " ").map { $0.lowercased() }

            case "pathname":
                flush()
                pending = (path: value, full: "", short: [], chapters: 0)
            case "fullname":
                pending?.full = value
            case "shortname":
                pending?.short = value.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            case "chapterqty":
                pending?.chapters = Int(value) ?? 0

            default:
                break
            }
        }
        flush()

        if info.shortName.isEmpty {
            info.shortName = info.name.isEmpty ? "?" : String(info.name.prefix(8))
        }
        return Result(info: info, books: books)
    }

    // MARK: -

    private static func isYes(_ value: String) -> Bool {
        let v = value.lowercased()
        return v.hasPrefix("y") || v == "1" || v == "true"
    }

    /// Збирає обидві підказки про кодування, не змішуючи їх: у них різна вага.
    private static func encodingHints(in text: String) -> (declared: String.Encoding?, fontCharset: String.Encoding?) {
        var declared: String.Encoding?
        var fontCharset: String.Encoding?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            if key == "defaultencoding", declared == nil { declared = CodePage.encoding(forName: value) }
            if key == "desiredfontcharset", fontCharset == nil, let n = Int(value) {
                fontCharset = CodePage.encoding(forCharset: n)
            }
        }
        return (declared, fontCharset)
    }
}
