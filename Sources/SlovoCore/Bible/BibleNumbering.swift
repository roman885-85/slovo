import Foundation
import SQLite3

/// Невідповідності нумерації перекладів Біблії — база `inconsistencies.sqlite3`.
///
/// Різні переклади рахують розділи й вірші по-різному: у Псалтиря східного
/// рахунку (Септуагінта, Синодальний) розділи з 10-го по 145-й на одиницю менші,
/// ніж у західного (масоретський текст, KJV), а надписання в одних перекладах
/// займають перший вірш, в інших не займають. Поки адресу не перекладено з
/// одного рахунку на інший, другий переклад на слайді показує сусідній вірш.
///
/// Оригінал возить для цього готову базу і править її окремим вікном —
/// «Редактор невідповідностей нумерації перекладів Біблії» (пункт меню N40).
/// Будова бази (знято з файла автора, 338 правил):
/// - `t_info` — стандарти нумерації: код і опис;
/// - `modules` — якому стандарту належить модуль, за його скороченням;
/// - `bibletrans` — правила переведення адреси з одного стандарту в інший.
///
/// Номери книг у `bibletrans` — ті самі наскрізні номери MyBible, що живуть у
/// `BookInfo.canonicalNumber` (Буття = 10, … Псалтир = 230), тож правило
/// прикладається до книги напряму.
public struct NumberingStandard: Sendable, Hashable, Identifiable {
    public var code: String
    public var description: String
    public var id: String { code }

    public init(code: String, description: String) {
        self.code = code
        self.description = description
    }
}

/// Вид правила. Літери — як у колонці `type` бази автора.
public enum NumberingRuleKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// `OC` — зсув номера розділу на сталу величину.
    case offsetChapter = "OC"
    /// `OV` — зсув номера вірша всередині розділу.
    case offsetVerse = "OV"
    /// `P` — частина розділу переїхала в інший розділ цілком, з новою нумерацією.
    case part = "P"
    /// `D` — окремий вірш стоїть в іншому місці, іноді розбитий на кілька.
    case displaced = "D"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .offsetChapter: return OurWords.t("Сдвиг глав")
        case .offsetVerse:   return OurWords.t("Сдвиг стихов")
        case .part:          return OurWords.t("Перенос части главы")
        case .displaced:     return OurWords.t("Перенесённый стих")
        }
    }
}

/// Одне правило переведення адреси.
///
/// Порожні поля бази означають «не задано»: в `OC` не заповнені вірші, в `OV`
/// зазвичай не заповнений розділ призначення, у `P` і `D` розділ і вірш призначення
/// задано числом, а не зсувом.
public struct NumberingRule: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var from: String
    public var to: String
    public var kind: NumberingRuleKind
    public var book: Int
    public var chapterBegin: Int
    public var chapterEnd: Int?
    public var verseBegin: Int?
    public var verseEnd: Int?
    /// В `OC` — зсув розділів, у `P` і `D` — номер розділу призначення,
    /// в `OV` — номер розділу призначення, якщо його задано.
    public var chapterTo: Int?
    public var chapterToEnd: Int?
    /// В `OV` — зсув віршів, у `P` і `D` — номер першого вірша призначення.
    public var verseTo: Int?
    public var verseToEnd: Int?

    public init(id: UUID = UUID(), from: String, to: String, kind: NumberingRuleKind,
                book: Int, chapterBegin: Int, chapterEnd: Int? = nil,
                verseBegin: Int? = nil, verseEnd: Int? = nil,
                chapterTo: Int? = nil, chapterToEnd: Int? = nil,
                verseTo: Int? = nil, verseToEnd: Int? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.book = book
        self.chapterBegin = chapterBegin
        self.chapterEnd = chapterEnd
        self.verseBegin = verseBegin
        self.verseEnd = verseEnd
        self.chapterTo = chapterTo
        self.chapterToEnd = chapterToEnd
        self.verseTo = verseTo
        self.verseToEnd = verseToEnd
    }

    /// Останній розділ, на який поширюється правило.
    public var chapterLast: Int { chapterEnd ?? chapterBegin }

    /// Адреса-джерело рядком — для списку у вікні редактора.
    public var sourceText: String {
        // Проміжок з одного розділу пишемо одним числом: в автора в базі
        // «з 13-го по 13-й» трапляється часто, і «13–13» читається як помилка.
        var text = (chapterEnd.map { $0 > chapterBegin } ?? false)
            ? "\(chapterBegin)–\(chapterEnd!)"
            : "\(chapterBegin)"
        if let begin = verseBegin {
            text += ":" + (verseEnd.map { "\(begin)–\($0)" } ?? "\(begin)…")
        }
        return text
    }

    /// Адреса-призначення рядком. У зсувів показуємо знак, у переносів — номер.
    public var targetText: String {
        switch kind {
        case .offsetChapter:
            return signed(chapterTo ?? 0) + " к главе"
        case .offsetVerse:
            var text = signed(verseTo ?? 0) + " к стиху"
            if let chapter = chapterTo { text = OurWords.t("гл. \(chapter), ") + text }
            return text
        case .part, .displaced:
            var text = chapterTo.map { "\($0)" } ?? "та же глава"
            if let verse = verseTo {
                text += ":" + (verseToEnd.map { "\(verse)–\($0)" } ?? "\(verse)")
            }
            return text
        }
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
}

