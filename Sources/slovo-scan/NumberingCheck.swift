import Foundation
import SlovoCore

/// Проверка базы несоответствий нумерации (`inconsistencies.sqlite3`) —
/// на настоящем файле автора и настоящих модулях владельца.
///
/// Проверяем три вещи: база читается, наша запись даёт тот же состав, и
/// переложенный адрес попадает в существующий стих другого перевода.
func runNumberingCheck(modulesURL: URL) -> Int32 {
    let dataRoot = modulesURL.deletingLastPathComponent()
    let original = NumberingBase.originalURL(dataRoot: dataRoot)

    print("база: \(original.path)")
    guard FileManager.default.fileExists(atPath: original.path) else {
        print("  файла нет — проверять нечего")
        return 1
    }

    let base: NumberingBase
    do { base = try NumberingBase.load(from: original) } catch {
        print("  не читается: \(error)")
        return 1
    }
    print("  стандартов \(base.standards.count), модулей \(base.modules.count), правил \(base.rules.count)")
    for standard in base.standards {
        let mine = base.modules.filter { $0.value == standard.code }.count
        print("    \(standard.code): \(standard.description) — модулей \(mine)")
    }
    for kind in NumberingRuleKind.allCases {
        print("    \(kind.rawValue) (\(kind.title)): \(base.rules.filter { $0.kind == kind }.count)")
    }

    var problems = 0

    // 1. Круговой прогон записи: пишем свою копию, читаем обратно, сверяем.
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("slovo-numbering-\(UUID().uuidString).sqlite3")
    do {
        try base.save(to: temporary)
        let again = try NumberingBase.load(from: temporary)
        var mismatch: [String] = []
        if again.standards != base.standards { mismatch.append("стандарты") }
        if again.modules != base.modules { mismatch.append("модули") }
        let before = base.rules.map(key).sorted()
        let after = again.rules.map(key).sorted()
        if before != after {
            mismatch.append("правила (\(before.count) → \(after.count))")
            for line in Set(before).symmetricDifference(Set(after)).sorted().prefix(5) {
                mismatch.append("      расходится: \(line)")
            }
        }
        if mismatch.isEmpty {
            print("\nзапись и чтение обратно: сошлось всё")
        } else {
            print("\nзапись и чтение обратно: РАСХОЖДЕНИЯ — \(mismatch.joined(separator: ", "))")
            problems += 1
        }
        try? FileManager.default.removeItem(at: temporary)
    } catch {
        print("\nзапись не удалась: \(error)")
        problems += 1
    }

    // 2. Известные места Псалтири: восточный счёт против западного.
    print("\nпересчёт адресов (Псалтирь, книга 230):")
    let samples: [(Int, Int, String, String)] = [
        (22, 1, "ru", "ua"),   // Синодальный «Господь — Пастырь мой» = 23-й псалом
        (9, 22, "ru", "ua"),   // конец 9-го псалма = начало 10-го
        (11, 2, "ru", "en"),
        (146, 1, "ru", "ua"),
        (23, 1, "ua", "ru"),
    ]
    // Движок один на всю программу — тот же, что собирает слайд.
    let engine = VerseNumbering.over(rules: base.rules, standards: base.standards)
    func standard(_ code: String) -> VerseNumberingStandard {
        VerseNumberingStandard(id: code, title: code)
    }
    for (chapter, verse, from, to) in samples {
        let spans = engine.translate(book: 230, chapter: chapter, verses: [verse],
                                     from: standard(from), to: standard(to))
        let address = spans.first ?? VerseSpan(chapter: chapter, verses: [verse])
        print("  \(from) → \(to): \(chapter):\(verse) → \(address.chapter):"
              + address.verses.map(String.init).joined(separator: ","))
    }

    // 3. Настоящие модули: переложенный адрес обязан существовать.
    //
    // Модуль назначения берём не наугад, а по самой базе: в таблице `modules`
    // записаны сокращения (`BibleShortName`), и стандарт модуля известен
    // только оттуда. Модуль-источник — тот, которого в таблице нет: у автора
    // перечислены только исключения, остальное считается восточным счётом.
    let library = ModuleLibrary(modulesDirectory: modulesURL)
    func shortNames(_ module: TextModule) -> [String] {
        [module.info.shortName, module.identifier].filter { !$0.isEmpty }
    }

    // Какой у модуля счёт — видно по самой Псалтири: в восточном счёте
    // 10-й псалом короткий (7 стихов), в западном длинный (18). На это и
    // опираемся: таблица `modules` у автора заполнена по языку издания, и
    // трём украинским переводам стандарт «ua» проставлен зря — считают они
    // по-восточному. Ради этого редактор и нужен, но проверять пересчёт надо
    // на модуле, который правда считает по-западному.
    func psalmShape(_ module: TextModule) -> Int? {
        guard let book = module.books.first(where: { $0.canonicalNumber == 230 }),
              let chapters = try? module.chapters(ofBook: book),
              let tenth = chapters.first(where: { $0.number == 10 }) else { return nil }
        return tenth.verses.count
    }

    let listed = library.modules.filter { base.standardCode(forModuleNames: shortNames($0)) == "ua" }
    print("\nмодулей библиотеки со стандартом «ua»: "
          + listed.map { $0.info.shortName }.joined(separator: ", "))
    let mislabelled = listed.filter { (psalmShape($0) ?? 0) < 10 }
    if !mislabelled.isEmpty {
        print("  из них считают по-восточному, вопреки записи в базе: "
              + mislabelled.map { $0.info.shortName }.joined(separator: ", "))
    }
    let unmatched = base.modules.keys.filter { name in
        !library.modules.contains { shortNames($0).contains { $0.lowercased() == name } }
    }
    if !unmatched.isEmpty {
        print("  названы базой, но в библиотеке не найдены: " + unmatched.sorted().joined(separator: ", "))
    }

    guard let target = listed.first(where: { (psalmShape($0) ?? 0) >= 10 }),
          let source = library.modules.first(where: {
              $0.identifier.lowercased().hasPrefix("rst") && (psalmShape($0) ?? 0) < 10
          }),
          let sourceBook = source.books.first(where: { $0.canonicalNumber == 230 }),
          let targetBook = target.books.first(where: { $0.canonicalNumber == 230 }) else {
        print("  пары модулей разного счёта не нашлось — пропущено")
        return problems == 0 ? 0 : 1
    }

    let sourceChapters = (try? source.chapters(ofBook: sourceBook)) ?? []
    let targetChapters = (try? target.chapters(ofBook: targetBook)) ?? []
    print("сверка: \(source.info.shortName) (восточный счёт) → \(target.info.shortName) (западный)")

    var checked = 0, missing = 0, examples: [String] = []
    for chapter in sourceChapters {
        for verse in chapter.verses {
            let spans = engine.translate(book: 230, chapter: chapter.number,
                                         verses: [verse.number],
                                         from: standard("ru"), to: standard("ua"))
            let address = spans.first ?? VerseSpan(chapter: chapter.number, verses: [verse.number])
            checked += 1
            guard let landed = targetChapters.first(where: { $0.number == address.chapter }) else {
                missing += 1
                if examples.count < 6 { examples.append("нет главы \(address.chapter) (из \(chapter.number):\(verse.number))") }
                continue
            }
            for number in address.verses where landed.verse(number) == nil {
                missing += 1
                if examples.count < 6 {
                    examples.append("нет стиха \(address.chapter):\(number) (из \(chapter.number):\(verse.number))")
                }
            }
        }
    }
    print("  проверено адресов \(checked), не нашлось \(missing)")
    for line in examples { print("    \(line)") }

    // Для сравнения: сколько промахов даёт тот же прогон без пересчёта.
    var raw = 0
    for chapter in sourceChapters {
        for verse in chapter.verses {
            guard let landed = targetChapters.first(where: { $0.number == chapter.number }),
                  landed.verse(verse.number) != nil else { raw += 1; continue }
        }
    }
    print("  без пересчёта промахов было бы \(raw)")
    if missing >= raw {
        print("  пересчёт НЕ помогает — правила приложены неверно")
        problems += 1
    }

    print(problems == 0 ? "\nвсё сошлось" : "\nрасхождений: \(problems)")
    return problems == 0 ? 0 : 1
}

private func key(_ rule: NumberingRule) -> String {
    [rule.from, rule.to, rule.kind.rawValue, "\(rule.book)", "\(rule.chapterBegin)",
     text(rule.chapterEnd), text(rule.verseBegin), text(rule.verseEnd),
     text(rule.chapterTo), text(rule.chapterToEnd), text(rule.verseTo), text(rule.verseToEnd)]
        .joined(separator: "|")
}

private func text(_ value: Int?) -> String { value.map { "\($0)" } ?? "" }
