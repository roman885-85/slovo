import Foundation

/// Знайдена пісня і те, чим саме вона підійшла під запит.
public struct SongMatch: Sendable, Hashable, Identifiable {
    public enum Reason: Sendable, Hashable {
        case listing         // запиту не було — це просто весь збірник
        case number          // збігся номер у збірнику
        case catalogNumber   // збігся `$ID$` з властивостей пісні
        case title
        case alternateTitle
        case author
    }

    public let song: Song
    public let reason: Reason

    /// Номер пісні у збірнику — те, що оператор набирає на цифрах.
    public var number: Int { song.number }
    public var id: Int { song.index }

    public init(song: Song, reason: Reason) {
        self.song = song
        self.reason = reason
    }
}

extension Song {
    /// Номер пісні — її позиція у збірнику, рахуючи з одиниці. Саме так
    /// нумерує пісні старої програми, і за цим номером їх шукають у залі.
    public var number: Int { index + 1 }

    /// Властивості пісні — рядки виду `$ID$=1728`, `$TUNE$=`.
    public var propertyPairs: [String: String] {
        var result: [String: String] = [:]
        for line in properties.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("$"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eq])
            result[key] = String(trimmed[trimmed.index(after: eq)...])
        }
        return result
    }

    /// Номер з `$ID$`. У більшості збірників він збігається з позицією, але,
    /// наприклад, у `lepel.vbm` розходиться в 74 пісень із 78 — там номер з
    /// друкованого збірника, а не порядок у файлі.
    public var catalogNumber: Int? {
        propertyPairs["$ID$"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Перший непорожній рядок першої частини — за ним пісню впізнають, коли
    /// назва нічого не каже.
    public var firstLine: String {
        for part in parts {
            for line in part.lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}

/// Як підписувати пісню в списку. Налаштування з `[settings]`:
/// `SongNameWithNumInCollection`, `SongNameDotAfterNum`,
/// `SongNameWithNumInCollectionInBrackets`.
public struct SongTitleFormat: Sendable, Hashable {
    public var showsNumber: Bool
    public var dotAfterNumber: Bool
    public var numberInBrackets: Bool

    public init(showsNumber: Bool = true, dotAfterNumber: Bool = true, numberInBrackets: Bool = false) {
        self.showsNumber = showsNumber
        self.dotAfterNumber = dotAfterNumber
        self.numberInBrackets = numberInBrackets
    }

    public init(config: IniSettings) {
        self.init(showsNumber: config.bool("SongNameWithNumInCollection", in: "settings") ?? true,
                  dotAfterNumber: config.bool("SongNameDotAfterNum", in: "settings") ?? true,
                  numberInBrackets: config.bool("SongNameWithNumInCollectionInBrackets", in: "settings") ?? false)
    }

    public func number(_ number: Int) -> String {
        if numberInBrackets { return "(\(number))" }
        return dotAfterNumber ? "\(number)." : "\(number)"
    }

    public func title(of song: Song) -> String {
        guard showsNumber else { return song.title }
        return "\(number(song.number)) \(song.title)"
    }
}

/// Каталог пісенників з лінивим завантаженням.
///
/// Файли великі: `pv3400.vbm` — це 3400 пісень і 17 тисяч частин, а таких
/// збірників у користувача два десятки. Читати їх усі при старті — це
/// секунди очікування і десятки мегабайтів марно, тому збірник відкривається
/// лише коли його вибрали, і в пам'яті тримається лише кілька останніх.
/// Так само поводиться й оригінал — у нього це `LazyLoadModule=1`.
public final class SongLibrary {

    /// Пісенник у каталозі. Поки файл не відкрито, про нього відомо лише ім'я.
    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: String            // ім'я файлу без розширення
        public let url: URL
        public var title: String         // до завантаження — ім'я файлу
        public var shortName: String
        public var publisher: String
        public var revisionDate: String
        public var comment: String
        public var songCount: Int?       // відомо лише після завантаження
        public var isLoaded: Bool
        public var failure: String?

        public var displayName: String { title.isEmpty ? id : title }

        public init(id: String, url: URL, title: String = "", shortName: String = "",
                    publisher: String = "", revisionDate: String = "", comment: String = "",
                    songCount: Int? = nil, isLoaded: Bool = false, failure: String? = nil) {
            self.id = id
            self.url = url
            self.title = title.isEmpty ? id : title
            self.shortName = shortName
            self.publisher = publisher
            self.revisionDate = revisionDate
            self.comment = comment
            self.songCount = songCount
            self.isLoaded = isLoaded
            self.failure = failure
        }
    }

    public private(set) var books: [Entry]

    /// Скільки збірників тримаємо відкритими. Три — це вибраний, попередній
    /// і той, куди оператор зазирнув мимохідь; далі витісняємо.
    public var cacheLimit: Int {
        didSet { trimCache() }
    }

    private struct Loaded {
        let book: SongBook
        /// Заголовки, згорнуті для пошуку, — щоб не згортати 3400 рядків
        /// заново на кожне натискання клавіші в полі пошуку.
        let foldedTitles: [String]
        let foldedAlternates: [String]
        let foldedAuthors: [String]
    }

    private var cache: [String: Loaded] = [:]
    private var recent: [String] = []     // найсвіжіший — у кінці

    public init(songFiles: [URL], cacheLimit: Int = 3) {
        self.cacheLimit = max(1, cacheLimit)
        self.books = songFiles
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                Entry(id: url.deletingPathExtension().lastPathComponent,
                      url: url,
                      title: url.deletingPathExtension().lastPathComponent,
                      shortName: "", publisher: "", revisionDate: "", comment: "",
                      songCount: nil, isLoaded: false, failure: nil)
            }
    }

    public convenience init(modulesDirectory: URL, cacheLimit: Int = 3) {
        self.init(songFiles: ModuleLibrary(modulesDirectory: modulesDirectory).songFiles, cacheLimit: cacheLimit)
    }

    // MARK: - Завантаження

    public func entry(_ id: String) -> Entry? {
        books.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Збірник за ім'ям файла — повним або без розширення: План та «Історія»
    /// пам'ятають «pv3055.vbm», а збірник уже лежить як «pv3055.songbook».
    public func entry(fileName: String) -> Entry? {
        if let exact = books.first(where: { $0.url.lastPathComponent.caseInsensitiveCompare(fileName) == .orderedSame }) {
            return exact
        }
        let stem = (fileName as NSString).deletingPathExtension
        return entry(stem)
    }

    private func index(of id: String) -> Int? {
        books.firstIndex { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    /// Уже відкритий збірник, без звертання до диска.
    public func loadedBook(_ id: String) -> SongBook? {
        guard let position = index(of: id) else { return nil }
        return cache[books[position].id]?.book
    }

    /// Відкрити збірник (або повернути вже відкритий). Невдача не кидається
    /// винятком, а лишається в `Entry.failure`: один битий файл у теці не
    /// привід ронити список — у користувача такий є, `UNTTP.vbm`.
    @discardableResult
    public func book(_ id: String) -> SongBook? {
        guard let position = index(of: id) else { return nil }
        let key = books[position].id

        if let loaded = cache[key] {
            touch(key)
            return loaded.book
        }
        do {
            let book = try SongBook(fileAt: books[position].url)
            cache[key] = Loaded(book: book,
                                foldedTitles: book.songs.map { Self.fold($0.title) },
                                foldedAlternates: book.songs.map { Self.fold($0.alternateTitle) },
                                foldedAuthors: book.songs.map { Self.fold($0.author) })
            touch(key)
            trimCache()

            books[position].title = book.title.isEmpty ? key : book.title
            books[position].shortName = book.shortName
            books[position].publisher = book.publisher
            books[position].revisionDate = book.revisionDate
            books[position].comment = book.comment
            books[position].songCount = book.songs.count
            books[position].isLoaded = true
            books[position].failure = nil
            return book
        } catch {
            books[position].isLoaded = false
            books[position].failure = "\(error)"
            return nil
        }
    }

    /// Прийняти вже зібраний у пам'яті Пісенник як вміст запису каталогу.
    ///
    /// Потрібно після збереження з редактора: «Название либо Короткое название
    /// отображаются в названии Песенника на панели Выбора Песенника (33)»
    /// (5.3.9.3), а `unload` назву не чіпає — вона лишилася б колишньою до
    /// наступного відкриття файла. Перечитувати з диска те, що ми щойно
    /// туди записали, нема чого: це зайві секунди на збірнику в 3400 пісень.
    public func adopt(_ book: SongBook, as id: String) {
        guard let position = index(of: id) else { return }
        let key = books[position].id
        cache[key] = Loaded(book: book,
                            foldedTitles: book.songs.map { Self.fold($0.title) },
                            foldedAlternates: book.songs.map { Self.fold($0.alternateTitle) },
                            foldedAuthors: book.songs.map { Self.fold($0.author) })
        touch(key)
        trimCache()

        // Редактор пише у своєму форматі поруч із `.vbm`: відтоді збірник —
        // це `.songbook`, і саме його віддають планшету й експорту.
        if books[position].url.pathExtension.lowercased() == "vbm" {
            let own = books[position].url.deletingPathExtension().appendingPathExtension(SongBookJSON.pathExtension)
            if FileManager.default.fileExists(atPath: own.path) { books[position] = Entry(
                id: key, url: own, title: books[position].title, shortName: books[position].shortName,
                publisher: books[position].publisher, revisionDate: books[position].revisionDate,
                comment: books[position].comment, songCount: books[position].songCount,
                isLoaded: books[position].isLoaded, failure: books[position].failure) }
        }
        books[position].title = book.title.isEmpty ? key : book.title
        books[position].shortName = book.shortName
        books[position].publisher = book.publisher
        books[position].revisionDate = book.revisionDate
        books[position].comment = book.comment
        books[position].songCount = book.songs.count
        books[position].isLoaded = true
        books[position].failure = nil
    }

    public func unload(_ id: String) {
        guard let position = index(of: id) else { return }
        let key = books[position].id
        cache[key] = nil
        recent.removeAll { $0 == key }
        books[position].isLoaded = false
    }

    public func unloadAll() {
        cache.removeAll()
        recent.removeAll()
        for position in books.indices { books[position].isLoaded = false }
    }

    private func touch(_ key: String) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }

    private func trimCache() {
        while recent.count > cacheLimit, let oldest = recent.first {
            recent.removeFirst()
            cache[oldest] = nil
            if let position = index(of: oldest) { books[position].isLoaded = false }
        }
    }

    // MARK: - Доступ до пісень

    public func songs(in id: String) -> [Song] {
        book(id)?.songs ?? []
    }

    /// Пісня за її місцем у збірнику, рахуючи з нуля.
    public func song(at index: Int, in id: String) -> Song? {
        guard let book = book(id), book.songs.indices.contains(index) else { return nil }
        return book.songs[index]
    }

    /// Пісня за номером, як його набирають на цифровій клавіатурі.
    public func song(number: Int, in id: String) -> Song? {
        guard let book = book(id) else { return nil }
        if book.songs.indices.contains(number - 1) { return book.songs[number - 1] }
        // Там, де номер у файлі не збігається з позицією, допомагає `$ID$`.
        return book.songs.first { $0.catalogNumber == number }
    }

    // MARK: - Пошук

    /// Пошук за номером і за підрядком назви.
    ///
    /// Цифровий запит — це номер: спершу точне влучання, потім усе, де
    /// цифри трапляються в номері або в назві. Літерний — підрядок у
    /// назві, у другій назві і в авторі, без урахування регістру і
    /// діакритики (`Śpiewnik` знаходиться за `spiewnik`).
    public func search(_ query: String, in id: String, limit: Int = 300) -> [SongMatch] {
        guard let book = book(id), let position = index(of: id), let loaded = cache[books[position].id] else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Порожній запит — це не «нічого не знайдено», а весь збірник цілком.
        guard !trimmed.isEmpty else {
            return book.songs.map { SongMatch(song: $0, reason: .listing) }
        }

        var result: [SongMatch] = []
        var taken = Set<Int>()

        func add(_ song: Song, _ reason: SongMatch.Reason) {
            guard result.count < limit, taken.insert(song.index).inserted else { return }
            result.append(SongMatch(song: song, reason: reason))
        }

        if let number = Int(trimmed) {
            if book.songs.indices.contains(number - 1) { add(book.songs[number - 1], .number) }
            for song in book.songs where song.catalogNumber == number { add(song, .catalogNumber) }
            for song in book.songs where String(song.number).hasPrefix(trimmed) { add(song, .number) }
        }

        let needle = Self.fold(trimmed)
        guard !needle.isEmpty else { return result }

        for (position, title) in loaded.foldedTitles.enumerated() where title.contains(needle) {
            add(book.songs[position], .title)
        }
        for (position, alternate) in loaded.foldedAlternates.enumerated() where !alternate.isEmpty && alternate.contains(needle) {
            add(book.songs[position], .alternateTitle)
        }
        for (position, author) in loaded.foldedAuthors.enumerated() where !author.isEmpty && author.contains(needle) {
            add(book.songs[position], .author)
        }
        return result
    }

    /// Згортка для пошуку: регістр і діакритика значення не мають, а `ё`
    /// у пісенниках пишуть і так і так.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "е")
    }
}
