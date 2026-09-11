import Foundation

/// Елемент плану служіння — одна зупинка в порядку подачі: біблійний
/// уривок, частина пісні або довільний текст модуля «Текст».
///
/// У перших двох у плані лежить посилання, а не текст. Текст живе в модулях і
/// пісенниках; якщо користувач оновить модуль або поправить пісню, план
/// зобов'язаний показати новий вміст, а не законсервовану копію, зняту
/// при складанні.
///
/// Пункту «Текст» посилатися нема на що: оголошення набрано просто в полі (25)
/// і ніде більше не зберігається. Тому він — єдиний, хто везе свій
/// вміст із собою (див. `PlainTextDocument`).
public struct PlanItem: Sendable, Hashable, Identifiable {

    /// Тип пункту окремим переліком, а не розбором `content`: за ним
    /// будуються значок у списку, фільтри і пункти меню додавання.
    public enum Kind: String, Sendable, Codable, CaseIterable, Identifiable {
        case scripture
        case song
        case text

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .scripture: return OurWords.t("Отрывок")
            case .song:      return OurWords.t("Песня")
            case .text:      return OurWords.t("Текст")
            }
        }
    }

    /// Посилання на біблійний уривок.
    ///
    /// Книга зберігається індексом, а не назвою: порядок книг у перекладів спільний,
    /// а назви і скорочення різні. За індексом уривок знаходиться в будь-якому
    /// модулі, навіть якщо план збирали в іншому перекладі.
    public struct Scripture: Sendable, Hashable {
        public var moduleID: String
        public var bookIndex: Int
        public var chapter: Int
        /// Порожній список означає «розділ цілком».
        public var verses: [Int]

        public init(moduleID: String, bookIndex: Int, chapter: Int, verses: [Int] = []) {
            self.moduleID = moduleID
            self.bookIndex = bookIndex
            self.chapter = chapter
            self.verses = verses
        }
    }

    /// Посилання на частину пісні.
    public struct SongPartReference: Sendable, Hashable {
        /// Ім'я файлу пісенника без шляху: теку з модулями користувач вільний
        /// перенести або перепідключити, а ім'я файлу переїзд переживає.
        public var bookFileName: String
        public var songIndex: Int
        public var partIndex: Int?

        public init(bookFileName: String, songIndex: Int, partIndex: Int? = nil) {
            self.bookFileName = bookFileName
            self.songIndex = songIndex
            self.partIndex = partIndex
        }
        /// Порожній — пісня цілком: в автора пісню кладуть у план одним пунктом,
        /// а частини гортають уже при показі; частина кладеться окремо (5.3.3).
        public var isWholeSong: Bool { partIndex == nil }
    }

    public enum Content: Sendable, Hashable {
        case scripture(Scripture)
        case song(SongPartReference)
        /// Довільний текст модуля «Текст» — кнопка `SBAddTextToPlan` (24).
        case text(PlainTextDocument)
    }

    public var id: UUID
    /// Підпис у списку: «Ів 3:16-18», «Великий Бог — Куплет 1».
    public var title: String
    /// Початок тексту цитати — друга половина рядка списку.
    ///
    /// На знімку посібника (5.1.10) рядок плану виглядає як
    /// «1Кор. 11:23-32 - Ибо я от Самого Господа принял то, что…»: адреса і
    /// одразу за нею початок самої цитати, в один рядок. Тому тут лежить
    /// саме текст, а не назва перекладу: знімати його при подачі в список
    /// не можна — це читання модуля в головному потоці на кожну перемальовку.
    public var subtitle: String?
    public var content: Content

    public init(id: UUID = UUID(), title: String, subtitle: String? = nil, content: Content) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    public var kind: Kind {
        switch content {
        case .scripture: return .scripture
        case .song:      return .song
        case .text:      return .text
        }
    }

    public var scripture: Scripture? {
        if case .scripture(let value) = content { return value }
        return nil
    }

    public var songPart: SongPartReference? {
        if case .song(let value) = content { return value }
        return nil
    }

    public var plainText: PlainTextDocument? {
        if case .text(let value) = content { return value }
        return nil
    }

    // MARK: - Збирання пунктів

    /// Пункт з поточного положення курсора по тексту.
    ///
    /// `quote` — початок тексту уривка; він і стане другою половиною рядка
    /// списку. Береться в момент додавання, коли вірш уже розібрано і він лежить
    /// перед очима, а не при малюванні плану.
    public static func scripture(moduleID: String,
                                 book: BookInfo,
                                 chapter: Int,
                                 verses: [Int],
                                 quote: String? = nil) -> PlanItem {
        PlanItem(title: reference(book: book, chapter: chapter, verses: verses),
                 subtitle: shorten(quote),
                 content: .scripture(Scripture(moduleID: moduleID,
                                               bookIndex: book.index,
                                               chapter: chapter,
                                               verses: verses.sorted())))
    }

    /// Пункт із частини пісні. Ім'я файлу беремо у збірника, а не в пісні: шукати
    /// пісенник при відкритті плану будемо саме за ним.
    public static func songPart(bookFileName: String,
                                song: Song,
                                part: SongPart) -> PlanItem {
        let name = song.title.isEmpty ? "Песня \(song.index + 1)" : song.title
        let kind = part.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlanItem(title: kind.isEmpty ? name : "\(name) — \(kind)",
                        subtitle: shorten(part.lines.joined(separator: " ")),
                        content: .song(SongPartReference(bookFileName: bookFileName,
                                                         songIndex: song.index,
                                                         partIndex: part.index)))
    }

    public static func songPart(bookFile: URL, book: SongBook, song: Song, part: SongPart) -> PlanItem {
        songPart(bookFileName: bookFile.lastPathComponent, song: song, part: part)
    }

    /// Пісня цілком — один пункт плану. Власник побачив: «при добавлении
    /// песни вместо песни добавляются куплеты» — план засипало частинами.
    public static func song(bookFileName: String, song: Song) -> PlanItem {
        let name = song.title.isEmpty ? "Песня \(song.index + 1)" : song.title
        let first = song.parts.first?.lines.joined(separator: " ")
        return PlanItem(title: name, subtitle: shorten(first),
                        content: .song(SongPartReference(bookFileName: bookFileName,
                                                         songIndex: song.index, partIndex: nil)))
    }

    /// Початок цитати для рядка списку: довше за один рядок у вузькій панелі
    /// плану все одно не видно, а тягати у файлі весь уривок нема чого.
    static func shorten(_ text: String?, limit: Int = 160) -> String? {
        guard let text else { return nil }
        let single = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !single.isEmpty else { return nil }
        return single.count <= limit ? single : String(single.prefix(limit)) + "…"
    }

    /// Усі частини пісні підряд — звичайний спосіб поставити пісню в план цілком.
    public static func songParts(bookFile: URL, book: SongBook, song: Song) -> [PlanItem] {
        song.parts.map { songPart(bookFile: bookFile, book: book, song: song, part: $0) }
    }

    /// Кнопка «Додати в План» (24, `SBAddTextToPlan`) модуля «Текст».
    ///
    /// Підпис рядка — заголовок і початок тексту: два оголошення з одним і
    /// тим самим заголовком у списку інакше не розрізнити. Якщо заголовка немає,
    /// рядком стає сам початок тексту.
    public static func text(_ document: PlainTextDocument, subtitle: String? = nil) -> PlanItem {
        let summary = document.summary(limit: 80)
        return PlanItem(title: summary.isEmpty ? Kind.text.title : summary,
                        subtitle: subtitle,
                        content: .text(document))
    }

    // MARK: - Посилання в тексті

    /// «Ів 3:16-18» — те саме, що показує рядок посилання на слайді.
    public static func reference(book: BookInfo, chapter: Int, verses: [Int]) -> String {
        let name = book.shortNames.first ?? book.fullName
        let numbers = formatVerses(verses)
        return numbers.isEmpty ? "\(name) \(chapter)" : "\(name) \(chapter):\(numbers)"
    }

    /// Вірші, що йдуть підряд, згортаються в діапазон: 1,2,3,7 → «1-3,7».
    public static func formatVerses(_ verses: [Int]) -> String {
        let sorted = Array(Set(verses.filter { $0 >= 0 })).sorted()
        guard !sorted.isEmpty else { return "" }

        var groups: [String] = []
        var start = sorted[0]
        var previous = sorted[0]

        for number in sorted.dropFirst() {
            if number == previous + 1 { previous = number; continue }
            groups.append(start == previous ? "\(start)" : "\(start)-\(previous)")
            start = number
            previous = number
        }
        groups.append(start == previous ? "\(start)" : "\(start)-\(previous)")
        return groups.joined(separator: ",")
    }

    /// Зворотна операція: «1-3, 7» → [1,2,3,7]. Потрібна, щоб план, набраний
    /// у текстовому редакторі руками, читався нарівні зі збереженим програмою.
    public static func parseVerses(_ text: String) -> [Int] {
        var result: [Int] = []
        for chunk in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
            let parts = chunk.split(separator: "-", maxSplits: 1)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            switch parts.count {
            case 1:
                if let single = parts[0], single >= 0 { result.append(single) }
            case 2:
                guard let from = parts[0], let to = parts[1], from >= 0, to >= from else { continue }
                // Діапазон із чужого файла може бути яким завгодно, а віршів
                // у розділі не тисячі — далі розумного не розгортаємо.
                //
                // Межу рахуємо через віднімання, а не як `from + 1000`:
                // при `from` близько `Int.max` додавання переповнюється і ронить
                // програму просто на відкритті файла плану.
                let span = min(to - from, 1000)
                result.append(contentsOf: from...(from + span))
            default:
                continue
            }
        }
        return result
    }
}