/// Уся база цілком, значенням: вікно редактора править копію і записує її
/// по «Ок», а по «Скасувати» просто викидає — як в оригіналі.
public struct NumberingBase: Sendable {

    public var standards: [NumberingStandard]
    /// Скорочення модуля → код стандарту. Ключі порівнюємо без урахування регістру.
    public var modules: [String: String]
    public var rules: [NumberingRule]

    public init(standards: [NumberingStandard] = [],
                modules: [String: String] = [:],
                rules: [NumberingRule] = []) {
        self.standards = standards
        self.modules = modules
        self.rules = rules
    }

    public var isEmpty: Bool { standards.isEmpty && modules.isEmpty && rules.isEmpty }

    // MARK: - Де лежить

    /// Своя копія бази. Файл автора лежить у теці програми і належить
    /// користувачеві — писати в нього не можна, тому правки йдуть сюди.
    public static var userURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Slovo/inconsistencies.sqlite3")
    }

    /// Файл автора поруч із модулями — лише для читання.
    public static func originalURL(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("inconsistencies.sqlite3")
    }

    /// Читаємо свою копію, якщо вона є, інакше базу оригіналу.
    public static func load(dataRoot: URL?) -> NumberingBase {
        let manager = FileManager.default
        if manager.fileExists(atPath: userURL.path), let mine = try? load(from: userURL) {
            return mine
        }
        if let dataRoot {
            let original = originalURL(dataRoot: dataRoot)
            if manager.fileExists(atPath: original.path), let theirs = try? load(from: original) {
                return theirs
            }
        }
        return NumberingBase()
    }

    // MARK: - Читання

    public enum NumberingError: Error {
        case cannotOpen(String)
        case cannotWrite(String)
    }

    public static func load(from url: URL) throws -> NumberingBase {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw NumberingError.cannotOpen(url.lastPathComponent)
        }
        defer { sqlite3_close(handle) }

        var base = NumberingBase()

        each(handle, "SELECT lng, description FROM t_info") { row in
            guard let code = text(row, 0), !code.isEmpty else { return }
            base.standards.append(NumberingStandard(code: code, description: text(row, 1) ?? code))
        }
        base.standards.sort { $0.code < $1.code }

        each(handle, "SELECT name, lng FROM modules") { row in
            guard let name = text(row, 0), let code = text(row, 1) else { return }
            base.modules[name.lowercased()] = code
        }

        let columns = """
            SELECT lng_from, lng_to, type, book_from, chapter_from_begin, chapter_from_end, \
            verse_from_begin, verse_from_end, chapter_to_begin, chapter_to_end, \
            verse_to_begin, verse_to_end FROM bibletrans
            """
        each(handle, columns) { row in
            guard let from = text(row, 0), let to = text(row, 1),
                  let type = text(row, 2), let kind = NumberingRuleKind(rawValue: type),
                  let book = number(row, 3), let chapter = number(row, 4) else { return }
            base.rules.append(NumberingRule(from: from, to: to, kind: kind, book: book,
                                            chapterBegin: chapter,
                                            chapterEnd: number(row, 5),
                                            verseBegin: number(row, 6),
                                            verseEnd: number(row, 7),
                                            chapterTo: number(row, 8),
                                            chapterToEnd: number(row, 9),
                                            verseTo: number(row, 10),
                                            verseToEnd: number(row, 11)))
        }
        return base
    }

    private static func each(_ handle: OpaquePointer, _ sql: String,
                             _ body: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { body(statement) }
    }

    private static func text(_ row: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(row, index) else { return nil }
        return String(cString: raw)
    }

    /// Порожній рядок у базі автора означає «не задано», і відрізняти його від нуля
    /// обов'язково: зсув 0 — це правило, яке нічого не міняє.
    private static func number(_ row: OpaquePointer, _ index: Int32) -> Int? {
        if sqlite3_column_type(row, index) == SQLITE_NULL { return nil }
        if let raw = sqlite3_column_text(row, index) {
            let value = String(cString: raw).trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return nil }
            return Int(value)
        }
        return Int(sqlite3_column_int64(row, index))
    }

    // MARK: - Запис

    /// Пишемо свою копію цілком і тією самою схемою, що в автора: щоб файл
    /// відкривався і оригіналом, якщо власник вирішить перенести правки назад.
    public func save(to url: URL = NumberingBase.userURL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("inconsistencies-\(UUID().uuidString).sqlite3")

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(temporary.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw NumberingError.cannotWrite(url.lastPathComponent)
        }

        func run(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw NumberingError.cannotWrite(String(cString: sqlite3_errmsg(handle)))
            }
        }

        do {
            try run("""
                CREATE TABLE bibletrans (lng_from TEXT, lng_to TEXT, type TEXT, book_from INTEGER, \
                chapter_from_begin INTEGER, chapter_from_end INTEGER, verse_from_begin INTEGER, \
                verse_from_end INTEGER, chapter_to_begin INTEGER, chapter_to_end INTEGER, \
                verse_to_begin INTEGER, verse_to_end INTEGER);
                CREATE UNIQUE INDEX idx1 ON bibletrans (lng_from, lng_to, type, book_from, \
                chapter_from_begin, verse_from_begin, verse_from_end, chapter_from_end);
                CREATE TABLE modules (name TEXT UNIQUE NOT NULL, lng TEXT NOT NULL);
                CREATE INDEX Index0 ON modules (name, lng);
                CREATE TABLE t_info (lng TEXT PRIMARY KEY UNIQUE NOT NULL, description TEXT);
                """)
            try run("BEGIN")
            for standard in standards {
                try run("INSERT OR REPLACE INTO t_info (lng, description) VALUES ("
                        + quote(standard.code) + ", " + quote(standard.description) + ")")
            }
            for (name, code) in modules.sorted(by: { $0.key < $1.key }) {
                try run("INSERT OR REPLACE INTO modules (name, lng) VALUES ("
                        + quote(name) + ", " + quote(code) + ")")
            }
            for rule in rules {
                let values = [quote(rule.from), quote(rule.to), quote(rule.kind.rawValue),
                              "\(rule.book)", "\(rule.chapterBegin)",
                              cell(rule.chapterEnd), cell(rule.verseBegin), cell(rule.verseEnd),
                              cell(rule.chapterTo), cell(rule.chapterToEnd),
                              cell(rule.verseTo), cell(rule.verseToEnd)]
                try run("INSERT OR REPLACE INTO bibletrans VALUES (" + values.joined(separator: ", ") + ")")
            }
            try run("COMMIT")
        } catch {
            sqlite3_close(handle)
            try? manager.removeItem(at: temporary)
            throw error
        }
        sqlite3_close(handle)

        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
    }

    /// В автора «не задано» записано порожнім рядком, а не NULL, — повторюємо.
    private func cell(_ value: Int?) -> String { value.map { "\($0)" } ?? "''" }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: - Стандарт модуля

    /// Стандарт нумерації модуля шукаємо за його скороченням та ім'ям файлу:
    /// у базі автора записано скорочення (`BW`, `UBT2020`, `МСЦ'22`).
    public func standardCode(forModuleNames names: [String]) -> String? {
        for name in names {
            let key = name.lowercased()
            if let code = modules[key] { return code }
        }
        for name in names {
            if let near = ModuleNameMatch.nearest(name, among: Array(modules.keys)),
               let code = modules[near] { return code }
        }
        return nil
    }

}

