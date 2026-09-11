import Foundation
import SQLite3

/// Модуль MyBible — уся книга в одній базі SQLite.
///
/// Формат поширений у російськомовних програмах, і оригінальна
/// програма вміє його нарівні з «Цитатою з Біблії», тому без нього
/// половина зібраної користувачем бібліотеки лишилася б за бортом.
///
/// Будова бази: таблиця `info` — пари ім'я/значення з описом модуля,
/// `books` — книги з їхніми наскрізними номерами (Буття = 10, … Об'явлення = 730),
/// `verses` — самі вірші з полями `book_number`, `chapter`, `verse`, `text`.
public final class MyBibleModule: TextModule {

    public let identifier: String
    public let info: ModuleInfo
    public let books: [BookInfo]
    public var format: TextModuleFormat { .myBible }

    private let database: OpaquePointer
    private var chapterCache: [Int: [Chapter]] = [:]
    private let cacheLock = NSLock()

    public init(fileAt url: URL) throws {
        var handle: OpaquePointer?
        // Лише читання: модуль користувача не наш, псувати його не можна навіть
        // випадковим службовим записом на кшталт журналу.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw MyBibleError.cannotOpen(url.lastPathComponent)
        }
        database = handle
        identifier = url.deletingPathExtension().lastPathComponent

        let values = Self.readInfo(handle)
        guard Self.hasTable("verses", in: handle), Self.hasTable("books", in: handle) else {
            sqlite3_close(handle)
            throw MyBibleError.notAModule(url.lastPathComponent)
        }

        var info = ModuleInfo()
        info.name = values["description"] ?? identifier
        // Свого скорочення в `info` у модулів MyBible зазвичай немає, і брати
        // замість нього `chapter_string` не можна — там лежить слово «Глава».
        // Ім'я файлу якраз і є звичне скорочення: RST+, TUB, VIN-ru+.
        info.shortName = values["abbreviation"].flatMap { $0.isEmpty ? nil : $0 } ?? identifier
        info.language = values["language"]
        info.copyright = values["detailed_info"] ?? values["origin"]
        // Ключ називався по-різному в різних поколіннях формату.
        info.hasStrongNumbers = Self.flag(values["strong_numbers"] ?? values["is_strong"])
        info.rightToLeft = Self.flag(values["right_to_left"])
        info.isBible = true
        info.encoding = .utf8
        self.info = info

        self.books = Self.readBooks(handle)
        guard !books.isEmpty else {
            sqlite3_close(handle)
            throw MyBibleError.noBooks(url.lastPathComponent)
        }
    }

    deinit { sqlite3_close(database) }

    // MARK: - Тексти

    public func chapters(ofBook book: BookInfo) throws -> [Chapter] {
        cacheLock.lock()
        if let cached = chapterCache[book.index] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let number = book.canonicalNumber else { return [] }

        // Викидаємо номери Стронга `<S>`, розбір слова `<m>` і виноски `<f>`:
        // на слайді їм не місце. А от `<n>` лишаємо — у звичайних модулях це
        // рідкісна примітка, зате в підрядниках саме там лежить переклад,
        // і без нього від тексту лишається сама грецька.
        let dropped: Set<String> = ["s", "m", "f"]

        var statement: OpaquePointer?
        let sql = "SELECT chapter, verse, text FROM verses WHERE book_number = ? ORDER BY chapter, verse"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MyBibleError.queryFailed(identifier)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(number))

        var chapters: [Chapter] = []
        var currentNumber = Int.min
        var verses: [Verse] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let chapter = Int(sqlite3_column_int(statement, 0))
            let verse = Int(sqlite3_column_int(statement, 1))
            let raw = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""

            if chapter != currentNumber {
                if currentNumber != Int.min {
                    chapters.append(Chapter(number: currentNumber, heading: nil, verses: verses))
                }
                currentNumber = chapter
                verses = []
            }
            // Розмітка в MyBible та сама за духом, що в «Цитаті»: інлайнові
            // теги плюс номери Стронга і виноски, які на слайді не потрібні.
            let text = HTMLText.plain(raw, dropContentOf: dropped)
            if !text.isEmpty { verses.append(Verse(number: verse, text: text)) }
        }
        if currentNumber != Int.min {
            chapters.append(Chapter(number: currentNumber, heading: nil, verses: verses))
        }

        cacheLock.lock()
        chapterCache[book.index] = chapters
        cacheLock.unlock()
        return chapters
    }

    /// Уже розібрана книга, якщо вона є в кеші. Потрібна, щоб відрізнити
    /// миттєвий випадок від того, заради якого варто йти у фон.
    public func cachedChapters(ofBook book: BookInfo) -> [Chapter]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return chapterCache[book.index]
    }

    public func releaseCache() {
        cacheLock.lock()
        chapterCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Читання службових таблиць

    /// В `info` трапляються і «true»/«false», і «1»/«0» — розбираємо обидва.
    private static func flag(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return raw == "true" || raw == "yes" || raw == "1"
    }

    private static func readInfo(_ handle: OpaquePointer) -> [String: String] {
        guard hasTable("info", in: handle) else { return [:] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT name, value FROM info", -1, &statement, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var values: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = sqlite3_column_text(statement, 0) else { continue }
            let value = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            values[String(cString: key).lowercased()] = value
        }
        return values
    }

    private static func readBooks(_ handle: OpaquePointer) -> [BookInfo] {
        // Число розділів рахуємо просто в запиті: окремий прохід по віршах заради
        // цього читав би всю базу, а модулі бувають на десятки мегабайтів.
        let sql = """
            SELECT b.book_number, b.short_name, b.long_name, MAX(v.chapter)
            FROM books AS b
            JOIN verses AS v ON v.book_number = b.book_number
            GROUP BY b.book_number, b.short_name, b.long_name
            ORDER BY b.book_number
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var books: [BookInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let number = Int(sqlite3_column_int(statement, 0))
            let short = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let long = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let chapters = Int(sqlite3_column_int(statement, 3))

            let shortNames = short.isEmpty ? [long] : [short]
            books.append(BookInfo(index: books.count,
                                  fileName: String(number),
                                  fullName: long.isEmpty ? short : long,
                                  shortNames: shortNames,
                                  chapterCount: chapters,
                                  canonicalNumber: number))
        }
        return books
    }

    private static func hasTable(_ name: String, in handle: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND lower(name)=lower('\(name)') LIMIT 1"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

public enum MyBibleError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case notAModule(String)
    case noBooks(String)
    case queryFailed(String)

    public var description: String {
        switch self {
        case .cannotOpen(let name): return OurWords.t("%s: не удалось открыть базу модуля", name)
        case .notAModule(let name): return OurWords.t("%s: это не модуль MyBible — нет таблиц books и verses", name)
        case .noBooks(let name):    return OurWords.t("%s: в модуле нет ни одной книги", name)
        case .queryFailed(let name): return OurWords.t("%s: ошибка запроса к базе модуля", name)
        }
    }
}
