import Foundation
import SlovoCore

// Проверочный прогон парсера по настоящим модулям: сверяет число разобранных
// глав с тем, что модуль сам о себе объявил в ChapterQty.

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("использование: slovo-scan <папка Modules> [--full] [--show <модуль>]")
    exit(2)
}

// Пісенники старої програми у теці модулів → свій .songbook (оригінали — в
// «Імпорт зі старої програми» поруч). Кличе deploy.sh до підпису пакета, щоб
// програмі не доводилося писати в підписаний пакет на першому запуску.
if arguments[1] == "--songbooks", arguments.count >= 3 {
    let modules = URL(fileURLWithPath: arguments[2])
    var report = DataHome.Report(source: modules.path)
    DataHome.convertSongBooks(in: modules,
                              archive: modules.deletingLastPathComponent().appendingPathComponent(DataHome.importArchiveName),
                              report: &report)
    print(report.summary)
    exit(report.errors.isEmpty ? 0 : 1)
}

// Ресурси для GitHub: zip-и та catalog.json з теки даних програми.
if arguments[1] == "--catalog", arguments.count >= 5 {
    exit(runCatalogPack(app: URL(fileURLWithPath: arguments[2]),
                        out: URL(fileURLWithPath: arguments[3]), base: arguments[4]))
}

let modulesURL = URL(fileURLWithPath: arguments[1])
let full = arguments.contains("--full")
let showIndex = arguments.firstIndex(of: "--show").map { $0 + 1 }
let showModule = showIndex.flatMap { $0 < arguments.count ? arguments[$0] : nil }

// Модуль «Текст» (5.2) папку с модулями не читает: проверять там нечего,
// кроме собственных настроек из VisioBible.ini.
if arguments.contains("--text") {
    exit(runTextModuleCheck())
}

// Разделы 5.1.5–5.1.11: сокращения книг, быстрый выбор места, поиск и План.
if arguments.contains("--desk") {
    exit(runDeskCheck(modulesURL: modulesURL))
}

// Несоответствия нумерации переводов (пункт меню N40, база inconsistencies.sqlite3).
if arguments.contains("--songbench") {
    exit(runSongBench(modulesURL: modulesURL))
}

// Обновить наши блоки в странице веб-слайда: привязку и живые настройки.
// Тем же занимается мастерская при открытии страницы; отдельная команда нужна
// затем, чтобы чинить страницы пачкой и проверять правки из терминала.
if let index = arguments.firstIndex(of: "--reequip"), index + 1 < arguments.count {
    let file = URL(fileURLWithPath: arguments[index + 1])
    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
        print("не прочитать: \(file.path)"); exit(1)
    }
    // Значения снимаем со страницы заново, а не берём из блока: блок мог
    // написать прежний выпуск, мерявший чужую страницу плохо. Меряем по
    // странице без наших блоков — то есть по ней самой.
    let bare = WebSlideParameters.stripBlocks(html: text)
    // Меряем страницу так же, как мастерская: браузером. Разбор листа стилей
    // остаётся запасным путём — он не видит ни наследования, ни настоящего
    // места текста на экране.
    var answer: WebSlideSettings?
    var ready = false
    MainActor.assumeIsolated {
        WebSlideProbe.computedSettings(html: bare, folder: file.deletingLastPathComponent()) { measured in
            answer = measured
            ready = true
        }
    }
    let deadline = Date().addingTimeInterval(12)
    while !ready && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    var settings = answer ?? WebSlideParameters.inferred(from: bare)
    if answer == nil { print("  (браузер не ответил — мерили по листу стилей)") }
    let explicit = WebSlideParameters.declared(in: bare)
    for name in explicit.names { if let value = explicit[name] { settings.set(name, value) } }
    switch WebSlideParameters.write(html: text, settings: settings.applyingDefaults()) {
    case .written(let updated):
        try? updated.write(to: file, atomically: true, encoding: .utf8)
        print("обновлено: \(file.lastPathComponent)")
        exit(0)
    case .refused(let reason):
        print("отказ: \(reason)"); exit(1)
    }
}

