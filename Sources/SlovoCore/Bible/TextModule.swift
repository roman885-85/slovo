import Foundation

/// Текстовий модуль — книга, доступна для показу, незалежно від формату файла.
///
/// Оригінальна програма працює і з модулями «Цитати з Біблії»
/// (тека з `bibleqt.ini` і HTML), і з модулями MyBible (одна база SQLite).
/// Решті застосунку різниця байдужа, тому вона закінчується
/// тут: далі йдуть книги, розділи і вірші.
public protocol TextModule: AnyObject {
    /// Ім'я теки або файлу — ним модуль упізнається в налаштуваннях і в порядку вкладок.
    var identifier: String { get }
    var info: ModuleInfo { get }
    var books: [BookInfo] { get }
    var format: TextModuleFormat { get }

    func chapters(ofBook book: BookInfo) throws -> [Chapter]
    /// Уже розібрана книга, якщо вона є в кеші.
    func cachedChapters(ofBook book: BookInfo) -> [Chapter]?
    func releaseCache()
}

public enum TextModuleFormat: String, Sendable {
    case bibleQuote
    case myBible
    case mySword

    public var title: String {
        switch self {
        case .bibleQuote: return OurWords.t("Цитата из Библии")
        case .myBible:    return "MyBible"
        case .mySword:    return "MySword"
        }
    }
}

public extension TextModule {

    var displayName: String {
        info.name.isEmpty ? identifier : info.name
    }

    func chapter(_ number: Int, ofBook book: BookInfo) throws -> Chapter? {
        try chapters(ofBook: book).first { $0.number == number }
    }

    /// Пошук книги за будь-яким з її скорочень або за повною назвою.
    func book(matching token: String) -> BookInfo? {
        let needle = Self.fold(token)
        return books.first { book in
            book.shortNames.contains { Self.fold($0) == needle } || Self.fold(book.fullName) == needle
        }
    }

    /// Та сама книга в іншому перекладі.
    ///
    /// Спершу за наскрізним номером канону, і лише якщо його немає — за
    /// порядковим. Порядковий лишено як запасний шлях для модулів,
    /// де книгу впізнати не вдалося: краще показати сусідню, ніж нічого.
    func counterpart(of book: BookInfo) -> BookInfo? {
        if let canonical = book.canonicalNumber,
           let match = books.first(where: { $0.canonicalNumber == canonical }) {
            return match
        }
        return books.indices.contains(book.index) ? books[book.index] : nil
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { !$0.isWhitespace && $0 != "." }
    }
}
