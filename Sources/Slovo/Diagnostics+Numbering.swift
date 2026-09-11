import Foundation
import SlovoCore

/// Самопроверка нумерации переводов.
///
/// Проверять тут есть что: правила лежат в чужой базе, стандарт переводу
/// никто не объявлял, а ошибка в трансляции выглядит не как поломка, а как
/// соседний стих на экране — заметить её на служении уже поздно. Поэтому все
/// проверки ниже считают по настоящим модулям владельца: переводят каждый
/// адрес целой книги, ищут его в целевом переводе и сверяют текст.
extension Diagnostics {

    /// Книги для кругового прогона: те, где правила есть, и одна без правил.
    ///
    /// Всю Библию гонять незачем — разбор шестидесяти шести книг в двух
    /// переводах стоит десятки секунд, а окно диагностики открывают между
    /// служениями. Эти семь книг накрывают все четыре вида правил.
    private static let numberingBooks = [20, 40, 220, 230, 250, 350, 510]

    /// Имя раздела нарочно своё: в `Diagnostics.swift` уже есть
    /// `numberingSection(_:)` от окна редактора, и два одноимённых раздела
    /// путали бы и вызывающего, и отчёт.
    static func verseNumberingSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        let engine = VerseNumbering.shared
        if !engine.isReady { engine.loadRules() }

        checks.append(numberingTable(engine))

        // Опорные переводы считаем по-настоящему (это разбор Псалтири), а
        // остальным берём уже посчитанное — иначе открытие окна диагностики
        // упёрлось бы в полминуты разбора пятидесяти пяти переводов.
        let ru = numberingModule(state, standard: "ru", preferring: ["rst+", "RU_RST", "RU_RBO_2011", "nrt", "bti'15"])
        let en = numberingModule(state, standard: "en", preferring: ["KJV", "ubg", "bwp", "sch'51"])
        NumberingAssignments.shared.applyKnown(modules: state.allModules)

