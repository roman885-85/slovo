import Foundation
import SQLite3

/// Модуль MySword — теж база SQLite, але влаштована інакше, ніж MyBible.
///
/// Увесь опис перекладу лежить в єдиному рядку таблиці `Details`, а
/// вірші — в таблиці `Bible` з полями `Book`, `Chapter`, `Verse`, `Scripture`.
/// Таблиці книг тут немає зовсім: `Book` — наскрізний номер канону 1…66, а підписи
/// книг MySword малює сама, тому назви ми беремо з `MySwordBookNames`.
///
/// Тип модуля стоїть в імені файлу перед розширенням: вірші є лише в
/// `*.bbl.mybible`, а `.cmt`, `.dct`, `.bok`, `.jor` — це коментарі,
/// словники, книги і щоденники, показувати їх нічим.
public final class MySwordModule: TextModule {

    public let identifier: String
    public let info: ModuleInfo
    public let books: [BookInfo]
    public var format: TextModuleFormat { .mySword }

    private let database: OpaquePointer
    private var chapterCache: [Int: [Chapter]] = [:]
    private let cacheLock = NSLock()

    public init(fileAt url: URL) throws {
        let fileName = url.lastPathComponent
        // Відмова за ім'ям — до відкриття файла: нема чого чіпати чужу базу,
        // якщо вже за типом видно, що віршів у ній немає.
        guard Self.isBibleModuleName(fileName) else {
            throw MySwordError.notBibleModule(fileName)
        }
        // Ідентифікатор — ім'я без обох розширень: інакше замість «Proba»
        // у налаштуваннях осіло б «Proba.bbl».
        identifier = url.deletingPathExtension().deletingPathExtension().lastPathComponent

        var handle: OpaquePointer?
        // Лише читання: модуль користувача не наш, псувати його не можна навіть
        // випадковим службовим записом на кшталт журналу.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw MySwordError.cannotOpen(fileName)
        }

