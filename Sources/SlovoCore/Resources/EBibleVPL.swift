import Foundation
import SQLite3

/// Переклади з eBible.org — у модуль MyBible.
///
/// Власник: «добавить репозитории для скачивания других совместимых модулей
/// (в том числе английских и других переводов)». eBible.org віддає понад
/// півтори тисячі перекладів із вільною ліцензією, але у своїх форматах
/// (HTML, USFM, OSIS, Sword). Найпростіший із них — VPL, «вірш на рядок»:
/// `GEN 1:1 In the beginning…`. Його й перекладаємо в базу MyBible
/// (`info`, `books`, `verses`) — формат, який програма, планшет і пульт уже
/// читають. Назви книг — англійські: у VPL їх немає.
public enum EBibleVPL {

    public enum Failure: Error, CustomStringConvertible {
        case noVerses(String)
        case database(String)

        public var description: String {
            switch self {
            case .noVerses(let name): return OurWords.t("%s: в файле нет ни одного стиха", name)
            case .database(let detail): return OurWords.t("Не удалось записать модуль: %s", detail)
            }
        }
    }

    /// Книга: коди VPL і USFM → номер MyBible (той самий канон, що в програмі).
    struct Book {
        let number: Int
        let short: String
        let long: String
    }

    /// Коди книг. У VPL eBible.org свої скорочення («JOH», «PHI», «SOL»), в
    /// USFM — інші («JHN», «PHP», «SNG»): приймаємо обидва.
    static let books: [String: Book] = {
        let rows: [([String], Int, String, String)] = [
            (["GEN"], 10, "Gen", "Genesis"), (["EXO"], 20, "Exo", "Exodus"), (["LEV"], 30, "Lev", "Leviticus"),
            (["NUM"], 40, "Num", "Numbers"), (["DEU"], 50, "Deu", "Deuteronomy"), (["JOS"], 60, "Josh", "Joshua"),
            (["JDG"], 70, "Judg", "Judges"), (["RUT"], 80, "Ruth", "Ruth"), (["1SA"], 90, "1Sam", "1 Samuel"),
            (["2SA"], 100, "2Sam", "2 Samuel"), (["1KI"], 110, "1Kgs", "1 Kings"), (["2KI"], 120, "2Kgs", "2 Kings"),
            (["1CH"], 130, "1Chr", "1 Chronicles"), (["2CH"], 140, "2Chr", "2 Chronicles"), (["EZR"], 150, "Ezra", "Ezra"),
            (["NEH"], 160, "Neh", "Nehemiah"), (["EST"], 190, "Esth", "Esther"), (["JOB"], 220, "Job", "Job"),
            (["PSA"], 230, "Ps", "Psalms"), (["PRO"], 240, "Prov", "Proverbs"), (["ECC"], 250, "Eccl", "Ecclesiastes"),
            (["SOL", "SNG"], 260, "Song", "Song of Songs"), (["ISA"], 290, "Isa", "Isaiah"), (["JER"], 300, "Jer", "Jeremiah"),
            (["LAM"], 310, "Lam", "Lamentations"), (["EZE", "EZK"], 330, "Ezek", "Ezekiel"), (["DAN"], 340, "Dan", "Daniel"),
            (["HOS"], 350, "Hos", "Hosea"), (["JOE", "JOL"], 360, "Joel", "Joel"), (["AMO"], 370, "Amos", "Amos"),
            (["OBA"], 380, "Obad", "Obadiah"), (["JON"], 390, "Jonah", "Jonah"), (["MIC"], 400, "Mic", "Micah"),
            (["NAH", "NAM"], 410, "Nah", "Nahum"), (["HAB"], 420, "Hab", "Habakkuk"), (["ZEP"], 430, "Zeph", "Zephaniah"),
            (["HAG"], 440, "Hag", "Haggai"), (["ZEC"], 450, "Zech", "Zechariah"), (["MAL"], 460, "Mal", "Malachi"),
            (["MAT"], 470, "Matt", "Matthew"), (["MAR", "MRK"], 480, "Mark", "Mark"), (["LUK"], 490, "Luke", "Luke"),
            (["JOH", "JHN"], 500, "John", "John"), (["ACT"], 510, "Acts", "Acts"), (["ROM"], 520, "Rom", "Romans"),
            (["1CO"], 530, "1Cor", "1 Corinthians"), (["2CO"], 540, "2Cor", "2 Corinthians"), (["GAL"], 550, "Gal", "Galatians"),
            (["EPH"], 560, "Eph", "Ephesians"), (["PHI", "PHP"], 570, "Phil", "Philippians"), (["COL"], 580, "Col", "Colossians"),
            (["1TH"], 590, "1Thess", "1 Thessalonians"), (["2TH"], 600, "2Thess", "2 Thessalonians"),
            (["1TI"], 610, "1Tim", "1 Timothy"), (["2TI"], 620, "2Tim", "2 Timothy"), (["TIT"], 630, "Titus", "Titus"),
            (["PHM"], 640, "Phlm", "Philemon"), (["HEB"], 650, "Heb", "Hebrews"), (["JAM", "JAS"], 660, "Jas", "James"),
            (["1PE"], 670, "1Pet", "1 Peter"), (["2PE"], 680, "2Pet", "2 Peter"), (["1JO", "1JN"], 690, "1John", "1 John"),
            (["2JO", "2JN"], 700, "2John", "2 John"), (["3JO", "3JN"], 710, "3John", "3 John"), (["JUD", "JDE"], 720, "Jude", "Jude"),
            (["REV"], 730, "Rev", "Revelation"),
            // Неканонічні — номери тієї самої схеми MyBible.
            (["TOB"], 170, "Tob", "Tobit"), (["JDT"], 180, "Jdt", "Judith"), (["WIS"], 270, "Wis", "Wisdom"),
            (["SIR"], 280, "Sir", "Sirach"), (["BAR"], 320, "Bar", "Baruch"), (["LJE"], 315, "EpJer", "Letter of Jeremiah"),
            (["1MA"], 462, "1Macc", "1 Maccabees"), (["2MA"], 464, "2Macc", "2 Maccabees"), (["3MA"], 466, "3Macc", "3 Maccabees"),
            (["1ES"], 165, "1Esd", "1 Esdras"), (["2ES"], 468, "2Esd", "2 Esdras"), (["MAN"], 790, "PrMan", "Prayer of Manasseh"),
        ]
        var map: [String: Book] = [:]
        for (codes, number, short, long) in rows {
            for code in codes { map[code] = Book(number: number, short: short, long: long) }
        }
        return map
    }()

