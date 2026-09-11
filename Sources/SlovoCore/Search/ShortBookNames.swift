import Foundation

/// Найкоротші скорочення назв книг — розділ 5.1.9 посібника.
///
/// У посібнику на сторінці 14 надруковано список: «Матфея — мт», «Иакова — иа»,
/// «Titus — ti». Список не вигаданий автором вручну: це результат роботи самого
/// розбору, і правило в нього рівно таке:
///
///   1. спершу шукається **точний** збіг з одним зі скорочень книги
///      (`ShortName` у `bibleqt.ini` — «Ин», «Ez», «Jud»);
///   2. якщо точного немає — перше скорочення, яке **починається** з уведеного;
///   3. книги перебираються в тому порядку, в якому вони лежать у модулі.
///
/// Порядок «точне поперед префікса» тут не прикраса, а необхідність.
/// У King James «ez» — це Ezekiel (у нього є рівно таке скорочення),
/// хоча за самим лише префіксом першим трапився б Ezra. Тим самим правилом
/// пояснюються «ze» = Zechariah при наявному Zephaniah, «ma» = Matthew
/// при наявному Malachi, «jn» = John при наявному Jonah і «jud» = Jude
/// при наявному Judges.
///
/// Повне ім'я книги (`FullName`) у порівнянні не бере участі — інакше «от» давало
/// б «От Матфея», а посібник обіцяє Об'явлення. Повне ім'я лишається
/// запасним варіантом, коли за скороченнями не знайшлося нічого.
///
/// Обидві таблиці нижче звірено зі справжніми модулями користувача: усі 66 рядків
/// «Русской Синодальной Библии» і всі 66 рядків «King James Bible» розв'язуються
/// цим правилом рівно в ті книги, що надруковані в посібнику.
public enum ShortBookNames {

    /// Рядок таблиці: як книгу названо в посібнику і найкоротше
    /// скорочення, яким її можна викликати.
    public struct Entry: Sendable, Hashable, Identifiable {
        public let name: String
        public let abbreviation: String

        public var id: String { abbreviation }

        public init(_ name: String, _ abbreviation: String) {
            self.name = name
            self.abbreviation = abbreviation
        }
    }

    /// «Русская Синодальная Библия» — сторінка 14 посібника, слово в слово.
    public static let russianSynodal: [Entry] = [
        Entry("Бытие", "б"),
        Entry("Исход", "и"),
        Entry("Левит", "л"),
        Entry("Числа", "ч"),
        Entry("Второзаконие", "в"),
        Entry("Иисус Навин", "ии"),
        Entry("Судьи", "с"),
        Entry("Руфь", "р"),
        Entry("1 Царств", "1ц"),
        Entry("2 Царств", "2ц"),
        Entry("3 Царств", "3ц"),
        Entry("4 Царств", "4ц"),
        Entry("1 Паралипоменон", "1п"),
        Entry("2 Паралипоменон", "2п"),
        Entry("Ездра", "е"),
        Entry("Неемия", "не"),
        Entry("Есфирь", "ес"),
        Entry("Иов", "ио"),
        Entry("Псалтирь", "пс"),
        Entry("Притчи", "пр"),
        Entry("Екклесиаст", "ек"),
        Entry("Песня Песней", "пе"),

        Entry("Исаия", "иса"),
        Entry("Иеремия", "ие"),
        Entry("Плач Иеремии", "пл"),
        Entry("Иезекииль", "иез"),
        Entry("Даниил", "д"),
        Entry("Осия", "о"),
        Entry("Иоиль", "иои"),
        Entry("Амос", "а"),
        Entry("Авдий", "ав"),
        Entry("Иона", "ион"),
        Entry("Михей", "м"),
        Entry("Наум", "нау"),
        Entry("Аввакум", "авв"),
        Entry("Софония", "со"),
        Entry("Аггей", "аг"),
        Entry("Захария", "з"),
        Entry("Малахия", "ма"),
        Entry("От Матфея", "мт"),
        Entry("От Марка", "мр"),
        Entry("От Луки", "лу"),
        Entry("От Иоанна", "ин"),
        Entry("Деяния", "де"),

        Entry("Иакова", "иа"),
        Entry("1 Петра", "1пе"),
        Entry("2 Петра", "2пе"),
        Entry("1 Иоанна", "1и"),
        Entry("2 Иоанна", "2и"),
        Entry("3 Иоанна", "3и"),
        Entry("Иуды", "иу"),
        Entry("Римлянам", "ри"),
        Entry("1 Коринфянам", "1к"),
        Entry("2 Коринфянам", "2к"),
        Entry("Галатам", "г"),
        Entry("Ефесянам", "еф"),
        Entry("Филиппийцам", "ф"),
        Entry("Колоссянам", "к"),
        Entry("1 Фессалоникийцам", "1ф"),
        // У посібнику в цьому рядку описка: «1 Фессалоникийцам» надруковано
        // двічі, хоча скорочення стоїть «2ф». Назву виправлено, скорочення
        // лишено як в оригіналі.
        Entry("2 Фессалоникийцам", "2ф"),
        Entry("1 Тимофею", "1т"),
        Entry("2 Тимофею", "2т"),
        Entry("Титу", "т"),
        Entry("Филимону", "флм"),
        Entry("Евреям", "ев"),
        Entry("Откровение", "от"),
    ]

