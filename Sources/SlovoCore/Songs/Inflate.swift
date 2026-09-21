import Foundation
import Compression

/// Розпакування zlib-потоку.
///
/// У `Compression` від Apple алгоритм `COMPRESSION_ZLIB` — це «сирий» DEFLATE
/// без двобайтового заголовка zlib і без контрольної суми в кінці. Дані
/// стара програма записано повноцінним zlib-потоком, тому заголовок знімаємо
/// самі, а adler32 у хвості просто не заважає — розпакування кінчається раніше.
enum Inflate {

    static func zlib(_ data: Data) throws -> Data {
        guard data.count > 6 else { throw SongBookError.inflateFailed }

        let raw = data.dropFirst(2)          // 78 9C і подібні
        var capacity = max(data.count * 8, 1 << 16)

        // Розмір розпакованих даних заздалегідь невідомий: якщо не вмістилося,
        // пробуємо ще раз з більшим буфером, а не гадаємо один раз.
        for _ in 0..<8 {
            if let result = inflate(raw, capacity: capacity) { return result }
            capacity *= 4
        }
        throw SongBookError.inflateFailed
    }

    private static func inflate(_ raw: Data, capacity: Int) -> Data? {
        raw.withUnsafeBytes { input -> Data? in
            guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }

            let written = compression_decode_buffer(destination, capacity,
                                                    source, raw.count,
                                                    nil, COMPRESSION_ZLIB)
            // Рівно врівень з буфером — майже напевно обрізано, беремо більше.
            guard written > 0, written < capacity else { return nil }
            return Data(bytes: destination, count: written)
        }
    }
}