// MARK: - Читання і запис у JSON

/// Формат пункту у файлі плану (див. `ServicePlan` — там описано документ цілком):
///
///     { "type": "scripture", "title": "Ин 3:16-18", "subtitle": "Синодальный",
///       "module": "RST", "book": 42, "chapter": 3, "verses": [16, 17, 18] }
///     { "type": "song", "title": "Великий Бог — Куплет 1", "subtitle": "Песнь возрождения",
///       "songBook": "Песнь возрождения.vbm", "song": 11, "part": 0 }
///     { "type": "text", "title": "Объявление - После служения…",
///       "heading": "Объявление", "body": "После служения — братское общение." }
///
/// Читання навмисно поблажливе: файл людина може поправити в редакторі, і
/// описка в одному пункті не має ронити весь план. Усе, що не розібралося,
/// перетворюється на помилку `unsupportedItem`, а `ServicePlan` такий пункт пропускає.
extension PlanItem: Codable {

    private enum CodingKeys: String, CodingKey {
        case id, type, title, subtitle
        case module, book, chapter, verses      // уривок
        case songBook, song, part               // частина пісні
        case heading, body                      // довільний текст
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString, forKey: .id)
        try container.encode(kind.rawValue, forKey: .type)
        try container.encode(title, forKey: .title)
        if let subtitle, !subtitle.isEmpty { try container.encode(subtitle, forKey: .subtitle) }