if arguments.contains("--mysword") {
    exit(runMySwordProbe(args: arguments))
}

if arguments.contains("--verse") {
    exit(runShowVerse(modulesURL: modulesURL, args: arguments))
}

// Разборщик презентаций: вид слайда проверяется глазами, поэтому утилита
// пишет каждый слайд картинкой.
if arguments.contains("--pptx") {
    exit(runPresentationCheck(args: arguments))
}

if arguments.contains("--numbering") {
    exit(runNumberingCheck(modulesURL: modulesURL))
}

if arguments.contains("--canon") {
    let library = ModuleLibrary(modulesDirectory: modulesURL)
    print("модулей: \(library.modules.count)")
    var unresolved = 0
    for module in library.modules {
        let known = module.books.filter { $0.canonicalNumber != nil }.count
        if known < module.books.count { unresolved += 1 }
        print(String(format: "  %-24s книг %3d, опознано %3d  [%@]",
                     (module.identifier as NSString).utf8String!,
                     module.books.count, known, module.format.title))
    }
    print("\nмодулей с неопознанными книгами: \(unresolved)")

    // Главная проверка: одна и та же книга в модулях разной длины.
    print("\nсверка «Бытие 1:1» по переводам разной длины:")
    for id in ["rst+", "RU_RST", "UA_Homenko", "UA_Turkonyak", "KJV", "ubt2020"] {
        guard let module = library.module(withIdentifier: id),
              let genesis = module.books.first(where: { $0.canonicalNumber == 10 }) else {
            print("  \(id): книга не найдена")
            continue
        }
        let verse = (try? module.chapter(1, ofBook: genesis))??.verses.first?.text ?? "—"
        print(String(format: "  %-14s книг %3d, индекс %2d, «%@» → %@",
                     (id as NSString).utf8String!, module.books.count, genesis.index,
                     genesis.fullName, String(verse.prefix(52))))
    }
    exit(0)
}

if arguments.contains("--songwrite") {
    // Круговой прогон: читаем настоящий песенник, записываем своим кодом,
    // читаем обратно и сверяем каждое поле. Если формат записан неверно,
    // расхождение вылезет здесь, а не на служении.
    let files = ModuleLibrary(modulesDirectory: modulesURL).songFiles
    var checked = 0, broken = 0
    for url in files {
        guard let original = try? SongBook(fileAt: url) else { continue }
        do {
            let data = try SongBookWriter.data(for: original)
            let again = try SongBook(data: data, name: url.lastPathComponent)

            var problems: [String] = []
            if again.title != original.title { problems.append("название") }
            if again.shortName != original.shortName { problems.append("краткое имя") }
            if again.songs.count != original.songs.count {
                problems.append("песен \(again.songs.count) вместо \(original.songs.count)")
            } else {
                for (a, b) in zip(original.songs, again.songs) {
                    if a.title != b.title { problems.append("название песни \(a.index)"); break }
                    if a.parts.count != b.parts.count { problems.append("частей песни \(a.index)"); break }
                    if a.parts.map(\.text) != b.parts.map(\.text) { problems.append("текст песни \(a.index)"); break }
                }
            }
            checked += 1
            if !problems.isEmpty {
                broken += 1
                print("  ✗ \(url.lastPathComponent): \(problems.joined(separator: ", "))")
            }
        } catch {
            broken += 1
            print("  ✗ \(url.lastPathComponent): \(error)")
        }
    }
    print("круговой прогон: сверено \(checked), с расхождениями \(broken)")
    exit(broken == 0 ? 0 : 1)
}

