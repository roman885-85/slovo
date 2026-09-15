import Foundation
import SQLite3

/// Імпорт Пісенника з чужих форматів — посібник, 5.3.8.3.
/// «Импорт возможен из 2-х источников: BibleQuote модуль, SoftProjector модуль».
public enum SongBookImporter {

    public enum Failure: Error, CustomStringConvertible {
        case cannotOpen(String)
        case notASongSource(String)
        case empty(String)
        /// Файл відкрився, але всередині не те, що очікувалося. Друге поле —
        /// готове пояснення: що знайшли і чого забракло. Мовчазна відмова
        /// операторові не допомагає — він має бачити, на чому саме спіткнулися.
        case unexpectedStructure(String, String)
        /// Пісенник новіший, ніж розуміє розбір (у SoftProjector це
        /// `PRAGMA user_version`).
        case unsupportedVersion(String, Int)

        public var description: String {
            switch self {
            case .cannotOpen(let name):    return OurWords.t("Не удалось открыть файл модуля.\n%s", "\(name)")
            case .notASongSource(let name): return OurWords.t("%s: в файле не нашлось таблицы с песнями", name)
            case .empty(let name):          return OurWords.t("%s: песен не найдено", name)
            case .unexpectedStructure(let name, let detail):
                // Та сама біда буває різною: і «всередині не те», і «всередині
                // те, але порожньо». Тому спільний заголовок нейтральний, а
                // подробиця завжди своя — оператор має зрозуміти, лагодити йому
                // файл чи брати інший.
                return OurWords.t("Не удалось прочитать «%s» как песенник SoftProjector.\n%s", "\(name)", "\(detail)")
            case .unsupportedVersion(let name, let version):
                return "\(name): песенник версии \(version), а разбор знает версию 2.\n"
                    + OurWords.t("Откройте его в SoftProjector и выгрузите заново.")
            }
        }
    }

    // MARK: - BibleQuote

    /// Модуль «Цитати з Біблії» влаштовано як книгу: у неї розділи, у розділів вірші.
    /// У пісенному модулі розділ — це пісня, а вірш — куплет; інакше такі
    /// модулі просто не збирають. Рівно так їх і розбираємо.
    ///
    /// `refrainMarker` — той самий «рядок-ознака» з вікна імпорту: у різних
    /// модулях приспів позначають по-різному, ознака не стандартизована,
    /// тому її вводить людина. Порожня ознака — не позначати нічого.
    public static func fromBibleQuote(iniAt url: URL,
                                      refrainMarker: String?,
                                      palette: SongChunkPalette = .factoryDefault) throws -> SongBook {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let module: BibleModule
        do {
            module = try BibleModule(directory: directory)
        } catch {
            throw Failure.cannotOpen(directory.lastPathComponent)
        }

        let verseName = palette.chunk(key: "Verse")?.title ?? "Куплет"
        let chorusName = palette.chunk(key: "Chorus")?.title ?? "Припев"
        let marker = refrainMarker?.trimmingCharacters(in: .whitespaces) ?? ""

        var songs: [Song] = []
        for book in module.books {
            let chapters = (try? module.chapters(ofBook: book)) ?? []
            for chapter in chapters {
                var parts: [SongPart] = []
                var verseNumber = 0

                for verse in chapter.verses {
                    var text = verse.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let isRefrain = !marker.isEmpty && contains(marker, in: text)
                    if isRefrain, !marker.isEmpty {
                        text = strip(marker, from: text)
                    }
                    if isRefrain {
                        parts.append(SongPart(index: parts.count, kind: chorusName, text: normalize(text)))
                    } else {
                        verseNumber += 1
                        parts.append(SongPart(index: parts.count,
                                              kind: "\(verseName) \(verseNumber)",
                                              text: normalize(text)))
                    }
                }
                guard !parts.isEmpty else { continue }

                let title = chapter.heading?.trimmingCharacters(in: .whitespacesAndNewlines)
                let song = Song(index: songs.count,
                                title: (title?.isEmpty == false ? title! : firstLine(of: parts)),
                                properties: "$ID$=\(songs.count + 1)")
                songs.append(withParts(parts, in: song))
            }
        }
        guard !songs.isEmpty else { throw Failure.empty(directory.lastPathComponent) }

        return SongBook(title: module.info.name.isEmpty ? directory.lastPathComponent : module.info.name,
                        shortName: module.info.shortName,
                        publisher: module.info.copyright ?? "",
                        revisionDate: "",
                        comment: OurWords.t("Импортировано из модуля «Цитата из Библии»"),
                        songs: songs)
    }

    // MARK: - SoftProjector: що лежить у файлі

