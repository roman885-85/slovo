import AppKit
import SlovoCore

/// Самопроверка окна «Редактор несоответствий нумерации переводов Библии» (N40).
///
/// Проверки настоящие, по живым данным: сколько строк в базе, скольким
/// переводам назначен стандарт, сходятся ли опорные адреса туда и обратно,
/// и не расходятся ли правила с содержимым тех переводов, что уже открыты.
/// Ничего не читает с диска сверх маленькой базы правил: диагностика не имеет
/// права подвесить окно.
extension Diagnostics {

    static func numberingEditorSection(state: AppState) -> [Check] {
        let area = "Нумерація"
        var checks: [Check] = []

        let dataRoot = state.modulesFolder.deletingLastPathComponent()
        let original = NumberingBase.originalURL(dataRoot: dataRoot)
        let authorCopy = NumberingBase.userURL.deletingLastPathComponent()
            .appendingPathComponent("inconsistencies.author.sqlite3")

        // 1. База открыта — и числа настоящие, а не «файл на месте».
        //
        // Читаем копию, которую окно снимает с базы автора. Копии ещё нет —
        // берём то, что уже разобрала программа: подключаться самим к файлу
        // внутри чужого приложения незачем даже на чтение.
        let hasCopy = FileManager.default.fileExists(atPath: authorCopy.path)
        let reference = hasCopy ? ((try? NumberingBase.load(from: authorCopy)) ?? NumberingBase())
                                : state.numbering
        let sourceName = hasCopy ? "копія бази автора: \(authorCopy.path)"
                                 : "копію ще не знято, числа з пам'яті програми"
        checks.append(Check(area: area, name: "Базу невідповідностей відкрито",
                            status: reference.rules.isEmpty ? .failed : .ok,
                            detail: reference.rules.isEmpty
                                ? "правил не прочитано; база автора: \(original.path)"
                                : "стандартів \(reference.standards.count), рядків модулів "
                                    + "\(reference.modules.count), правил \(reference.rules.count); "
                                    + sourceName))

        // 2. Пока стандарт не назначен, перевод адреса для модуля не работает
        //    вовсе, и параллельный перевод показывает не тот стих.
        let modules = state.allModules.filter { $0.info.isBible }
        let named = modules.filter { inBase(state, $0) != nil }
        let resolved = modules.filter { standardID(state, $0) != nil }
        checks.append(Check(area: area, name: "Стандарт призначено модулям",
                            status: resolved.isEmpty ? .failed
                                : (resolved.count == modules.count ? .ok : .warning),
                            detail: "зі стандартом \(resolved.count) із \(modules.count) "
                                + "(у базі названо \(named.count), решту визначено за вмістом)"
                                + (resolved.count == modules.count ? ""
                                   : "; без стандарту \(modules.count - resolved.count) — "
                                     + "вони перекладаються тотожно, як і до вікна N40")))

        // 3. Имя в таблице автора, которому не отвечает ни одна папка, — это
        //    молча неработающее назначение. У владельца такое одно: UA_Ogienka
        //    при папке UA_Ogienko.
        let names = Array(Set(state.allModules.flatMap {
            [$0.identifier.lowercased(), $0.info.shortName.lowercased()]
        }))
        let known = Set(names)
        let unmatched = reference.modules.keys.filter { !known.contains($0) }.sorted()
        // Имя с опиской теперь связывается с папкой само (`ModuleNameMatch`),
        // и «нет такой папки» про него уже неправда. Но и молчать нельзя:
        // связь по близкому имени — догадка, и в отчёте она названа.
        let bound = unmatched.compactMap { name in
            ModuleNameMatch.nearest(name, among: names).map { (name, $0) }
        }
        let orphans = unmatched.filter { name in !bound.contains { $0.0 == name } }
        let boundText = bound.map { "\($0.0) пов'язано з \($0.1)" }.joined(separator: "; ")
        checks.append(Check(area: area, name: "Імена модулів у базі ведуть на справжні модулі",
                            status: orphans.isEmpty ? .ok : .warning,
                            detail: orphans.isEmpty
                                ? (bound.isEmpty
                                   ? "усі \(reference.modules.count) рядків таблиці modules знайшли свій переклад"
                                   : "усі \(reference.modules.count) рядків знайшли свій переклад; за близьким ім'ям: \(boundText)")
                                : orphans.map { name in
                                    let nearest = nearestModuleName(to: name, in: state.allModules)
                                    return nearest.map { "\(name) — такої теки немає, найближча \($0)" }
                                        ?? "\(name) — такої теки немає"
                                  }.joined(separator: "; ")))

        // 4. Опорные точки ru↔en: порядок разбора правил (D → P → OC+OV)
        //    восстановлен по данным, документа с ним нет. Если он когда-нибудь
        //    окажется другим, эта проверка увидит это первой.
        checks.append(roundTrip(area: area, rules: reference.rules, state: state))

        // 5. Правила против настоящего текста: считаем промахи по Псалтири.
        checks.append(psalmRun(area: area, state: state))

        // 5а. Окно и зал считают одним движком — сторож против третьего.
        checks.append(sameEngineCheck(state: state))

        // 6. Где лежат свои правки — вопрос, который человек задаёт первым.
        let userURL = NumberingBase.userURL
        if FileManager.default.fileExists(atPath: userURL.path),
           let mine = try? NumberingBase.load(from: userURL) {
            var differing = 0
            for rule in mine.rules where !reference.rules.contains(where: { same($0, rule) }) { differing += 1 }
            for rule in reference.rules where !mine.rules.contains(where: { same($0, rule) }) { differing += 1 }
            for (name, code) in mine.modules where reference.modules[name] != code { differing += 1 }
            checks.append(Check(area: area, name: "Свої правки на місці",
                                status: .ok,
                                detail: "своя копія є, рядків відрізняється від авторських: \(differing); "
                                    + userURL.path))
        } else {
            checks.append(Check(area: area, name: "Свої правки на місці",
                                status: .ok,
                                detail: "своєї копії немає — читається база автора; з'явиться по «Ок» у вікні N40: "
                                    + userURL.path))
        }

        return checks
    }

