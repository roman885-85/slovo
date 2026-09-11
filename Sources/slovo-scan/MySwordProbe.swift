import Foundation
import SlovoCore

/// Разбор одного настоящего модуля MySword, названного по имени файла.
///
/// Читатель формата написан по описанию: живого модуля на машине не было ни
/// у кого, и образец для проверок мы собирали сами по тому же описанию —
/// то есть проверяли себя собственной догадкой. Эта команда для того и
/// нужна: положить рядом скачанный `*.bbl.mybible` и увидеть, сходится ли
/// описание с действительностью, не запуская всю программу.
func runMySwordProbe(args: [String]) -> Int32 {
    guard let at = args.firstIndex(of: "--mysword"), args.count > at + 1 else {
        print("использование: slovo-scan <папка Modules> --mysword <файл .bbl.mybible>")
        return 2
    }
    let url = URL(fileURLWithPath: args[at + 1])
    print("файл: \(url.path)")

    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    print("размер: \(size.map { "\($0) байт" } ?? "не прочитан")")

    // Сначала — устройство базы, как она есть, без наших ожиданий: если
    // описание формата разойдётся с настоящим модулем, это будет видно
    // здесь, а не в загадочном отказе читателя.
    print("\n── таблицы и колонки, как в файле ──")
    dumpSchema(url)

    print("\n── что увидел наш читатель ──")
    let module: MySwordModule
    do {
        module = try MySwordModule(fileAt: url)
    } catch {
        print("  ОТКАЗ: \(error)")
        print("\n  Если файл — настоящий модуль Библии MySword, значит описание формата")
        print("  разошлось с действительностью. Пришлите вывод раздела «таблицы и колонки».")
        return 1
    }

    print("  название: \(module.info.name)")
    print("  сокращение: \(module.info.shortName)")
    print("  книг: \(module.books.count)")

    var chapters = 0, verses = 0, empty = 0
    var withMarkup: [String] = []
    for book in module.books {
        guard let list = try? module.chapters(ofBook: book) else { continue }
        chapters += list.count
        for chapter in list {
            for verse in chapter.verses {
                verses += 1
                if verse.text.isEmpty { empty += 1 }
                // Уцелевшая разметка — первый признак, что очистка не знает
                // какого-то тега этого модуля.
                if withMarkup.count < 6, verse.text.contains("<"), verse.text.contains(">") {
                    withMarkup.append("\(book.fullName) \(chapter.number):\(verse.number) — \(verse.text.prefix(90))")
                }
            }
        }
    }
    print("  глав: \(chapters), стихов: \(verses), пустых стихов: \(empty)")

    let canonical = module.books.filter { $0.canonicalNumber != nil }.count
    print("  книг опознано по канону: \(canonical) из \(module.books.count)")

    // Номера Стронга, оставшиеся голыми числами в тексте, — верный признак
    // выпрямленного подстрочника: «that they 2532 having come 3854 to 4314».
    var bareStrongs = 0
    // Пробел перед точкой или запятой в обычном переводе не встречается вовсе.
    // Зато он неизбежен там, где слова разносили по отдельности ради номеров
    // Стронга, а потом номера срезали вместе с соседним знаком.
    var loosePunctuation = 0
    for book in module.books.prefix(6) {
        guard let list = try? module.chapters(ofBook: book) else { continue }
        for chapter in list.prefix(3) {
            for verse in chapter.verses {
                if verse.text.range(of: "[a-zA-Zа-яА-Я] [0-9]{3,4} [a-zA-Zа-яА-Я]",
                                    options: .regularExpression) != nil {
                    bareStrongs += 1
                }
                if verse.text.contains(" .") || verse.text.contains(" ,") {
                    loosePunctuation += 1
                }
            }
        }
    }

    var missingAnchors = 0
    print("\n── опорные места (смотрите глазами, тот ли это текст) ──")
    for (number, chapter, verse, name) in [(10, 1, 1, "Бытие 1:1"),
                                           (230, 23, 1, "Псалом 23:1 — о Пастыре, счёт KJV"),
                                           (500, 3, 16, "Иоанна 3:16"),
                                           (470, 5, 3, "Матфея 5:3")] {
        guard let book = module.books.first(where: { $0.canonicalNumber == number }) else {
            missingAnchors += 1
            print("  \(name): книги нет в модуле"); continue
        }
        guard let text = (try? module.chapter(chapter, ofBook: book))??.verse(verse)?.text else {
            missingAnchors += 1
            print("  \(name): — нет такого стиха —"); continue
        }
        print("  \(name): \(text.prefix(100))")
    }

    // Годен ли модуль вообще. Формат может быть безупречным, а содержимое —
    // мусором: попадаются «переводы», собранные из подстрочника, где номера
    // Стронга рассыпаны прямо в тексте, а главы и стихи пронумерованы наугад.
    // Читателю такое отвергать нельзя (неполный модуль — законное дело), но
    // человек должен увидеть это ДО того, как поставит его в полосу переводов.
    var doubts: [String] = []
    if verses < 20_000 {
        doubts.append("стихов всего \(verses) — в полной Библии их 31 102; это неполный модуль")
    }
    if missingAnchors > 0 {
        doubts.append("не нашлось опорных мест: \(missingAnchors) из 4 — нумерация глав и стихов не похожа на обычную")
    }
    if loosePunctuation > 4 {
        doubts.append("пробел перед точкой или запятой (встретилось \(loosePunctuation) раз) — след того, что слова разделяли для номеров Стронга, а потом теги срезали вместе с буквами; проверьте текст глазами")
    }
    if bareStrongs > 0 {
        doubts.append("номера Стронга рассыпаны прямо в тексте (встретилось \(bareStrongs) раз) — это выпрямленный подстрочник, для показа он не годится")
    }
    if doubts.isEmpty {
        print("\n── модуль выглядит годным ──")
    } else {
        print("\n── ВНИМАНИЕ: модуль выглядит негодным для показа ──")
        for line in doubts { print("  • " + line) }
    }

    if withMarkup.isEmpty {
        print("\n── разметка: не осталось ни одного стиха с угловыми скобками ──")
    } else {
        print("\n── ВНИМАНИЕ: разметка уцелела, очистка знает не все теги ──")
        for line in withMarkup { print("  " + line) }
    }

    // Папку выбирает `AppState.guessModulesFolder()`: первая существующая из
    // трёх. У собранной программы это её собственная папка внутри пакета,
    // и она побеждает всегда — значит и модуль надо класть туда. Совет
    // «положите в Application Support» был бы неверным: для собранной
    // программы та папка не смотрится вовсе, а для запуска из исходников она
    // библиотеку не дополняет, а ЗАМЕНЯЕТ — с одним модулем вместо всех.
    print("\nЧтобы модуль появился в самой программе, положите его сюда:")
    print("  ~/Desktop/Слово/Слово.app/Contents/Resources/app/Modules/")
    print("и перезапустите «Слово» — он встанет в полосу переводов сам.")
    return 0
}

/// Устройство базы своими глазами: имена таблиц и колонок как есть.
private func dumpSchema(_ url: URL) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    task.arguments = [url.path, ".schema"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { print("  sqlite3 не запустился: \(error)"); return }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    for line in text.split(separator: "\n").prefix(24) { print("  " + line) }
}
