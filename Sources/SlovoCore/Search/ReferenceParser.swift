import Foundation

/// Посилання, впізнане в рядку швидкого вводу: книга модуля плюс те, що
/// вдалося вичитати з цифрового хвоста.
///
/// Книга тут уже конкретна — `BookInfo` вибраного модуля, а не ім'я.
/// Ввід буває неоднозначним («Иоан» — це і Євангеліє, і три послання),
/// тому розбір повертає список таких посилань, а не одне.
public struct ParsedReference: Sendable, Hashable, Identifiable {

    /// Наскільки впевнено впізнано книгу. Порядок значень — це і порядок
    /// підказок у списку: точне скорочення завжди вище за здогадку за підрядком.
    public enum Match: Int, Sendable, Comparable, CaseIterable {
        case exact = 0      // «Ин» — рівно одне зі скорочень або повне ім'я
        case prefix = 1     // «Иоа» — початок скорочення або повного імені
        case initials = 2   // «иис нав» — початки слів підряд
        case inside = 3     // «коринф» — шматок імені десь усередині

        public static func < (lhs: Match, rhs: Match) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let book: BookInfo
    /// `nil`, коли ввели лише книгу: «Ин» — відкрити її перший розділ.
    public let chapter: Int?
    /// Порожньо, коли вірш не названо: «Ин 3» — весь розділ.
    public let verses: [Int]
    public let match: Match

    public var id: Int { book.index }

    public init(book: BookInfo, chapter: Int?, verses: [Int], match: Match) {
        self.book = book
        self.chapter = chapter
        self.verses = verses
        self.match = match
    }

    /// Чи є такий розділ у книзі. Число розділів відоме з `ChapterQty`,
    /// тому перевірка не вимагає читання тексту — підказку можна позначити
    /// просто під час набору.
    public var isChapterValid: Bool {
        guard let chapter else { return true }
        guard book.chapterCount > 0 else { return chapter >= 0 }
        return chapter >= 0 && chapter <= book.chapterCount
    }

    public var shortName: String { book.shortNames.first ?? book.fullName }

    /// Посилання у звичному вигляді: «Ин 3:16-18».
    public var displayText: String {
        guard let chapter else { return shortName }
        guard !verses.isEmpty else { return "\(shortName) \(chapter)" }
        return "\(shortName) \(chapter):\(ReferenceParser.format(verses: verses))"
    }
}

/// Розбір рядка-посилання: «Ин 3:16», «Быт 1:1-5», «Мф.5:3,5,7», «Genesis 1 1».
///
/// Синтаксис вводу в оригіналі ніде не описано — друкують як звикли,
/// тому розбір нічого не перевіряє, а витягує з рядка все, що в ньому
/// є: спершу відрізає цифровий хвіст, потім шукає книгу за залишком.
public enum ReferenceParser {

    /// Скільки підказок показувати. Більше десятка в список швидкого вводу
    /// все одно не влазить, а перебір усіх 66 книг нічого не коштує.
    public static let defaultLimit = 12

    /// Діапазон, довший за будь-який розділ Біблії (у Пс 118 — 176 віршів), означає
    /// описку, а не намір; такий ввід не має роздувати вибірку.
    public static let maxVerseSpan = 200

    // MARK: - Розбір цілком

    public static func parse(_ input: String, in module: any TextModule, limit: Int = defaultLimit) -> [ParsedReference] {
        parse(input, books: module.books, limit: limit)
    }

    public static func parse(_ input: String, books: [BookInfo], limit: Int = defaultLimit) -> [ParsedReference] {
        let parts = split(input)
        let tail = numbers(in: parts.numbers)

        return self.books(matching: parts.book, in: books, limit: limit).map { found in
            ParsedReference(book: found.book, chapter: tail.chapter, verses: tail.verses, match: found.match)
        }
    }

    /// Однозначна відповідь або нічого. Потрібен там, де питати нема в кого:
    /// Enter у полі швидкого вводу, посилання з плану служіння, зовнішня команда.
    public static func resolve(_ input: String, books: [BookInfo]) -> ParsedReference? {
        let found = parse(input, books: books, limit: 2)
        guard let first = found.first else { return nil }
        // Дві однаково добрі книги — це не відповідь, а питання до оператора.
        if found.count > 1, found[1].match == first.match { return nil }
        return first
    }

    public static func resolve(_ input: String, in module: any TextModule) -> ParsedReference? {
        resolve(input, books: module.books)
    }

    // MARK: - Межа між книгою і цифрами

    /// Ділить ввід на ім'я книги і цифровий хвіст.
    ///
    /// Хвіст шукаємо з кінця, інакше цифра на початку імені («1Кор», «2Ин») поїде
    /// в номер розділу. Крапки і пробіли, проковтнуті при зворотному ході, віддаємо
    /// книзі назад: у «Быт. 1:1» крапка належить скороченню, а не числу.
    public static func split(_ input: String) -> (book: String, numbers: String) {
        let chars = Array(input)
        guard !chars.isEmpty else { return ("", "") }

        var cursor = chars.count - 1
        while cursor >= 0, chars[cursor].isNumber || isSeparator(chars[cursor]) {
            cursor -= 1
        }

        var start = cursor + 1
        while start < chars.count, !chars[start].isNumber { start += 1 }

        let book = String(chars[0..<start]).trimmingCharacters(in: .whitespaces)
        return (book, String(chars[start...]))
    }