    /// Опис перекладу, що ляже в таблицю `info`.
    public struct Description: Sendable {
        public var title: String
        public var abbreviation: String
        public var language: String
        public var copyright: String
        public var rightToLeft: Bool

        public init(title: String, abbreviation: String, language: String, copyright: String, rightToLeft: Bool) {
            self.title = title
            self.abbreviation = abbreviation
            self.language = language
            self.copyright = copyright
            self.rightToLeft = rightToLeft
        }
    }

    /// Файл `…_vpl.txt` у розпакованому архіві eBible.org.
    public static func findText(in folder: URL) -> URL? {
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return all.first { $0.lastPathComponent.lowercased().hasSuffix("_vpl.txt") }
            ?? all.first { $0.pathExtension.lowercased() == "txt" && !$0.lastPathComponent.hasPrefix(".") }
    }

    /// Перекласти VPL у базу MyBible. Пише в тимчасовий файл і лише потім
    /// ставить на місце: обірвана робота не лишає напівмодуля.
    /// - Returns: скільки віршів лягло.
    @discardableResult
    public static func convert(text url: URL, to destination: URL, description: Description) throws -> Int {
        let raw = try Data(contentsOf: url)
        let text = String(data: raw, encoding: .utf8) ?? String(decoding: raw, as: UTF8.self)
        var verses: [(book: Int, chapter: Int, verse: Int, text: String)] = []
        var seen: Set<Int> = []
        var order: [Int] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(line)
            if rest.hasPrefix("\u{FEFF}") { rest = rest.dropFirst() }
            // «GEN 1:1 текст», буває й «PSA 119:1-2 текст».
            guard let space = rest.firstIndex(of: " ") else { continue }
            let code = rest[..<space].uppercased()
            guard let book = books[code] else { continue }
            rest = rest[rest.index(after: space)...]
            guard let second = rest.firstIndex(of: " ") else { continue }
            let reference = rest[..<second]
            let words = rest[rest.index(after: second)...].trimmingCharacters(in: .whitespaces)
            let pieces = reference.split(separator: ":")
            guard pieces.count == 2, let chapter = Int(pieces[0]),
                  let verse = Int(pieces[1].split(separator: "-").first ?? ""), !words.isEmpty else { continue }
            verses.append((book.number, chapter, verse, words))
            if seen.insert(book.number).inserted { order.append(book.number) }
        }
        guard !verses.isEmpty else { throw Failure.noVerses(url.lastPathComponent) }

