import Foundation
import Compression

/// Читання архіву ZIP — рівно стільки, скільки потрібно, щоб відкрити `.pptx`.
///
/// Презентація Microsoft — це звичайний ZIP з XML усередині. Свого читання ZIP у
/// Foundation немає, а кликати `/usr/bin/unzip` посеред служіння не годиться:
/// це чужий процес, тимчасова тека і сміття на диску, яке одного разу
/// лишиться. Тут усе в пам'яті і своїм кодом.
///
/// Читаємо за «центральним каталогом» у кінці файла, а не підряд з початку:
/// так знаходяться рівно ті частини, що потрібні, і не розбирається все підряд —
/// у презентації з сотнею картинок це різниця в секунди.
///
/// Зі способів стиснення підтримано два, й інших у `.pptx` не буває: 0 —
/// «як є» і 8 — DEFLATE.
public enum ZipArchive {

    public enum Failure: Error, CustomStringConvertible {
        case notAZip
        case unsupported(method: Int, entry: String)
        case damaged(entry: String)

        public var description: String {
            switch self {
            case .notAZip: return OurWords.t("это не архив ZIP — у файла нет оглавления")
            case let .unsupported(method, entry):
                return OurWords.t("«%s»: неизвестный способ сжатия %s", "\(entry)", "\(method)")
            case let .damaged(entry): return OurWords.t("«%s»: часть архива не распаковалась", "\(entry)")
            }
        }
    }

    /// Що лежить в архіві: ім'я частини → де її шукати.
    struct Entry {
        let name: String
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        /// Зсув локального запису від початку файла.
        let headerOffset: Int
    }

    /// Зміст архіву. Відкривається один раз, далі частини беруться за іменем.
    public struct Reader {
        let data: Data
        let entries: [String: Entry]

        public var names: [String] { entries.keys.sorted() }

        public func contains(_ name: String) -> Bool { entries[name] != nil }

        /// Дістати частину за іменем. `nil` — такої частини в архіві немає.
        public func part(_ name: String) throws -> Data? {
            guard let entry = entries[name] else { return nil }
            return try ZipArchive.extract(entry, from: data)
        }

        /// Частина текстом. Усі XML усередині `.pptx` записано в UTF-8.
        public func text(_ name: String) throws -> String? {
            guard let bytes = try part(name) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
    }

    // MARK: - Зміст

    public static func open(_ url: URL) throws -> Reader {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try open(data)
    }

    public static func open(_ data: Data) throws -> Reader {
        // Кінець центрального каталогу — підпис 0x06054b50. Шукаємо його з кінця:
        // після нього буває коментар довжиною до 64 КБ, тому далі не йдемо.
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let limit = min(data.count, 66_000)
        var end: Int?
        var at = data.count - 22
        let lowest = data.count - limit
        while at >= max(0, lowest) {
            if data[at] == signature[0], data[at + 1] == signature[1],
               data[at + 2] == signature[2], data[at + 3] == signature[3] {
                end = at
                break
            }
            at -= 1
        }
        guard let end, end + 22 <= data.count else { throw Failure.notAZip }

        let count = Int(number(data, at: end + 10, bytes: 2))
        var offset = Int(number(data, at: end + 16, bytes: 4))

        var entries: [String: Entry] = [:]
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 46 <= data.count,
                  number(data, at: offset, bytes: 4) == 0x0201_4b50 else { break }
            let method = Int(number(data, at: offset + 10, bytes: 2))
            let compressed = Int(number(data, at: offset + 20, bytes: 4))
            let uncompressed = Int(number(data, at: offset + 24, bytes: 4))
            let nameLength = Int(number(data, at: offset + 28, bytes: 2))
            let extraLength = Int(number(data, at: offset + 30, bytes: 2))
            let commentLength = Int(number(data, at: offset + 32, bytes: 2))
            let header = Int(number(data, at: offset + 42, bytes: 4))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { break }
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            if !name.hasSuffix("/") {
                entries[name] = Entry(name: name, method: method,
                                      compressedSize: compressed,
                                      uncompressedSize: uncompressed,
                                      headerOffset: header)
            }
            offset = nameStart + nameLength + extraLength + commentLength
        }
        guard !entries.isEmpty else { throw Failure.notAZip }
        return Reader(data: data, entries: entries)
    }

    // MARK: - Розпакування однієї частини

    private static func extract(_ entry: Entry, from data: Data) throws -> Data {
        // Локальний запис: ім'я і «додаткове поле» в ньому своєї довжини,
        // і брати її з центрального каталогу не можна — вони розходяться.
        let at = entry.headerOffset
        guard at + 30 <= data.count, number(data, at: at, bytes: 4) == 0x0403_4b50 else {
            throw Failure.damaged(entry: entry.name)
        }
        let nameLength = Int(number(data, at: at + 26, bytes: 2))
        let extraLength = Int(number(data, at: at + 28, bytes: 2))
        let start = at + 30 + nameLength + extraLength
        let finish = start + entry.compressedSize
        guard finish <= data.count else { throw Failure.damaged(entry: entry.name) }
        let payload = data.subdata(in: start..<finish)

        switch entry.method {
        case 0:
            return payload
        case 8:
            guard let inflated = inflate(payload, capacity: max(entry.uncompressedSize, 1)) else {
                throw Failure.damaged(entry: entry.name)
            }
            return inflated
        default:
            throw Failure.unsupported(method: entry.method, entry: entry.name)
        }
    }

    /// «Сирий» DEFLATE — той самий, що лежить у ZIP: без заголовка zlib.
    private static func inflate(_ raw: Data, capacity: Int) -> Data? {
        raw.withUnsafeBytes { input -> Data? in
            guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return nil }
            // Плюс запас: у порожніх частин розмір нульовий, а буфер потрібен завжди.
            let room = max(capacity + 64, 1024)
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: room)
            defer { destination.deallocate() }
            let written = compression_decode_buffer(destination, room,
                                                    source, raw.count,
                                                    nil, COMPRESSION_ZLIB)
            guard written > 0 || capacity == 0 else { return nil }
            return Data(bytes: destination, count: written)
        }
    }

    /// Ціле з архіву: молодший байт першим, як записано в ZIP.
    private static func number(_ data: Data, at offset: Int, bytes: Int) -> UInt32 {
        guard offset >= 0, offset + bytes <= data.count else { return 0 }
        var value: UInt32 = 0
        for index in (0..<bytes).reversed() {
            value = value << 8 | UInt32(data[data.startIndex + offset + index])
        }
        return value
    }
}
