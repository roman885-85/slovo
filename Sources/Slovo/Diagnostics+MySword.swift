import Foundation
import SQLite3
import SlovoCore

/// Самопроверка читателя модулей MySword.
///
/// Настоящих файлов MySword у владельца нет ни одного — ни в папке модулей,
/// ни где-либо ещё на этой машине. Поэтому проверка сама собирает образец
/// во временной папке ровно по описанию формата и читает его нашим читателем:
/// это честная работа с настоящей базой SQLite, а не сверка строк с ожиданием.
/// Как только у владельца появится хоть один живой `*.bbl.mybible`, первым
/// делом надо сравнить его `.schema` с этим образцом — последняя проверка
/// раздела для того и следит за папкой модулей.
///
/// Образец делается заново на каждый прогон и удаляется в конце: держать
/// подделку рядом с настоящими модулями нельзя, её однажды покажут на экране.
extension Diagnostics {

    static func mySwordSection(state: AppState) -> [Check] {
        let area = "MySword"
        var checks: [Check] = []

        let started = Date()
        guard let sample = MySwordFixture.build() else {
            return [Check(area: area, name: "Зразок модуля",
                          status: .failed,
                          detail: "не вдалося зібрати зразок у тимчасовій теці — "
                              + "перевірити читача нічим")]
        }
        defer { sample.discard() }

        checks.append(Check(area: area, name: "Зразок модуля",
                            status: .ok,
                            detail: "зібрано в тимчасовій теці за "
                                + String(format: "%.0f", Date().timeIntervalSince(started) * 1000)
                                + " мс: переклад і \(sample.strangers.count) чужих файли; "
                                + "справжніх модулів MySword на цій машині немає"))

        checks.append(contentsOf: readerChecks(area: area, sample: sample))
        checks.append(markupCheck(area: area))
        checks.append(markupThroughModuleCheck(area: area, sample: sample))
        checks.append(bookNamesCheck(area: area))
        checks.append(refusalCheck(area: area, sample: sample))
        checks.append(libraryCheck(area: area, sample: sample))
        checks.append(wizardCheck(area: area, sample: sample))
        checks.append(settingsCheck(area: area, sample: sample))
        checks.append(realModulesCheck(area: area, state: state))

        return checks
    }

    // MARK: - Чтение образца

    private static func readerChecks(area: String, sample: MySwordFixture) -> [Check] {
        let module: MySwordModule
        do {
            module = try MySwordModule(fileAt: sample.good)
        } catch {
            return [Check(area: area, name: "Модуль відкривається",
                          status: .failed, detail: "\(error)")]
        }
        defer { module.releaseCache() }

        var checks: [Check] = []

        // Шапка: всё это разные колонки `Details`, и читаются они по именам,
        // а не по номерам, — перепутанный порядок тут и вылезет.
        let header = [
            ("назва", module.info.name, "Слово — проверочный модуль MySword"),
            ("скорочення", module.info.shortName, "PROBA"),
            ("мова", module.info.language ?? "", "rus"),
        ]
        let headerWrong = header.filter { $0.1 != $0.2 }
        checks.append(Check(area: area, name: "Шапка модуля (Details)",
                            status: headerWrong.isEmpty && module.info.hasStrongNumbers
                                && !module.info.rightToLeft ? .ok : .failed,
                            detail: headerWrong.isEmpty
                                ? "«\(module.info.name)», \(module.info.shortName), "
                                    + "\(module.info.language ?? "—"), Стронг є, зліва направо"
                                : headerWrong.map { "\($0.0): «\($0.1)», чекали «\($0.2)»" }
                                    .joined(separator: "; ")))

        // Книги: номер MySword 1…66 обязан превратиться в наш сквозной, иначе
        // второй перевод встанет напротив чужой книги.
        let expected: [(file: String, canonical: Int, name: String, chapters: Int)] = [
            ("1", 10, "Бытие", 2),
            ("19", 230, "Псалтирь", 23),
            ("40", 470, "От Матфея", 5),
            ("43", 500, "От Иоанна", 3),
        ]
        var bookTrouble: [String] = []
        if module.books.count != expected.count {
            bookTrouble.append("книг \(module.books.count), чекали \(expected.count)")
        } else {
            for (book, want) in zip(module.books, expected) {
                if book.fileName != want.file || book.canonicalNumber != want.canonical
                    || book.fullName != want.name || book.chapterCount != want.chapters {
                    bookTrouble.append("\(book.fileName) → \(book.canonicalNumber.map(String.init) ?? "немає") "
                        + "«\(book.fullName)», розділів \(book.chapterCount); чекали "
                        + "\(want.canonical) «\(want.name)», розділів \(want.chapters)")
                }
            }
        }
        checks.append(Check(area: area, name: "Книги й наскрізна нумерація",
                            status: bookTrouble.isEmpty ? .ok : .failed,
                            detail: bookTrouble.isEmpty
                                ? module.books.map { "\($0.fileName)→\($0.canonicalNumber ?? 0) \($0.fullName)" }
                                    .joined(separator: ", ")
                                : bookTrouble.joined(separator: "; ")))

        // Главы и стихи. Псалом здесь единственный, но с номером 23, а не 1:
        // так и проверяем, что номер главы берётся из базы, а не из порядка.
        var layout: [String] = []
        var total = 0
        for book in module.books {
            let chapters = (try? module.chapters(ofBook: book)) ?? []
            total += chapters.reduce(0) { $0 + $1.verses.count }
            layout.append("\(book.fileName):[" + chapters.map { "\($0.number)×\($0.verses.count)" }
                .joined(separator: ",") + "]")
        }
        let wantedLayout = "1:[1×5,2×3] 19:[23×3] 40:[5×2] 43:[1×1,3×3]"
        let gotLayout = layout.joined(separator: " ")
        checks.append(Check(area: area, name: "Розділи й вірші",
                            status: gotLayout == wantedLayout && total == 17 ? .ok : .failed,
                            detail: gotLayout == wantedLayout && total == 17
                                ? "\(gotLayout), віршів усього \(total)"
                                : "вийшло «\(gotLayout)», віршів \(total); чекали «\(wantedLayout)», 17"))

        // Ин 3:16 — та книга, по которой сама MySword подписывает пример
        // перекрёстной ссылки `<RX43.3.16>`. Заодно смотрим, что от разметки
        // в готовом тексте не осталось ни скобок, ни номеров Стронга.
        var johnDetail = "книгу 43 не знайдено"
        var johnOK = false
        if let john = module.books.first(where: { $0.fileName == "43" }),
           let chapter = try? module.chapter(3, ofBook: john),
           let verse = chapter.verse(16) {
            let clean = !verse.text.contains("<") && !verse.text.contains(">")
                && !verse.text.contains("WG") && !verse.text.contains("  ")
            johnOK = john.canonicalNumber == 500 && verse.text.hasPrefix("Ибо так возлюбил Бог мир")
                && clean
            johnDetail = "\(john.fullName) 3:16 → «\(verse.text)»"
        }
        checks.append(Check(area: area, name: "Ін 3:16 на своєму місці й без розмітки",
                            status: johnOK ? .ok : .failed, detail: johnDetail))

        return checks
    }