        let fm = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".slovo-vpl-" + UUID().uuidString + ".SQLite3")
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(temporary.path, &handle) == SQLITE_OK, let db = handle else {
            throw Failure.database(OurWords.t("база не открылась"))
        }
        var closed = false
        defer {
            if !closed { sqlite3_close(db) }
            try? fm.removeItem(at: temporary)
        }
        func exec(_ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
                let detail = message.map { String(cString: $0) } ?? sql
                sqlite3_free(message)
                throw Failure.database(detail)
            }
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func prepared(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Failure.database(String(cString: sqlite3_errmsg(db)))
            }
            return statement
        }

        try exec("""
            CREATE TABLE info (name TEXT, value TEXT);
            CREATE TABLE books (book_color TEXT, book_number NUMERIC, short_name TEXT, long_name TEXT);
            CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT);
            BEGIN;
            """)
        let info = try prepared("INSERT INTO info (name, value) VALUES (?, ?)")
        let pairs: [(String, String)] = [
            ("description", description.title), ("abbreviation", description.abbreviation),
            ("language", description.language), ("detailed_info", description.copyright),
            ("origin", "eBible.org"), ("right_to_left", description.rightToLeft ? "true" : "false"),
            ("strong_numbers", "false"), ("chapter_string", "Chapter"),
        ]
        for (name, value) in pairs {
            sqlite3_reset(info)
            sqlite3_bind_text(info, 1, name, -1, transient)
            sqlite3_bind_text(info, 2, value, -1, transient)
            guard sqlite3_step(info) == SQLITE_DONE else { sqlite3_finalize(info); throw Failure.database(String(cString: sqlite3_errmsg(db))) }
        }
        sqlite3_finalize(info)

        let bookRow = try prepared("INSERT INTO books (book_color, book_number, short_name, long_name) VALUES ('#ffcccccc', ?, ?, ?)")
        let names = Dictionary(books.values.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        for number in order.sorted() {
            guard let book = names[number] else { continue }
            sqlite3_reset(bookRow)
            sqlite3_bind_int(bookRow, 1, Int32(number))
            sqlite3_bind_text(bookRow, 2, book.short, -1, transient)
            sqlite3_bind_text(bookRow, 3, book.long, -1, transient)
            guard sqlite3_step(bookRow) == SQLITE_DONE else { sqlite3_finalize(bookRow); throw Failure.database(String(cString: sqlite3_errmsg(db))) }
        }
        sqlite3_finalize(bookRow)

        let verseRow = try prepared("INSERT INTO verses (book_number, chapter, verse, text) VALUES (?, ?, ?, ?)")
        for item in verses {
            sqlite3_reset(verseRow)
            sqlite3_bind_int(verseRow, 1, Int32(item.book))
            sqlite3_bind_int(verseRow, 2, Int32(item.chapter))
            sqlite3_bind_int(verseRow, 3, Int32(item.verse))
            sqlite3_bind_text(verseRow, 4, item.text, -1, transient)
            guard sqlite3_step(verseRow) == SQLITE_DONE else { sqlite3_finalize(verseRow); throw Failure.database(String(cString: sqlite3_errmsg(db))) }
        }
        sqlite3_finalize(verseRow)
        try exec("COMMIT; CREATE INDEX verses_index ON verses (book_number, chapter, verse);")
        sqlite3_close(db)
        closed = true

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
        return verses.count
    }
}
