import Foundation

/// Частина пісні: куплет, приспів, місток… Назва частини задає і її колір
/// у списку — відповідність лежить у `[SongChunksColors]` налаштувань старої програми.
public struct SongPart: Sendable, Hashable, Identifiable {
    public var index: Int
    public var kind: String
    public var text: String
    /// Вирівнювання тексту частини (кнопки 9–12 панелі «Текст», розділ 5.3.9.2).
    public var align: SongPartAlign

    public init(index: Int, kind: String, text: String, align: SongPartAlign = .default) {
        self.index = index
        self.kind = kind
        self.text = text
        self.align = align
    }

    public var id: Int { index }

    /// Текст, розбитий на рядки так, як його набирали, — перенос рядка
    /// в пісні значущий, його не можна схлопувати як у біблійному вірші.
    public var lines: [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}

public struct Song: Sendable, Hashable, Identifiable {
    public var index: Int
    public var title: String
    public var alternateTitle: String
    public var author: String
    public var composer: String
    public var note: String
    public var properties: String
    public var parts: [SongPart]

    public init(index: Int, title: String, alternateTitle: String = "", author: String = "",
                composer: String = "", note: String = "", properties: String = "",
                parts: [SongPart] = []) {
        self.index = index
        self.title = title
        self.alternateTitle = alternateTitle
        self.author = author
        self.composer = composer
        self.note = note
        self.properties = properties
        self.parts = parts
    }

    public var id: Int { index }

    public var subtitle: String? {
        let credits = [author, composer].filter { !$0.isEmpty }
        guard !credits.isEmpty else { return nil }
        // Автор слів і музики часто збігаються — дублювати ім'я нема чого.
        return Set(credits).count == 1 ? credits[0] : credits.joined(separator: " / ")
    }
}

/// Пісенник у форматі старої програми (`.vbm`).
///
/// Файл — це короткий заголовок і один zlib-потік слідом. Усередині потоку все
/// одноманітно: рядок це UInt16 з числом символів і самі символи в UTF-16LE.
///
/// Зсув потоку не фіксований: у заголовку лежать назва і коротке ім'я
/// збірника, а вони різної довжини. Зате на зсуві 20 записано розмір стиснутих
/// даних, і потік завжди впирається в останні чотири байти файла — звідси
/// і рахуємо початок.
///
/// Розкладка заголовка (перевірена на всіх 22 пісенниках користувача):
///     0   «VisioBibleModule»
///     16  UInt32 версія формату (0x0102)
///     20  UInt32 розмір стиснутих даних
///     24  UInt32 розмір розпакованих даних
///     28  UInt32 ознака (скрізь 1)
///     32  UInt32 кодування Пісенника (0x200 — UNICODE; 1 трапляється в
///         одному старому збірнику, про такі й каже розділ 5.3.9.3)
///     36  36 нульових байтів
///     72  коротке ім'я і назва (дублі того, що лежить у потоці)
///         UInt32 0, потім сам zlib-потік і UInt32 0 у хвості файла
public struct SongBook: Sendable {

    public var title: String
    public var shortName: String
    public var publisher: String
    public var revisionDate: String
    public var comment: String
    public var songs: [Song]
    /// Користувацькі групи пісень (список «Група», розділ 5.3.1).
    public var groups: [SongGroup]

    /// Поля заголовка файла. Їх нема чого показувати, але при збереженні треба
    /// повернути рівно ті самі значення — інакше оригінал не відкриє файл.
    public var formatVersion: UInt32
    public var flags: UInt32
    public var charset: UInt32

    public init(title: String, shortName: String, publisher: String = "", revisionDate: String = "",
                comment: String = "", songs: [Song] = [], groups: [SongGroup] = [],
                formatVersion: UInt32 = SongBook.currentFormatVersion,
                flags: UInt32 = 1,
                charset: UInt32 = SongBook.unicodeCharset) {
        self.title = title
        self.shortName = shortName
        self.publisher = publisher
        self.revisionDate = revisionDate
        self.comment = comment
        self.songs = songs
        self.groups = groups
        self.formatVersion = formatVersion
        self.flags = flags
        self.charset = charset
    }

    public static let currentFormatVersion: UInt32 = 0x0102
    /// Значення поля «Кодування», яке стоїть у всіх збірниках, крім
    /// одного старого. Посібник (5.3.9.3) вимагає для нових Пісенників
    /// саме «UNICODE».
    public static let unicodeCharset: UInt32 = 0x200

