import Foundation
import SlovoCore

/// Проверка разделов 5.1.5–5.1.11 руководства: сокращения названий книг из
/// таблицы на странице 14, формат быстрого выбора места Писания (9), поиск (8)
/// и файл Плана (10).
///
/// Почему не XCTest: полного Xcode на машине нет, только Command Line Tools,
/// и модуля `XCTest` в них нет — `swift test` не собирается вовсе. Поэтому
/// проверки живут в консольной цели, рядом с остальной самопроверкой.
///
/// Всё считается на настоящих модулях пользователя. На запись трогается
/// только временная папка, и та за собой убирается.
func runDeskCheck(modulesURL: URL) -> Int32 {
    var failures = 0

    func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("  ✓ \(name)")
        } else {
            failures += 1
            let extra = detail()
            print("  ✗ \(name)" + (extra.isEmpty ? "" : " — \(extra)"))
        }
    }

    let library = ModuleLibrary(modulesDirectory: modulesURL)
    print("модулей: \(library.modules.count)")

    // MARK: Список самых коротких сокращений (страница 14 руководства)

    /// Сверяем название книги, а не её канонический номер: порядок книг в
    /// напечатанной таблице — синодальный (соборные послания перед посланиями
    /// Павла), а `canonicalOrder` идёт западным порядком, и по позиции они
    /// разойдутся, хотя обе таблицы верны.
    ///
    /// Само сравнение вольное: в руководстве «1 Царств», в модуле «1-я
    /// Царств», «Римлянам» против «К Римлянам» — это одна и та же книга.
    func normalized(_ text: String) -> String {
        var result = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        for suffix in ["-я", "-е", "-й", "-го"] { result = result.replacingOccurrences(of: suffix, with: "") }
        for prefix in ["от ", "к "] where result.hasPrefix(prefix) { result.removeFirst(prefix.count) }
        return result.filter { $0.isLetter || $0.isNumber }
    }

    func checkTable(_ title: String, _ table: [ShortBookNames.Entry], moduleIDs: [String]) {
        guard let module = moduleIDs.compactMap({ library.module(withIdentifier: $0) }).first else {
            print("  · \(title): модуля нет, пропущено")
            return
        }
        var wrong: [String] = []
        for entry in table {
            let wanted = normalized(entry.name)
            guard let found = ShortBookNames.book(matching: entry.abbreviation, in: module.books) else {
                wrong.append("\(entry.abbreviation) → ничего")
                continue
            }
            let actual = normalized(found.fullName)
            guard actual == wanted || actual.hasPrefix(wanted) || wanted.hasPrefix(actual) else {
                wrong.append("\(entry.abbreviation) → «\(found.fullName)» вместо «\(entry.name)»")
                continue
            }
        }
        check("\(title) (\(module.identifier)): все \(table.count) сокращений ведут к своей книге",
              wrong.isEmpty, wrong.prefix(4).joined(separator: ", "))
    }

    print("самые короткие сокращения (5.1.9):")
    checkTable("Русская Синодальная Библия", ShortBookNames.russianSynodal,
               moduleIDs: ["RU_RST", "rst+", "RST"])
    checkTable("King James Bible", ShortBookNames.kingJames, moduleIDs: ["KJV", "kjv+"])

    // Таблица, посчитанная для модуля, обязана быть не хуже напечатанной:
    // каждое её сокращение тоже ведёт именно к своей книге.
    if let module = library.module(withIdentifier: "RU_RST") ?? library.modules.first {
        let computed = ShortBookNames.shortest(in: module.books)
        let broken = zip(module.books, computed).filter { book, entry in
            ShortBookNames.book(matching: entry.abbreviation, in: module.books)?.index != book.index
        }
        check("посчитанная таблица для «\(module.identifier)» (\(computed.count) книг) однозначна",
              broken.isEmpty, broken.prefix(3).map(\.1.abbreviation).joined(separator: ", "))
    }

    // MARK: Быстрый выбор места Писания (9) — примеры из руководства

    print("быстрый выбор места Писания (5.1.9):")
    if let module = library.module(withIdentifier: "RU_RST") ?? library.modules.first {
        let books = module.books

        func verses(_ input: String) -> [Int] {
            guard let address = ScriptureAddress.parse(input, books: books) else { return [] }
            guard let book = address.book as BookInfo?,
                  let chapter = try? module.chapter(address.chapter ?? 1, ofBook: book) else { return [] }
            return address.verseNumbers(available: chapter.verses.map(\.number))
        }

        // «Матфея 4:6-9: матф 4 6 9»
        let matthew = ScriptureAddress.parse("матф 4 6 9", books: books)
        check("«матф 4 6 9» — Матфея, глава 4",
              matthew?.book.canonicalNumber == 470 && matthew?.chapter == 4,
              "\(matthew?.book.fullName ?? "—") \(matthew?.chapter.map(String.init) ?? "—")")
        check("«матф 4 6 9» выделяет стихи 6…9", verses("матф 4 6 9") == [6, 7, 8, 9],
              "\(verses("матф 4 6 9"))")

        // «1-е Коринфянам 10:12: 1 кор 10 12»
        let corinth = ScriptureAddress.parse("1 кор 10 12", books: books)
        check("«1 кор 10 12» — 1 Коринфянам, глава 10",
              corinth?.book.canonicalNumber == 530 && corinth?.chapter == 10,
              "\(corinth?.book.fullName ?? "—")")
        check("«1 кор 10 12» выделяет один стих 12", verses("1 кор 10 12") == [12],
              "\(verses("1 кор 10 12"))")

        // «Иакова 4, вся глава: иак 4 -»
        let james = verses("иак 4 -")
        check("«иак 4 -» берёт главу целиком", james.count > 10 && james.first == 1,
              "стихов \(james.count)")

        // «в качестве последнего стиха указать число заведомо большее»
        let tail = verses("иак 4 12 333")
        check("«иак 4 12 333» берёт с 12-го до конца главы",
              tail.first == 12 && tail.count == max(james.count - 11, 0),
              "стихов \(tail.count), в главе \(james.count)")

        // Перечисление через запятую — привычка, которую разбор тоже понимает.
        check("«Мф 5:3,7» читается как список стихов", verses("Мф 5:3,7") == [3, 7],
              "\(verses("Мф 5:3,7"))")

        // ErrorMessages11 «Адрес не найден.»: непонятая строка обязана вернуть
        // именно «ничего», иначе поле показало бы чужое место вместо отказа.
        for garbage in ["яблоко 3 5", "?", "12345", ""] {
            check("«\(garbage)» — адрес не найден",
                  ScriptureAddress.parse(garbage, books: books) == nil,
                  ScriptureAddress.parse(garbage, books: books)?.book.fullName ?? "")
        }
    }

    // MARK: Поиск (8)

    print("поиск по тексту (5.1.8):")
    // Ход по модулю строим один раз на все проверки: `TextSearch.run` каждый
    // раз читает и сворачивает весь перевод заново, а это 31 тысяча стихов.
    if let module = library.module(withIdentifier: "RU_RST") ?? library.modules.first,
       let index = TextSearch.Index.build(for: module) {
        let started = Date()
        func find(_ query: String, limit: Int = 500) -> TextSearch.Outcome {
            TextSearch.search(query, in: index, options: .init(limit: limit))
        }
        let outcome = find("возлюбил", limit: 200)
        check("«возлюбил» находится в модуле «\(module.identifier)»", !outcome.hits.isEmpty,
              "совпадений \(outcome.hits.count)")
        check("подсветка попадает в найденное слово",
              outcome.hits.allSatisfy { hit in hit.segments.contains { $0.isMatch } },
              "первое: «\(outcome.hits.first?.segments.first(where: { $0.isMatch })?.text ?? "")»")
        check("строка списка идёт с начала стиха, а не с многоточия",
              outcome.hits.allSatisfy { $0.segments.map(\.text).joined() == $0.text })
        // «Слова можно писать не полностью» — обрубок обязан находить больше.
        let partial = find("возлюб", limit: 400)
        check("незаконченное слово находит не меньше полного",
              partial.hits.count >= outcome.hits.count,
              "«возлюб» \(partial.hits.count), «возлюбил» \(outcome.hits.count)")
        print("    поиск занял \(String(format: "%.2f", Date().timeIntervalSince(started))) с")

        // «Поиск производится строго по введенным словам»: слова ищутся по
        // отдельности, порядок между ними значения не имеет. Снимок стр. 12:
        // «имеет жизнь» находит 1Иоан. 5:13, где текст — «имеете жизнь».
        let phrase = find("имеет жизнь")
        let continuous = phrase.hits.filter {
            $0.text.range(of: "имеет жизнь", options: .caseInsensitive) != nil
        }
        check("поиск идёт по отдельным словам, а не одной подстрокой",
              phrase.hits.count > continuous.count,
              "по словам \(phrase.hits.count), непрерывной подстрокой \(continuous.count)")
        check("«имеет жизнь» находит и «имеете жизнь»",
              phrase.hits.contains { $0.text.range(of: "имеете жизнь", options: .caseInsensitive) != nil })
        let swapped = find("жизнь имеет")
        check("порядок слов в запросе значения не имеет",
              swapped.hits.count == phrase.hits.count,
              "«жизнь имеет» \(swapped.hits.count), «имеет жизнь» \(phrase.hits.count)")
        check("подсвечены оба слова",
              phrase.hits.allSatisfy { $0.highlights.count >= 2 },
              "минимум подсветок: \(phrase.hits.map(\.highlights.count).min() ?? 0)")

        // Слова соединяются «и»: стих без одного из них в список не попадает.
        let absent = find("возлюбил тарантул")
        check("слово, которого нет, отбрасывает весь стих", absent.hits.isEmpty,
              "совпадений \(absent.hits.count)")

        // «Окончания слов лучше не дописывать»: поле поиска (8) ищет по началу
        // слова, а не по целому слову. Проверяем, что переключатель различает
        // эти два случая — на нём держится вся выгода от обрубков.
        let prefix = TextSearch.search("дар", in: index, options: .init(limit: 400))
        let whole = TextSearch.search("дар", in: index, options: .init(limit: 400, wholeWords: true))
        check("«дар» по началу слова находит больше, чем целым словом",
              prefix.hits.count > whole.hits.count,
              "по началу \(prefix.hits.count), целым словом \(whole.hits.count)")
        check("целым словом «дар» не цепляет «удар» и «дарования»",
              whole.hits.allSatisfy { hit in
                  hit.highlights.contains { range in
                      let characters = Array(hit.text)
                      let before = range.lowerBound > 0 ? characters[range.lowerBound - 1] : " "
                      let after = range.upperBound < characters.count ? characters[range.upperBound] : " "
                      return !before.isLetter && !after.isLetter
                  }
              })

        // Лишние пробелы и перевод строки в запросе слов не выдумывают.
        let messy = TextSearch.Query("  имеет   жизнь \n")
        check("лишние пробелы в запросе не создают пустых слов",
              messy.words == ["имеет", "жизнь"], messy.words.joined(separator: "|"))
    }

    // MARK: План (10)

    print("план служения (5.1.10):")
    if let module = library.module(withIdentifier: "RU_RST") ?? library.modules.first,
       let john = module.books.first(where: { $0.canonicalNumber == 500 }) ?? module.books.last {
        var plan = ServicePlan(title: "Проверка")
        plan.append(PlanItem.scripture(moduleID: module.identifier, book: john,
                                       chapter: 3, verses: [16, 17, 18],
                                       quote: "Ибо так возлюбил Бог мир…"))
        plan.append(PlanItem.scripture(moduleID: module.identifier, book: john,
                                       chapter: 1, verses: [1], quote: "В начале было Слово…"))
        plan.append(PlanItem.text(PlainTextDocument(title: "Объявление", body: "После служения — общение.")))
        check("три пункта добавились", plan.count == 3, "\(plan.count)")
        // Строка плана на снимке — «адрес - начало цитаты», без номера и значка.
        check("в строке плана есть и адрес, и начало цитаты",
              plan.items[0].subtitle?.hasPrefix("Ибо так возлюбил") == true,
              plan.items[0].subtitle ?? "—")

        // TBPlanDown: второй пункт вниз — тот же уговор, что и у списка
        // SwiftUI, поэтому шаг вниз считается как destination + 2.
        let second = plan.items[1].id
        plan.move(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        check("TBPlanDown опускает пункт на строку ниже", plan.items[2].id == second,
              plan.items.map(\.title).joined(separator: " | "))

        // TBPlanUp: обратно наверх.
        plan.move(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        check("TBPlanUp возвращает его на место", plan.items[1].id == second)

        // TBPlanDel.
        plan.remove(at: 0)
        check("TBPlanDel убирает строку", plan.count == 2, "\(plan.count)")

        // TBPlanSave / TBPlanOpen — круговой прогон через настоящий файл.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-plan-check-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent(ServicePlan.fileName(for: plan.title))
        do {
            try plan.save(to: file)
            let loaded = try ServicePlan.read(contentsOf: file)
            check("TBPlanSave/TBPlanOpen: план читается обратно без потерь",
                  loaded.plan.items == plan.items && loaded.skippedItems == 0,
                  "прочитано \(loaded.plan.count), пропущено \(loaded.skippedItems)")
            check("после сохранения план считается сохранённым", !plan.hasUnsavedChanges)
        } catch {
            failures += 1
            print("  ✗ TBPlanSave: \(error)")
        }
        try? FileManager.default.removeItem(at: folder)

        // Формат оригинала: тот же план через <JournalFile>.
        let journalFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-journal-check-\(UUID().uuidString)", isDirectory: true)
        let journalFile = journalFolder.appendingPathComponent("Проверка.ini")
        do {
            var copy = plan
            try copy.saveAsJournal(to: journalFile)
            let text = try String(contentsOf: journalFile, encoding: .utf8)
            check("план пишется в формате оригинала", JournalFile.looksLikeJournal(text))
            check("в файле три журнала Bible/Text/Songs",
                  text.contains("Name=\"Bible\"") && text.contains("Name=\"Text\"")
                      && text.contains("Name=\"Songs\""))

            let back = try ServicePlan.readAny(contentsOf: journalFile)
            check("порядок пунктов после чтения сохраняется",
                  back.plan.items.map(\.title) == plan.items.map(\.title),
                  back.plan.items.map(\.title).joined(separator: " | "))
            check("отрывок читается обратно тем же",
                  back.plan.items.first?.scripture == plan.items.first?.scripture,
                  "\(String(describing: back.plan.items.first?.scripture))")
            check("начало цитаты переживает круг",
                  back.plan.items.first?.subtitle == plan.items.first?.subtitle,
                  back.plan.items.first?.subtitle ?? "—")
        } catch {
            failures += 1
            print("  ✗ план в формате оригинала: \(error)")
        }
        try? FileManager.default.removeItem(at: journalFolder)

        // Часть песни в плане: в журнале у неё свой набор полей, и через файл
        // она раньше не проверялась вовсе — а «Добавить в План» из песенника
        // кладёт именно такие пункты.
        let part = SongPart(index: 2, kind: "Припев", text: "Господь мой Бог,\nкак Ты велик")
        let song = Song(index: 11, title: "Великий Бог", parts: [part])
        var songPlan = ServicePlan(title: "Песни")
        songPlan.append(PlanItem.songPart(bookFileName: "Песнь возрождения.vbm", song: song, part: part))
        let songBack = ServicePlan(journal: songPlan.journal())
        check("часть песни ходит в файл плана и обратно",
              songBack.items.first?.songPart == songPlan.items.first?.songPart,
              "\(String(describing: songBack.items.first?.songPart))")
        check("строка пункта песни — название и часть",
              songBack.items.first?.title == "Великий Бог — Припев",
              songBack.items.first?.title ?? "—")

        // TBPlanNew.
        plan.removeAll()
        check("TBPlanNew очищает план", plan.isEmpty && plan.currentIndex == nil)
    }

    // MARK: История (11) и файлы-журналы оригинала

    print("история и журналы оригинала (5.1.11):")
    do {
        // Разбор ровно того файла, что лежит у пользователя рядом с прежней программой.
        let sample = """
        <JournalFile>
          <Journal Name="Bible">
            <Item Caption="Руф.- В те дни, когда управляли судьи." Reference="Руф." \
        Quote="1. В те дни, когда управляли судьи." Class="0" Book="7" Chapter="0" Verse="0" \
        QuoteFont="" QuoteCharSet="512" ModuleShortName="RST+" ModuleShortNameSecond="KJV" \
        ShortName="Руф.,Руф,Рф." FullName="Руфь" VersesRangeCount="0"/>
          </Journal>
          <Journal Name="Text"/>
          <Journal Name="Songs"/>
        </JournalFile>
        """
        let parsed = JournalFile.parse(sample)
        check("журнал оригинала разбирается", parsed[.bible].count == 1, "пунктов \(parsed[.bible].count)")
        check("пустые журналы остаются пустыми", parsed[.text].isEmpty && parsed[.songs].isEmpty)

        let history = ServiceHistory(journal: parsed)
        let first = history.records.first
        check("книга, глава и стих считаются с нуля",
              first?.bookIndex == 7 && first?.chapter == 1 && first?.verses == [1],
              "книга \(first?.bookIndex ?? -1), глава \(first?.chapter ?? -1), стихи \(first?.verses ?? [])")
        check("короткое имя перевода читается", first?.moduleShortName == "RST+")

        // Круговой прогон: запись и чтение обратно.
        var mine = ServiceHistory()
        mine.remember(HistoryRecord(kind: .bible, reference: "Ин. 3:16", quote: "Ибо так возлюбил Бог мир",
                                    bookIndex: 42, chapter: 3, verses: [16],
                                    moduleShortName: "RST", fullName: "От Иоанна"))
        mine.remember(HistoryRecord(kind: .song, reference: "Великий Бог — Куплет 1",
                                    quote: "Господь мой Бог", songBookFileName: "Песнь возрождения.vbm",
                                    songIndex: 11, partIndex: 0))
        check("подпись строки собрана как у автора",
              mine.records.last?.caption == "Ин. 3:16- Ибо так возлюбил Бог мир",
              mine.records.last?.caption ?? "—")
        check("повтор того же места второй строкой не заводится", {
            var copy = mine
            copy.remember(HistoryRecord(kind: .bible, reference: "Ин. 3:16", quote: "Ибо так возлюбил Бог мир",
                                        bookIndex: 42, chapter: 3, verses: [16]))
            return copy.count == mine.count
        }(), "записей \(mine.count)")

        let historyFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-history-check-\(UUID().uuidString)", isDirectory: true)
        let historyFile = historyFolder.appendingPathComponent(ServiceHistory.fileName)
        do {
            try mine.write(to: historyFile)
            let back = ServiceHistory.read(contentsOf: historyFile)
            check("история переживает перезапуск", back.count == mine.count,
                  "записано \(mine.count), прочитано \(back.count)")
            check("часть песни попадает в историю",
                  back.records.contains { $0.kind == .song && $0.songIndex == 11 && $0.partIndex == 0 })
            check("адрес и текст читаются обратно",
                  back.records.contains { $0.reference == "Ин. 3:16" && $0.quote == "Ибо так возлюбил Бог мир" })
        } catch {
            failures += 1
            print("  ✗ запись истории: \(error)")
        }
        try? FileManager.default.removeItem(at: historyFolder)

        // Экранирование: кавычки и амперсанд в тексте стиха ломали бы разметку.
        var tricky = ServiceHistory()
        tricky.remember(HistoryRecord(kind: .text, reference: "Объявление",
                                      quote: "«Мир & радость» — сказал <он>"))
        let round = ServiceHistory(journal: JournalFile.parse(tricky.journal().xml()))
        check("кавычки и амперсанд в тексте не ломают файл",
              round.records.first?.quote == "«Мир & радость» — сказал <он>",
              round.records.first?.quote ?? "—")
    }

    // MARK: Настоящие файлы оригинала — только на чтение

    // Проверка на синтетическом образце не ловит того, что бывает в живом
    // файле: сотня записей, длинные цитаты, кавычки, пустые журналы. Файлы
    // пользователя открываются здесь именно на чтение — ничего в папку
    // прежняя программа этот прогон не пишет.
    print("файлы оригинала рядом с программой:")
    do {
        let dataRoot = modulesURL.deletingLastPathComponent()
        let historyFile = dataRoot.appendingPathComponent(ServiceHistory.fileName)
        if FileManager.default.fileExists(atPath: historyFile.path) {
            let history = ServiceHistory.read(contentsOf: historyFile)
            check("\(ServiceHistory.fileName) пользователя разбирается",
                  !history.records.isEmpty, "записей \(history.count)")
            check("у каждой записи есть подпись строки",
                  history.records.allSatisfy { !$0.caption.isEmpty })
            check("библейские записи знают книгу, главу и стих",
                  history.records.filter { $0.kind == .bible }
                      .allSatisfy { $0.chapter >= 1 && !$0.verses.isEmpty },
                  history.records.first.map { "\($0.caption.prefix(46))" } ?? "—")
            check("больше \(ServiceHistory.limit) записей история не держит",
                  history.count <= ServiceHistory.limit, "\(history.count)")
        } else {
            print("  · \(ServiceHistory.fileName): рядом с модулями нет, пропущено")
        }

        let planFile = dataRoot.appendingPathComponent(ServicePlan.defaultFileName)
        if FileManager.default.fileExists(atPath: planFile.path) {
            let text = (try? String(contentsOf: planFile, encoding: .utf8)) ?? ""
            check("\(ServicePlan.defaultFileName) пользователя опознаётся как журнал",
                  JournalFile.looksLikeJournal(text))
            let last = try ServicePlan.readAny(contentsOf: planFile)
            check("последний план оригинала читается без потерь",
                  last.skippedItems == 0,
                  "пунктов \(last.plan.count), пропущено \(last.skippedItems)")
        } else {
            print("  · \(ServicePlan.defaultFileName): рядом с модулями нет, пропущено")
        }

        // Папка Plans оригинала: «Загрузить план» открывает её первой, и
        // каждый лежащий там файл обязан прочитаться нашим кодом.
        let plansFolder = dataRoot.appendingPathComponent(ServicePlan.folderName, isDirectory: true)
        let saved = (try? FileManager.default.contentsOfDirectory(at: plansFolder,
                                                                  includingPropertiesForKeys: nil)) ?? []
        let readable = saved.filter { (try? ServicePlan.readAny(contentsOf: $0)) != nil }
        if saved.isEmpty {
            print("  · папка \(ServicePlan.folderName) пуста — открывать нечего")
        } else {
            check("все \(saved.count) сохранённых планов оригинала открываются",
                  readable.count == saved.count,
                  "прочиталось \(readable.count)")
        }
    } catch {
        failures += 1
        print("  ✗ файлы оригинала: \(error)")
    }

    print(failures == 0 ? "\nвсё сошлось" : "\nрасхождений: \(failures)")
    return failures == 0 ? 0 : 1
}