    /// «King James Bible» — та сама сторінка посібника.
    public static let kingJames: [Entry] = [
        Entry("Genesis", "ge"),
        Entry("Exodus", "ex"),
        Entry("Leviticus", "le"),
        Entry("Numbers", "nu"),
        Entry("Deuteronomy", "de"),
        Entry("Joshua", "jos"),
        Entry("Judges", "judg"),
        Entry("Ruth", "ru"),
        Entry("1 Samuel", "1s"),
        Entry("2 Samuel", "2s"),
        Entry("1 Kings", "1k"),
        Entry("2 Kings", "2k"),
        Entry("1 Chronicles", "1ch"),
        Entry("2 Chronicles", "2ch"),
        Entry("Ezra", "ezr"),
        Entry("Nehemiah", "ne"),
        Entry("Esther", "est"),
        Entry("Job", "job"),
        Entry("Psalms", "ps"),
        Entry("Proverbs", "pr"),
        Entry("Ecclesiastes", "ec"),
        Entry("Song of Solomon", "ss"),

        Entry("Isaiah", "is"),
        Entry("Jeremiah", "je"),
        Entry("Lamentations", "la"),
        Entry("Ezekiel", "ez"),
        Entry("Daniel", "da"),
        Entry("Hosea", "ho"),
        Entry("Joel", "joe"),
        Entry("Amos", "am"),
        Entry("Obadiah", "ob"),
        Entry("Jonah", "jon"),
        Entry("Micah", "mi"),
        Entry("Nahum", "na"),
        Entry("Habakkuk", "hab"),
        Entry("Zephaniah", "zep"),
        Entry("Haggai", "hag"),
        Entry("Zechariah", "ze"),
        Entry("Malachi", "mal"),
        Entry("Matthew", "ma"),
        Entry("Mark", "mar"),
        Entry("Luke", "lu"),
        Entry("John", "jn"),
        Entry("Acts", "ac"),

        Entry("Romans", "ro"),
        Entry("1 Corinthians", "1co"),
        Entry("2 Corinthians", "2co"),
        Entry("Galatians", "ga"),
        Entry("Ephesians", "ep"),
        Entry("Philippians", "ph"),
        Entry("Colossians", "col"),
        Entry("1 Thessalonians", "1th"),
        Entry("2 Thessalonians", "2th"),
        Entry("1 Timothy", "1ti"),
        Entry("2 Timothy", "2ti"),
        Entry("Titus", "ti"),
        Entry("Philemon", "phile"),
        Entry("Hebrews", "he"),
        Entry("James", "ja"),
        Entry("1 Peter", "1pe"),
        Entry("2 Peter", "2pe"),
        Entry("1 John", "1jo"),
        Entry("2 John", "2jo"),
        Entry("3 John", "3jo"),
        Entry("Jude", "jud"),
        Entry("Revelation", "re"),
    ]

    // MARK: - Розв'язання введеного скорочення

    /// Книга, яку викликає набраний шматок назви.
    ///
    /// Порядок перевірок описано в коментарі до типу і повторює оригінал.
    public static func book(matching token: String, in books: [BookInfo]) -> BookInfo? {
        index(matching: token, in: books).map { books[$0] }
    }

    /// Те саме, але повертається позиція в переданому списку, а не книга:
    /// список буває відфільтрований «Класом» (1), і позиція там своя.
    public static func index(matching token: String, in books: [BookInfo]) -> Int? {
        let needle = key(token)
        guard !needle.isEmpty else { return nil }

        // 1. Точне скорочення.
        for (position, book) in books.enumerated()
        where book.shortNames.contains(where: { key($0) == needle }) {
            return position
        }
        // 2. Початок скорочення.
        for (position, book) in books.enumerated()
        where book.shortNames.contains(where: { key($0).hasPrefix(needle) }) {
            return position
        }
        // 3. Запасний варіант — повне ім'я. В оригіналі його немає, але й шкоди
        //    від нього немає: сюди доходить лише те, що за скороченнями не знайшлося.
        for (position, book) in books.enumerated() where key(book.fullName) == needle {
            return position
        }
        for (position, book) in books.enumerated() where key(book.fullName).hasPrefix(needle) {
            return position
        }
        return nil
    }

    /// Найкоротше скорочення для кожної книги списку — та сама таблиця,
    /// що надрукована в посібнику, але порахована для поточного модуля.
    ///
    /// Рахується перебором: беремо кожне скорочення книги, вкорочуємо його до
    /// одного знака і лишаємо найкоротший шматок, який усе ще приводить
    /// саме до цієї книги. Інакше таблицю довелося б тримати окремо для
    /// кожного з півтори сотні модулів — а в користувача вони сімома мовами.
    public static func shortest(in books: [BookInfo]) -> [Entry] {
        // Ключі рахуємо один раз: їх близько тисячі, а перебір проганяє по них
        // кожен пробний префікс.
        let keys = books.map { $0.shortNames.map(key).filter { !$0.isEmpty } }

        func resolves(_ needle: String) -> Int? {
            for (position, list) in keys.enumerated() where list.contains(needle) { return position }
            for (position, list) in keys.enumerated()
            where list.contains(where: { $0.hasPrefix(needle) }) { return position }
            return nil
        }

        return books.enumerated().map { position, book in
            var best: String?
            for candidate in keys[position] {
                let characters = Array(candidate)
                for length in 1...characters.count {
                    let probe = String(characters[0..<length])
                    guard resolves(probe) == position else { continue }
                    if best == nil || probe.count < best!.count { best = probe }
                    break
                }
            }
            return Entry(book.fullName, best ?? (book.shortNames.first ?? book.fullName))
        }
    }

    // MARK: -

    /// Ключ порівняння: регістр, діакритика, крапки, пробіли і дефіси значення
    /// не мають — «1Кор.», «1 кор» і «1КОР» це одне й те саме скорочення.
    static func key(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        where character.isLetter || character.isNumber {
            result.append(character)
        }
        return result
    }
}
