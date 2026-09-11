import AppKit
import SlovoCore

/// Власник: «усе за умовчанням українською, включно зі службовими
/// повідомленнями; російська — лише в розмові з асистентом», а раніше —
/// «повний переклад у всі локалізації».
///
/// Три перевірки. Українська: кожен наш напис, відомий будь-якому словнику,
/// має український переклад — інакше при українському інтерфейсі на екрані
/// лишається російська. Покриття: кожна мова, для якої є наш словник
/// (`Resources/OurWords/<код>.json`), перекладена цілком; мови автора без
/// нашого словника лише перелічуються. «Каша»: перемикаємо інтерфейс на
/// англійську, обходимо вікна й шукаємо кирилицю — її не має лишитися
/// (назви модулів, книг і шаблонів, шляхи з кирилицею — дані, вони не в
/// рахунок).
extension Diagnostics {

    static func translationsSection(state: AppState) -> [Check] {
        let area = "Мова"
        var checks: [Check] = []

        // 1. Українська — мова програми за умовчанням.
        let allKeys = OurWords.russianKeys
        let withoutUk = allKeys.filter { OurWords.builtIn($0, language: "uk") == nil }.sorted()
        checks.append(Check(area: area, name: "Усі наші написи мають український переклад",
                            status: withoutUk.isEmpty ? .ok : .failed,
                            detail: withoutUk.isEmpty
                                ? "написів \(allKeys.count), українською всі"
                                : "без перекладу \(withoutUk.count): "
                                    + withoutUk.prefix(8).map { "«\($0.prefix(50))»" }.joined(separator: ", ")))

        // 2. Покриття мов, для яких є наш словник.
        let catalog = (state.languageCatalog?.languages.map { $0.code.lowercased() } ?? []).filter { $0 != "ru" && $0 != "uk" }
        let withDictionary = Set(OurWords.coverage.keys).subtracting(["uk", "ru"])
        var lines: [String] = []
        var thin: [String] = []
        for code in withDictionary.sorted() {
            let covered = OurWords.covered(in: code)
            let percent = covered.total == 0 ? 0 : covered.translated * 100 / covered.total
            lines.append("\(code) \(percent) %")
            if percent < 100 {
                thin.append("\(code): не перекладено \(covered.missing.count), наприклад «\(covered.missing.first.map { String($0.prefix(40)) } ?? "")»")
            }
        }
        let withoutDictionary = catalog.filter { !withDictionary.contains($0) }.sorted()
        checks.append(Check(area: area, name: "Наші написи перекладено на мови зі словником",
                            status: thin.isEmpty ? .ok : .failed,
                            detail: (thin.isEmpty ? "" : thin.joined(separator: "; ") + ". ")
                                + (lines.isEmpty ? "словників інших мов немає" : lines.joined(separator: ", "))
                                + (withoutDictionary.isEmpty ? "" : "; без нашого словника (інтерфейс автора + українська для наших написів): " + withoutDictionary.joined(separator: ", "))))

        // 3. Англійський інтерфейс без кирилиці.
        guard let wasCode = state.language?.code, state.languageCatalog?.language(code: "en") != nil else {
            checks.append(Check(area: area, name: "Англійський інтерфейс без кирилиці", status: .skipped, detail: "у каталозі немає англійської"))
            return checks
        }
        /// Пункти підменю будуються при відкритті меню (`menuNeedsUpdate`);
        /// без відкриття вони лишаються такими, як при старті. Робимо те, що
        /// зробив би сам показ меню.
        func rebuildSubmenus() {
            for item in NSApp.mainMenu?.items ?? [] {
                guard let submenu = item.submenu else { continue }
                submenu.delegate?.menuNeedsUpdate?(submenu)
            }
        }
        state.setLanguage(code: "en")
        // Підписи перемальовуються не в ту ж мить: віджети дізнаються про
        // зміну мови через міст стану наступним обертом циклу подій.
        wait(untilTrue: { false }, seconds: 0.6)
        rebuildSubmenus()
        defer {
            state.setLanguage(code: wasCode)
            wait(untilTrue: { false }, seconds: 0.6)
            rebuildSubmenus()
        }
        var data: Set<String> = []
        for module in state.allModules {
            data.insert(module.info.name); data.insert(module.info.shortName); data.insert(module.displayName)
            // Редактор нумерації показує книги будь-якого перекладу, не лише
            // основного — назви книг усіх модулів теж дані.
            for book in module.books { data.insert(book.fullName); for short in book.shortNames { data.insert(short) } }
        }
        for book in state.books { data.insert(book.fullName); for short in book.shortNames { data.insert(short) } }
        // Назви модулів із бази нумерації та ім'я застосунку пульта.
        for name in state.numbering.modules.keys { data.insert(name) }
        data.insert("Пульт Слова")
        for language in state.languageCatalog?.languages ?? [] { data.insert(language.displayName) }
        for scheme in state.schemes?.templates ?? [] { data.insert(scheme.name) }
        for preset in state.presets.presets { data.insert(preset.name) }
        data.insert(state.media.title)
        data.insert("Слово")
        data.remove("")
        let cyrillic = CharacterSet(charactersIn: "абвгдеёжзийклмнопрстуфхцчшщъыьэюяіїєґАБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯІЇЄҐ")
        /// Що лишається від рядка, коли з нього прибрати дані: назви модулів
        /// і книг, ім'я програми, шляхи (у теки на цьому диску кирилиця в
        /// іменах — «Слово», «Робочий стіл»).
        // Довші лексеми — першими: коротке скорочення («Са», «1») інакше
        // вирізало б шматок із середини повної назви, і назва вже не збігалася
        // б. Лексеми коротші за три знаки не чіпаємо зовсім.
        let tokens = data.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
        func stripped(_ text: String) -> String {
            if data.contains(text) { return "" }
            var rest = text
            for token in tokens where rest.contains(token) { rest = rest.replacingOccurrences(of: token, with: " ") }
            let words = rest.split(whereSeparator: { $0 == " " || $0 == "\n" })
                .filter { !$0.contains("/") && !$0.hasSuffix(".app") }
            return words.joined(separator: " ")
        }
        var leftovers: [String: String] = [:]
        let fileKinds: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "heic", "webp", "mp4", "mov", "mp3",
                                      "m4a", "pdf", "pptx", "ppt", "key", "vbm", "sch", "html", "json", "ini", "sqlite3"]
        for (place, text) in interfaceStrings(state: state) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 1, trimmed.rangeOfCharacter(from: cyrillic) != nil else { continue }
            // Ім'я файла з кирилицею — дані, а не підпис.
            if fileKinds.contains((trimmed as NSString).pathExtension.lowercased()) { continue }
            guard stripped(trimmed).rangeOfCharacter(from: cyrillic) != nil else { continue }
            if leftovers[trimmed] == nil { leftovers[trimmed] = place }
        }
        let shown = leftovers.sorted { $0.key < $1.key }.prefix(100).map { "«\($0.key.prefix(60))» (\($0.value))" }.joined(separator: "; ")
        checks.append(Check(area: area, name: "Англійський інтерфейс без кирилиці",
                            status: leftovers.isEmpty ? .ok : .failed,
                            detail: leftovers.isEmpty
                                ? "кирилиці у вікнах немає (даних-винятків \(data.count), модулів \(state.allModules.count))"
                                : "лишилося \(leftovers.count): " + shown))
        return checks
    }
}