/// Зіставлення імені модуля з рядком чужої таблиці, коли в імені описка.
///
/// У базі нумерації у власника рядок названо `ua_ogienka`, а тека перекладу
/// — `UA_Ogienko`: одна літера. Поки імена звірялися точно, переклад Огієнка
/// лишався без стандарту з таблиці автора і розбирався по книгах заново.
///
/// Правило навмисно вузьке, і ось чому. Різниця в один знак буває і в РІЗНИХ
/// перекладів: `ubt2020` і `ubt2022` — теж одна правка. Тому пов'язуємо
/// лише тоді, коли розходяться літери, а не цифри, довжина збігається, ім'я не
/// коротше за п'ять знаків і підхожий рядок рівно один. Усе інше — не
/// описка, а інше ім'я, і пов'язувати його означало б мовчки показати в залі
/// чужі номери віршів.
public enum ModuleNameMatch {

    public static func nearest(_ name: String, among keys: [String]) -> String? {
        let key = name.lowercased()
        guard key.count >= 5 else { return nil }
        let near = keys.filter { differsByOneLetter($0, key) }
        return near.count == 1 ? near[0] : nil
    }

    /// Та сама довжина і рівно одне розходження, причому обидві розбіжні літери —
    /// не цифри.
    static func differsByOneLetter(_ one: String, _ two: String) -> Bool {
        let a = Array(one), b = Array(two)
        guard a.count == b.count else { return false }
        var difference: (Character, Character)?
        for (left, right) in zip(a, b) where left != right {
            if difference != nil { return false }
            difference = (left, right)
        }
        guard let (left, right) = difference else { return false }
        return !left.isNumber && !right.isNumber
    }
}
