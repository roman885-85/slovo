import Foundation
import SlovoCore

/// Проверка модуля «Текст» (раздел 5.2 руководства): очистка, приём стиха из
/// «Библии», разбивка длинного текста на слайды и пункт плана с текстом.
///
/// Почему не XCTest: полного Xcode на машине нет, только Command Line Tools,
/// и модуля `XCTest` в них не поставляется — `swift test` там не собирается
/// вовсе. Поэтому проверки живут в консольной цели, как и остальная
/// самопроверка разбора модулей.
///
/// Настройки берём настоящие — из `VisioBible.ini` пользователя. Ничего не
/// пишем: план сохраняется во временную папку и оттуда же удаляется.
func runTextModuleCheck() -> Int32 {
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

    // MARK: Кнопки работы с текстом (24)

    print("кнопки работы с текстом (24):")
    var document = PlainTextDocument(title: "Объявление", body: "После служения — общение.")
    check("до очистки документ не пуст", !document.isEmpty)
    document.clear()
    check("SBClearText чистит и текст (25), и заголовок (23)",
          document.title.isEmpty && document.body.isEmpty && document.isEmpty)
    check("пробелы и переводы строк за содержимое не считаются",
          PlainTextDocument(title: "  ", body: "\n\n \n").isEmpty)

    // MARK: Приём текста из «Библии» (MICopyToText)

    print("приём стиха из модуля «Библия» (MICopyToText):")
    var received = PlainTextDocument(title: "Старое", body: "Старый текст")
    received.receive(reference: "Ин 3:16", text: "Ибо так возлюбил Бог мир…")
    check("адрес уходит в заголовок, стих — в текст",
          received.title == "Ин 3:16" && received.body == "Ибо так возлюбил Бог мир…",
          "получилось «\(received.title)» / «\(received.body)»")

    var appended = PlainTextDocument()
    appended.receive(reference: "Ин 3:16", text: "Первый", mode: .append)
    appended.receive(reference: "Ин 3:17", text: "Второй", mode: .append)
    check("дописывание снизу сохраняет первый заголовок",
          appended.title == "Ин 3:16" && appended.body == "Первый\nВторой",
          "получилось «\(appended.title)» / «\(appended.body.replacingOccurrences(of: "\n", with: "⏎"))»")

    // MARK: Слайд собирается как библейский

    print("слайд (заголовок на месте адреса, текст на месте цитаты):")
    let short = PlainTextDocument.Pagination(charactersPerLine: 40, linesPerPage: 4,
                                             minimumFillPercent: 0)
    let one = PlainTextDocument(title: "Объявление", body: "Короткий текст").slides(short)
    check("один короткий текст — один слайд", one.count == 1, "слайдов \(one.count)")
    check("заголовок встал на место адреса", one.first?.reference == "Объявление")
    check("текст встал на место цитаты", one.first?.mainText == "Короткий текст")
    check("заголовок без текста — тоже слайд",
          PlainTextDocument(title: "Объявление").pageCount(short) == 1)
    check("пустой документ не даёт слайдов", PlainTextDocument().slides(short).isEmpty)
    check("номер страницы за краем прижимается к краю",
          PlainTextDocument(title: "Т", body: "текст").slide(atPage: 99, short).mainText == "текст")

    // MARK: Разбивка длинного текста на слайды

    print("разбивка длинного текста на слайды:")
    let long = (1...20).map { "строка номер \($0)" }.joined(separator: "\n")

    var noSplit = short
    noSplit.splitsIntoPages = false
    noSplit.splitsIntoParagraphs = false
    check("оба способа выключены — весь текст на одном слайде",
          PlainTextDocument(body: long).pageCount(noSplit) == 1,
          "страниц \(PlainTextDocument(body: long).pageCount(noSplit))")

    var perLine = short
    perLine.splitsIntoParagraphs = true
    check("«Разбивать на стихи» — слайд на строку",
          PlainTextDocument(body: "первая\n\nвторая\nтретья").pages(perLine)
            == ["первая", "вторая", "третья"])

    check("пустая строка — разрыв, поставленный вручную",
          PlainTextDocument(body: "первая\n\nвторая").pages(short) == ["первая", "вторая"])

    var narrow = short
    narrow.charactersPerLine = 10
    narrow.linesPerPage = 2
    let cut = PlainTextDocument(body: "раз два три четыре пять шесть семь восемь").pages(narrow)
    check("длинная строка режется по словам", cut.count > 1, "страниц \(cut.count)")
    check("ни одно слово не потеряно и не переставлено",
          cut.joined(separator: " ").split(separator: " ").map(String.init)
            == ["раз", "два", "три", "четыре", "пять", "шесть", "семь", "восемь"],
          cut.joined(separator: " | "))
    check("слово длиннее слайда рубится посередине",
          PlainTextDocument.chunks(of: String(repeating: "я", count: 25), budget: 10)
            .map(\.count) == [10, 10, 5])

    var tail = short
    tail.charactersPerLine = 10
    tail.linesPerPage = 4
    tail.blankLineBreaksPage = false
    let lines = (1...5).map { "строка \($0)" }.joined(separator: "\n")
    tail.minimumFillPercent = 0
    let split = PlainTextDocument(body: lines).pages(tail)
    tail.minimumFillPercent = 90
    let merged = PlainTextDocument(body: lines).pages(tail)
    check("короткий хвост уезжает на предыдущую страницу",
          split.count == 2 && merged.count == 1,
          "без порога \(split.count), с порогом \(merged.count)")

    check("перевод строки Windows даёт одну границу",
          PlainTextDocument.normalizedLines("первая\r\nвторая\r\n") == ["первая", "вторая"])

    var numbered = short
    numbered.showsPageNumber = true
    check("номер страницы по умолчанию выключен",
          PlainTextDocument(title: "О", body: "а\n\nб").slides(short).map(\.reference) == ["О", "О"])
    check("включённый номер страницы дописывается к заголовку",
          PlainTextDocument(title: "О", body: "а\n\nб").slides(numbered).map(\.reference)
            == ["О · 1/2", "О · 2/2"])

    // MARK: Настройки оригинала — секция [Text]

    print("настройки оригинала, секция [Text]:")
    if let url = IniSettings.locateConfig(),
       let config = try? IniSettings(fileAt: url) {
        print("  файл: \(url.path)")
        let text = PlainTextDocument.Pagination(config: config, section: "Text")
        let bible = PlainTextDocument.Pagination(config: config, section: "Bible")

        check("«Разбивать на стихи» у текста своё, не библейское",
              text.splitsIntoParagraphs != bible.splitsIntoParagraphs,
              "текст \(text.splitsIntoParagraphs), Библия \(bible.splitsIntoParagraphs)")
        check("«Разбивать на страницы» включено", text.splitsIntoPages)
        check("«Автоперенос слов» включён", text.wrapsWords)
        check("минимальный процент заполнения взят из [OutScreen]",
              text.minimumFillPercent == 30, "\(text.minimumFillPercent)")
        check("ёмкость страницы посчитана",
              text.charactersPerLine > 8 && text.linesPerPage > 1,
              "\(text.charactersPerLine) знаков × \(text.linesPerPage) строк")
        print("    ёмкость слайда: \(text.charactersPerLine) знаков в строке × "
              + "\(text.linesPerPage) строк = \(text.charactersPerLine * text.linesPerPage) знаков")

        // Живой пример: настоящее объявление на служении.
        let sample = PlainTextDocument(
            title: "Объявление",
            body: "Дорогие братья и сёстры! Сегодня после богослужения состоится "
                + "братское общение в малом зале. Приглашаются все желающие.")
        let sheets = sample.slides(text)
        print("    объявление из \(sample.body.count) знаков ляжет на \(sheets.count) слайд(ов):")
        for (number, slide) in sheets.enumerated() {
            print("      \(number + 1). «\(slide.mainText)»")
        }
        check("объявление не потеряло ни слова при разбивке",
              sheets.map(\.mainText).joined(separator: " ").split(separator: " ").map(String.init)
                == sample.body.split(separator: " ").map(String.init))

        let textStyle = SlideStyle(config: config, section: "Text", dataRoot: nil)
        let bibleStyle = SlideStyle(config: config, section: "Bible", dataRoot: nil)
        check("у режима «Текст» свой шаблон слайда",
              textStyle.name != bibleStyle.name,
              "текст «\(textStyle.name)», Библия «\(bibleStyle.name)»")
    } else {
        print("  — Slovo.ini не знайдено, перевірку пропущено")
    }

    // MARK: Пункт плана «Текст» (SBAddTextToPlan)

    print("пункт плана «Текст» (SBAddTextToPlan):")
    let announcement = PlainTextDocument(title: "Объявление", body: "Первая строка\nВторая строка")
    let item = PlanItem.text(announcement)
    check("тип пункта — «Текст»", item.kind == .text)
    check("пункт везёт содержимое с собой", item.plainText == announcement)
    check("подпись строки начинается с заголовка", item.title.hasPrefix("Объявление"), item.title)

    do {
        var plan = ServicePlan(title: "Служение", items: [
            PlanItem.scripture(moduleID: "RST",
                               book: BookInfo(index: 42, fileName: "43", fullName: "От Иоанна",
                                              shortNames: ["Ин"], chapterCount: 21),
                               chapter: 3, verses: [16]),
            item,
        ])
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("slovo-plan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try plan.save(to: url)
        let read = try ServicePlan.read(contentsOf: url)
        check("план с текстом сохраняется и читается",
              read.skippedItems == 0 && read.plan.count == 2,
              "пропущено \(read.skippedItems), пунктов \(read.plan.count)")
        check("текст пережил запись и чтение",
              read.plan[1]?.plainText == announcement)
        check("отрывок рядом с текстом не пострадал", read.plan[0]?.kind == .scripture)
    } catch {
        failures += 1
        print("  ✗ план с текстом не сохранился — \(error)")
    }

    do {
        // План, набранный руками без поля `type`, тоже должен читаться.
        let json = Data(#"{"heading":"Объявление","body":"Текст"}"#.utf8)
        let manual = try JSONDecoder().decode(PlanItem.self, from: json)
        check("пункт без поля type опознаётся по heading/body",
              manual.kind == .text && manual.plainText?.title == "Объявление")
    } catch {
        failures += 1
        print("  ✗ пункт без поля type не прочитался — \(error)")
    }

    print(failures == 0 ? "\nмодуль «Текст»: все проверки пройдены"
                        : "\nмодуль «Текст»: не пройдено проверок — \(failures)")
    return failures == 0 ? 0 : 1
}