    // MARK: - Очистка разметки

    /// Пары «сырой стих → показ». Все до одной сверены с эталонной
    /// реализацией разбора формата, которой собирался и сам образец.
    private static let markupCases: [(raw: String, want: String)] = [
        ("Земля же была безвидна и пуста, и тьма над бездною.<CM>",
         "Земля же была безвидна и пуста, и тьма над бездною."),
        ("И сказал Бог: да будет свет. И стал свет.<RF>Буквально: «и был свет».<Rf>",
         "И сказал Бог: да будет свет. И стал свет."),
        ("<TS>Псалом Давида<Ts><PI1><PF1>Господь — Пастырь мой; я ни в чем не буду нуждаться:<CM>",
         "Господь — Пастырь мой; я ни в чем не буду нуждаться:"),
        ("<TS1>Надписание<Ts>Текст стиха.",
         "Текст стиха."),
        ("<TS>Заповеди блаженства<Ts><FR>Блаженны нищие духом, ибо их есть Царство Небесное.<Fr><CM>",
         "Блаженны нищие духом, ибо их есть Царство Небесное."),
        ("<FR>Ибо так возлюбил<WG25> Бог<WG2316> мир, что отдал Сына Своего.<Fr><RX43.3.17>",
         "Ибо так возлюбил Бог мир, что отдал Сына Своего."),
        ("<FR>Но чтобы мир спасен был чрез Него.<Fr><RF q=a>В некоторых списках — «через Него».<Rf><CM>",
         "Но чтобы мир спасен был чрез Него."),
        ("Верующий в Него не судится.<FI>есть<Fi>",
         "Верующий в Него не судится. есть"),
        ("И сказал им: <FR>Я есмь путь<Fr>.<CM>",
         "И сказал им: Я есмь путь."),
        ("<Q><wg>Εν<WG1722><WTPREP><E>В начале<e><q> <Q><wg>ἀρχῇ<WG746><X>ar·khe<x><E>было<e><q>"
            + " <Q><wg>ἦν<WG2258><E>Слово<e><q>",
         "Εν В начале ἀρχῇ было ἦν Слово"),
        ("<Q><H><wh>בְּ<D>רֵאשִׁ֖ית<WH7225><h><X>be·re·Shit<x><T>In the beginning<t><q>",
         "בְּרֵאשִׁ֖ית In the beginning"),
        ("Текст.<RF>кусок примечания",
         "Текст."),

        // Дальше — теги формата, которых в списке не было. Каждый взят из
        // описания GBF, каким его понимает MySword, а не выдуман.
        ("Первая строка<CL>вторая строка", "Первая строка вторая строка"),
        ("<PF0>Абзац без отступа.", "Абзац без отступа."),
        ("Он сказал: <FO>Я есмь<Fo> — и умолк.", "Он сказал: Я есмь — и умолк."),
        ("Слово <FU>подчёркнуто<Fu> в издании.", "Слово подчёркнуто в издании."),
        // Сноска целиком выбрасывается вместе с разметкой внутри неё.
        ("Стих.<RF>примечание с <FI>курсивом<Fi> внутри<Rf>", "Стих."),
        // Заголовок тоже: и сам, и всё, что в нём.
        ("<TS2>Раздел с <FI>пояснением<Fi><Ts2>Текст стиха.", "Текст стиха."),
        // Незакрытый подстрочник съедает хвост — как и незакрытая сноска:
        // показать латинскую запись вместо слов Писания хуже, чем потерять
        // остаток стиха.
        ("Слово<X>ar·khe и дальше без закрытия", "Слово"),
        // Мнемоники HTML в тексте стиха встречаются у самодельных модулей.
        ("Марфа &amp; Мария сказали: &quot;Господи&quot;.",
         "Марфа & Мария сказали: \"Господи\"."),
        // Номер Стронга и морфология подряд, без пробелов вокруг.
        ("В начале<WH7225><WTHNcfsa> сотворил<WH1254> Бог<WH430>.",
         "В начале сотворил Бог."),
    ]

