import Foundation

/// Рядок Історії (11) — розділ 5.1.11 посібника.
///
/// «В историю заносятся адреса всех стихов, которые были первыми показаны в
/// окне слайда после их выбора.» Тому запис зберігає не лише адресу, а й
/// усе, чим це місце потім відкривається заново: клас, номер книги, розділ і
/// вірші, а для пісні — файл збірника, номер пісні і номер частини.
///
/// Склад полів узято з `History.ini` оригіналу: там у пункту є Caption,
/// Reference, Quote, Class, Book, Chapter, Verse, ModuleShortName,
/// ModuleShortNameSecond, ShortName, FullName і VersesRangeCount. Тримаємо той
/// самий набір, щоб історія читалася і записувалася у файл того самого вигляду.
public struct HistoryRecord: Sendable, Hashable, Identifiable {

    /// Журнал, у який пункт потрапляє: в оригіналу історія ведеться окремо
    /// для кожної вкладки модулів (18).
    public enum Kind: Sendable, Hashable {
        case bible
        case text
        case song

        public var section: JournalFile.Section {
            switch self {
            case .bible: return .bible
            case .text:  return .text
            case .song:  return .songs
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Рядок списку цілком — «Быт.- В начале сотворил Бог небо и землю.»
    public var caption: String
    /// Адреса місця Писання в тому вигляді, в якому вона пішла на слайд.
    public var reference: String
    /// Текст показаного — вірш, частина пісні або оголошення.
    public var quote: String

    // Місце Писання
    public var bookClass: Int
    public var bookIndex: Int
    public var chapter: Int
    public var verses: [Int]
    public var moduleShortName: String
    public var moduleShortNameSecond: String
    /// Скорочення книги через кому — так їх зберігає оригінал.
    public var shortNames: String
    public var fullName: String

    // Частина пісні
    public var songBookFileName: String
    public var songIndex: Int
    public var partIndex: Int

    public init(kind: Kind,
                caption: String = "",
                reference: String = "",
                quote: String = "",
                bookClass: Int = 0,
                bookIndex: Int = 0,
                chapter: Int = 0,
                verses: [Int] = [],
                moduleShortName: String = "",
                moduleShortNameSecond: String = "",
                shortNames: String = "",
                fullName: String = "",
                songBookFileName: String = "",
                songIndex: Int = 0,
                partIndex: Int = 0,
                id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.reference = reference
        self.quote = quote
        self.caption = caption.isEmpty ? Self.caption(reference: reference, quote: quote) : caption
        self.bookClass = bookClass
        self.bookIndex = bookIndex
        self.chapter = chapter
        self.verses = verses
        self.moduleShortName = moduleShortName
        self.moduleShortNameSecond = moduleShortNameSecond
        self.shortNames = shortNames
        self.fullName = fullName
        self.songBookFileName = songBookFileName
        self.songIndex = songIndex
        self.partIndex = partIndex
    }

    /// Підпис рядка рівно як у файлі оригіналу: «Руф.- В те дни, когда…».
    /// Між адресою і текстом стоїть дефіс без пробілу зліва — так в автора.
    public static func caption(reference: String, quote: String) -> String {
        let text = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if reference.isEmpty { return text }
        return text.isEmpty ? reference : "\(reference)- \(text)"
    }

    /// Ключ повтору: те саме місце підряд другим рядком не заводиться.
    public var identity: String {
        switch kind {
        case .bible: return "b:\(bookIndex):\(chapter):\(verses.map(String.init).joined(separator: ","))"
        case .song:  return "s:\(songBookFileName):\(songIndex):\(partIndex)"
        case .text:  return "t:\(caption)"
        }
    }
}

/// Історія (11) цілком, разом із читанням і записом у файл оригіналу.
///
/// «Оригінал історію зберігає між запусками»: у користувача поруч із
/// програмою лежить `History.ini` у форматі `<JournalFile>`. Читаємо ми і
/// його, і свій файл, а пишемо лише у свій — чужу установку на запис не
/// чіпаємо.
public struct ServiceHistory: Sendable, Hashable {

    /// Ім'я файлу — те саме, що в оригіналу.
    public static let fileName = "History.ini"
    /// Скільки рядків тримаємо. В оригіналу список теж не нескінченний.
    public static let limit = 60

    public private(set) var records: [HistoryRecord] = []

    public init(records: [HistoryRecord] = []) {
        self.records = records
    }

    public var isEmpty: Bool { records.isEmpty }
    public var count: Int { records.count }

    /// Нове місце нагору списку. Повтор того самого місця одразу за собою не
    /// заводиться, а знайдений нижче — піднімається нагору, як в оригіналі.
    public mutating func remember(_ record: HistoryRecord) {
        let key = record.identity
        if records.first?.identity == key { return }
        records.removeAll { $0.identity == key }
        records.insert(record, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
    }

    public mutating func remove(id: UUID) {
        records.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        records.removeAll()
    }

    // MARK: - Файл

    public static func read(contentsOf url: URL) -> ServiceHistory {
        guard let journal = try? JournalFile.read(contentsOf: url) else { return ServiceHistory() }
        return ServiceHistory(journal: journal)
    }

    public init(journal: JournalFile) {
        var result: [HistoryRecord] = []
        for item in journal[.bible] { result.append(Self.bibleRecord(item)) }
        for item in journal[.songs] { result.append(Self.songRecord(item)) }
        for item in journal[.text] { result.append(Self.textRecord(item)) }
        self.init(records: Array(result.prefix(Self.limit)))
    }

    public func journal() -> JournalFile {
        var journal = JournalFile()
        for record in records {
            journal.items[record.kind.section, default: []].append(item(for: record))
        }
        return journal
    }

    public func write(to url: URL) throws {
        try journal().write(to: url)
    }

    // MARK: - Пункт файла

    private func item(for record: HistoryRecord) -> JournalFile.Item {
        switch record.kind {
        case .bible:
            // Порядок та імена полів — як у History.ini оригіналу. Номери
            // розділу і вірша там рахуються з нуля, а довжина уривка записана
            // окремим полем VersesRangeCount.
            let first = record.verses.first ?? 1
            return JournalFile.Item([
                ("Caption", record.caption),
                ("Reference", record.reference),
                ("Quote", record.quote),
                ("Class", "\(record.bookClass)"),
                ("Book", "\(record.bookIndex)"),
                ("Chapter", "\(max(record.chapter - 1, 0))"),
                ("Verse", "\(max(first - 1, 0))"),
                ("QuoteFont", ""),
                ("QuoteCharSet", "512"),
                ("ModuleShortName", record.moduleShortName),
                ("ModuleShortNameSecond", record.moduleShortNameSecond),
                ("ShortName", record.shortNames),
                ("FullName", record.fullName),
                ("VersesRangeCount", "\(max(record.verses.count - 1, 0))"),
            ])
        case .song:
            return JournalFile.Item([
                ("Caption", record.caption),
                ("Reference", record.reference),
                ("Quote", record.quote),
                ("SongBook", record.songBookFileName),
                ("Song", "\(record.songIndex)"),
                ("Part", "\(record.partIndex)"),
            ])
        case .text:
            return JournalFile.Item([
                ("Caption", record.caption),
                ("Reference", record.reference),
                ("Quote", record.quote),
            ])
        }
    }

    private static func bibleRecord(_ item: JournalFile.Item) -> HistoryRecord {
        let chapter = (item.int("Chapter") ?? 0) + 1
        let first = (item.int("Verse") ?? 0) + 1
        let extra = max(item.int("VersesRangeCount") ?? 0, 0)
        // Уривок у файлі задано першим віршем і довжиною; більшим за розділ він бути
        // не може, і чуже число сюди краще не пускати.
        let verses = Array(first...(first + min(extra, 400)))

        return HistoryRecord(kind: .bible,
                             caption: item.string("Caption"),
                             reference: item.string("Reference"),
                             quote: item.string("Quote"),
                             bookClass: item.int("Class") ?? 0,
                             bookIndex: item.int("Book") ?? 0,
                             chapter: chapter,
                             verses: verses,
                             moduleShortName: item.string("ModuleShortName"),
                             moduleShortNameSecond: item.string("ModuleShortNameSecond"),
                             shortNames: item.string("ShortName"),
                             fullName: item.string("FullName"))
    }

    private static func songRecord(_ item: JournalFile.Item) -> HistoryRecord {
        HistoryRecord(kind: .song,
                      caption: item.string("Caption"),
                      reference: item.string("Reference"),
                      quote: item.string("Quote"),
                      songBookFileName: item.string("SongBook"),
                      songIndex: item.int("Song") ?? 0,
                      partIndex: item.int("Part") ?? 0)
    }

    private static func textRecord(_ item: JournalFile.Item) -> HistoryRecord {
        HistoryRecord(kind: .text,
                      caption: item.string("Caption"),
                      reference: item.string("Reference"),
                      quote: item.string("Quote"))
    }
}