    /// Цифровий хвіст: «3:16-18» → (3, [16, 17, 18]).
    /// Перше число — завжди розділ, решта — вірші; так само читається і
    /// «Genesis 1 1», де роздільником служить пробіл.
    public static func numbers(in text: String) -> (chapter: Int?, verses: [Int]) {
        guard let firstDigit = text.firstIndex(where: { $0.isNumber }) else { return (nil, []) }
        var end = firstDigit
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }

        return (Int(text[firstDigit..<end]), verseList(in: String(text[end...])))
    }

    /// Список віршів з розкритими діапазонами: «3,5,7-9» → [3, 5, 7, 8, 9].
    /// Окрема точка входу потрібна F9: там книгу і розділ уже вибрано і в поле
    /// вводять лише вірші.
    public static func verseList(in text: String) -> [Int] {
        var result: [Int] = []
        var digits = ""
        var afterDash = false

        func flush() {
            defer { digits = ""; afterDash = false }
            guard let number = Int(digits) else { return }
            if afterDash, let from = result.last, number > from {
                // `from + maxVerseSpan` переповнюється на числі на кшталт
                // «1-9223372036854775807», набраному в полі швидкого вводу,
                // і це не помилка розбору, а аварійне завершення. Рахуємо
                // довжину діапазону відніманням.
                let span = min(number - from, maxVerseSpan)
                result.append(contentsOf: (from + 1)...(from + span))
            } else {
                result.append(number)
            }
        }

        for character in text {
            if character.isNumber {
                digits.append(character)
                continue
            }
            if !digits.isEmpty { flush() }
            if isDash(character) { afterDash = true }
        }
        if !digits.isEmpty { flush() }

        // Порядок вводу («7,3») нічого не значить, а виділення віршів — значить.
        return Array(Set(result)).sorted()
    }

    /// Згортає номери, що йдуть підряд, назад у діапазон — для підпису.
    public static func format(verses: [Int]) -> String {
        let sorted = Array(Set(verses)).sorted()
        guard let first = sorted.first, let last = sorted.last else { return "" }
        if sorted.count > 1, last - first == sorted.count - 1 { return "\(first)-\(last)" }
        return sorted.map(String.init).joined(separator: ",")
    }

    // MARK: - Пошук книги

    public struct BookMatch: Sendable, Hashable {
        public let book: BookInfo
        public let match: ParsedReference.Match

        public init(book: BookInfo, match: ParsedReference.Match) {
            self.book = book
            self.match = match
        }
    }

    /// Кандидати на книгу, від найточнішого до найвільнішого.
    ///
    /// Точного збігу мало: скорочення в `bibleqt.ini` покривають не все,
    /// чим користуються (у послань до Коринтян немає варіанта «Кор»), а повні
    /// імена починаються зі службових слів — «От Иоанна», «К Римлянам»,
    /// «1-е Петра». Тому крім початку рядка перевіряємо початки слів і
    /// входження всередину імені.
    public static func books(matching token: String, in books: [BookInfo], limit: Int = defaultLimit) -> [BookMatch] {
        let needle = key(token)
        guard !needle.isEmpty else { return [] }
        let needleWords = words(token)

        var found: [BookMatch] = []
        for book in books {
            var best: ParsedReference.Match?

            for candidate in book.shortNames + [book.fullName] {
                let candidateKey = key(candidate)
                guard !candidateKey.isEmpty else { continue }

                let match: ParsedReference.Match?
                if candidateKey == needle {
                    match = .exact
                } else if candidateKey.hasPrefix(needle) {
                    match = .prefix
                } else if matchesWordwise(needleWords, in: words(candidate)) {
                    match = .initials
                } else if needle.count >= 3, candidateKey.contains(needle) {
                    // Шматок закоротший упізнає що завгодно: «ин» сидить і всередині
                    // «Коринфянам», і всередині «Филиппийцам».
                    match = .inside
                } else {
                    match = nil
                }

                if let match, best == nil || match < best! { best = match }
                if best == .exact { break }
            }

            if let best { found.append(BookMatch(book: book, match: best)) }
        }

        found.sort { left, right in
            if left.match != right.match { return left.match < right.match }
            return left.book.index < right.book.index
        }
        return Array(found.prefix(limit))
    }

    // MARK: -

    /// Ключ для порівняння: регістр, діакритика, крапки, дефіси і пробіли у
    /// вводі значення не мають — «мф.», «Мф» і «МФ .» це одне й те саме.
    private static func key(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) {
            if character.isWhitespace || character == "." || character == "-" { continue }
            result.append(character)
        }
        return result
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "-" })
            .map(String.init)
    }

    /// «иис нав» → «Иисус Навин»: кожне слово вводу починає своє слово імені.
    private static func matchesWordwise(_ needle: [String], in candidate: [String]) -> Bool {
        guard needle.count > 1, needle.count <= candidate.count else { return false }
        for (index, word) in needle.enumerated() where !candidate[index].hasPrefix(word) {
            return false
        }
        return true
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character == ":" || character == "," || character == ";"
            || character == "." || isDash(character)
    }

    private static func isDash(_ character: Character) -> Bool {
        character == "-" || character == "\u{2013}" || character == "\u{2014}"
    }
}
