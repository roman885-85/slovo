import Foundation

/// Свій формат пісенника «Слова» — `.songbook`: JSON в UTF-8.
///
/// Власник: «формат vbi та vbm — це формат старої програми; для нас потрібен свій,
/// але так, щоб не поламати імпорт пісенників чи перекладів з старої програми та
/// інших сумісних форматів». Тому:
///  • програма пише лише `.songbook` — читається будь-яким редактором, лягає
///    в git, без zlib і UTF-16;
///  • `.vbm` лишається форматом ІМПОРТУ (майстер, бібліотека відкриває його
///    як і раніше) та ЕКСПОРТУ (планшет розбирає лише `.vbm`, стара програма на
///    Windows — теж): `SongBookWriter` збирає його з тієї самої структури;
///  • поля заголовка старої програми (`formatVersion`, `flags`, `charset`) їдуть
///    у файлі в гілці `vbm`, щоб експорт віддавав файл, який відкриє оригінал.
public enum SongBookJSON {

    public static let pathExtension = "songbook"
    public static let format = "slovo-songbook"
    public static let version = 1

    struct File: Codable {
        var format: String
        var version: Int
        var title: String
        var shortName: String
        var publisher: String
        var revisionDate: String
        var comment: String
        var groups: [Group]
        var songs: [SongRecord]
        var vbm: Header?

        struct Header: Codable {
            var formatVersion: UInt32
            var flags: UInt32
            var charset: UInt32
        }
        struct Group: Codable {
            var name: String
            var songs: [Int]
        }
        struct SongRecord: Codable {
            var index: Int
            var title: String
            var alternateTitle: String?
            var author: String?
            var composer: String?
            var note: String?
            var properties: String?
            var parts: [Part]
        }
        struct Part: Codable {
            var index: Int
            var kind: String
            var text: String
            var align: String?
        }
    }

    public static func isSongBookFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == pathExtension
    }

    // MARK: - Запис

    public static func data(for book: SongBook) throws -> Data {
        func blank(_ text: String) -> String? { text.isEmpty ? nil : text }
        let file = File(
            format: format, version: version,
            title: book.title, shortName: book.shortName, publisher: book.publisher,
            revisionDate: book.revisionDate, comment: book.comment,
            groups: book.groups.map { File.Group(name: $0.name, songs: $0.songIndices) },
            songs: book.songs.map { song in
                File.SongRecord(index: song.index, title: song.title,
                                alternateTitle: blank(song.alternateTitle), author: blank(song.author),
                                composer: blank(song.composer), note: blank(song.note),
                                properties: blank(song.properties),
                                parts: song.parts.map { part in
                                    File.Part(index: part.index, kind: part.kind, text: part.text,
                                              align: part.align == .default ? nil : name(of: part.align))
                                })
            },
            vbm: File.Header(formatVersion: book.formatVersion, flags: book.flags, charset: book.charset))
        let encoder = JSONEncoder()
        // Ключі за абеткою й відступи: файл однаковий за однакового вмісту —
        // зручно порівнювати й тримати в git.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    public static func write(_ book: SongBook, to url: URL) throws {
        try data(for: book).write(to: url, options: .atomic)
    }

    /// Зберегти у своєму форматі ПОРУЧ із тим файлом, на який показали: для
    /// `pv3055.vbm` це `pv3055.songbook` (сам `.vbm` не чіпаємо — він для
    /// стара програма). Повертає, куди лягло.
    @discardableResult
    public static func save(_ book: SongBook, near url: URL) throws -> URL {
        let target = isSongBookFile(url) ? url
            : url.deletingPathExtension().appendingPathExtension(pathExtension)
        try write(book, to: target)
        return target
    }

    // MARK: - Читання

    public static func book(from data: Data, name: String) throws -> SongBook {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw SongBookError.damaged(name)
        }
        guard file.format == format else { throw SongBookError.notASongBook(name) }
        var book = SongBook(
            title: file.title, shortName: file.shortName, publisher: file.publisher,
            revisionDate: file.revisionDate, comment: file.comment,
            songs: file.songs.map { record in
                Song(index: record.index, title: record.title,
                     alternateTitle: record.alternateTitle ?? "", author: record.author ?? "",
                     composer: record.composer ?? "", note: record.note ?? "",
                     properties: record.properties ?? "",
                     parts: record.parts.map { part in
                         SongPart(index: part.index, kind: part.kind, text: part.text,
                                  align: align(named: part.align))
                     })
            },
            groups: file.groups.map { SongGroup(name: $0.name, songIndices: $0.songs) })
        if let header = file.vbm {
            book.formatVersion = header.formatVersion
            book.flags = header.flags
            book.charset = header.charset
        }
        return book
    }

    // MARK: - Вирівнювання

    static func name(of align: SongPartAlign) -> String {
        switch align {
        case .default: return "default"
        case .left:    return "left"
        case .right:   return "right"
        case .center:  return "center"
        }
    }

    static func align(named name: String?) -> SongPartAlign {
        switch name {
        case "left":   return .left
        case "right":  return .right
        case "center": return .center
        default:       return .default
        }
    }
}
