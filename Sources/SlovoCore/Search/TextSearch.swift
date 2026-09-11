import Foundation

/// Пошук по тексту модуля — розділ 5.1.8 посібника.
///
/// «Слова можно писать не полностью. Поиск производится строго по введенным
/// словам. Синтаксический анализ не производится. То есть для увеличения числа
/// совпадений, окончания слов лучше не дописывать.»
///
/// Звідси правило відбору: запит ділиться на слова за пробілами, і вірш підходить,
/// коли в ньому знайшлося КОЖНЕ слово — у будь-якому місці і в будь-якому порядку. Шукати
/// весь запит одним неперервним підрядком не можна: в автора «имеет жизнь»
/// знаходить зокрема «имеете жизнь» (1Иоан. 5:13 на знімку стор. 12), а
/// підрядка «имеет жизнь» там немає.
///
/// Модуль — це 31 тисяча віршів у 66 файлах, і перший пошук зобов'язаний їх усі
/// прочитати й розібрати. Тому роботу влаштовано так: читання йде у фоні,
/// на головний потік повертаються лише готові результати, а будь-який новий
/// запит скасовує попередній — оператор на служінні набирає слово по літері
/// і не має чекати, поки догорять проміжні пошуки.
///
/// Розібрані книги лишаються в кеші самого модуля, а згорнутий текст —
/// в `Index` тут же, тому диск і нормалізація оплачуються один раз
/// за модуль, а не на кожну натиснуту літеру.
public final class TextSearch {

    // MARK: - Що шукати

    public struct Options: Sendable {
        /// Скільки віршів показати. Слово «Бог» трапляється понад три тисячі
        /// разів — весь список не потрібен ні на екрані, ні в пам'яті.
        public var limit: Int
        /// Лише цілі слова: «дар» без «удар» і «дарования».
        ///
        /// У самому полі пошуку (8) завжди вимкнено: посібник прямо просить
        /// не дописувати закінчення, а це і означає «шукати за початком слова».
        public var wholeWords: Bool
        /// Номери книг модуля, якими йти. `nil` — весь модуль.
        public var bookIndices: [Int]?

        public init(limit: Int = 300,
                    wholeWords: Bool = false,
                    bookIndices: [Int]? = nil) {
            self.limit = limit
            self.wholeWords = wholeWords
            self.bookIndices = bookIndices
        }
    }

    /// Розібраний запит: ті самі «введені слова».
    ///
    /// Згорнуті копії слів рахуємо один раз на запит, а не на кожен із
    /// 31 тисячі віршів: нормалізація рядка коштує дорожче за саме порівняння.
    public struct Query: Sendable {
        public let text: String
        public let words: [String]
        fileprivate let foldedWords: [[UInt8]]

        public init(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.text = trimmed
            // Роздільники — лише пробіли і переноси рядків: «синтаксический
            // анализ не производится», тому кома і дефіс лишаються
            // частиною слова, як їх набрав оператор.
            let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            self.words = parts
            self.foldedWords = parts.map(Index.fold).filter { !$0.isEmpty }
        }

        public var isEmpty: Bool { foldedWords.isEmpty }
    }

    // MARK: - Що знайшли

    public struct Hit: Sendable, Hashable, Identifiable {
        public let bookIndex: Int
        public let bookName: String        // скорочення для підпису
        public let chapter: Int
        public let verse: Int
        /// Повний текст вірша — він же піде на слайд.
        ///
        /// Рядок у вікні результатів (5) ріже сам список, а не пошук: на
        /// знімку посібника (стор. 12) він іде з початку вірша і обривається
        /// по правому краю вікна, а не навколо знайденого слова.
        public let text: String
        /// Зсуви всіх знайдених слів у символах `text`, за зростанням і
        /// без перекриттів. Слів у запиті може бути кілька, і підсвічено
        /// в оригіналі кожне.
        public let highlights: [Range<Int>]

        public var id: String { "\(bookIndex).\(chapter).\(verse)" }

        public var reference: String { "\(bookName) \(chapter):\(verse)" }

        /// Перший збіг — ним підписано вірш, до нього прокручується список.
        public var highlight: Range<Int> { highlights.first ?? 0..<0 }

        /// Шматок рядка і ознака «це знайдене слово».
        public struct Segment: Sendable, Hashable {
            public let text: String
            public let isMatch: Bool
        }

        /// Текст вірша, розкладений на шматки для підсвічування. Вид просто йде по
        /// них підряд і фарбує ті, в яких `isMatch`.
        public var segments: [Segment] { TextSearch.segments(of: text, highlights: highlights) }