    private static func markupCheck(area: String) -> Check {
        var wrong: [String] = []
        for item in markupCases {
            let got = MySwordText.plain(item.raw)
            if got != item.want { wrong.append("«\(got)» замість «\(item.want)»") }
        }
        return Check(area: area, name: "Очищення розмітки вірша",
                     status: wrong.isEmpty ? .ok : .failed,
                     detail: wrong.isEmpty
                        ? "\(markupCases.count) випадків: виноски, заголовки, слова Христа, "
                            + "підрядник, номери Стронга, незакрита виноска"
                        : wrong.joined(separator: "; "))
    }

    // MARK: - Таблица названий книг

    private static func bookNamesCheck(area: String) -> Check {
        var wrong: [String] = []
        let order = CanonicalBook.canonicalOrder
        guard MySwordBookNames.all.count == order.count else {
            return Check(area: area, name: "Назви 66 книг",
                         status: .failed,
                         detail: "у таблиці \(MySwordBookNames.all.count) рядків, у каноні \(order.count)")
        }
        for (offset, entry) in MySwordBookNames.all.enumerated() {
            let number = offset + 1
            // Латинское сокращение обязано узнаваться той же таблицей, что и
            // у прочих форматов, — иначе поиск по книге и разбор ссылки
            // работали бы для MySword не так, как для всех.
            let byAlias = entry.shortNames.compactMap { CanonicalBook.number(forAlias: $0) }.first
            let byPosition = MySwordBookNames.canonicalNumber(number)
            if byAlias != order[offset] || byPosition != order[offset] {
                wrong.append("\(number) «\(entry.fullName)»: за скороченням "
                    + "\(byAlias.map(String.init) ?? "не узнана"), за місцем "
                    + "\(byPosition.map(String.init) ?? "немає"), у каноні \(order[offset])")
            }
        }
        return Check(area: area, name: "Назви 66 книг",
                     status: wrong.isEmpty ? .ok : .failed,
                     detail: wrong.isEmpty
                        ? "усі 66 сходяться з каноном і за скороченням, і за місцем"
                        : wrong.prefix(3).joined(separator: "; ")
                            + (wrong.count > 3 ? " і ще \(wrong.count - 3)" : ""))
    }

    // MARK: - Отказы

    private static func refusalCheck(area: String, sample: MySwordFixture) -> Check {
        var wrong: [String] = []
        var reasons: [String] = []

        for stranger in sample.strangers {
            do {
                _ = try MySwordModule(fileAt: stranger.url)
                wrong.append("\(stranger.url.lastPathComponent): відкрився, а не мав би")
            } catch let error as MySwordError {
                if MySwordFixture.kind(of: error) == stranger.expected {
                    reasons.append("\(stranger.url.lastPathComponent) — \(error)")
                } else {
                    wrong.append("\(stranger.url.lastPathComponent): «\(error)», "
                        + "а чекали відмову виду «\(stranger.expected.title)»")
                }
            } catch {
                wrong.append("\(stranger.url.lastPathComponent): \(error)")
            }
        }

        return Check(area: area, name: "Чужі файли відкинуто зі своєю причиною",
                     status: wrong.isEmpty ? .ok : .failed,
                     detail: wrong.isEmpty
                        ? "\(reasons.count) файлів, кожен зі своїм поясненням: "
                            + reasons.joined(separator: "; ")
                        : wrong.joined(separator: "; "))
    }