    /// Пісенник SoftProjector, прочитаний «як є», до перекладання в наш
    /// формат. Окремий тип потрібен самоперевірці: вона має вміти сказати,
    /// що саме знайшлося у файлі, не створюючи при цьому Пісенника.
    public struct SoftProjectorBook: Sendable {
        public var title: String
        public var info: String
        /// Звідки прочитано: «база SQLite, версія 2» або «XML, версія 2.0».
        public var origin: String
        public var songs: [SoftProjectorSong]

        public init(title: String, info: String, origin: String, songs: [SoftProjectorSong]) {
            self.title = title
            self.info = info
            self.origin = origin
            self.songs = songs
        }
    }

    /// Рядок таблиці `Songs` файла `.sps`. Імена полів — ті самі, що в самому
    /// SoftProjector, щоб відповідність читалася без словника.
    public struct SoftProjectorSong: Sendable {
        public var number: Int?
        public var title: String
        public var tune: String
        public var words: String     // автор слів
        public var music: String     // автор музики
        public var text: String      // song_text — весь текст пісні
        public var notes: String
        public var date: String

        public init(number: Int? = nil, title: String = "", tune: String = "",
                    words: String = "", music: String = "", text: String = "",
                    notes: String = "", date: String = "") {
            self.number = number
            self.title = title
            self.tune = tune
            self.words = words
            self.music = music
            self.text = text
            self.notes = notes
            self.date = date
        }
    }

    // MARK: - SoftProjector

    /// «Імпортувати з модуля SoftProjector» (5.3.8.3). Ознаку приспіву
    /// вводити не треба: «в этом формате припевы промаркированы однозначно».
    public static func fromSoftProjector(fileAt url: URL,
                                         palette: SongChunkPalette = .factoryDefault) throws -> SongBook {
        let source = try readSoftProjector(fileAt: url)

        var songs: [Song] = []
        for row in source.songs {
            let parts = softProjectorParts(row.text, palette: palette)
            // Пісня без тексту в Пісеннику марна, але й мовчки губити її
            // не можна: номери сусідів від цього не поїдуть — їх ми беремо з
            // самого файла, а не з позиції.
            guard !parts.isEmpty || !row.title.isEmpty else { continue }

            var song = Song(index: songs.count,
                            title: row.title.isEmpty ? "Песня \(songs.count + 1)" : row.title,
                            author: row.words,
                            composer: row.music,
                            note: row.date)
            song.parts = parts
            song.setProperty("$ID$", String(row.number ?? (songs.count + 1)))
            if !row.tune.isEmpty { song.setProperty("$TUNE$", row.tune) }
            // Нотатки пісні в нашому форматі окремого поля не мають, а
            // губити їх шкода — кладемо у властивість, як це робить сам оригінал
            // з іншими «$Ключ$=значення».
            if !row.notes.isEmpty { song.setProperty("$NOTES$", oneLine(row.notes)) }
            songs.append(song)
        }
        guard !songs.isEmpty else {
            // Рядки у файлі були, а пісень не вийшло — отже колонка
            // тексту прочиталася не та. Це найприкріше мовчання, тому
            // кажемо прямо, що читали і скільки рядків бачили.
            throw Failure.unexpectedStructure(url.lastPathComponent, """
                прочитано строк: \(source.songs.count), но ни в одной нет ни названия, ни текста.
                Читали: \(source.origin).
                """)
        }

        let name = source.title.isEmpty ? url.deletingPathExtension().lastPathComponent : source.title
        var comment = OurWords.t("Импортировано из модуля SoftProjector (%s)", "\(source.origin)")
        if !source.info.isEmpty { comment = source.info + "\n" + comment }

        return SongBook(title: name,
                        shortName: url.deletingPathExtension().lastPathComponent,
                        comment: comment,
                        songs: songs)
    }

    /// Прочитати `.sps`, не перекладаючи його в наш формат.
    ///
    /// Файл буває двох видів, і обидва треба впізнавати за вмістом, а не за
    /// розширенням: у SoftProjector 2 це база SQLite з `user_version = 2`,
    /// а до неї був XML `<spSongBook version="2.0">`. Усе інше — привід
    /// сказати людині, що саме ми побачили, а не промовчати.
    public static func readSoftProjector(fileAt url: URL) throws -> SoftProjectorBook {
        let name = url.lastPathComponent
        guard let head = try? peek(at: url, bytes: 96) else { throw Failure.cannotOpen(name) }
        guard !head.isEmpty else {
            throw Failure.unexpectedStructure(name, "файл пуст (0 байт).")
        }

        if head.starts(with: Array("SQLite format 3\u{0}".utf8)) {
            return try readSoftProjectorDatabase(at: url, name: name)
        }
        // Вивантаження буває і в UTF-16 з міткою порядку байтів — тоді UTF-8 на
        // початку файла нічого осмисленого не дасть. Мітку знімаємо самі:
        // `trimmingCharacters(in: .whitespacesAndNewlines)` U+FEFF не прибирає,
        // і файл з міткою раніше відкидався як «не той формат».
        if looksLikeXML(head) {
            return try readSoftProjectorXML(at: url, name: name)
        }
        if head.starts(with: Array("##".utf8)) || head.starts(with: [0xEF, 0xBB, 0xBF, 0x23, 0x23]) {
            return try readSoftProjectorText(at: url, name: name)
        }
        throw Failure.unexpectedStructure(name, """
            Ожидались база SQLite (SoftProjector 2), XML <spSongBook> или текст \
            SoftProjector 1.x (начинается на «##»), а файл начинается на «\(preview(head))».
            """)
    }

