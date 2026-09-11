import Foundation

/// Як збирається адреса місця Писання на слайді.
///
/// В оригіналі це вкладка «Слайд» вікна параметрів. Адреса буває двох видів:
/// об'єднана, коли на слайді два переклади й обидві назви зливаються в
/// один рядок виду «Буття(Gen.) 1:1», і окрема, коли в кожного перекладу
/// свій рядок — «Буття 1:1» і «Genesis 1:1». Для кожного з чотирьох випадків
/// окремо задається, брати повну назву книги чи скорочення.
public struct ReferenceFormat: Sendable, Hashable {

    public enum NameLength: Int, Sendable, CaseIterable, Identifiable {
        case long = 0     // «Буття»
        case short = 1    // «Бут.»

        public var id: Int { rawValue }
        public var title: String { self == .long ? "Длинный" : "Короткий" }
    }

    /// Об'єднана адреса: основний переклад і другий у дужках.
    public var combinedMain: NameLength
    public var combinedSecondary: NameLength
    /// Окремі адреси, коли кожен переклад підписано сам по собі.
    public var separateMain: NameLength
    public var separateSecondary: NameLength

    public init(combinedMain: NameLength = .long,
                combinedSecondary: NameLength = .short,
                separateMain: NameLength = .long,
                separateSecondary: NameLength = .long) {
        self.combinedMain = combinedMain
        self.combinedSecondary = combinedSecondary
        self.separateMain = separateMain
        self.separateSecondary = separateSecondary
    }

    public init(config: IniSettings) {
        func length(_ key: String, _ fallback: NameLength) -> NameLength {
            guard let raw = config.int(key, in: "settings"), let value = NameLength(rawValue: raw) else {
                return fallback
            }
            return value
        }
        combinedMain = length("RefAllMainType", .long)
        combinedSecondary = length("RefAllSecType", .short)
        separateMain = length("RefMainType", .long)
        separateSecondary = length("RefSecType", .long)
    }

    // MARK: - Збирання

    public func name(of book: BookInfo, _ length: NameLength) -> String {
        switch length {
        case .long:  return book.fullName
        case .short: return book.shortNames.first ?? book.fullName
        }
    }

    /// Хвіст адреси: «1:1», «1:1-5» для віршів, що йдуть підряд, або «1:1,3,5»
    /// для розрізнених.
    public static func position(chapter: Int, verses: [Int]) -> String {
        let sorted = verses.sorted()
        guard let first = sorted.first else { return "\(chapter)" }
        guard sorted.count > 1, let last = sorted.last else { return "\(chapter):\(first)" }

        let isRange = last - first == sorted.count - 1
        return isRange ? "\(chapter):\(first)-\(last)"
                       : "\(chapter):\(sorted.map(String.init).joined(separator: ","))"
    }

    /// Об'єднана адреса для двох перекладів: «Буття(Gen.) 1:1».
    public func combined(main: BookInfo, secondary: BookInfo?, chapter: Int, verses: [Int]) -> String {
        let tail = Self.position(chapter: chapter, verses: verses)
        let head = name(of: main, combinedMain)
        guard let secondary else { return "\(head) \(tail)" }
        return "\(head)(\(name(of: secondary, combinedSecondary))) \(tail)"
    }

    /// Окрема адреса для одного перекладу.
    public func separate(book: BookInfo, chapter: Int, verses: [Int], isSecondary: Bool) -> String {
        let length = isSecondary ? separateSecondary : separateMain
        return "\(name(of: book, length)) \(Self.position(chapter: chapter, verses: verses))"
    }
}