    // MARK: - Каталог

    private static func libraryCheck(area: String, sample: MySwordFixture) -> Check {
        let library = ModuleLibrary(modulesDirectory: sample.folder)
        let opened = library.modules.filter { $0.format == .mySword }
        // Спутники (`.cmt`, `.dct`) обязаны пропускаться молча: строка в
        // списке неудач про словарь — это шум, из-за которого не заметят
        // настоящую поломку.
        let noisy = library.failures.filter {
            $0.directory.hasSuffix(".cmt.mybible") || $0.directory.hasSuffix(".dct.mybible")
        }
        let ok = opened.count == 1 && opened.first?.identifier == "Proba" && noisy.isEmpty
        return Check(area: area, name: "Каталог бере переклад і пропускає супутників",
                     status: ok ? .ok : .failed,
                     detail: ok
                        ? "із \(sample.strangers.count + 1) файлів відкрито один — «Proba»; "
                            + "супутників пропущено мовчки, решту \(library.failures.count) "
                            + "названо причиною"
                        : "відкрито \(opened.count) (\(opened.map(\.identifier).joined(separator: ", "))), "
                            + "зайвих скарг \(noisy.count)")
    }

    /// (30) Мастер импорта: перевод MySword обязан встать строкой описи и
    /// пройти проверку «модуль читается», а спутники — не попасть в опись.
    private static func wizardCheck(area: String, sample: MySwordFixture) -> Check {
        // Смотрим на отдельную папку с переводом и его спутниками: в общей
        // папке образца лежат ещё девять нарочно испорченных файлов, и по
        // имени мастер обязан взять их тоже — правду о них скажет `validate`.
        guard let folder = sample.wizardFolder() else {
            return Check(area: area, name: "Майстер імпорту бере переклад MySword (30)",
                         status: .failed, detail: "не вдалося зібрати теку для майстра")
        }
        let source = ImportSource(version: "образец", url: folder, kind: .folder)
        let destination = ImportDestination(dataRoot: folder.appendingPathComponent("куда"))
        let inventory = ModuleImporter.inventory(of: source, destination: destination)
        let ours = inventory.modules.filter { $0.id.hasPrefix("mysword:") }

        guard let item = ours.first, ours.count == 1,
              inventory.modules.count == 1,
              item.sourceURL.lastPathComponent == "Proba.bbl.mybible" else {
            return Check(area: area, name: "Майстер імпорту бере переклад MySword (30)",
                         status: .failed,
                         detail: "в описі \(inventory.modules.count) рядків, із них MySword "
                            + "\(ours.count): "
                            + inventory.modules.map { $0.sourceURL.lastPathComponent }
                                .joined(separator: ", "))
        }
        // `validate` не просто открывает шапку: он читает первую главу — так
        // в библиотеку не попадёт модуль, который потом нечем показать.
        if let trouble = ModuleImporter.validate(item) {
            return Check(area: area, name: "Майстер імпорту бере переклад MySword (30)",
                         status: .failed, detail: "перевірка читання не пройшла: \(trouble)")
        }
        // И обратное: битый файл с тем же именем мастер обязан задержать
        // именно здесь, а не после копирования в папку с данными.
        let broken = sample.strangers
            .filter { MySwordModule.isBibleModuleName($0.url.lastPathComponent) }
            .map { ModuleImporter.validate(ImportItem(id: "mysword:" + $0.url.lastPathComponent,
                                                      category: .module,
                                                      title: $0.url.lastPathComponent,
                                                      subtitle: "",
                                                      sourceURL: $0.url,
                                                      destinationURL: destination.modulesFolder,
                                                      condition: .missing)) }
        let slipped = broken.filter { $0 == nil }.count
        guard slipped == 0 else {
            return Check(area: area, name: "Майстер імпорту бере переклад MySword (30)",
                         status: .failed,
                         detail: "битих файлів пройшло перевірку читання: \(slipped) із \(broken.count)")
        }
        return Check(area: area, name: "Майстер імпорту бере переклад MySword (30)",
                     status: .ok,
                     detail: "рядок «\(item.title) — \(item.subtitle)», перший розділ читається; "
                        + "супутники в опис не потрапили, а всі \(broken.count) битих файли "
                        + "затримано перевіркою читання")
    }