    /// Найстаріший формат SoftProjector (1.x) — текст, рядок на пісню.
    ///
    /// Так досі лежать пісенники на softprojector.org («Євангельські пісні»,
    /// «Пісні спасенних», «Псалмоспіви», «Песнь Возрождения»). Шапка — рядки
    /// «##версія», «##назва», «##опис»; далі пісня — десять полів через «#$#»:
    /// номер, назва, категорія, тональність, слова, музика, текст, нотатки,
    /// вирівнювання, шрифт. У тексті «@$» розділяє частини, «@%» — рядки;
    /// перший рядок частини — її назва («Куплет 1.», «Приспів», «Verse 1.»).
    private static func readSoftProjectorText(at url: URL, name: String) throws -> SoftProjectorBook {
        guard let raw = try? Data(contentsOf: url) else { throw Failure.cannotOpen(name) }
        var data = raw
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) else {
            throw Failure.cannotOpen(name)
        }
        var header: [String] = []
        var songs: [SoftProjectorSong] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("##") {
                header.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            let fields = line.components(separatedBy: "#$#")
            guard fields.count >= 7 else { continue }
            func field(_ index: Int) -> String {
                fields.indices.contains(index) ? fields[index].trimmingCharacters(in: .whitespaces) : ""
            }
            let lyrics = field(6)
                .replacingOccurrences(of: "@$", with: "\n\n")
                .replacingOccurrences(of: "@%", with: "\n")
            songs.append(SoftProjectorSong(number: Int(field(0)), title: field(1), tune: field(3),
                                           words: field(4), music: field(5), text: lyrics,
                                           notes: field(7).replacingOccurrences(of: "@%", with: "\n")))
        }
        guard !songs.isEmpty else {
            throw Failure.unexpectedStructure(name, "текст SoftProjector 1.x без песен: строк с полями «#$#» не нашлось.")
        }
        // Перший рядок шапки — номер версії («##0», «##4»), далі назва й опис.
        let rest = header.first.map { $0.allSatisfy(\.isNumber) } == true ? Array(header.dropFirst()) : header
        return SoftProjectorBook(title: rest.first ?? "",
                                 info: rest.dropFirst().joined(separator: "\n").replacingOccurrences(of: "@%", with: "\n"),
                                 origin: "текст SoftProjector 1.x", songs: songs)
    }

    /// Початок файла схожий на XML? Дивимося і однобайтовий текст, і UTF-16 —
    /// в обох порядках байтів.
    private static func looksLikeXML(_ head: [UInt8]) -> Bool {
        var bytes = head
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }

        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let isBigEndian = bytes.starts(with: [0xFE, 0xFF])
            bytes.removeFirst(2)
            // Кожен другий байт латинського тексту в UTF-16 — нуль; збираємо
            // з нього однобайтовий рядок і дивимося на нього звичайним способом.
            var ascii: [UInt8] = []
            var index = isBigEndian ? 1 : 0
            while index < bytes.count {
                ascii.append(bytes[index])
                index += 2
            }
            bytes = ascii
        }
        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{0}", with: "")
        return text.hasPrefix("<?xml") || text.lowercased().hasPrefix("<spsongbook")
    }

    // MARK: SoftProjector: база SQLite

    /// Розбір `.sps` версії 2. Схему взято з самого SoftProjector
    /// (`exportSongbook`): таблиця `SongBook` (title, info) і таблиця `Songs`
    /// (number, title, category, tune, words, music, song_text, notes, …).
    ///
    /// Колонки все одно шукаємо за іменами, а не одним зашитим запитом: у
    /// пісенників з інтернету трапляються і врізані таблиці, і зайві
    /// колонки, і падати на них нема чого.
    private static func readSoftProjectorDatabase(at url: URL, name: String) throws -> SoftProjectorBook {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let database = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "неизвестная ошибка"
            if let handle { sqlite3_close(handle) }
            throw Failure.unexpectedStructure(name, OurWords.t("SQLite не открыл файл: %s.", "\(reason)"))
        }
        defer { sqlite3_close(database) }

        let version = userVersion(in: database)
        if version > 2 { throw Failure.unsupportedVersion(name, version) }

        let tables = tableNames(in: database)
        guard !tables.isEmpty else {
            throw Failure.unexpectedStructure(name, OurWords.t("в базе нет ни одной таблицы."))
        }
        guard let table = songTable(in: database, tables: tables) else {
            throw Failure.unexpectedStructure(name, structureReport(tables: tables, in: database))
        }

        // Колонки перелічуємо по одній: у файлі їх два десятки, і більша
        // частина — оформлення слайда, яке до тексту стосунку не має.
        let picked = [table.title, table.lyrics, table.number, table.tune,
                      table.words, table.music, table.notes, table.date]
        let sql = "SELECT " + picked.map { $0.map(quoted) ?? "NULL" }.joined(separator: ", ")
            + " FROM \(quoted(table.name))"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            let reason = String(cString: sqlite3_errmsg(database))
            throw Failure.unexpectedStructure(name, OurWords.t("таблица «%s» не читается: %s.", "\(table.name)", "\(reason)"))
        }
        defer { sqlite3_finalize(statement) }

        var songs: [SoftProjectorSong] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            songs.append(SoftProjectorSong(number: number(statement, 2),
                                           title: column(statement, 0),
                                           tune: column(statement, 3),
                                           words: column(statement, 4),
                                           music: column(statement, 5),
                                           text: unpackRhythmicLines(column(statement, 1)),
                                           notes: column(statement, 6),
                                           date: column(statement, 7)))
        }
        guard !songs.isEmpty else {
            throw Failure.unexpectedStructure(name, OurWords.t("таблица «%s» есть, но в ней ни одной строки.", "\(table.name)"))
        }

        let head = bookRow(in: database, tables: tables)
        // У «звідки» пишемо і таблицю з колонками: коли пісенник з інтернету
        // виявиться з іншою схемою і частина полів приїде порожньою, за цим
        // рядком видно, що саме програма читала.
        return SoftProjectorBook(title: head.title, info: head.info,
                                 origin: "база SQLite, версия \(version), таблица «\(table.name)»,"
                                     + " текст «\(table.lyrics)», название «\(table.title)»",
                                 songs: songs)
    }

    /// Заголовок Пісенника — таблиця `SongBook` з одного рядка.
    private static func bookRow(in database: OpaquePointer, tables: [String]) -> (title: String, info: String) {
        guard let table = tables.first(where: { $0.caseInsensitiveCompare("SongBook") == .orderedSame }) else {
            return ("", "")
        }
        let columns = columnNames(of: table, in: database)
        guard let title = pick(["title", "name"], from: columns) else { return ("", "") }
        let info = pick(["info", "comment", "description"], from: columns)

        var statement: OpaquePointer?
        let sql = "SELECT \(quoted(title)), \(info.map(quoted) ?? "NULL") FROM \(quoted(table)) LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return ("", "") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return ("", "") }
        return (column(statement, 0), oneLine(column(statement, 1)))
    }

    // MARK: SoftProjector: XML

    /// Старе вивантаження `<spSongBook version="2.0">`. Склад полів той самий, що
    /// й у базі, — це видно за кодом імпорту самого SoftProjector.
    private static func readSoftProjectorXML(at url: URL, name: String) throws -> SoftProjectorBook {
        guard let data = try? Data(contentsOf: url) else { throw Failure.cannotOpen(name) }
        let reader = SoftProjectorXMLReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else {
            let line = parser.lineNumber
            let reason = parser.parserError.map { "\($0.localizedDescription)" } ?? "разбор прерван"
            throw Failure.unexpectedStructure(name, OurWords.t("XML не разобрался (строка %s): %s.", "\(line)", "\(reason)"))
        }
        guard reader.sawSongBookElement else {
            throw Failure.unexpectedStructure(name, """
                в XML нет узла <spSongBook> — это не выгрузка SoftProjector.
                Встретились узлы: \(reader.seenElements.joined(separator: ", ")).
                """)
        }
        guard !reader.songs.isEmpty else {
            throw Failure.unexpectedStructure(name, """
                в XML нет ни одного узла <Song>.
                Встретились узлы: \(reader.seenElements.joined(separator: ", ")).
                """)
        }
        let version = reader.version.isEmpty ? OurWords.t("без номера") : reader.version
        return SoftProjectorBook(title: reader.title, info: oneLine(reader.info),
                                 origin: "XML, версия \(version)",
                                 songs: reader.songs)
    }

    /// Розбір XML за подіями: файл може бути на тисячі пісень, тримати з
    /// нього дерево в пам'яті нема чого.
    private final class SoftProjectorXMLReader: NSObject, XMLParserDelegate {
        var title = ""
        var info = ""
        var version = ""
        var songs: [SoftProjectorSong] = []
        var sawSongBookElement = false
        /// Які вузли взагалі трапилися. Потрібно лише для повідомлення про
        /// помилку: «немає <Song>» без переліку побаченого — глухий кут.
        private(set) var seenElements: [String] = []
        private var seen = Set<String>()

        private var value = ""
        private var current: SoftProjectorSong?
        private var inHeader = false

        /// Імена вузлів порівнюємо без урахування регістру і підкреслень: у різних
        /// збірок SoftProjector трапляються і `song_text`, і `songText`, і
        /// `<song>` з малої літери. Розбір через таку дрібницю мовчки
        /// повертати порожній Пісенник не повинен.
        private static func tag(_ element: String) -> String {
            element.lowercased().replacingOccurrences(of: "_", with: "")
        }

        private static func attribute(_ attributes: [String: String], _ name: String) -> String? {
            attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            value = ""
            if seen.insert(element).inserted, seenElements.count < 24 { seenElements.append(element) }
            switch Self.tag(element) {
            case "spsongbook":
                sawSongBookElement = true
                version = Self.attribute(attributes, "version") ?? ""
            case "songbook":
                inHeader = true
            case "song":
                inHeader = false
                var song = SoftProjectorSong()
                song.number = Self.attribute(attributes, "number")
                    .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                current = song
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            // Текст пісні у вивантаженнях нерідко загорнуто в CDATA — без цього
            // обробника він просто пропадав би.
            value += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                    qualifiedName: String?) {
            defer { value = "" }
            let tag = Self.tag(element)
            if tag == "song" {
                if let song = current { songs.append(song) }
                current = nil
                return
            }
            if tag == "songbook" { inHeader = false; return }

            if inHeader {
                switch tag {
                case "title", "name":            title = value
                case "info", "comment", "about": info = value
                default:                         break
                }
                return
            }
            guard current != nil else { return }
            switch tag {
            case "title", "songtitle", "name":                current?.title = value
            case "tune", "key":                               current?.tune = value
            case "words", "author", "poet", "writer":         current?.words = value
            case "music", "composer":                         current?.music = value
            case "songtext", "lyrics", "text", "body":        current?.text = SongBookImporter.unpackRhythmicLines(value)
            case "notes", "note":                             current?.notes = value
            case "date", "created":                           current?.date = value
            case "number", "songnumber":
                current?.number = Int(value.trimmingCharacters(in: .whitespaces)) ?? current?.number
            default:                                          break
            }
        }
    }

    // MARK: SoftProjector: текст пісні

    /// Частини в SoftProjector позначено рядком-заголовком: «Verse 1»,
    /// «Куплет 2», «Chorus», «Припев». Список слів узято з його вихідників
    /// (`song.cpp`, функції `isStanza*Title`) — програма вважає початком
    /// нової частини рівно їх, тому й ми читаємо так само, а не за порожніми
    /// рядками.
    static func softProjectorParts(_ lyrics: String,
                                   palette: SongChunkPalette) -> [SongPart] {
        let lines = SongTextMarkup.normalizedLines(lyrics)
        var parts: [SongPart] = []
        var kind = ""
        var buffer: [String] = []
        var sawHeading = false

        func flush() {
            let body = SongTextMarkup.trimBlankEdges(buffer)
            defer { buffer = []; kind = "" }
            guard !body.isEmpty else { return }
            parts.append(SongPart(index: parts.count, kind: kind,
                                  text: body.joined(separator: "\r\n")))
        }

        for line in lines {
            if let heading = softProjectorHeading(line, palette: palette) {
                flush()
                kind = heading
                sawHeading = true
                continue
            }
            buffer.append(line)
        }
        flush()

        // Жодного заголовка не знайшлося — отже текст набрано суцільно.
        // Тоді лишається єдина ознака, яка в ньому є: порожній
        // рядок між куплетами.
        guard sawHeading else { return softProjectorBlocks(lines, palette: palette) }
        return parts
    }

    /// Заголовок частини SoftProjector → назва частини мовою палітри.
    /// Повертає `nil`, якщо рядок звичайний.
    private static func softProjectorHeading(_ line: String, palette: SongChunkPalette) -> String? {
        // «&Chorus» у SoftProjector означає «продовження того самого приспіву» —
        // для нас це просто ще одна частина з тією самою назвою.
        var head = line.trimmingCharacters(in: .whitespaces)
        while head.hasPrefix("&") { head.removeFirst() }
        guard !head.isEmpty, head.count <= 32 else { return nil }

        for (prefix, key) in softProjectorHeadings where head.hasPrefix(prefix) {
            // Хвіст заголовка буває лише номером або розділовим знаком:
            // «Verse 2», «Chorus:», «Слайд 3». Рядок пісні, який просто
            // починається на це слово, за заголовок приймати не можна.
            let tail = head.dropFirst(prefix.count)
            guard tail.allSatisfy({ $0.isNumber || $0.isWhitespace || $0.isPunctuation }) else { continue }
            let name = palette.chunk(key: key)?.title ?? key
            let digits = tail.filter(\.isNumber)
            return digits.isEmpty ? name : "\(name) \(digits)"
        }
        return nil
    }

    /// Слова-заголовки SoftProjector та їхня відповідність типам частин VisioBible.
    /// Порядок важливий: спершу довгі, інакше «Verš» не відрізнити від «Verse».
    private static let softProjectorHeadings: [(String, String)] = {
        let table: [(String, String)] = [
            ("Verse", "Verse"), ("Куплет", "Verse"), ("Strophe", "Verse"), ("Verš", "Verse"),
            ("Chorus", "Chorus"), ("Refrain", "Chorus"), ("Sbor", "Chorus"),
            ("Припев", "Chorus"), ("Приспів", "Chorus"), ("Refrén", "Chorus"),
            // «Слайд» і «Вставка» — вставний шматок між куплетами; найближче
            // за змістом «Місток», окремого типу для них у VisioBible немає.
            ("Slide", "Bridge"), ("Слайд", "Bridge"), ("Snímek", "Bridge"),
            ("Insert", "Bridge"), ("Вставка", "Bridge"), ("Einfügung", "Bridge"), ("Vložka", "Bridge"),
            ("Intro", "Intro"), ("Вступление", "Intro"), ("Einleitung", "Intro"), ("Úvod", "Intro"),
            ("Ending", "End"), ("Окончание", "End"), ("Закінчення", "End"),
            ("Ende", "End"), ("Závěr", "End"),
        ]
        return table.sorted { $0.0.count > $1.0.count }
    }()

    /// Запасний розбір: частини розділено порожнім рядком, назв немає.
    private static func softProjectorBlocks(_ lines: [String],
                                            palette: SongChunkPalette) -> [SongPart] {
        let verseName = palette.chunk(key: "Verse")?.title ?? "Куплет"
        var parts: [SongPart] = []
        var number = 0
        let blocks = lines
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { Array($0) }

        for block in blocks {
            let body = SongTextMarkup.trimBlankEdges(block)
            guard !body.isEmpty else { continue }
            number += 1
            parts.append(SongPart(index: parts.count, kind: "\(verseName) \(number)",
                                  text: body.joined(separator: "\r\n")))
        }
        return parts
    }

    /// Старі вивантаження зберігають весь текст одним рядком: `@$` розділяє частини,
    /// `@%` — рядки всередині частини. Так це розпаковує і сам SoftProjector
    /// (`cleanSongLines`), інакше пісня приїде одним довгим рядком.
    static func unpackRhythmicLines(_ text: String) -> String {
        guard text.contains("@$") || text.contains("@%") else { return text }
        return text.replacingOccurrences(of: "@%", with: "\n")
            .replacingOccurrences(of: "@$", with: "\n\n")
    }

    // MARK: - Внутрішнє

    private struct SongTable {
        let name: String
        let title: String
        let lyrics: String
        let number: String?
        let tune: String?
        let words: String?
        let music: String?
        let notes: String?
        let date: String?
    }

    private static func songTable(in database: OpaquePointer, tables: [String]) -> SongTable? {
        for table in tables {
            let columns = columnNames(of: table, in: database)
            guard let lyrics = pick(["song_text", "songtext", "lyrics", "text", "body", "verses"], from: columns),
                  let title = pick(["title", "song_title", "name", "song_name"], from: columns) else { continue }
            return SongTable(name: table,
                             title: title,
                             lyrics: lyrics,
                             number: pick(["number", "song_number", "songnumber", "num"], from: columns),
                             tune: pick(["tune", "key"], from: columns),
                             // У SoftProjector автор слів — «words», автор
                             // музики — «music»; у чужих базах буває «author».
                             words: pick(["words", "author", "writer", "poet"], from: columns),
                             music: pick(["music", "composer"], from: columns),
                             notes: pick(["notes", "note", "comment"], from: columns),
                             date: pick(["date", "created", "song_date"], from: columns))
        }
        return nil
    }

    /// Що саме знайшлося в базі — цей текст бачить оператор, коли пісенник
    /// виявився не тим, чого чекали.
    private static func structureReport(tables: [String], in database: OpaquePointer) -> String {
        var lines = [OurWords.t("Нужны таблица с песнями и в ней колонки текста (song_text) и названия (title).")]
        lines.append(OurWords.t("В файле есть таблицы: ") + tables.joined(separator: ", ") + ".")
        for table in tables.prefix(4) {
            let columns = columnNames(of: table, in: database)
            guard !columns.isEmpty else { continue }
            lines.append("  \(table): " + columns.prefix(16).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private static func pick(_ candidates: [String], from columns: [String]) -> String? {
        for candidate in candidates {
            if let match = columns.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return match
            }
        }
        return nil
    }

    private static func userVersion(in database: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func tableNames(in database: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table'"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { names.append(column(statement, 0)) }
        // Таблиця «Songs» — та сама, що пише SoftProjector, тому її
        // пробуємо першою; службові таблиці SQLite не чіпаємо зовсім.
        //
        // Розкладаємо у два списки, а не сортуємо: порівняння «зліва стоїть
        // Songs» — не відношення порядку (для двох чужих таблиць воно і в той, і
        // в інший бік хибне), і `sorted` на такому порівнянні має право
        // видати що завгодно.
        let usable = names.filter { !$0.lowercased().hasPrefix("sqlite_") }
        let songs = usable.filter { $0.caseInsensitiveCompare("Songs") == .orderedSame }
        let rest = usable.filter { $0.caseInsensitiveCompare("Songs") != .orderedSame }
        return songs + rest
    }

    private static func columnNames(of table: String, in database: OpaquePointer) -> [String] {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(quoted(table)))"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { names.append(column(statement, 1)) }
        return names
    }

    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    /// Номер пісні буває і числом, і рядком — колонку оголошено INTEGER,
    /// але у вивантаженнях трапляється текст.
    private static func number(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER, SQLITE_FLOAT: return Int(sqlite3_column_int64(statement, index))
        case SQLITE_NULL:                  return nil
        default:
            let text = column(statement, index).trimmingCharacters(in: .whitespaces)
            return Int(text)
        }
    }

    private static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Перші байти файла — за ними й упізнаємо формат.
    private static func peek(at url: URL, bytes count: Int) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: count)
        return [UInt8](data)
    }

    /// Початок файла в читабельному вигляді — для повідомлення про помилку.
    private static func preview(_ bytes: [UInt8]) -> String {
        let printable = bytes.prefix(24).map { byte -> Character in
            (byte >= 32 && byte < 127) ? Character(UnicodeScalar(byte)) : "·"
        }
        return String(printable)
    }

    private static func oneLine(_ text: String) -> String {
        SongTextMarkup.normalizedLines(text)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func contains(_ marker: String, in text: String) -> Bool {
        text.range(of: marker, options: [.caseInsensitive]) != nil
    }

    private static func strip(_ marker: String, from text: String) -> String {
        text.replacingOccurrences(of: marker, with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ text: String) -> String {
        SongTextMarkup.trimBlankEdges(SongTextMarkup.normalizedLines(text))
            .joined(separator: "\r\n")
    }

    private static func firstLine(of parts: [SongPart]) -> String {
        for part in parts {
            for line in part.lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return OurWords.t("Без названия")
    }

    private static func withParts(_ parts: [SongPart], in song: Song) -> Song {
        var result = song
        result.parts = parts
        return result
    }
}

// MARK: - Самоперевірка розбору SoftProjector

/// Перевірка імпорту `.sps` на свідомо відомих файлах.
///
/// Модулі SoftProjector лежать в інтернеті, і приходять вони різні: і база
/// SQLite версії 2, і старе вивантаження XML, і просто чужий файл з тим самим
/// розширенням. Перевіряти таке «на око» не можна — помилка вилізе в оператора
/// перед служінням. Тому зразки кожного випадку програма робить сама, у
/// тимчасовій теці, і сама ж дивиться, що вийшло: справжні дані
/// користувача при цьому не чіпаються зовсім.
public enum SoftProjectorSelfTest {

    public struct Case: Sendable {
        public let name: String
        /// Чи чекаємо ми, що файл прочитається.
        public let expectsSuccess: Bool
        public let passed: Bool
        /// Що вийшло насправді — цей рядок і бачить людина у звіті.
        public let outcome: String
    }

    public static func run() -> [Case] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-sps-selftest-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return [Case(name: "Тимчасова тека", expectsSuccess: true, passed: false,
                         outcome: "не створилася: \(folder.path)")]
        }
        defer { try? FileManager.default.removeItem(at: folder) }

        var cases: [Case] = []
        cases.append(check("база SoftProjector 2", expectsSuccess: true,
                           at: makeDatabase(in: folder, name: "good", userVersion: 2, full: true),
                           expecting: { $0.songs.count == 2 && $0.songs.allSatisfy { !$0.parts.isEmpty } },
                           expectation: "2 пісні, обидві з частинами"))
        cases.append(check("вивантаження XML із міткою порядку байтів", expectsSuccess: true,
                           at: makeXML(in: folder, name: "xmlbom", withBOM: true),
                           expecting: { $0.songs.count == 2 },
                           expectation: "2 пісні"))
        cases.append(check("база з чужими таблицями", expectsSuccess: false,
                           at: makeDatabase(in: folder, name: "wrong", userVersion: 2, full: false),
                           expecting: { _ in false },
                           expectation: "перелік знайдених таблиць і колонок"))
        cases.append(check("пісенник версії з майбутнього", expectsSuccess: false,
                           at: makeDatabase(in: folder, name: "newver", userVersion: 9, full: true),
                           expecting: { _ in false },
                           expectation: "номер версії в повідомленні"))
        cases.append(check("порожній файл", expectsSuccess: false,
                           at: write(Data(), in: folder, name: "empty"),
                           expecting: { _ in false },
                           expectation: "«файл порожній»"))
        cases.append(check("чужий файл із тим самим розширенням", expectsSuccess: false,
                           at: write(Data("PK\u{3}\u{4}not a songbook".utf8), in: folder, name: "junk"),
                           expecting: { _ in false },
                           expectation: "початок файлу в повідомленні"))
        cases.append(check("чужий XML", expectsSuccess: false,
                           at: write(Data("<?xml version=\"1.0\"?><playlist><item/></playlist>".utf8),
                                     in: folder, name: "otherxml"),
                           expecting: { _ in false },
                           expectation: "«немає вузла <spSongBook>»"))
        return cases
    }

    // MARK: - Один випадок

    private static func check(_ name: String, expectsSuccess: Bool, at url: URL?,
                              expecting: (SongBook) -> Bool, expectation: String) -> Case {
        guard let url else {
            return Case(name: name, expectsSuccess: expectsSuccess, passed: false,
                        outcome: "зразок не вдалося записати")
        }
        do {
            let book = try SongBookImporter.fromSoftProjector(fileAt: url)
            guard expectsSuccess else {
                return Case(name: name, expectsSuccess: false, passed: false,
                            outcome: "прочитався мовчки, хоча не мав би: пісень \(book.songs.count)")
            }
            let ok = expecting(book)
            return Case(name: name, expectsSuccess: true, passed: ok,
                        outcome: ok ? "пісень \(book.songs.count), частин \(book.songs.reduce(0) { $0 + $1.parts.count })"
                                    : "прочиталося не те: чекали \(expectation), вийшло пісень \(book.songs.count)")
        } catch {
            let message = "\(error)".replacingOccurrences(of: "\n", with: " ")
            guard !expectsSuccess else {
                return Case(name: name, expectsSuccess: true, passed: false, outcome: "відмова: \(message)")
            }
            // Відмова має бути зрозумілою: порожня або односкладова відмовка
            // тут не краща за мовчання.
            let explained = message.count > 40
            return Case(name: name, expectsSuccess: false, passed: explained,
                        outcome: explained ? "відмова з поясненням: \(message)"
                                           : "відмова без пояснення: «\(message)»")
        }
    }

    // MARK: - Зразки

    private static func write(_ data: Data, in folder: URL, name: String) -> URL? {
        let url = folder.appendingPathComponent(name + ".sps")
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// Текст пісні у двох видах одразу: із заголовками частин і зі «стиснутими»
    /// рядками `@%` / `@$`, якими старі вивантаження склеюють весь текст.
    private static let lyrics = """
        Verse 1
        Господь, мой Бог, когда на мир смотрю я
        Chorus
        Тогда поет душа моя
        """
    private static let packedLyrics = "Куплет 1\nТихая ночь@%Дивная ночь@$Припев\nСпит всё, лишь не спит"

    private static func makeDatabase(in folder: URL, name: String, userVersion: Int, full: Bool) -> URL? {
        let url = folder.appendingPathComponent(name + ".sps")
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(database) }

        var script = "PRAGMA user_version = \(userVersion);"
        if full {
            script += """
                CREATE TABLE SongBook (id INTEGER PRIMARY KEY, title TEXT, info TEXT);
                INSERT INTO SongBook VALUES (1, 'Гимны надежды', 'Пробный сборник');
                CREATE TABLE Songs (id INTEGER PRIMARY KEY, number INTEGER, title TEXT,
                    category TEXT, tune TEXT, words TEXT, music TEXT, song_text TEXT,
                    notes TEXT, date TEXT);
                INSERT INTO Songs VALUES (1, 12, 'Великий Бог', '', 'C', 'К. Боберг', 'Ш. Хайн',
                    '\(escaped(lyrics))', 'проба', '01.01.2020');
                INSERT INTO Songs VALUES (2, 13, 'Тихая ночь', '', '', '', '',
                    '\(escaped(packedLyrics))', '', '');
                """
        } else {
            script += """
                CREATE TABLE Slides (id INTEGER PRIMARY KEY, caption TEXT, body TEXT);
                INSERT INTO Slides VALUES (1, 'а', 'б');
                CREATE TABLE Settings (name TEXT, value TEXT);
                """
        }
        guard sqlite3_exec(database, script, nil, nil, nil) == SQLITE_OK else { return nil }
        return url
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }

    private static func makeXML(in folder: URL, name: String, withBOM: Bool) -> URL? {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <spSongBook version="2.0">
             <SongBook><title>Старая выгрузка</title><info>XML вариант</info></SongBook>
             <Song number="5">
              <title>Как Ты велик</title><words>автор слов</words><music>автор музыки</music>
              <song_text><![CDATA[\(lyrics)]]></song_text>
             </Song>
             <Song number="6">
              <title>Без частей</title><song_text>Одна строка

            Другая строка</song_text>
             </Song>
            </spSongBook>
            """
        var data = withBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(Data(xml.utf8))
        return write(data, in: folder, name: name)
    }
}