    // MARK: - Опорные точки

    /// Пять адресов, на которых нумерации расходятся сильнее всего: конец
    /// главы уехал в начало следующей (Нав 5:16, Иов 39:31, Дан 3:31),
    /// славословие Римлян переставлено в конец (Рим 14:24) и Псалтирь
    /// сдвинута на главу (Пс 9:22).
    private static func roundTrip(area: String, rules: [NumberingRule], state: AppState) -> Check {
        let points = [(60, 5, 16, "Нав 5:16"), (220, 39, 31, "Иов 39:31"),
                      (520, 14, 24, "Рим 14:24"), (340, 3, 31, "Дан 3:31"),
                      (230, 9, 22, "Пс 9:22")]
        guard !rules.isEmpty else {
            return Check(area: area, name: "Переклад адреси туди й назад",
                         status: .skipped, detail: "правил немає — перекладати нічим")
        }

        var moved: [String] = []
        for (book, chapter, verse, name) in points {
            let forward = NumberingEditorModel.translate(rules: rules, book: book, chapter: chapter,
                                                         verses: [verse], from: "ru", to: "en")
            var back: [(Int, Int)] = []
            for span in forward.spans {
                for number in span.verses {
                    let answer = NumberingEditorModel.translate(rules: rules, book: book,
                                                               chapter: span.chapter, verses: [number],
                                                               from: "en", to: "ru")
                    for returned in answer.spans {
                        back.append(contentsOf: returned.verses.map { (returned.chapter, $0) })
                    }
                }
            }
            guard back.contains(where: { $0.0 == chapter && $0.1 == verse }) else {
                let there = forward.spans
                    .map { ReferenceFormat.position(chapter: $0.chapter, verses: $0.verses) }
                    .joined(separator: ", ")
                let here = back.map { "\($0.0):\($0.1)" }.joined(separator: ", ")
                return Check(area: area, name: "Переклад адреси туди й назад",
                             status: .failed,
                             detail: "\(name) → \(there) → \(here.isEmpty ? "никуда" : here)")
            }
            let there = forward.spans
                .map { ReferenceFormat.position(chapter: $0.chapter, verses: $0.verses) }
                .joined(separator: ", ")
            if there != ReferenceFormat.position(chapter: chapter, verses: [verse]) {
                moved.append("\(name) → \(there)")
            }
        }
        _ = state
        return Check(area: area, name: "Переклад адреси туди й назад",
                     status: .ok,
                     detail: "п'ять опорних точок ru↔en повернулися на своє місце"
                        + (moved.isEmpty ? "" : "; \(moved.joined(separator: ", "))"))
    }

