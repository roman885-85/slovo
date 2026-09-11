import Foundation

/// Адреса місця Писання з поля швидкого вибору (9) — розділ 5.1.9 посібника.
///
/// Формат оригіналу:
///
///     [Номер] Книга Розділ НомерПершогоВірша НомерОстанньогоВірша
///
/// Частини розділяються пробілами; «Номер» потрібен лише книгам, у яких він є.
/// Два особливі випадки описано там само:
///
///   * замість номера вірша стоїть «-» — узяти розділ цілком з першого вірша
///     («иак 4 -»);
///   * останнім віршем указано число свідомо більше, ніж є в розділі
///     (у посібнику це «333»), — узяти до кінця розділу.
///
/// Окремий тип, а не розширення `ReferenceParser`, бо сенс чисел
/// тут інший: у розбору загального вигляду «3,5,7» — це перелік віршів, а у
/// форматі оригіналу два числа після розділу — це межі уривка. Перелік
/// усе ж підтримано: якщо в рядку є кома, читаємо її як список — люди
/// набирають «Мф 5:3,7» за звичкою, і відмовляти їм нема чого.
public struct ScriptureAddress: Sendable, Hashable {

    public let book: BookInfo
    /// `nil`, якщо названо лише книгу: «иак» — відкрити її перший розділ.
    public let chapter: Int?
    /// Перший вірш уривка. `nil` — вірш не названо.
    public let firstVerse: Int?
    /// Останній вірш уривка. `nil` — уривок з одного вірша.
    public let lastVerse: Int?
    /// У рядку стояв «-» замість вірша: потрібен весь розділ.
    public let wantsWholeChapter: Bool
    /// Явний перелік віршів («3,5,7») — тоді межі не рахуються.
    public let listedVerses: [Int]

    public init(book: BookInfo,
                chapter: Int?,
                firstVerse: Int? = nil,
                lastVerse: Int? = nil,
                wantsWholeChapter: Bool = false,
                listedVerses: [Int] = []) {
        self.book = book
        self.chapter = chapter
        self.firstVerse = firstVerse
        self.lastVerse = lastVerse
        self.wantsWholeChapter = wantsWholeChapter
        self.listedVerses = listedVerses
    }

    // MARK: - Розбір

    /// Розбирає рядок в адресу. `nil` — книгу впізнати не вдалося.
    ///
    /// - Parameter books: список книг, серед яких шукати. Зазвичай це книги
    ///   модуля цілком: поле (9) не обмежене вибраним «Класом» (1).
    public static func parse(_ input: String, books: [BookInfo]) -> ScriptureAddress? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Межу між ім'ям книги і числами шукаємо з кінця — інакше цифра на
        // початку імені («1 кор») поїде в номер розділу.
        let parts = ReferenceParser.split(trimmed)
        guard let book = ShortBookNames.book(matching: parts.book, in: books) else { return nil }

        let tail = parts.numbers
        let numbers = integers(in: tail)
        let chapter = numbers.first

        // Перелік через кому — це список, а не межі уривка.
        if tail.contains(",") || tail.contains(";") {
            let listed = ReferenceParser.verseList(in: dropFirstNumber(tail))
            return ScriptureAddress(book: book, chapter: chapter, listedVerses: listed)
        }

        let verses = Array(numbers.dropFirst())
        // «-» без другого числа означає «весь розділ». Між двома числами той
        // самий знак — звичайний діапазон, і цілого розділу не просить.
        let whole = tail.contains(where: isDash) && verses.isEmpty

        return ScriptureAddress(book: book,
                                chapter: chapter,
                                firstVerse: verses.first,
                                lastVerse: verses.count > 1 ? verses[1] : nil,
                                wantsWholeChapter: whole)
    }

    // MARK: - Що виділяти

    /// Номери віршів, які треба виділити, з тих, що є в розділі.
    ///
    /// Саме тут відпрацьовує прийом із посібника з «333»: верхня межа
    /// не перевіряється, а просто обрізається по кінцю розділу.
    public func verseNumbers(available: [Int]) -> [Int] {
        guard !available.isEmpty else { return [] }
        if wantsWholeChapter { return available }
        if !listedVerses.isEmpty { return listedVerses.filter { available.contains($0) } }

        guard let first = firstVerse else { return [] }
        guard let last = lastVerse else {
            return available.contains(first) ? [first] : []
        }
        let lower = min(first, last)
        let upper = max(first, last)
        return available.filter { $0 >= lower && $0 <= upper }
    }

    /// Посилання у звичному вигляді — те, що можна показати підказкою.
    public func displayText(verses: [Int]) -> String {
        let name = book.shortNames.first ?? book.fullName
        guard let chapter else { return name }
        let numbers = ReferenceParser.format(verses: verses)
        return numbers.isEmpty ? "\(name) \(chapter)" : "\(name) \(chapter):\(numbers)"
    }

    // MARK: -

    private static func integers(in text: String) -> [Int] {
        var result: [Int] = []
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
                continue
            }
            if let number = Int(digits) { result.append(number) }
            digits = ""
        }
        if let number = Int(digits) { result.append(number) }
        return result
    }

    /// Хвіст без першого числа: перше — це розділ, далі йдуть вірші.
    private static func dropFirstNumber(_ text: String) -> String {
        guard let start = text.firstIndex(where: { $0.isNumber }) else { return text }
        var end = start
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
        return String(text[end...])
    }

    private static func isDash(_ character: Character) -> Bool {
        character == "-" || character == "\u{2013}" || character == "\u{2014}"
    }
}