if arguments.contains("--songs") {
    var totalSongs = 0, totalParts = 0, books = 0
    for url in ModuleLibrary(modulesDirectory: modulesURL).songFiles {
        do {
            let book = try SongBook(fileAt: url)
            books += 1
            totalSongs += book.songs.count
            let parts = book.songs.reduce(0) { $0 + $1.parts.count }
            totalParts += parts
            print(String(format: "  %-30s песен %5d  частей %6d  «%@»",
                         (url.lastPathComponent as NSString).utf8String!,
                         book.songs.count, parts, book.title))
        } catch {
            print("  ✗ \(url.lastPathComponent): \(error)")
        }
    }
    print("\nпесенников \(books), песен \(totalSongs), частей \(totalParts)")

    if let first = try? SongBook(fileAt: ModuleLibrary(modulesDirectory: modulesURL).songFiles.first!),
       let song = first.songs.first {
        print("\nпример — «\(song.title)»\(song.subtitle.map { ", \($0)" } ?? "")")
        for part in song.parts.prefix(2) {
            print("  [\(part.kind)] \(part.lines.prefix(2).joined(separator: " / "))")
        }
    }
    exit(0)
}

if arguments.contains("--lang") {
    let folder = modulesURL.deletingLastPathComponent().appendingPathComponent("Language")
    let catalog = LanguageCatalog(directory: folder)
    print("переводов интерфейса: \(catalog.languages.count)")
    print(catalog.languages.map { "\($0.code)=\($0.displayName)" }.joined(separator: ", "))

    guard let ru = catalog.language(code: "ru") else { exit(1) }
    print("\nформ в ru.lng: \(ru.forms.count), строк: \(ru.forms.values.reduce(0) { $0 + $1.count })")
    print("\nпункты главного меню:")
    for key in ["N1", "N18", "N13", "N39", "N14", "N4"] {
        print("  \(key) = \(ru.caption(key, form: "MainForm"))")
    }
    print("\nдействия:")
    for key in ["N24", "N25", "N35", "N34", "N30", "N28", "N20", "N29", "N21"] {
        let entry = ru.entry(key, form: "MainForm")
        print("  \(key) = \(entry?.caption ?? "—")\(entry?.hint.map { " — \($0)" } ?? "")")
    }
    exit(0)
}

if arguments.contains("--config") {
    guard let url = IniSettings.locateConfig(),
          let config = try? IniSettings(fileAt: url) else {
        print("файл налаштувань Slovo.ini не знайдено")
        exit(1)
    }
    print("конфиг: \(url.path)")
    print("секций: \(config.sections.count), ключей: \(config.sections.values.reduce(0) { $0 + $1.count })")

    let style = SlideStyle(config: config, section: "Bible", dataRoot: modulesURL.deletingLastPathComponent())
    print("\nстиль из [Bible] — схема «\(style.name)»")
    print("  шрифт цитаты: \(style.main.fontName) жирный=\(style.main.isBold)")
    print("  шрифт адреса: \(style.reference.fontName) курсив=\(style.reference.isItalic)")
    print(String(format: "  цвет текста:  R%.2f G%.2f B%.2f", style.main.color.red, style.main.color.green, style.main.color.blue))
    print(String(format: "  цвет адреса:  R%.2f G%.2f B%.2f", style.reference.color.red, style.reference.color.green, style.reference.color.blue))
    print(String(format: "  цвет контура: R%.2f G%.2f B%.2f, толщина %.5f высоты",
                 style.main.outlineColor.red, style.main.outlineColor.green, style.main.outlineColor.blue, style.main.outlineWidth))
    print(String(format: "  тень: радиус %.5f высоты", style.main.shadowRadius))
    print("  переход: \(style.transition.title), \(Int(style.transitionDuration * 1000)) мс")
    print("  фон: \(style.backgroundImagePath ?? "— не найден —")")

    let output = OutputSettings(config: config)
    print("\nвывод: монитор №\(output.monitorIndex), слайд \(output.slideWidth)×\(output.slideHeight), "
          + "номера стихов основной=\(output.showVerseNumbers) второй=\(output.showSecondaryVerseNumbers)")

    let order = config.moduleOrder()
    print("\nпорядок модулей (\(order.count)): \(order.prefix(12).joined(separator: ", "))…")
    exit(0)
}

