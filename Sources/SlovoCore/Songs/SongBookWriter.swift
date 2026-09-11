import Foundation
import Compression

/// Запис пісенника у форматі VisioBible (`.vbm`).
///
/// Без запису редактор безглуздий, а формат уже розібрано при читанні:
/// шістнадцять байтів підпису, версія, розмір стиснутих даних, потім коротка
/// службова область з назвою і коротким ім'ям — і один zlib-потік з усім
/// вмістом. Рядок усередині — число символів в UInt16 і самі символи
/// в UTF-16LE.
///
/// Пишемо рівно ту саму розкладку, щоб файл відкривався й оригінальною
/// програмою: правка пісень на маку не має відрізати від Windows.
public enum SongBookWriter {

    public static func data(for book: SongBook) throws -> Data {
        var body = Data()
        append(&body, book.title)
        append(&body, book.shortName)
        append(&body, book.publisher)
        append(&body, book.revisionDate)
        append(&body, book.comment)
        append(&body, UInt32(book.songs.count))

        for song in book.songs {
            append(&body, song.title)
            append(&body, song.alternateTitle)
            append(&body, song.author)
            append(&body, song.composer)
            append(&body, song.note)
            append(&body, song.properties)
            append(&body, UInt32(song.parts.count))

            for part in song.parts {
                append(&body, part.kind)
                append(&body, part.text)
                // Службове поле частини — її вирівнювання (5.3.9.2, кнопки 9–12).
                append(&body, part.align.rawValue)
            }
        }

        // Хвіст потоку — групи пісень. Навіть коли груп немає, нуль писати
        // обов'язково: оригінал читає це поле завжди.
        append(&body, UInt32(book.groups.count))
        for group in book.groups {
            append(&body, group.name)
            append(&body, UInt32(group.songIndices.count))
            for index in group.songIndices { append(&body, UInt32(max(0, index))) }
        }

        let compressed = try Deflate.zlib(body)

        // Заголовок повторюємо байт у байт: оригінал шукає коротке ім'я і
        // назву на фіксованому зсуві 72, а розміри й ознаку читає
        // з 20-го. Помилка тут — і файл відкриється лише в нас.
        var file = Data("VisioBibleModule".utf8)
        append(&file, book.formatVersion)
        append(&file, UInt32(compressed.count))
        append(&file, UInt32(body.count))
        append(&file, book.flags)
        append(&file, book.charset)
        file.append(Data(repeating: 0, count: 36))
        append(&file, book.shortName)
        append(&file, book.title)
        file.append(Data(repeating: 0, count: 4))

        file.append(compressed)
        file.append(Data(repeating: 0, count: 4))     // хвіст, як у вихідних файлах
        return file
    }

    public static func write(_ book: SongBook, to url: URL) throws {
        try data(for: book).write(to: url, options: .atomic)
    }

    // MARK: -

    private static func append(_ data: inout Data, _ text: String) {
        let units = Array(text.utf16)
        append(&data, UInt16(min(units.count, Int(UInt16.max))))
        for unit in units.prefix(Int(UInt16.max)) {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
    }

    private static func append(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func append(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}

/// Пакування в zlib. `Compression` уміє лише «сирий» DEFLATE, тому
/// заголовок і контрольну суму дописуємо самі — інакше оригінальна
/// програма файл не прийме.
enum Deflate {

    static func zlib(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw SongBookError.inflateFailed }

        let capacity = data.count + data.count / 2 + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }

        let written = data.withUnsafeBytes { input -> Int in
            guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, source, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw SongBookError.inflateFailed }

        var out = Data([0x78, 0x9C])                     // заголовок zlib
        out.append(Data(bytes: destination, count: written))
        var adler = adler32(data).bigEndian
        withUnsafeBytes(of: &adler) { out.append(contentsOf: $0) }
        return out
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