    public init(fileAt url: URL) throws {
        let data = try Data(contentsOf: url)
        let name = url.deletingPathExtension().lastPathComponent
        // Свій формат `.songbook` (JSON) — за розширенням або за першим
        // знаком; `.vbm` старої програми — далі, як і раніше.
        if SongBookJSON.isSongBookFile(url) || data.first == UInt8(ascii: "{") {
            self = try SongBookJSON.book(from: data, name: name)
            return
        }
        try self.init(data: data, name: name)
    }

    public init(data: Data, name: String) throws {
        guard data.count > 24, data.prefix(16) == Data("VisioBibleModule".utf8) else {
            throw SongBookError.notASongBook(name)
        }
        func header(_ offset: Int) -> UInt32 {
            guard data.count >= offset + 4 else { return 0 }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        formatVersion = header(16)
        flags = header(28)
        charset = header(32)

        let compressedSize = Int(header(20))
        let start = data.count - 4 - compressedSize
        guard start > 16, start < data.count else { throw SongBookError.damaged(name) }

        let body = try Inflate.zlib(Data(data[start...]))
        var reader = BinaryReader(body)

        title = reader.string()
        shortName = reader.string()
        publisher = reader.string()
        revisionDate = reader.string()
        comment = reader.string()

        let count = Int(reader.uint32())
        guard count >= 0, count < 100_000 else { throw SongBookError.damaged(name) }

        var songs: [Song] = []
        songs.reserveCapacity(count)

        for index in 0..<count {
            let title = reader.string()
            let alternate = reader.string()
            let author = reader.string()
            let composer = reader.string()
            let note = reader.string()
            let properties = reader.string()

            let partCount = Int(reader.uint32())
            guard partCount >= 0, partCount < 1000 else { throw SongBookError.damaged(name) }

            var parts: [SongPart] = []
            parts.reserveCapacity(partCount)
            for part in 0..<partCount {
                let kind = reader.string()
                let text = reader.string()
                // Службове поле частини — вирівнювання її тексту. Значення
                // розібрано за кодом оригіналу: 1 → Left, 2 → Right, 3 → Center.
                let align = SongPartAlign(rawValue: reader.uint32()) ?? .default
                parts.append(SongPart(index: part, kind: kind, text: text, align: align))
            }
            songs.append(Song(index: index, title: title, alternateTitle: alternate,
                              author: author, composer: composer, note: note,
                              properties: properties, parts: parts))
        }
        self.songs = songs

        // Групи пісень лежать у самому кінці потоку: їхня кількість, потім на
        // кожну групу назва і номери пісень, що входять до неї. Збірники без
        // груп закінчуються нулем — його теж треба прочитати, інакше при
        // збереженні хвіст загубиться.
        var groups: [SongGroup] = []
        let groupCount = Int(reader.uint32())
        if groupCount > 0, groupCount < 10_000 {
            for _ in 0..<groupCount {
                let groupName = reader.string()
                let memberCount = Int(reader.uint32())
                guard memberCount >= 0, memberCount <= count else { break }
                var members: [Int] = []
                members.reserveCapacity(memberCount)
                for _ in 0..<memberCount { members.append(Int(reader.uint32())) }
                groups.append(SongGroup(name: groupName, songIndices: members))
            }
        }
        self.groups = groups
    }
}

public enum SongBookError: Error, CustomStringConvertible {
    case notASongBook(String)
    case damaged(String)
    case inflateFailed

    public var description: String {
        switch self {
        case .notASongBook(let name): return OurWords.t("%s: это не песенник .vbm", "\(name)")
        case .damaged(let name):      return OurWords.t("%s: файл повреждён или формат новее", name)
        case .inflateFailed:          return OurWords.t("не удалось распаковать данные песенника")
        }
    }
}

/// Послідовне читання простих значень з розпакованого блоку.
private struct BinaryReader {
    private let data: [UInt8]
    private var offset = 0

    init(_ data: Data) { self.data = [UInt8](data) }

    mutating func skip(_ count: Int) { offset = min(offset + count, data.count) }

    mutating func uint16() -> UInt16 {
        guard offset + 2 <= data.count else { offset = data.count; return 0 }
        defer { offset += 2 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    mutating func uint32() -> UInt32 {
        guard offset + 4 <= data.count else { offset = data.count; return 0 }
        defer { offset += 4 }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    /// Рядок: число символів в UInt16, потім самі символи в UTF-16LE.
    mutating func string() -> String {
        let characters = Int(uint16())
        let length = characters * 2
        guard characters > 0, offset + length <= data.count else {
            offset = min(offset + max(0, length), data.count)
            return ""
        }
        var units = [UInt16]()
        units.reserveCapacity(characters)
        for step in stride(from: offset, to: offset + length, by: 2) {
            units.append(UInt16(data[step]) | UInt16(data[step + 1]) << 8)
        }
        offset += length
        return String(decoding: units, as: UTF16.self)
    }
}