// Конструктор слайда (раздел 6.3): проверка на настоящих шаблонах автора.
// Смотрим, что из каждого `.sch` собирается преднастройка, что второй набор
// параметров `_2` действительно отличается от первого, что тень и выключка
// по вертикали доехали, и что всё это переживает запись в файл и чтение
// обратно, — иначе правки в конструкторе терялись бы при сохранении.
if arguments.contains("--constructor") {
    // `String(format:)` не умеет выравнивать `%@` по ширине — дополняем сами.
    func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    let dataRoot = modulesURL.deletingLastPathComponent()
    let config = IniSettings.locateConfig().flatMap { try? IniSettings(fileAt: $0) }
    let schemes = SchemeLibrary(dataRoot: dataRoot, config: config)
    let base = config.map { SlideStyle(config: $0, section: "Bible", dataRoot: dataRoot) } ?? SlideStyle()

    print("шаблонов: \(schemes.templates.count), не прочитано: \(schemes.failures.count)")
    for (file, reason) in schemes.failures { print("  ✗ \(file): \(reason)") }

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    var totalObjects = 0, withSecondScene = 0, withShadow = 0, missingImages = 0
    var roundTripFailures = 0, sceneDifferences = 0

    for template in schemes.templates {
        let preset = SlidePreset(template: template, base: base, designHeight: schemes.designHeight)
        totalObjects += preset.objects.count

        for object in preset.objects {
            let single = object.variant(withSecondTranslation: false)
            let dual = object.variant(withSecondTranslation: true)
            if object.secondVariant != nil { withSecondScene += 1 }
            if single != dual { sceneDifferences += 1 }
            if single.shadow.isVisible || dual.shadow.isVisible { withShadow += 1 }
            if object.kind == .image, object.imagePath == nil { missingImages += 1 }
        }

        // Круговой прогон: то, что сохранит конструктор, должно читаться
        // обратно без потерь. Сравниваем целиком, а не по полям.
        guard let data = try? encoder.encode(preset),
              let restored = try? decoder.decode(SlidePreset.self, from: data),
              restored == preset else {
            roundTripFailures += 1
            print("  ✗ \(template.name): преднастройка не пережила запись и чтение")
            continue
        }

        let thumbs = [template.thumbnailURL(.single), template.thumbnailURL(.dual)]
            .filter { $0 != nil }.count
        let own = preset.objects.filter { $0.secondVariant != nil }.count
        print("  " + pad(template.name, 18)
              + "объектов " + pad("\(preset.objects.count)", 4)
              + "со своей сценой 2: " + pad("\(own)", 4)
              + "миниатюр \(thumbs), фон: "
              + (template.backgroundURL?.lastPathComponent ?? "— нет —"))
    }

    print("\nвсего объектов: \(totalObjects)")
    print("со своим набором для сцены 2: \(withSecondScene), из них реально другие: \(sceneDifferences)")
    print("с тенью: \(withShadow)")
    print("картинок без найденного файла: \(missingImages)")
    print("не пережили запись и чтение: \(roundTripFailures)")

    // Подробно по SpringFade — тому шаблону, что снят на скриншоте
    // руководства: порядок списка, типы, разница между сценами.
    if let springFade = schemes.template(named: "SpringFade") {
        let preset = SlidePreset(template: springFade, base: base, designHeight: schemes.designHeight)
        print("\nSpringFade — «Объекты слайда» сверху вниз, как в окне оригинала:")
        for object in preset.objects.reversed() {
            let single = object.variant(withSecondTranslation: false)
            let dual = object.variant(withSecondTranslation: true)
            let shadow = single.shadow.isVisible
                ? String(format: "смещ %.1f%% размыт %.1f%%",
                         single.shadow.offsetPercent, single.shadow.blurPercent)
                : "нет"
            print("  " + pad(object.name, 11)
                  + pad(object.kind.title, 56)
                  + "сцена 2: " + (object.secondVariant != nil ? "Да " : "Нет")
                  + String(format: "  Ш %5.1f→%5.1f  В %5.1f→%5.1f  ",
                           single.frame.width * 100, dual.frame.width * 100,
                           single.frame.height * 100, dual.frame.height * 100)
                  + "выключка " + pad(single.verticalAlignment.rawValue, 7)
                  + "тень " + shadow)
        }
    }
    exit(roundTripFailures == 0 ? 0 : 1)
}