    /// (26) и (29) в окне настроек: перевод добавляется, спутник получает
    /// отказ словами автора, а не ложится строкой с «Индекс: Нет».
    private static func settingsCheck(area: String, sample: MySwordFixture) -> Check {
        guard let folder = sample.wizardFolder() else {
            return Check(area: area, name: "Налаштування: переклад береться, супутник відхиляється (26, 29)",
                         status: .failed, detail: "не вдалося зібрати теку для пошуку")
        }
        let good = SettingsStore.problem(with: sample.good)
        let companion = SettingsStore.problem(with: folder.appendingPathComponent("Proba.cmt.mybible"))
        let found = SettingsStore.scanForTexts(in: folder).entries
            .filter { $0.name.hasSuffix(".mybible") }
        let onlyBible = found.count == 1 && found.first?.name == "Proba.bbl.mybible"
        let ok = good == nil && companion == .mySword && onlyBible
        return Check(area: area, name: "Налаштування: переклад береться, супутник відхиляється (26, 29)",
                     status: ok ? .ok : .failed,
                     detail: ok
                        ? "«Proba.bbl.mybible» додається, «Proba.cmt.mybible» — TextMessages38 "
                            + "«Не підтримується»; пошук текстів знайшов лише переклад"
                        : "переклад: \(good.map { "\($0)" } ?? "принят"), "
                            + "супутник: \(companion.map { "\($0)" } ?? "принят"), "
                            + "пошук знайшов \(found.map(\.name).joined(separator: ", "))")
    }

    /// Разметка, прочитанная НАСКВОЗЬ: не строка через `MySwordText.plain`, а
    /// весь образец через читателя модуля.
    ///
    /// Разница не придирка. `plain` можно проверить и не открывая базы, но до
    /// него текст ещё должен доехать: своей дорогой идут кодировка, склейка
    /// глав, обрезка пустых стихов. Пока проверялась одна отдельная строка и
    /// один стих Ин 3:16, между ними оставалась щель, в которую пролезло бы
    /// что угодно — например тег, разорванный на границе чтения.
    ///
    /// Ищем остатки: угловая скобка в показанном тексте означает, что тег не
    /// разобрали. В зале это будет видно всем.
    private static func markupThroughModuleCheck(area: String, sample: MySwordFixture) -> Check {
        let module: MySwordModule
        do {
            module = try MySwordModule(fileAt: sample.good)
        } catch {
            return Check(area: area, name: "Розмітка через читача модуля",
                         status: .failed, detail: "модуль не відкрився: \(error)")
        }
        defer { module.releaseCache() }

        var shown = 0
        var tagged = 0
        var leftovers: [String] = []
        for book in module.books {
            guard let chapters = try? module.chapters(ofBook: book) else {
                leftovers.append("\(book.fullName): книга не читається")
                continue
            }
            for chapter in chapters {
                for verse in chapter.verses {
                    shown += 1
                    if verse.text.contains("<") || verse.text.contains(">") {
                        leftovers.append("\(book.shortNames.first ?? book.fullName) \(chapter.number):\(verse.number) — "
                            + "«\(verse.text.prefix(60))»")
                    }
                }
            }
        }
        // Сколько стихов образца вообще несут разметку: без этого числа
        // «остатков нет» значило бы и «разбирать было нечего».
        tagged = MySwordFixture.taggedVerseCount

        return Check(area: area, name: "Розмітка через читача модуля",
                     status: leftovers.isEmpty ? .ok : .failed,
                     detail: leftovers.isEmpty
                        ? "прочитано \(shown) віршів, із них із розміткою \(tagged); "
                            + "жодної кутової дужки в показаному тексті"
                        : "залишки розмітки: " + leftovers.joined(separator: "; "))
    }

    private static func realModulesCheck(area: String, state: AppState) -> Check {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: state.modulesFolder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let real = entries.filter { MySwordModule.isBibleModuleName($0.lastPathComponent) }
        guard !real.isEmpty else {
            return Check(area: area, name: "Справжні модулі MySword",
                         status: .skipped,
                         detail: "у теці модулів жодного «*.bbl.mybible» — читача перевірено "
                            + "лише на зібраному зразку, на живому модулі ще ні")
        }
        var failed: [String] = []
        var opened: [String] = []
        var withMarkup = 0
        for url in real {
            do {
                let module = try MySwordModule(fileAt: url)
                defer { module.releaseCache() }
                guard let first = module.books.first,
                      let chapter = try module.chapters(ofBook: first).first,
                      !chapter.verses.isEmpty else {
                    failed.append("\(url.lastPathComponent): перший розділ порожній")
                    continue
                }
                // Есть ли в модуле разметка вообще. Без этого отчёт про
                // «настоящий модуль открылся» читался бы как «разбор разметки
                // проверен на живых данных», а это разные вещи: у UKJV
                // угловых скобок нет ни в одном стихе, и разбирать там нечего.
                var markupSeen = false
                for book in module.books.prefix(4) {
                    guard let chapters = try? module.chapters(ofBook: book) else { continue }
                    if chapters.contains(where: { $0.verses.contains { $0.text.contains("<") } }) {
                        markupSeen = true
                        break
                    }
                }
                if markupSeen { withMarkup += 1 }
                opened.append("\(module.info.shortName) (книг \(module.books.count))")
            } catch {
                failed.append("\(error)")
            }
        }
        // Остаток разметки в показанном тексте — это уже поломка, а вот её
        // полное отсутствие в исходниках стихов означает только одно: разбор
        // на живом модуле по-прежнему не проверен, и сказать об этом надо.
        let note = withMarkup > 0
            ? "; розмітка трапляється — розбір працює на живих даних"
            : "; у жодному немає розмітки — розбір перевірено лише на зразку"
        return Check(area: area, name: "Справжні модулі MySword",
                     status: failed.isEmpty ? (withMarkup > 0 ? .ok : .warning) : .failed,
                     detail: failed.isEmpty ? opened.joined(separator: ", ") + note
                                            : failed.joined(separator: "; "))
    }
}