        public init(bookIndex: Int, bookName: String, chapter: Int, verse: Int,
                    text: String, highlights: [Range<Int>]) {
            self.bookIndex = bookIndex
            self.bookName = bookName
            self.chapter = chapter
            self.verse = verse
            self.text = text
            self.highlights = highlights
        }
    }

    public struct Outcome: Sendable {
        public let query: String
        public let hits: [Hit]
        /// Уперлися в `limit`: збігів у модулі більше, ніж показано.
        public let isTruncated: Bool
        public let scannedVerses: Int
        public let duration: TimeInterval

        public init(query: String, hits: [Hit], isTruncated: Bool, scannedVerses: Int, duration: TimeInterval) {
            self.query = query
            self.hits = hits
            self.isTruncated = isTruncated
            self.scannedVerses = scannedVerses
            self.duration = duration
        }

        public static func empty(query: String) -> Outcome {
            Outcome(query: query, hits: [], isTruncated: false, scannedVerses: 0, duration: 0)
        }
    }

    // MARK: - Згорнутий текст модуля

    /// Усі вірші модуля із заздалегідь згорнутою копією тексту.
    ///
    /// Без нього кожен пошук ганяв би `range(of:options:)` по 31 тисячі рядків,
    /// а це три секунди на запит — на служінні стільки не чекають. Нормалізація
    /// (регістр плюс діакритика) коштує дорого, але однакова для всіх запитів,
    /// тому її результат складаємо один раз: згорнуті вірші лежать підряд
    /// в одному буфері, а порівняння йде по байтах UTF-8.
    public final class Index {

        fileprivate struct Entry {
            let bookIndex: Int
            let bookName: String
            let chapter: Int
            let verse: Int
            let text: String
            let folded: Range<Int>   // шматок спільного буфера
        }

        public let moduleIdentifier: String
        fileprivate let entries: [Entry]
        fileprivate let storage: [UInt8]

        public var verseCount: Int { entries.count }

        fileprivate init(moduleIdentifier: String, entries: [Entry], storage: [UInt8]) {
            self.moduleIdentifier = moduleIdentifier
            self.entries = entries
            self.storage = storage
        }

        /// Читає і згортає весь модуль. `nil` — збирання скасували на півдорозі;
        /// половину модуля запам'ятовувати не можна, інакше пошук мовчки брехатиме.
        public static func build(for module: any TextModule,
                                 isCancelled: () -> Bool = { false },
                                 progress: ((Double) -> Void)? = nil) -> Index? {
            var entries: [Entry] = []
            var storage: [UInt8] = []
            entries.reserveCapacity(32_000)
            storage.reserveCapacity(4 << 20)

            for (position, book) in module.books.enumerated() {
                if isCancelled() { return nil }
                guard let chapters = try? module.chapters(ofBook: book) else { continue }
                let bookName = book.shortNames.first ?? book.fullName

                for chapter in chapters {
                    for verse in chapter.verses {
                        let start = storage.count
                        storage.append(contentsOf: fold(verse.text))
                        entries.append(Entry(bookIndex: book.index,
                                             bookName: bookName,
                                             chapter: chapter.number,
                                             verse: verse.number,
                                             text: verse.text,
                                             folded: start..<storage.count))
                    }
                }
                progress?(Double(position + 1) / Double(max(module.books.count, 1)))
            }
            return Index(moduleIdentifier: module.identifier, entries: entries, storage: storage)
        }

        fileprivate static func fold(_ text: String) -> [UInt8] {
            Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
        }
    }

    // MARK: - Фоновий пошук

    private let queue = DispatchQueue(label: "ua.slovo.text-search", qos: .userInitiated)
    private let lock = NSLock()
    /// Номер живого запиту. Скасування — це зміна номера, а не спільний прапорець:
    /// інакше швидко набраний другий запит скасовував би сам себе.
    private var currentToken = 0
    /// Чіпається лише з `queue`, тому замка не вимагає.
    private var index: Index?

    public init() {}