        checks.append(contentsOf: numberingRoster(state, engine))
        checks.append(contentsOf: numberingGuessCheck(state))
        checks.append(contentsOf: numberingWiringCheck(state))
        checks.append(contentsOf: numberingAnchors(ru: ru, en: en, engine: engine))
        checks.append(contentsOf: numberingRoundTrip(ru: ru, en: en, engine: engine))
        checks.append(numberingCollisions(ru: ru, engine: engine))
        checks.append(numberingMissingTarget(state: state, en: en, engine: engine))
        checks.append(numberingOwnerStore())
        return checks
    }

    // MARK: - Таблица правил

    private static func numberingTable(_ engine: VerseNumbering) -> Check {
        guard engine.isReady else {
            return Check(area: "Нумерація", name: "Таблиця правил",
                         status: .warning,
                         detail: "базу inconsistencies.sqlite3 не знайдено — трансляцію вимкнено, "
                             + "переклади показуються кожен за своїми номерами")
        }
        let names = engine.standards.map { "\($0.id) — \($0.title)" }.joined(separator: "; ")
        return Check(area: "Нумерація", name: "Таблиця правил",
                     status: .ok,
                     detail: "правил \(engine.ruleCount), із них наших поправок \(engine.correctionCount); "
                         + "стандарти: \(names); база \(engine.databasePath ?? "—")")
    }

    // MARK: - Кто по какому стандарту

    private static func numberingRoster(_ state: AppState, _ engine: VerseNumbering) -> [Check] {
        let store = NumberingAssignments.shared
        var byStandard: [String: Int] = [:]
        var bySource: [String: Int] = [:]
        var unknown: [String] = []

        for module in state.allModules {
            guard let assignment = store.knownAssignment(forModule: module.identifier), assignment.isKnown else {
                unknown.append(module.identifier)
                continue
            }
            byStandard[assignment.standardID, default: 0] += 1
            bySource[assignment.source.title, default: 0] += 1
        }
        let known = state.allModules.count - unknown.count
        let spread = byStandard.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let sources = bySource.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")

        var checks = [
            Check(area: "Нумерація", name: "Переклади розписано за стандартами",
                  status: known == 0 ? .warning : .ok,
                  detail: known == 0
                      ? "жодному перекладу стандарт ще не пораховано: врізку в завантаження бібліотеки не зроблено"
                      : "зі стандартом \(known) із \(state.allModules.count) (\(spread)); звідки: \(sources)"
                          + (unknown.isEmpty ? "" : "; без стандарту: \(unknown.prefix(6).joined(separator: ", "))")),
        ]

        // Перевод без стандарта — не поломка: он просто показывается по своим
        // номерам. Поломка была бы, если бы мы подставили ему чужие.
        let identity = unknown.compactMap { state.module($0) }.allSatisfy { module in
            engine.isIdentity(from: engine.standard(id: "ru"), to: engine.standard(of: module))
        }
        checks.append(Check(area: "Нумерація", name: "Переклад без стандарту не перекладається",
                            status: identity ? .ok : .failed,
                            detail: unknown.isEmpty
                                ? "таких перекладів немає"
                                : "\(unknown.count) перекладів без стандарту показуються за своїми номерами"))
        return checks
    }

    // MARK: - Проводка до слайда

    /// Стандарт, по которому считает САМА сборка слайда.
    ///
    /// Проверка появилась не от хорошей жизни. Всё было посчитано и записано,
    /// но `NumberingAssignments.apply(to:modules:)` не звали ниоткуда: движок
    /// оставался с пустой таблицей, `AppState` находил стандарт только у
    /// восьми переводов из таблицы автора, а всем прочим — включая KJV —
    /// подставлял восточный счёт по умолчанию. Пересчёт при этом «работал»:
    /// зелёными были все проверки, которые звали движок напрямую, минуя
    /// `AppState`. Эта зовёт именно `AppState`.
    private static func numberingWiringCheck(_ state: AppState) -> [Check] {
        let expected = [("rst+", "ru"), ("KJV", "en"), ("bw", "pl"), ("ubt2020", "ua")]
        var lines: [String] = []
        var wrong = 0
        var tested = 0
        for (id, want) in expected {
            guard state.module(id) != nil else { continue }
            tested += 1
            let got = state.numberingCode(ofModule: id)
            if got != want { wrong += 1 }
            lines.append("\(id) → \(got.isEmpty ? "не определён" : got)\(got == want ? "" : " (ждали \(want))")")
        }
        guard tested > 0 else {
            return [Check(area: "Нумерація", name: "Стандарт доходить до збирання слайда",
                          status: .skipped, detail: "у бібліотеці немає жодного опорного перекладу")]
        }
        return [Check(area: "Нумерація", name: "Стандарт доходить до збирання слайда",
                      status: wrong == 0 ? .ok : .failed,
                      detail: lines.joined(separator: ", "))]
    }

    // MARK: - Догадка

    private static func numberingGuessCheck(_ state: AppState) -> [Check] {
        // Четыре перевода, про которые известно наверняка — по числам их
        // собственных книг: у rst+ девятый псалом из 39 стихов, у KJV третий
        // из восьми, у bw Еккл 8 из восемнадцати, у ubt2020 главы масоретские.
        let expected = [("rst+", "ru"), ("KJV", "en"), ("bw", "pl"), ("ubt2020", "ua")]
        var lines: [String] = []
        var wrong = 0
        var tested = 0
        for (id, want) in expected {
            guard let module = state.module(id) else { continue }
            tested += 1
            guard let guess = NumberingGuess.standard(for: module) else {
                wrong += 1
                lines.append("\(id): не впізнано, чекали \(want)")
                continue
            }
            if guess.standardID != want { wrong += 1 }
            lines.append("\(id) → \(guess.standardID)\(guess.standardID == want ? "" : " (ждали \(want))")")
        }
        guard tested > 0 else {
            return [Check(area: "Нумерація", name: "Здогад про стандарт",
                          status: .skipped, detail: "у бібліотеці немає жодного опорного перекладу")]
        }
        return [Check(area: "Нумерація", name: "Здогад про стандарт",
                      status: wrong == 0 ? .ok : .failed,
                      detail: lines.joined(separator: ", "))]
    }

    // MARK: - Опорные места по настоящему тексту

    private static func numberingAnchors(ru: TextModule?, en: TextModule?, engine: VerseNumbering) -> [Check] {
        guard let ru, let en else {
            return [Check(area: "Нумерація", name: "Опорні місця",
                          status: .skipped, detail: "немає пари перекладів східного й масоретського рахунку")]
        }
        let from = engine.standard(id: "ru"), to = engine.standard(id: "en")
        var checks: [Check] = []

        // Псалом о Пастыре: у Септуагинты он 22-й, у масоретского счёта 23-й.
        checks.append(numberingAnchor(name: "Пс 22 = Пс 23 (про Пастиря)",
                                      ru: ru, en: en, chapter: 22, verse: 1,
                                      expects: ("пастыр", "shepherd"), engine: engine, from: from, to: to))
        // Покаянный псалом: у Септуагинты 50-й, у масоретского 51-й, и стих
        // тоже съезжает — надписание там считается двумя стихами.
        checks.append(numberingAnchor(name: "Пс 50:3 = Пс 51:1 (Помилуй мя)",
                                      ru: ru, en: en, chapter: 50, verse: 3,
                                      expects: ("помилуй", "mercy"), engine: engine, from: from, to: to))
        return checks
    }

    private static func numberingAnchor(name: String, ru: TextModule, en: TextModule,
                                        chapter: Int, verse: Int,
                                        expects: (String, String),
                                        engine: VerseNumbering,
                                        from: VerseNumberingStandard,
                                        to: VerseNumberingStandard) -> Check {
        guard let ruBook = ru.books.first(where: { $0.canonicalNumber == 230 }),
              let enBook = en.books.first(where: { $0.canonicalNumber == 230 }),
              let ruChapters = try? ru.chapters(ofBook: ruBook),
              let enChapters = try? en.chapters(ofBook: enBook),
              let source = ruChapters.first(where: { $0.number == chapter })?.verse(verse) else {
            return Check(area: "Нумерація", name: name, status: .skipped, detail: "Псалтир не розібрався")
        }
        let spans = engine.existingSpans(book: ruBook, chapter: chapter, verses: [verse],
                                         from: from, to: en, chapters: enChapters)
        let addresses = spans.flatMap { span in span.verses.map { "\(span.chapter):\($0)" } }
        let target = spans.flatMap { span in
            span.verses.compactMap { enChapters.first { $0.number == span.chapter }?.verse($0)?.text }
        }.joined(separator: " ")

        // Проверка настоящая: не «адрес похож на верный», а тот ли это текст.
        // Слова взяты из опорных мест — «Пастырь» и «shepherd», «Помилуй» и «mercy».
        let sourceFits = source.text.range(of: expects.0, options: .caseInsensitive) != nil
        let targetFits = target.range(of: expects.1, options: .caseInsensitive) != nil
        // Заодно проверяется приписка к строке адреса: у этих двух мест номера
        // обязаны разойтись, иначе зал увидит один номер, а люди в руках другой.
        let suffix = engine.parallelSuffix(book: ruBook, chapter: chapter, verses: [verse],
                                           from: from, to: en, chapters: enChapters)
        let status: Diagnostics.Status = addresses.isEmpty || suffix.isEmpty ? .failed
            : (sourceFits && targetFits ? .ok : .warning)
        return Check(area: "Нумерація", name: name, status: status,
                     detail: "\(ru.identifier) \(chapter):\(verse) «\(source.text.prefix(38))» → "
                         + "\(en.identifier) \(addresses.joined(separator: ", ")) «\(target.prefix(38))»; "
                         + "рядок адреси: \(chapter):\(verse)\(suffix.isEmpty ? " — приписки нет!" : suffix)"
                         + (sourceFits && targetFits ? "" : " — слова опорного місця не знайшлися, звірте самі"))
    }

    // MARK: - Круговой прогон

    private static func numberingRoundTrip(ru: TextModule?, en: TextModule?, engine: VerseNumbering) -> [Check] {
        guard let ru, let en else {
            return [Check(area: "Нумерація", name: "Круговий прогін",
                          status: .skipped, detail: "немає пари перекладів для звірки")]
        }
        let from = engine.standard(id: "ru"), to = engine.standard(id: "en")
        var total = 0, missing = 0, notBack = 0
        var missingSamples: [String] = [], backSamples: [String] = []

        for number in numberingBooks {
            guard let here = ru.books.first(where: { $0.canonicalNumber == number }),
                  let there = en.books.first(where: { $0.canonicalNumber == number }),
                  let hereChapters = try? ru.chapters(ofBook: here),
                  let thereChapters = try? en.chapters(ofBook: there) else { continue }
            let thereCount: (Int) -> Int? = { c in thereChapters.first { $0.number == c }?.verses.count }
            let hereCount: (Int) -> Int? = { c in hereChapters.first { $0.number == c }?.verses.count }
            var index = Set<Int>()
            for chapter in thereChapters {
                for verse in chapter.verses { index.insert(chapter.number * 1000 + verse.number) }
            }

            for chapter in hereChapters {
                for verse in chapter.verses {
                    total += 1
                    let forward = engine.translate(book: number, chapter: chapter.number, verse: verse.number,
                                                   from: from, to: to, verseCount: thereCount)
                    if forward.contains(where: { !index.contains($0.chapter * 1000 + $0.verse) }) {
                        missing += 1
                        if missingSamples.count < 4 {
                            missingSamples.append("\(here.buttonTitle) \(chapter.number):\(verse.number)")
                        }
                    }
                    var back = Set<Int>()
                    for address in forward {
                        for result in engine.translate(book: number, chapter: address.chapter, verse: address.verse,
                                                       from: to, to: from, verseCount: hereCount) {
                            back.insert(result.chapter * 1000 + result.verse)
                        }
                    }
                    if !back.contains(chapter.number * 1000 + verse.number) {
                        notBack += 1
                        if backSamples.count < 8 {
                            backSamples.append("\(here.buttonTitle) \(chapter.number):\(verse.number)")
                        }
                    }
                }
            }
        }
        guard total > 0 else {
            return [Check(area: "Нумерація", name: "Круговий прогін",
                          status: .skipped, detail: "книги для звірки не розібралися")]
        }

        // Не вернуться имеют право надписания псалмов: в еврейском счёте их
        // просто нет, и два русских стиха сходятся в один английский. Всё
        // остальное — повод смотреть в правила.
        let allowed = 10
        return [
            Check(area: "Нумерація", name: "Круговий прогін \(ru.identifier) ↔ \(en.identifier)",
                  status: notBack <= allowed ? .ok : .failed,
                  detail: "адрес \(total), не повернулися \(notBack)"
                      + (backSamples.isEmpty ? "" : " (\(backSamples.joined(separator: ", ")))")
                      + " — надписання псалмів повертатися й не мають"),
            Check(area: "Нумерація", name: "Цільова адреса існує",
                  status: missing == 0 ? .ok : .warning,
                  detail: missing == 0
                      ? "усі \(total) перекладених адрес знайшлися в \(en.identifier)"
                      : "не знайшлося \(missing) із \(total): \(missingSamples.joined(separator: ", "))"
                          + " — у цих місцях правил немає, показувати треба «місця немає»"),
        ]
    }

    // MARK: - Столкновения правил

    private static func numberingCollisions(ru: TextModule?, engine: VerseNumbering) -> Check {
        guard let ru else {
            return Check(area: "Нумерація", name: "Правила не стикаються",
                         status: .skipped, detail: "немає перекладу для перебору")
        }
        var clashes: [String] = []
        var checked = 0
        let standards = ["ru", "en", "pl", "ua"].map { engine.standard(id: $0) }
        for number in numberingBooks {
            guard let book = ru.books.first(where: { $0.canonicalNumber == number }),
                  let chapters = try? ru.chapters(ofBook: book) else { continue }
            var lengths: [Int: Int] = [:]
            for chapter in chapters { lengths[chapter.number] = chapter.verses.count }
            for from in standards {
                for to in standards where from.id != to.id {
                    checked += 1
                    clashes.append(contentsOf: engine.duplicateRules(book: number, chapterLengths: lengths,
                                                                     from: from, to: to))
                }
            }
        }
        return Check(area: "Нумерація", name: "Правила не стикаються",
                     status: clashes.isEmpty ? .ok : .failed,
                     detail: clashes.isEmpty
                         ? "перебрано \(checked) пар «книга-напрямок»: двох правил одного виду на одну адресу ніде немає"
                         : clashes.prefix(3).joined(separator: "; "))
    }

    // MARK: - Места, которого нет

    private static func numberingMissingTarget(state: AppState, en: TextModule?, engine: VerseNumbering) -> Check {
        // 151-й псалом есть у Септуагинты и не имеет соответствия в еврейском
        // счёте. Подставить вместо него 150-й было бы подлогом. Берём тот
        // перевод восточного счёта, у которого этот псалом действительно есть.
        let candidates = ["RU_RST", "rsti", "rst+"].compactMap { state.module($0) } + state.allModules
        var found: (TextModule, BookInfo)?
        for module in candidates {
            guard engine.standard(of: module).id == "ru",
                  let book = module.books.first(where: { $0.canonicalNumber == 230 }),
                  let chapters = try? module.chapters(ofBook: book),
                  chapters.contains(where: { $0.number == 151 }) else { continue }
            found = (module, book)
            break
        }
        guard let en, let (ru, ruBook) = found,
              let enBook = en.books.first(where: { $0.canonicalNumber == 230 }),
              let enChapters = try? en.chapters(ofBook: enBook) else {
            return Check(area: "Нумерація", name: "«Місця немає» замість сусіднього вірша",
                         status: .skipped, detail: "не знайшлося перекладу східного рахунку зі 151-м псалмом")
        }
        let spans = engine.existingSpans(book: ruBook, chapter: 151, verses: [1],
                                         from: engine.standard(id: "ru"), to: en, chapters: enChapters)
        return Check(area: "Нумерація", name: "«Місця немає» замість сусіднього вірша",
                     status: spans.isEmpty ? .ok : .failed,
                     detail: spans.isEmpty
                         ? "\(ru.identifier) Пс 151:1 у \(en.identifier) відповідності не має — відповідь порожня, сусідній вірш не підставлено"
                         : "повернулося \(spans.map { "\($0.chapter):\($0.verses)" }.joined(separator: ", "))")
    }

    // MARK: - Свой файл назначений

    private static func numberingOwnerStore() -> Check {
        // Пишем в отдельный файл во временной папке: настоящие назначения
        // владельца трогать нельзя даже ради проверки.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slovo-numbering-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = NumberingAssignments(fileURL: url)
        let written = store.setOwnerChoice("ru", forModule: "Проверка'22")
        let onDisk = FileManager.default.fileExists(atPath: url.path)
        let reread = NumberingAssignments(fileURL: url).ownerChoice(forModule: "проверка'22")
        _ = store.setOwnerChoice(nil, forModule: "Проверка'22")
        let cleared = NumberingAssignments(fileURL: url).ownerChoice(forModule: "Проверка'22")

        let good = written && onDisk && reread == "ru" && cleared == nil
        return Check(area: "Нумерація", name: "Свої призначення зберігаються окремо",
                     status: good ? .ok : .failed,
                     detail: good
                         ? "призначення записалося, перечиталося і знялося; свій файл — "
                             + NumberingAssignments.defaultFileURL.path
                             + ", база автора не мінялася"
                         : "запис \(written), файл \(onDisk), перечитано \(reread ?? "—"), знято \(cleared ?? "—")")
    }

    // MARK: - Выбор перевода под стандарт

    private static func numberingModule(_ state: AppState, standard: String, preferring: [String]) -> TextModule? {
        let store = NumberingAssignments.shared
        for id in preferring {
            guard let module = state.module(id) else { continue }
            if store.assignment(for: module).standardID == standard { return module }
        }
        return state.allModules.first { module in
            store.knownAssignment(forModule: module.identifier)?.standardID == standard
        }
    }
}