        switch content {
        case .scripture(let reference):
            try container.encode(reference.moduleID, forKey: .module)
            try container.encode(reference.bookIndex, forKey: .book)
            try container.encode(reference.chapter, forKey: .chapter)
            try container.encode(reference.verses, forKey: .verses)
        case .song(let reference):
            try container.encode(reference.bookFileName, forKey: .songBook)
            try container.encode(reference.songIndex, forKey: .song)
            try container.encode(reference.partIndex, forKey: .part)
        case .text(let document):
            // Заголовок пишемо завжди, навіть порожній: без ключа `heading` пункт
            // без заголовка при читанні не відрізнити від пункту, де заголовок
            // загубили, — а за ним визначається тип пункту без поля `type`.
            try container.encode(document.title, forKey: .heading)
            try container.encode(document.body, forKey: .body)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let declared = (Self.string(container, .type) ?? "").lowercased()
        let looksLikeSong = container.contains(.songBook) || container.contains(.song) || container.contains(.part)
        let looksLikeText = container.contains(.body) || container.contains(.heading)
        let content: Content

        switch declared {
        case "scripture", "bible", "verse", "verses":
            content = .scripture(try Self.decodeScripture(container))
        case "song", "songpart", "song-part":
            content = .song(try Self.decodeSong(container))
        case "text", "plaintext", "plain-text":
            content = .text(Self.decodeText(container))
        case "":
            // Тип не написано — визначаємо за набором полів: так читається план,
            // набраний вручну за зразком сусіднього пункту.
            if looksLikeText {
                content = .text(Self.decodeText(container))
            } else {
                content = looksLikeSong
                    ? .song(try Self.decodeSong(container))
                    : .scripture(try Self.decodeScripture(container))
            }
        default:
            throw PlanError.unsupportedItem(OurWords.t("неизвестный тип пункта «%s»", "\(declared)"))
        }

        let title = Self.string(container, .title)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(id: Self.string(container, .id).flatMap(UUID.init(uuidString:)) ?? UUID(),
                  title: title.isEmpty ? Self.fallbackTitle(for: content) : title,
                  subtitle: Self.string(container, .subtitle),
                  content: content)
    }

    private static func decodeScripture(_ container: KeyedDecodingContainer<CodingKeys>) throws -> Scripture {
        guard let book = number(container, .book), book >= 0 else {
            throw PlanError.unsupportedItem(OurWords.t("у отрывка нет номера книги"))
        }
        // Розділ 0 законний: у деяких модулях нумерація починається з нуля.
        guard let chapter = number(container, .chapter), chapter >= 0 else {
            throw PlanError.unsupportedItem(OurWords.t("у отрывка нет главы"))
        }
        return Scripture(moduleID: string(container, .module) ?? "",
                         bookIndex: book,
                         chapter: chapter,
                         verses: verses(container))
    }