    // MARK: - Правила против текста

    /// Перевести всю Псалтирь первого перевода во второй и посчитать промахи.
    ///
    /// Читает только то, что уже разобрано: если книга ещё не открыта,
    /// проверка честно пропускается. Диагностика не имеет права ждать диск.
    private static func psalmRun(area: String, state: AppState) -> Check {
        let name = "Правила згодні з умістом модулів"
        guard let source = state.module(state.primaryModuleID) ?? state.allModules.first,
              let from = standardID(state, source),
              let sourceBook = source.books.first(where: { $0.canonicalNumber == 230 }),
              let left = source.cachedChapters(ofBook: sourceBook)
        else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "Псалтир основного перекладу ще не розібрано або стандарт йому не призначено")
        }

        // Второй перевод берём такой, чтобы стандарты разошлись: на паре с
        // одинаковым счётом проверять нечего. Сначала тот, что открыт рядом,
        // потом любой из библиотеки — но только с уже разобранной Псалтирью:
        // ждать диск диагностике нельзя.
        let candidates = (state.secondaryModuleIDs.compactMap { state.module($0) }
                          + state.allModules.filter { $0.info.isBible })
        var chosen: (module: TextModule, standard: String, chapters: [Chapter])?
        for module in candidates where module.identifier != source.identifier {
            guard let code = standardID(state, module), code != from,
                  let book = module.books.first(where: { $0.canonicalNumber == 230 }),
                  let ready = module.cachedChapters(ofBook: book) else { continue }
            chosen = (module, code, ready)
            break
        }
        guard let chosen else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "поруч немає розібраного перекладу з іншим стандартом (у \(source.displayName) — \(from))")
        }

        var known: Set<Int> = []
        for chapter in chosen.chapters {
            for verse in chapter.verses { known.insert(chapter.number &* 100_000 &+ verse.number) }
        }
        var total = 0
        var missed: [String] = []
        let rules = state.numbering.rules
        for chapter in left {
            for verse in chapter.verses {
                total += 1
                let answer = NumberingEditorModel.translate(rules: rules, book: 230,
                                                            chapter: chapter.number,
                                                            verses: [verse.number],
                                                            from: from, to: chosen.standard)
                let landed = answer.spans.contains { span in
                    span.verses.contains { known.contains(span.chapter &* 100_000 &+ $0) }
                }
                if !landed { missed.append("\(chapter.number):\(verse.number)") }
            }
        }
        let head = "\(source.displayName) (\(from)) → \(chosen.module.displayName) (\(chosen.standard)): "
            + "віршів \(total), промахів \(missed.count)"
        return Check(area: area, name: name,
                     status: missed.count <= 5 ? .ok : .warning,
                     detail: missed.count <= 5
                        ? head + (missed.isEmpty ? "" : " — \(missed.joined(separator: ", "))")
                        : head + " — перші: \(missed.prefix(3).joined(separator: ", "))")
    }

    /// Окно и зал считают одним движком.
    ///
    /// Раньше их было три: свой разбор в окне N40, свой в базе и настоящий в
    /// `VerseNumbering`. Расходились они на 947 адресах из 856 170, и прав
    /// всякий раз оказывался последний — а человек чинил адрес, глядя на
    /// первый. Теперь считает один, и эта проверка сторожит, чтобы второй не
    /// завёлся снова: адрес из окна обязан совпасть с адресом слайда.
    static func sameEngineCheck(state: AppState) -> Check {
        let area = "Нумерація"
        let engine = VerseNumbering.shared
        let rules = state.numbering.rules
        guard !rules.isEmpty, engine.isReady else {
            return Check(area: area, name: "Вікно й зал рахують однаково",
                         status: .skipped, detail: "правила ще не прочитано")
        }
        let pairs = [("ru", "en"), ("en", "ru"), ("ru", "ua"), ("ua", "ru"),
                     ("en", "pl"), ("pl", "en")]
        // Книги, у которых в базе вообще есть правила: где правил нет, оба
        // движка отдают те же числа, и сверять там нечего.
        let books = Array(Set(rules.map(\.book))).sorted()
        var checked = 0
        var differ: [String] = []
        for (from, to) in pairs {
            for book in books {
                for chapter in stride(from: 1, through: 151, by: 3) {
                    for verse in stride(from: 1, through: 40, by: 3) {
                        checked += 1
                        let window = NumberingEditorModel.translate(
                            rules: rules, book: book, chapter: chapter,
                            verses: [verse], from: from, to: to).spans
                        let hall = engine.translate(book: book, chapter: chapter, verses: [verse],
                                                    from: engine.standard(id: from),
                                                    to: engine.standard(id: to))
                        guard key(window) != key(hall) else { continue }
                        if differ.count < 3 {
                            differ.append("\(from)→\(to) кн.\(book) \(chapter):\(verse) — "
                                + "вікно \(key(window)), зал \(key(hall))")
                        }
                    }
                }
            }
        }
        return Check(area: area, name: "Вікно й зал рахують однаково",
                     status: differ.isEmpty ? .ok : .failed,
                     detail: differ.isEmpty
                        ? "звірено \(checked) адрес за \(books.count) книгами, розбіжностей немає"
                        : "розходяться:" + differ.joined(separator: "; "))
    }

    private static func key(_ spans: [VerseSpan]) -> String {
        spans.flatMap { span in span.verses.map { "\(span.chapter):\($0)" } }
            .sorted().joined(separator: ",")
    }

    // MARK: - Мелочи

    /// Стандарт перевода по базе несоответствий — как его видит окно N40.
    private static func inBase(_ state: AppState, _ module: TextModule) -> String? {
        state.numbering.standardCode(forModuleNames: [module.info.shortName, module.identifier])
    }

    /// Стандарт перевода тем же порядком, каким его берёт остальная
    /// программа: сперва строка базы, потом уже посчитанное по содержимому.
    /// Диск при этом не читается — иначе диагностика ждала бы Псалтирь.
    private static func standardID(_ state: AppState, _ module: TextModule) -> String? {
        if let code = inBase(state, module) { return code }
        guard let known = NumberingAssignments.shared.knownAssignment(forModule: module.identifier),
              known.isKnown else { return nil }
        return known.standardID
    }

    private static func same(_ one: NumberingRule, _ two: NumberingRule) -> Bool {
        NumberingEditorModel.key(one) == NumberingEditorModel.key(two)
            && one.chapterTo == two.chapterTo && one.chapterToEnd == two.chapterToEnd
            && one.verseTo == two.verseTo && one.verseToEnd == two.verseToEnd
    }

    private static func nearestModuleName(to name: String, in modules: [TextModule]) -> String? {
        var best: (String, Int)?
        for module in modules {
            for candidate in [module.identifier, module.info.shortName] where !candidate.isEmpty {
                let distance = editDistance(name.lowercased(), candidate.lowercased())
                if best == nil || distance < best!.1 { best = (candidate, distance) }
            }
        }
        guard let best, best.1 <= 3 else { return nil }
        return best.0
    }

    private static func editDistance(_ one: String, _ two: String) -> Int {
        let a = Array(one), b = Array(two)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            previous = current
        }
        return previous[b.count]
    }
}