let started = Date()
let library = ModuleLibrary(modulesDirectory: modulesURL)

print("модулей Библии: \(library.modules.count), песенников .vbm: \(library.songFiles.count)")
for failure in library.failures {
    print("  ✗ \(failure.directory): \(failure.reason)")
}

if let showModule, let module = library.module(withIdentifier: showModule) {
    print("\n=== \(module.identifier) — \(module.displayName) ===")
    print("кодировка: \(module.info.encoding.map(String.init(describing:)) ?? "авто"), "
          + "маркеры: глава \(module.info.chapterSign) / стих \(module.info.verseSign), "
          + "Стронг: \(module.info.hasStrongNumbers ? "да" : "нет")")
    for book in module.books.prefix(3) {
        let chapters = (try? module.chapters(ofBook: book)) ?? []
        print("\n\(book.fullName) [\(book.buttonTitle)] — глав \(chapters.count)/\(book.chapterCount)")
        if let first = chapters.first {
            for verse in first.verses.prefix(3) {
                print("  \(first.number):\(verse.number)  \(verse.text.prefix(110))")
            }
        }
    }
    exit(0)
}

var totalBooks = 0
var totalChapters = 0
var totalVerses = 0
var mismatched: [String] = []
var empties: [String] = []

for module in library.modules {
    let books = full ? module.books : Array(module.books.prefix(3))
    var moduleChapters = 0
    var moduleVerses = 0

    for book in books {
        totalBooks += 1
        let chapters: [Chapter]
        do {
            chapters = try module.chapters(ofBook: book)
        } catch {
            empties.append("\(module.identifier)/\(book.fileName): \(error)")
            continue
        }
        moduleChapters += chapters.count
        moduleVerses += chapters.reduce(0) { $0 + $1.verses.count }

        if book.chapterCount > 0, chapters.count != book.chapterCount {
            mismatched.append("\(module.identifier)/\(book.fullName): разобрано \(chapters.count), объявлено \(book.chapterCount)")
        }
        if chapters.isEmpty || chapters.allSatisfy({ $0.verses.isEmpty }) {
            empties.append("\(module.identifier)/\(book.fullName): пусто")
        }
    }

    module.releaseCache()
    totalChapters += moduleChapters
    totalVerses += moduleVerses
    print(String(format: "  %-24s книг %3d  глав %5d  стихов %6d",
                 (module.identifier as NSString).utf8String!, books.count, moduleChapters, moduleVerses))
}

print("\nитого: книг \(totalBooks), глав \(totalChapters), стихов \(totalVerses), "
      + "за \(String(format: "%.1f", Date().timeIntervalSince(started))) с")

if !mismatched.isEmpty {
    print("\nрасхождения по числу глав (\(mismatched.count)):")
    for line in mismatched.prefix(40) { print("  ! \(line)") }
    if mismatched.count > 40 { print("  … и ещё \(mismatched.count - 40)") }
}
if !empties.isEmpty {
    print("\nпустые или нечитаемые (\(empties.count)):")
    for line in empties.prefix(40) { print("  ✗ \(line)") }
    if empties.count > 40 { print("  … и ещё \(empties.count - 40)") }
}