    private static func decodeSong(_ container: KeyedDecodingContainer<CodingKeys>) throws -> SongPartReference {
        guard let file = string(container, .songBook), !file.isEmpty else {
            throw PlanError.unsupportedItem(OurWords.t("у части песни не указан песенник"))
        }
        guard let song = number(container, .song), song >= 0,
              let part = number(container, .part), part >= 0 else {
            throw PlanError.unsupportedItem(OurWords.t("у части песни нет номера песни или части"))
        }
        return SongPartReference(bookFileName: file, songIndex: song, partIndex: part)
    }

    /// Текст нічого «не розбирає»: порожній пункт — законний, його і покаже
    /// порожній слайд. Тому тут немає `throw`, на відміну від уривка і пісні.
    private static func decodeText(_ container: KeyedDecodingContainer<CodingKeys>) -> PlainTextDocument {
        PlainTextDocument(title: string(container, .heading) ?? "",
                          body: string(container, .body) ?? "")
    }

    private static func fallbackTitle(for content: Content) -> String {
        switch content {
        case .scripture(let reference):
            let numbers = formatVerses(reference.verses)
            return numbers.isEmpty
                ? OurWords.t("Отрывок, глава %s", "\(reference.chapter)")
                : OurWords.t("Отрывок %s:%s", "\(reference.chapter)", "\(numbers)")
        case .song(let reference):
            if let part = reference.partIndex {
                return "Песня \(reference.songIndex + 1), часть \(part + 1)"
            }
            return "Песня \(reference.songIndex + 1)"
        case .text(let document):
            let summary = document.summary(limit: 80)
            return summary.isEmpty ? Kind.text.title : summary
        }
    }

    // Значення могли записати не тим типом — «3» замість 3 і навпаки.
    // Заради однієї описки втрачати пункт нема чого.

    private static func string(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
        return nil
    }

    private static func number(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        // `Int(value)` для дробового поза діапазоном Int — це не помилка, а
        // аварійне завершення, тому межі перевіряємо до перетворення.
        if let value = try? container.decode(Double.self, forKey: key), value.isFinite,
           value >= Double(Int.min), value <= Double(Int.max) {
            return Int(value)
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func verses(_ container: KeyedDecodingContainer<CodingKeys>) -> [Int] {
        if let list = try? container.decode([Int].self, forKey: .verses) {
            return list.filter { $0 >= 0 }.sorted()
        }
        // «16-18» рядком — найзручніший спосіб вписати уривок руками.
        if let text = try? container.decode(String.self, forKey: .verses) {
            return parseVerses(text).sorted()
        }
        if let single = try? container.decode(Int.self, forKey: .verses), single >= 0 {
            return [single]
        }
        return []
    }
}

// MARK: - Розв'язання посилань у справжній текст

public extension PlanItem.Scripture {

    /// Книга цього уривка у вказаному модулі — nil, якщо книг у ньому менше
    /// (так буває в модулів, де лише Новий Заповіт).
    func book(in module: any TextModule) -> BookInfo? {
        module.books.indices.contains(bookIndex) ? module.books[bookIndex] : nil
    }

    /// Вірші уривка. Порожній список у посиланні означає «весь розділ», тому
    /// тут він розгортається у справжні вірші.
    func verses(in module: any TextModule) -> [Verse] {
        guard let book = book(in: module),
              let chapter = try? module.chapter(self.chapter, ofBook: book) else { return [] }
        guard !verses.isEmpty else { return chapter.verses }
        return verses.sorted().compactMap { chapter.verse($0) }
    }

    /// Готовий текст уривка — те, що піде на слайд.
    func text(in module: any TextModule, withNumbers: Bool = false) -> String? {
        let found = verses(in: module)
        guard !found.isEmpty else { return nil }
        return found
            .map { withNumbers ? "\($0.number) \($0.text)" : $0.text }
            .joined(separator: " ")
    }
}

public extension PlanItem.SongPartReference {

    /// Файл пісенника серед знайдених у теці модулів. Порівнюємо без урахування
    /// регістру: імена збірників набирали у Windows, там регістр не значущий.
    func file(among files: [URL]) -> URL? {
        files.first { $0.lastPathComponent.caseInsensitiveCompare(bookFileName) == .orderedSame }
    }

    func song(in book: SongBook) -> Song? {
        book.songs.indices.contains(songIndex) ? book.songs[songIndex] : nil
    }

    func part(in book: SongBook) -> SongPart? {
        guard let song = song(in: book), let partIndex, song.parts.indices.contains(partIndex) else { return nil }
        return song.parts[partIndex]
    }
}