    /// Запускає пошук, скасувавши попередній. Обидва замикання кличуться на
    /// головній черзі; у скасованого запиту не кличеться жодне.
    ///
    /// - Parameter progress: частка прочитаного модуля, 0…1. Приходить лише
    ///   при першому звертанні до модуля — далі шукати вже нема на що чекати.
    public func start(_ query: String,
                      in module: any TextModule,
                      options: Options = Options(),
                      progress: ((Double) -> Void)? = nil,
                      completion: @escaping (Outcome) -> Void) {
        lock.lock()
        currentToken += 1
        let token = currentToken
        lock.unlock()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { completion(.empty(query: trimmed)) }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let stale = { self.isStale(token) }

            // Хід будується один раз на модуль і за зміни запиту не
            // скасовується. Інакше набір по літері не давав би йому закінчитися:
            // кожна нова літера викидала б недобудований індекс, і
            // тридцять одна тисяча віршів читалася б заново. Прогрес теж
            // шлемо завжди, навіть застарілому запиту, — інакше смуга у вікні
            // результатів завмирає на середині.
            guard let index = self.preparedIndex(for: module, progress: { value in
                guard let progress else { return }
                DispatchQueue.main.async { progress(value) }
            }) else { return }

            let outcome = Self.search(trimmed, in: index, options: options, isCancelled: stale)
            guard !stale() else { return }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Побудувати хід заздалегідь, нічого не шукаючи.
    ///
    /// Потрібно полю пошуку (8): перше звертання до модуля читає його цілком, і
    /// платити за це секундами зручніше в момент, коли в поле лише ставлять
    /// курсор, ніж коли в ньому вже набрали слово.
    public func prepare(_ module: any TextModule,
                        progress: ((Double) -> Void)? = nil,
                        completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.preparedIndex(for: module, progress: { value in
                guard let progress else { return }
                DispatchQueue.main.async { progress(value) }
            })
            guard let completion else { return }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Забути поточний запит: його результат уже не прийде.
    public func cancel() {
        lock.lock()
        currentToken += 1
        lock.unlock()
    }

    /// Віддати пам'ять, зайняту згорнутим текстом. Сам модуль не чіпаємо —
    /// його кешем розпоряджається той, хто модуль відкрив.
    public func releaseIndex() {
        queue.async { self.index = nil }
    }

    private func isStale(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != currentToken
    }

    private func preparedIndex(for module: any TextModule,
                               progress: ((Double) -> Void)?) -> Index? {
        if let index, index.moduleIdentifier == module.identifier { return index }
        guard let built = Index.build(for: module, progress: progress) else { return nil }
        index = built
        return built
    }

    // MARK: - Сам обхід

    /// Разовий синхронний пошук: сам збирає індекс і сам його викидає.
    /// Годиться для перевірочних прогонів і зовнішніх команд, але не для набору
    /// з клавіатури — там потрібен екземпляр `TextSearch` з його кешем.
    public static func run(_ query: String,
                           in module: any TextModule,
                           options: Options = Options(),
                           isCancelled: () -> Bool = { false },
                           progress: ((Double) -> Void)? = nil) -> Outcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty(query: trimmed) }
        guard let index = Index.build(for: module, isCancelled: isCancelled, progress: progress) else {
            return .empty(query: trimmed)
        }
        return search(trimmed, in: index, options: options, isCancelled: isCancelled)
    }

    /// Пошук за готовим індексом.
    ///
    /// Відбір двоступеневий: за байтами згорнутого тексту відсіюємо все зайве,
    /// і лише для вцілілих віршів кличемо пошук Foundation — він один уміє
    /// повернути межі збігу у вихідному рядку, але коштує на два порядки
    /// дорожче за байтове порівняння.
    ///
    /// Вірш підходить, коли в ньому знайшлися ВСІ слова запиту: «поиск
    /// производится строго по введенным словам» (5.1.8).
    public static func search(_ query: String,
                              in index: Index,
                              options: Options = Options(),
                              isCancelled: () -> Bool = { false }) -> Outcome {
        search(Query(query), in: index, options: options, isCancelled: isCancelled)
    }

    public static func search(_ query: Query,
                              in index: Index,
                              options: Options = Options(),
                              isCancelled: () -> Bool = { false }) -> Outcome {
        let started = Date()
        guard !query.isEmpty else { return .empty(query: query.text) }

        let wanted = options.bookIndices.map { Set($0) }
        var hits: [Hit] = []
        var scanned = 0
        var truncated = false

        index.storage.withUnsafeBufferPointer { buffer in
            for entry in index.entries {
                if scanned & 0x3FF == 0, isCancelled() { return }
                if let wanted, !wanted.contains(entry.bookIndex) { continue }
                scanned += 1

                // Швидкий відсів: хоча б одного слова немає в байтах — вірш мимо.
                var missing = false
                for word in query.foldedWords where !contains(word, in: buffer, range: entry.folded) {
                    missing = true
                    break
                }
                if missing { continue }

                let ranges = highlights(of: query.words, in: entry.text, wholeWords: options.wholeWords)
                // Згорнутий рядок міняє довжину («ß» → «ss»), тому байтовий
                // збіг зрідка не підтверджується розбором Foundation.
                // Такий вірш у списку не показуємо: підсвічувати в ньому нічого.
                guard !ranges.isEmpty else { continue }
                guard hits.count < options.limit else {
                    truncated = true
                    return
                }
                hits.append(Hit(bookIndex: entry.bookIndex,
                                bookName: entry.bookName,
                                chapter: entry.chapter,
                                verse: entry.verse,
                                text: entry.text,
                                highlights: ranges))
            }
        }

        return Outcome(query: query.text,
                       hits: hits,
                       isTruncated: truncated,
                       scannedVerses: scanned,
                       duration: Date().timeIntervalSince(started))
    }

