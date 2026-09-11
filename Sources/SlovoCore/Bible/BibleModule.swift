import Foundation

/// Завантажений модуль Біблії: шапка, список книг і ліниве читання тексту.
///
/// Тексти не читаються при відкритті модуля — в одного лише BHS+ книги важать
/// сотні кілобайтів, а модулів більше півсотні. Книга читається і розбирається
/// при першому звертанні й лишається в кеші.
public final class BibleModule: TextModule {

    public let directory: URL
    public let identifier: String
    public let info: ModuleInfo
    public let books: [BookInfo]
    public var format: TextModuleFormat { .bibleQuote }

    private var chapterCache: [Int: [Chapter]] = [:]
    private let cacheLock = NSLock()

    public init(directory: URL) throws {
        guard let iniURL = Self.locateIni(in: directory) else {
            throw ModuleError.iniNotFound(directory)
        }
        let parsed = try BibleQuoteIni.parse(fileAt: iniURL)

        self.directory = directory
        self.identifier = directory.lastPathComponent
        self.info = parsed.info
        // Наскрізні номери проставляємо одразу: без них поруч із цим перекладом
        // не можна правильно показати другий.
        self.books = CanonicalBook.assignNumbers(to: parsed.books)
    }

    /// Розділи книги. Перше звертання читає файл з диска.
    public func chapters(ofBook book: BookInfo) throws -> [Chapter] {
        cacheLock.lock()
        if let cached = chapterCache[book.index] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let fileURL = resolveBookFile(book.fileName) else {
            throw ModuleError.bookFileNotFound(book.fileName, identifier)
        }
        let data = try Data(contentsOf: fileURL)
        let text = CodePage.decode(data, declared: info.encoding)
        let chapters = ChapterHTML.parse(text, info: info, expectedChapters: book.chapterCount)

        cacheLock.lock()
        chapterCache[book.index] = chapters
        cacheLock.unlock()
        return chapters
    }

    /// Уже розібрана книга, якщо вона є в кеші. Потрібна, щоб відрізнити
    /// миттєвий випадок від того, заради якого варто йти у фон.
    public func cachedChapters(ofBook book: BookInfo) -> [Chapter]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return chapterCache[book.index]
    }

    public func releaseCache() {
        cacheLock.lock()
        chapterCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: -

    private func resolveBookFile(_ name: String) -> URL? {
        let direct = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        // Регістр в ini і на диску збігається не завжди — на чутливій до
        // регістру файловій системі прямий шлях промахнеться.
        let wanted = name.lowercased()
        let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard let match = contents?.first(where: { $0.lowercased() == wanted }) else { return nil }
        return directory.appendingPathComponent(match)
    }

    private static func locateIni(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        guard let name = contents.first(where: { $0.lowercased() == "bibleqt.ini" }) else { return nil }
        return directory.appendingPathComponent(name)
    }
}

public enum ModuleError: Error, CustomStringConvertible {
    case iniNotFound(URL)
    case bookFileNotFound(String, String)

    public var description: String {
        switch self {
        case .iniNotFound(let url):
            return OurWords.t("в папке %s нет bibleqt.ini", "\(url.lastPathComponent)")
        case .bookFileNotFound(let file, let module):
            return OurWords.t("модуль %s: не найден файл книги %s", "\(module)", "\(file)")
        }
    }
}