        do {
            let contents = try Self.read(handle, fileName: fileName, identifier: identifier)
            info = contents.info
            books = contents.books
            database = handle
        } catch {
            // Об'єкт ще не зібрано цілком, і `deinit` за нами не покличуть —
            // базу закриваємо тут самі, інакше лишиться висіти дескриптор.
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    /// Чи модуль це з віршами. Дивимося на два розширення одразу: одне
    /// `.mybible` носять і нотатки, і закладки, і налаштування самої MySword.
    public static func isBibleModuleName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".bbl.mybible")
    }

    // MARK: - Тексти

    public func chapters(ofBook book: BookInfo) throws -> [Chapter] {
        cacheLock.lock()
        if let cached = chapterCache[book.index] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Ключ у базі — номер MySword, він же лежить у `fileName`. Брати
        // `canonicalNumber` не можна: там уже перераховані 10…730.
        guard let number = Int(book.fileName) else { return [] }

        var statement: OpaquePointer?
        let sql = "SELECT Chapter, Verse, Scripture FROM Bible WHERE Book = ? ORDER BY Chapter, Verse"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MySwordError.queryFailed(identifier)
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
            let text = MySwordText.plain(raw)
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

    // MARK: - Розбір бази

    /// Усе, що може відмовити, зібрано тут і робиться до збирання об'єкта.
    private static func read(_ handle: OpaquePointer,
                             fileName: String,
                             identifier: String) throws -> (info: ModuleInfo, books: [BookInfo]) {
        // Успішне відкриття про формат не каже нічого: справжній
        // `sqlite3_open_v2` повертає «все добре» і для порожнього файла, і
        // для звичайного тексту. Перша правда приходить лише на запиті.
        let tables = try tableNames(in: handle, fileName: fileName)
        guard tables.contains("bible") else {
            throw MySwordError.notAModule(fileName)
        }

        let details = readDetails(handle)
        let rows = readBookRows(handle)
        guard !rows.isEmpty else {
            throw MySwordError.noVerses(fileName)
        }
        // Фірмові модулі (ABP, HiSB) шифрують текст віршів, і спосіб ніде
        // не описано. Показати замість Писання кашу гірше, ніж чесно відмовити.
        guard !isEncrypted(details) else {
            throw MySwordError.encrypted(fileName)
        }

        var books: [BookInfo] = []
        for row in rows {
            // Неканонічних книг формат не знає, і сама MySword номери поза
            // 1…66 вважає недійсними. Таку книгу мовчки пропускаємо.
            guard let names = MySwordBookNames.book(row.book) else { continue }
            books.append(BookInfo(index: books.count,
                                  fileName: String(row.book),
                                  fullName: names.fullName,
                                  shortNames: names.shortNames,
                                  chapterCount: row.chapters,
                                  canonicalNumber: MySwordBookNames.canonicalNumber(row.book)))
        }
        guard !books.isEmpty else {
            throw MySwordError.strangeNumbering(fileName)
        }

        var info = ModuleInfo()
        // `Title` — спадок e-Sword 11: частина переселених модулів пише
        // назву саме туди, а `Description` у них немає зовсім.
        info.name = firstNonEmpty(details, "description", "title") ?? identifier
        // Скорочення в MySword за правилами формату без пробілів: пробіл там
        // розділяє частини посилання. Годиться на ярлик вкладки як є.
        info.shortName = firstNonEmpty(details, "abbreviation") ?? identifier
        // Мова тут трилітерна («rus», «ukr»), на відміну від дволітерної
        // у MyBible. Зводити до спільного вигляду нема чого: поле показне.
        info.language = firstNonEmpty(details, "language")
        info.copyright = firstNonEmpty(details, "comments")
        info.hasStrongNumbers = flag(details["strong"])
        info.rightToLeft = flag(details["righttoleft"])
        // Полям `OT` і `NT` вірити не можна: у саморобних модулів вони порожні.
        // Рахуємо за справжніми номерами книг.
        info.hasOldTestament = rows.contains { $0.book <= 39 }
        info.hasNewTestament = rows.contains { $0.book >= 40 }
        info.hasApocrypha = false
        info.isBible = true
        info.encoding = .utf8

        return (info, books)
    }

    /// Імена таблиць і представлень у нижньому регістрі.
    ///
    /// Представлення беремо нарівні з таблицями: MySword при «переселенні»
    /// чужих модулів іноді кладе `Bible` саме представленням.
    private static func tableNames(in handle: OpaquePointer, fileName: String) throws -> Set<String> {
        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type IN ('table','view')"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw MySwordError.notADatabase(fileName)
        }
        defer { sqlite3_finalize(statement) }

        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            names.insert(String(cString: raw).lowercased())
        }
        return names
    }

    /// Єдиний рядок `Details`, розібраний за іменами колонок.
    ///
    /// Лише `SELECT *` і лише за іменами: набір і порядок необов'язкових
    /// полів у різних виробників модулів свій, і читання за номерами
    /// одного разу видало б копірайт за мову.
    private static func readDetails(_ handle: OpaquePointer) -> [String: String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT * FROM Details LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return [:]
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return [:] }

        var values: [String: String] = [:]
        for column in 0..<sqlite3_column_count(statement) {
            guard let name = sqlite3_column_name(statement, column) else { continue }
            let value = sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            values[String(cString: name).lowercased()] = value
        }
        return values
    }

    /// Книги і число розділів у них — одним запитом.
    ///
    /// Індекс за `(Book, Chapter, Verse)` його закриває, тож базу цілком
    /// читати не доведеться, а модулі бувають на десятки мегабайтів.
    private static func readBookRows(_ handle: OpaquePointer) -> [(book: Int, chapters: Int)] {
        var statement: OpaquePointer?
        let sql = "SELECT Book, MAX(Chapter) FROM Bible GROUP BY Book ORDER BY Book"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [(book: Int, chapters: Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((Int(sqlite3_column_int(statement, 0)),
                         Int(sqlite3_column_int(statement, 1))))
        }
        return rows
    }

    /// Поля `encryption` у більшості модулів немає зовсім; якщо воно є і не
    /// порожнє і не нуль — текст віршів зашифровано.
    private static func isEncrypted(_ details: [String: String]) -> Bool {
        guard let raw = details["encryption"]?.trimmingCharacters(in: .whitespaces) else { return false }
        return !raw.isEmpty && raw != "0"
    }

    private static func firstNonEmpty(_ details: [String: String], _ keys: String...) -> String? {
        for key in keys {
            if let value = details[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// У `Details` це поля BOOL, але виробники пишуть туди і «1», і «true».
    private static func flag(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return raw == "true" || raw == "yes" || raw == "1"
    }
}

public enum MySwordError: Error, CustomStringConvertible {
    case notBibleModule(String)
    case cannotOpen(String)
    case notADatabase(String)
    case notAModule(String)
    case noVerses(String)
    case encrypted(String)
    case strangeNumbering(String)
    case queryFailed(String)

    public var description: String {
        switch self {
        case .notBibleModule(let name):
            return OurWords.t("%s: это не модуль со стихами — у MySword они лежат в файлах «.bbl.mybible»", "\(name)")
        case .cannotOpen(let name):
            return OurWords.t("%s: не удалось открыть файл модуля", name)
        case .notADatabase(let name):
            return OurWords.t("%s: это не база данных", name)
        case .notAModule(let name):
            return OurWords.t("%s: это не модуль MySword — нет таблицы Bible", "\(name)")
        case .noVerses(let name):
            return OurWords.t("%s: в модуле нет ни одного стиха", name)
        case .encrypted(let name):
            return OurWords.t("%s: модуль зашифрован, читать нечем", name)
        case .strangeNumbering(let name):
            return OurWords.t("%s: непонятная нумерация книг — ни одного номера в пределах 1…66", name)
        case .queryFailed(let name):
            return "\(name): ошибка запроса к базе модуля"
        }
    }
}