// MARK: - Образец модулей

/// Собранный во временной папке набор файлов MySword.
///
/// Собираем сами и своим кодом: настоящих модулей MySword нет ни у владельца,
/// ни у нас, а проверка обязана работать на любой машине и не зависеть от
/// того, что кто-то положил рядом нужный файл.
struct MySwordFixture {

    /// Каким отказом читатель обязан ответить на чужой файл.
    enum Refusal {
        case notBibleModule    // тип модуля виден по имени — до открытия файла
        case notADatabase      // не SQLite: `open` смолчит, правду скажет запрос
        case notAModule        // база есть, таблицы `Bible` нет
        case noVerses          // таблицы на месте, стихов ноль
        case encrypted         // текст зашифрован
        case strangeNumbering  // все книги вне 1…66

        var title: String {
            switch self {
            case .notBibleModule:   return "не тот тип модуля"
            case .notADatabase:     return "не база данных"
            case .notAModule:       return "нет таблицы Bible"
            case .noVerses:         return "нет ни одного стиха"
            case .encrypted:        return "модуль зашифрован"
            case .strangeNumbering: return "непонятная нумерация книг"
            }
        }
    }

    let folder: URL
    let good: URL
    let strangers: [(url: URL, expected: Refusal)]

    static func kind(of error: MySwordError) -> Refusal? {
        switch error {
        case .notBibleModule:   return .notBibleModule
        case .notADatabase:     return .notADatabase
        case .notAModule:       return .notAModule
        case .noVerses:         return .noVerses
        case .encrypted:        return .encrypted
        case .strangeNumbering: return .strangeNumbering
        case .cannotOpen, .queryFailed: return nil
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Отдельная папка с переводом и двумя его спутниками — так выглядит
    /// настоящая папка модулей MySword. В общей папке образца рядом лежат
    /// нарочно испорченные файлы, и для мастера они только мешают.
    func wizardFolder() -> URL? {
        let fm = FileManager.default
        let target = folder.appendingPathComponent("Мастер")
        if fm.fileExists(atPath: target.path) { return target }
        guard (try? fm.createDirectory(at: target, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        for name in ["Proba.bbl.mybible", "Proba.cmt.mybible", "Proba.dct.mybible"] {
            guard (try? fm.copyItem(at: folder.appendingPathComponent(name),
                                    to: target.appendingPathComponent(name))) != nil else { return nil }
        }
        return target
    }

    // MARK: Содержимое образца

    /// Стихи образца: номера книг сквозные, 1 Бытие, 19 Псалтирь, 40 Матфей,
    /// 43 Иоанн, — и в каждой книге своя ловушка разметки.
    private static let verses: [(book: Int, chapter: Int, verse: Int, text: String)] = [
        (1, 1, 1, "В начале сотворил Бог небо и землю."),
        (1, 1, 2, "Земля же была безвидна и пуста, и тьма над бездною, "
            + "и Дух Божий носился над водою.<CM>"),
        (1, 1, 3, "И сказал Бог: да будет свет. И стал свет."
            + "<RF>Буквально: «и был свет».<Rf>"),
        (1, 1, 4, "И увидел Бог свет, что он хорош, и отделил Бог свет от тьмы."),
        (1, 1, 5, "И назвал Бог свет днем, а тьму ночью. "
            + "И был вечер, и было утро: день один.<CM>"),
        (1, 2, 1, "Так совершены небо и земля и все воинство их."),
        (1, 2, 2, "И совершил Бог к седьмому дню дела Свои, которые Он делал."),
        (1, 2, 3, "И благословил Бог седьмой день, и освятил его."),

        (19, 23, 1, "<TS>Псалом Давида<Ts><PI1><PF1>Господь — Пастырь мой; "
            + "я ни в чем не буду нуждаться:<CM>"),
        (19, 23, 2, "<PI1>Он покоит меня на злачных пажитях и водит меня к водам тихим,"),
        (19, 23, 3, "<PI1>подкрепляет душу мою, направляет меня на стези правды "
            + "ради имени Своего.<CM>"),

        (40, 5, 3, "<TS>Заповеди блаженства<Ts><FR>Блаженны нищие духом, ибо их "
            + "есть Царство Небесное.<Fr><CM>"),
        (40, 5, 4, "<FR>Блаженны плачущие, ибо они утешатся.<Fr>"),

        (43, 1, 1, "<Q><wg>Εν<WG1722><WTPREP><E>В начале<e><q> "
            + "<Q><wg>ἀρχῇ<WG746><X>ar·khe<x><E>было<e><q> "
            + "<Q><wg>ἦν<WG2258><E>Слово<e><q>"),
        (43, 3, 16, "<FR>Ибо так возлюбил<WG25> Бог<WG2316> мир, что отдал Сына "
            + "Своего Единородного, дабы всякий верующий<WG4100> в Него "
            + "не погиб, но имел жизнь вечную.<Fr><RX43.3.17>"),
        (43, 3, 17, "<FR>Ибо не послал Бог Сына Своего в мир, чтобы судить мир, "
            + "но чтобы мир спасен был чрез Него.<Fr>"
            + "<RF q=a>В некоторых списках — «через Него».<Rf><CM>"),
        (43, 3, 18, "Верующий в Него не судится, а неверующий уже осужден, потому "
            + "что не уверовал во имя Единородного Сына Божия.<FI>есть<Fi>"),
    ]

    /// Сколько стихов образца несут разметку. Считается по самому списку, а
    /// не записано числом: допишешь стих — счёт сойдётся сам.
    static var taggedVerseCount: Int { verses.filter { $0.text.contains("<") }.count }

    /// Колонки `Details` образца: обязательные поля e-Sword-овского наследства
    /// плюс те, что добавил сам MySword. Набор и порядок у разных изготовителей
    /// свои — потому читатель и разбирает строку по именам колонок.
    private static let details: [(name: String, type: String, value: String)] = [
        ("Description", "NVARCHAR(255)", "Слово — проверочный модуль MySword"),
        ("Abbreviation", "NVARCHAR(50)", "PROBA"),
        ("Comments", "TEXT", "Образец для проверки читателя. Текст синодальный, общественное достояние."),
        ("Version", "TEXT", "1.0"),
        ("VersionDate", "DATETIME", "2026-08-25"),
        ("PublishDate", "DATETIME", "2026"),
        ("RightToLeft", "BOOL", "0"),
        ("OT", "BOOL", "1"),
        ("NT", "BOOL", "1"),
        ("Strong", "BOOL", "1"),
        ("Language", "NVARCHAR(3)", "rus"),
        ("ParagraphIndent", "INT", "1"),
        ("CustomCSS", "TEXT", ".ot {color:#777;}"),
    ]

    // MARK: Сборка

    static func build() -> MySwordFixture? {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory
            .appendingPathComponent("slovo-mysword-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return nil
        }

        func path(_ name: String) -> URL { folder.appendingPathComponent(name) }

        let good = path("Proba.bbl.mybible")
        guard makeBible(at: good, details: details, verses: verses, indexed: true) else { return nil }

        var strangers: [(url: URL, expected: Refusal)] = []

        // Комментарий и словарь — те же базы SQLite, но с другими таблицами.
        // Под своим расширением их видно ещё до открытия файла, а под чужим
        // правду скажет только отсутствие таблицы `Bible`.
        guard makeCommentary(at: path("Proba.cmt.mybible")),
              makeDictionary(at: path("Proba.dct.mybible")),
              makeCommentary(at: path("Proba-comment-inside.bbl.mybible")),
              makeDictionary(at: path("Proba-dict-inside.bbl.mybible")),
              makeMyBible(at: path("Proba-mybible-inside.bbl.mybible")),
              makeMyBible(at: path("Proba-mybible-format.SQLite3")),
              makeBible(at: path("Proba-no-bible-table.bbl.mybible"),
                        details: details, verses: nil, indexed: false),
              makeBible(at: path("Proba-no-verses.bbl.mybible"),
                        details: details, verses: [], indexed: false),
              makeBible(at: path("Proba-encrypted.bbl.mybible"),
                        details: details + [("encryption", "INT", "1")],
                        verses: [(1, 1, 1, "8f2a1c9e7d5b3a0f6c4e2d1b8a7f5c3e")], indexed: false),
              makeBible(at: path("Proba-apocrypha.bbl.mybible"), details: details,
                        verses: [(67, 1, 1, "Книга с номером вне канона."),
                                 (70, 1, 1, "И ещё одна.")], indexed: false),
              makeText(at: path("Proba-not-sqlite.bbl.mybible"),
                       "Это вовсе не база данных, а обычный текст.\n"),
              makeText(at: path("Proba-empty.bbl.mybible"), "")
        else {
            try? fm.removeItem(at: folder)
            return nil
        }

        strangers = [
            (path("Proba.cmt.mybible"), .notBibleModule),
            (path("Proba.dct.mybible"), .notBibleModule),
            (path("Proba-mybible-format.SQLite3"), .notBibleModule),
            (path("Proba-comment-inside.bbl.mybible"), .notAModule),
            (path("Proba-dict-inside.bbl.mybible"), .notAModule),
            (path("Proba-mybible-inside.bbl.mybible"), .notAModule),
            (path("Proba-no-bible-table.bbl.mybible"), .notAModule),
            (path("Proba-empty.bbl.mybible"), .notAModule),
            (path("Proba-no-verses.bbl.mybible"), .noVerses),
            (path("Proba-encrypted.bbl.mybible"), .encrypted),
            (path("Proba-apocrypha.bbl.mybible"), .strangeNumbering),
            (path("Proba-not-sqlite.bbl.mybible"), .notADatabase),
        ]

        return MySwordFixture(folder: folder, good: good, strangers: strangers)
    }

    /// Правильный модуль MySword. `verses == nil` — база вовсе без таблицы
    /// `Bible`, пустой массив — таблица есть, а стихов в ней нет.
    private static func makeBible(at url: URL,
                                  details: [(name: String, type: String, value: String)],
                                  verses: [(book: Int, chapter: Int, verse: Int, text: String)]?,
                                  indexed: Bool) -> Bool {
        write(to: url) { db in
            let columns = details.map { "\($0.name) \($0.type)" }.joined(separator: ", ")
            guard exec(db, "CREATE TABLE Details(\(columns))"),
                  exec(db, "INSERT INTO Details VALUES("
                        + details.map { quoted($0.value) }.joined(separator: ",") + ")")
            else { return false }

            guard let verses else { return true }
            guard exec(db, "CREATE TABLE Bible(Book INT, Chapter INT, Verse INT, "
                        + "Scripture TEXT, Primary Key(Book,Chapter,Verse))") else { return false }
            for row in verses {
                guard exec(db, "INSERT INTO Bible VALUES(\(row.book),\(row.chapter),"
                            + "\(row.verse),\(quoted(row.text)))") else { return false }
            }
            // Такой индекс кладут в модули ради быстрого перехода по ссылке;
            // на нём же держится наш запрос списка книг.
            guard !indexed || exec(db, "CREATE INDEX bible_key ON Bible(Book, Chapter, Verse)") else {
                return false
            }
            return true
        }
    }

    private static func makeCommentary(at url: URL) -> Bool {
        write(to: url) { db in
            exec(db, "CREATE TABLE Details(Description NVARCHAR(255), Abbreviation NVARCHAR(50))")
                && exec(db, "INSERT INTO Details VALUES('Проверочный комментарий','PROBA-C')")
                && exec(db, "CREATE TABLE Commentary(Book INT, Chapter INT, FromVerse INT, "
                        + "ToVerse INT, Data TEXT)")
                && exec(db, "INSERT INTO Commentary VALUES(43,3,16,0,'<p>О Ин 3:16.</p>')")
        }
    }

    private static func makeDictionary(at url: URL) -> Bool {
        write(to: url) { db in
            exec(db, "CREATE TABLE Details(Description NVARCHAR(255), Abbreviation NVARCHAR(50))")
                && exec(db, "INSERT INTO Details VALUES('Проверочный словарь','PROBA-D')")
                && exec(db, "CREATE TABLE Dictionary(Word NVARCHAR(255), Data TEXT)")
                && exec(db, "INSERT INTO Dictionary VALUES('G25','<p>ἀγαπάω — любить.</p>')")
        }
    }

    /// Модуль MyBible: тот же SQLite, но таблицы `info`/`books`/`verses` и
    /// номера книг 10…730. Для читателя MySword — чужак.
    private static func makeMyBible(at url: URL) -> Bool {
        write(to: url) { db in
            exec(db, "CREATE TABLE info(name TEXT, value TEXT)")
                && exec(db, "INSERT INTO info VALUES('description','Проверочный модуль MyBible')")
                && exec(db, "INSERT INTO info VALUES('language','ru')")
                && exec(db, "CREATE TABLE books(book_number NUMERIC, short_name TEXT, long_name TEXT)")
                && exec(db, "INSERT INTO books VALUES(10,'Быт','Бытие')")
                && exec(db, "INSERT INTO books VALUES(500,'Ин','От Иоанна')")
                && exec(db, "CREATE TABLE verses(book_number NUMERIC, chapter NUMERIC, "
                        + "verse NUMERIC, text TEXT)")
                && exec(db, "INSERT INTO verses VALUES(10,1,1,'В начале сотворил Бог небо и землю.')")
                && exec(db, "INSERT INTO verses VALUES(500,3,16,'Ибо так возлюбил Бог мир…')")
        }
    }

    private static func makeText(at url: URL, _ text: String) -> Bool {
        (try? Data(text.utf8).write(to: url)) != nil
    }

    private static func write(to url: URL, _ body: (OpaquePointer) -> Bool) -> Bool {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return false
        }
        let ok = body(handle)
        sqlite3_close(handle)
        return ok
    }

    private static func exec(_ handle: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Одинарная кавычка внутри текста удваивается — в образце такие есть.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
