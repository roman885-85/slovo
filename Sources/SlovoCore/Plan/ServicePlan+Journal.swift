import Foundation

/// План (10) у форматі оригіналу.
///
/// Посібник (5.1.10): «Для каждого случая можно сохранить свой план в
/// отдельный файл и загружать нужный. При запуске VisioBible отображает
/// последний использовавшийся вариант плана». В оригіналу останній план
/// лежить у `PlanDef.ini`, збережені — у теці `Plans`, і обидва в тій самій
/// розмітці `<JournalFile>`, що й `History.ini`.
///
/// Раніше «Слово» писало свій JSON і файлів VisioBible не відкривало зовсім.
/// Тепер читаються обидва види: журнал упізнається за першим рядком, а все
/// інше як і раніше розбирається як JSON.
public extension ServicePlan {

    /// Ім'я файлу останнього плану — те саме, що в оригіналу.
    static let defaultFileName = "PlanDef.ini"
    /// Розширення збережених планів оригіналу.
    static let journalFileExtension = "ini"

    // MARK: - Читання

    /// План із файла будь-якого з двох видів.
    static func readAny(contentsOf url: URL) throws -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PlanError.unreadable(url.lastPathComponent, "\(error.localizedDescription)")
        }

        let text = CodePage.decode(data, declared: nil)
        guard JournalFile.looksLikeJournal(text) else {
            return try read(contentsOf: url)
        }

        var plan = ServicePlan(journal: JournalFile.parse(text))
        plan.title = url.deletingPathExtension().lastPathComponent
        plan.markSaved(as: url)
        return LoadResult(plan: plan, skippedItems: 0)
    }

    /// Пункти з трьох журналів.
    ///
    /// У нашому плані список один і порядок у ньому — порядок подачі, а в
    /// оригіналу пункти розкладено за вкладками модулів. Свій порядок пишемо
    /// окремим полем `Order`; у чужому файлі його немає, і тоді пункти йдуть
    /// журналами підряд — Біблія, Текст, Пісні.
    init(journal: JournalFile) {
        var numbered: [(order: Int, item: PlanItem)] = []
        var fallback = 0

        for section in JournalFile.Section.allCases {
            for entry in journal[section] {
                guard let item = PlanItem(journalItem: entry, section: section) else { continue }
                numbered.append((entry.int("Order") ?? (1_000_000 + fallback), item))
                fallback += 1
            }
        }
        numbered.sort { $0.order < $1.order }
        self.init(items: numbered.map(\.item))
    }

    // MARK: - Запис

    func journal() -> JournalFile {
        var result = JournalFile()
        for (position, item) in items.enumerated() {
            let (section, entry) = item.journalItem(order: position)
            result.items[section, default: []].append(entry)
        }
        return result
    }

    /// Збереження у файл оригіналу.
    mutating func saveAsJournal(to url: URL) throws {
        try journal().write(to: url)
        markSaved(as: url)
    }
}

// MARK: - Пункт плану

extension PlanItem {

    /// Розбір пункту з журналу. `nil` — пункт ні про що: в оригіналу в
    /// журналі «Текст» може лежати порожній рядок, і списку він не потрібен.
    init?(journalItem item: JournalFile.Item, section: JournalFile.Section) {
        let caption = item.string("Caption")
        let reference = item.string("Reference")
        let quote = item.string("Quote")

        switch section {
        case .bible:
            guard let book = item.int("Book"), book >= 0 else { return nil }
            // Розділ і вірш у файлі рахуються з нуля, довжина уривка лежить
            // окремим полем. Свій список віршів пишемо рядком «16,17,18»:
            // виділення може бути й не суцільним, а поле довжини цього не виражає.
            let chapter = (item.int("Chapter") ?? 0) + 1
            let listed = PlanItem.parseVerses(item.string("Verses"))
            let verses: [Int]
            if !listed.isEmpty {
                verses = listed
            } else {
                let first = (item.int("Verse") ?? 0) + 1
                let extra = min(max(item.int("VersesRangeCount") ?? 0, 0), 400)
                verses = Array(first...(first + extra))
            }
            // Підпис рядка — лише адреса: текст цитати в оригіналу лежить
            // окремим полем Quote, а Caption склеює їх через дефіс.
            let title = reference.isEmpty ? caption : reference
            self.init(title: title.isEmpty ? OurWords.t("Отрывок %s", "\(chapter)") : title,
                      subtitle: PlanItem.shorten(quote),
                      content: .scripture(Scripture(moduleID: item.string("Module"),
                                                    bookIndex: book,
                                                    chapter: chapter,
                                                    verses: verses)))

        case .songs:
            let file = item.string("SongBook")
            guard !file.isEmpty else { return nil }
            self.init(title: caption.isEmpty ? file : caption,
                      subtitle: PlanItem.shorten(quote),
                      content: .song(SongPartReference(bookFileName: file,
                                                       songIndex: max(item.int("Song") ?? 0, 0),
                                                       // Немає частини або вона від'ємна — пісня цілком.
                                                       partIndex: item.int("Part").flatMap { $0 >= 0 ? $0 : nil })))

        case .text:
            let heading = item.string("Heading", default: reference)
            let body = item.string("Body", default: quote)
            guard !heading.isEmpty || !body.isEmpty || !caption.isEmpty else { return nil }
            let document = PlainTextDocument(title: heading, body: body.isEmpty ? caption : body)
            self.init(title: caption.isEmpty ? document.summary(limit: 80) : caption,
                      content: .text(document))
        }
    }

    /// Пункт для запису в журнал разом із журналом, якому він належить.
    func journalItem(order: Int) -> (JournalFile.Section, JournalFile.Item) {
        switch content {
        case .scripture(let reference):
            let first = reference.verses.first ?? 1
            var entry = JournalFile.Item([
                ("Caption", HistoryRecord.caption(reference: title, quote: subtitle ?? "")),
                ("Reference", title),
                ("Quote", subtitle ?? ""),
                ("Class", "0"),
                ("Book", "\(reference.bookIndex)"),
                ("Chapter", "\(max(reference.chapter - 1, 0))"),
                ("Verse", "\(max(first - 1, 0))"),
                ("VersesRangeCount", "\(max(reference.verses.count - 1, 0))"),
            ])
            // Свої поля йдуть у кінці: VisioBible зайвих атрибутів не читає і
            // на них не спотикається, а нам вони повертають точний уривок.
            entry["Verses"] = PlanItem.formatVerses(reference.verses)
            entry["Module"] = reference.moduleID
            entry["Order"] = "\(order)"
            return (.bible, entry)

        case .song(let reference):
            var fields: [(String, String)] = [
                ("Caption", title),
                ("Quote", subtitle ?? ""),
                ("SongBook", reference.bookFileName),
                ("Song", "\(reference.songIndex)"),
            ]
            // Пісня цілком — без частини.
            if let part = reference.partIndex { fields.append(("Part", "\(part)")) }
            var entry = JournalFile.Item(fields)
            entry["Order"] = "\(order)"
            return (.songs, entry)

        case .text(let document):
            var entry = JournalFile.Item([
                ("Caption", title),
                ("Reference", document.title),
                ("Quote", document.body),
            ])
            entry["Heading"] = document.title
            entry["Body"] = document.body
            entry["Order"] = "\(order)"
            return (.text, entry)
        }
    }
}