    /// Розкласти рядок на шматки за знайденими відрізками. Спільна для віршів і
    /// пісень: підсвічування у вікні результатів одне на все, що шукають.
    public static func segments(of text: String, highlights: [Range<Int>]) -> [Hit.Segment] {
        let characters = Array(text)
        var result: [Hit.Segment] = []
        var position = 0
        for range in highlights {
            let lower = min(max(range.lowerBound, position), characters.count)
            let upper = min(max(range.upperBound, lower), characters.count)
            if lower > position {
                result.append(Hit.Segment(text: String(characters[position..<lower]), isMatch: false))
            }
            if upper > lower {
                result.append(Hit.Segment(text: String(characters[lower..<upper]), isMatch: true))
            }
            position = upper
        }
        if position < characters.count {
            result.append(Hit.Segment(text: String(characters[position...]), isMatch: false))
        }
        return result
    }

    /// Усі входження всіх слів запиту у вірш, у зсувах символів.
    ///
    /// Порожній список означає «вірш не підходить»: слово, якого немає, робить
    /// негодним весь вірш — слова з'єднуються «і», а не «або».
    public static func highlights(of words: [String], in text: String, wholeWords: Bool) -> [Range<Int>] {
        guard !words.isEmpty, !text.isEmpty else { return [] }
        var found: [Range<Int>] = []

        for word in words where !word.isEmpty {
            let ranges = allMatches(of: word, in: text, wholeWords: wholeWords)
            guard !ranges.isEmpty else { return [] }
            found.append(contentsOf: ranges)
        }

        // Слова запиту можуть перетнутися в тексті («сын» і «сына»), і два
        // накладені шматки розклали б рядок у кашу. Склеюємо їх в один.
        found.sort { $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Кожне входження слова у вірш — у зсувах символів вихідного рядка.
    private static func allMatches(of needle: String, in text: String, wholeWords: Bool) -> [Range<Int>] {
        guard !needle.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var result: [Range<Int>] = []
        var from = text.startIndex

        while from < text.endIndex,
              let range = text.range(of: needle, options: options, range: from..<text.endIndex) {
            if !wholeWords || isWholeWord(range, in: text) {
                let lower = text.distance(from: text.startIndex, to: range.lowerBound)
                let upper = text.distance(from: text.startIndex, to: range.upperBound)
                result.append(lower..<upper)
            }
            // З наступного знака, а не з кінця збігу: інакше «аа» в
            // «ааа» знайшлося б один раз замість двох, і підсвічування з'їхало б.
            guard range.lowerBound < text.endIndex else { break }
            from = text.index(after: range.lowerBound)
        }
        return result
    }

    /// Байтове входження. UTF-8 самосинхронізується: продовження символу
    /// ніколи не збіжиться з його початком, тому потрапити в середину літери
    /// таке порівняння не може.
    private static func contains(_ needle: [UInt8], in buffer: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> Bool {
        let count = needle.count
        guard count > 0, range.count >= count else { return false }
        let first = needle[0]
        let last = range.upperBound - count

        var position = range.lowerBound
        while position <= last {
            if buffer[position] == first {
                var offset = 1
                while offset < count, buffer[position + offset] == needle[offset] { offset += 1 }
                if offset == count { return true }
            }
            position += 1
        }
        return false
    }

    /// Перший збіг у вірші.
    ///
    /// Регістр і діакритику знімає сам пошук Foundation, і він же повертає
    /// діапазон у вихідному рядку. Це важливіше за швидкість: згорнутий рядок
    /// міняє довжину («ß» → «ss»), і підсвічування довелося б відображати назад
    /// вручну, посимвольно.
    public static func firstMatch(of needle: String, in text: String, wholeWords: Bool) -> Range<String.Index>? {
        guard !needle.isEmpty, !text.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        var from = text.startIndex
        while from < text.endIndex,
              let range = text.range(of: needle, options: options, range: from..<text.endIndex) {
            if !wholeWords || isWholeWord(range, in: text) { return range }
            guard range.lowerBound < text.endIndex else { break }
            from = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }

}
