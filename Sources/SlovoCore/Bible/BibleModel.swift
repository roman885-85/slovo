import Foundation

/// Одна книга всередині модуля: опис із `bibleqt.ini` або з таблиці
/// `books` модуля MyBible — тексту тут немає.
public struct BookInfo: Sendable, Identifiable, Hashable {
    public let index: Int          // порядковий номер у модулі, 0-based
    public let fileName: String    // PathName (у MyBible — номер книги рядком)
    public let fullName: String    // FullName
    public let shortNames: [String] // ShortName, розбитий за пробілами
    public let chapterCount: Int   // ChapterQty

    /// Наскрізний номер книги в каноні — див. `CanonicalBook`.
    ///
    /// Потрібен, щоб показати поруч два переклади: порядковий номер усередині
    /// модуля для цього не годиться, бо модулі з неканонічними
    /// книгами довші за звичайні і нумерація в них зсунута — «Буття» одного
    /// перекладу ставало навпроти «Товита» іншого.
    public let canonicalNumber: Int?

    public var id: Int { index }

    /// Перше скорочення — те, що показуємо на кнопці в сітці книг.
    public var buttonTitle: String { shortNames.first ?? fullName }

    public init(index: Int, fileName: String, fullName: String,
                shortNames: [String], chapterCount: Int, canonicalNumber: Int? = nil) {
        self.index = index
        self.fileName = fileName
        self.fullName = fullName
        self.shortNames = shortNames
        self.chapterCount = chapterCount
        self.canonicalNumber = canonicalNumber
    }

    public func withCanonicalNumber(_ number: Int?) -> BookInfo {
        BookInfo(index: index, fileName: fileName, fullName: fullName,
                 shortNames: shortNames, chapterCount: chapterCount, canonicalNumber: number)
    }
}

/// Вірш у розібраному вигляді.
public struct Verse: Sendable, Hashable, Identifiable {
    public let number: Int
    public let text: String

    public var id: Int { number }

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

/// Розділ — просто список віршів плюс необов'язковий заголовок.
public struct Chapter: Sendable, Hashable {
    public let number: Int
    public let heading: String?
    public let verses: [Verse]

    public init(number: Int, heading: String?, verses: [Verse]) {
        self.number = number
        self.heading = heading
        self.verses = verses
    }

    public func verse(_ n: Int) -> Verse? { verses.first { $0.number == n } }
}

/// Шапка модуля — усе, що описує переклад цілком.
public struct ModuleInfo: Sendable, Hashable {
    public var name: String              // BibleName
    public var shortName: String         // BibleShortName — ярлик вкладки
    public var isBible: Bool             // Bible = Y/N
    public var hasOldTestament: Bool
    public var hasNewTestament: Bool
    public var hasApocrypha: Bool
    public var isGreek: Bool
    public var language: String?         // Language = ru_RU
    public var copyright: String?
    public var alphabet: String?
    public var hasStrongNumbers: Bool
    public var chapterZero: Bool         // нумерація розділів з нуля
    public var rightToLeft: Bool
    public var showVerseNumbers: Bool
    public var chapterSign: String       // маркер початку розділу в HTML
    public var verseSign: String         // маркер початку вірша
    public var htmlFilter: [String]      // теги, які модуль просить вирізати
    public var encoding: String.Encoding?

    public init() {
        name = ""
        shortName = ""
        isBible = true
        hasOldTestament = true
        hasNewTestament = true
        hasApocrypha = false
        isGreek = false
        language = nil
        copyright = nil
        alphabet = nil
        hasStrongNumbers = false
        chapterZero = false
        rightToLeft = false
        showVerseNumbers = true
        chapterSign = "<h1>"
        verseSign = "<sup>"
        htmlFilter = []
        encoding = nil
    }
}
