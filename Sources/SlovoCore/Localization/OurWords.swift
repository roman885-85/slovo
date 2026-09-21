import Foundation

/// Переклад наших власних написів.
///
/// Написи, що є в автора, беруться з його файлів перекладу (`state.text`).
/// Але половина вікон у цій програмі — наші: майстерня веб-слайдів,
/// Конструктор, вікно налаштувань. Їхні написи ми придумали самі, і в автора їх
/// немає — тому при українській мові вони лишалися російськими.
///
/// Словник побудовано від російського рядка: так його видно просто в коді, і
/// додати переклад можна, не заводячи ключів і не переписуючи місць виклику.
/// Чого в словнику немає — лишається як є: пропущений рядок не має
/// перетворюватися на порожнє місце на екрані.
public enum OurWords {

    /// Мова, якою говорити. Ставиться раз при виборі мови.
    public nonisolated(unsafe) static var language = "ru"

    public static func t(_ russian: String) -> String {
        // Правка людини з вікна «Переклад інтерфейсу» — насамперед:
        // інакше вікно обіцяло б переклад, якого на екрані не видно.
        if let own = overrides[russian], !own.isEmpty { return own }
        guard language != "ru" else { return russian }
        guard let table = tables[language] else { return russian }
        return table[russian] ?? russian
    }

    // MARK: - Правки з вікна «Переклад інтерфейсу»

    /// Секція файла `.lng`, у якій лежать переклади НАШИХ написів.
    ///
    /// Автор перекладав свої форми, і вікно 7.1 знало лише їх. Наші вікна —
    /// Конструктор, веб-редактор, «Параметри», пульт — лишалися тією
    /// мовою, що зашита в словник, і перекладач не міг їх торкнутися: саме про
    /// це «переклад інтерфейсу не працює повноцінно». Тепер наші написи
    /// йдуть у файл перекладу окремою секцією: ключ — російський рядок із коду,
    /// значення — його переклад.
    public static let sectionName = "Slovo"

    /// Що людина переклала сама для поточної мови. Міняється лише з
    /// головного потоку при зміні мови або після збереження перекладу.
    public nonisolated(unsafe) private(set) static var overrides: [String: String] = [:]

    /// Застосувати правки людини для вибраної мови (секція `[Slovo]`).
    public static func applyOverrides(_ table: [String: String]) {
        overrides = table.filter { !$0.value.isEmpty }
    }

    /// Вбудований переклад рядка для мови — без правок людини. Вікну
    /// перекладу: показати, що стоїть зараз, якщо людина ще нічого не міняла.
    public static func builtIn(_ russian: String, language code: String) -> String? {
        guard code != "ru" else { return russian }
        return tables[code]?[russian]
    }

    /// Усі наші рядки, відомі словнику, — список для вікна перекладу.
    /// Російський рядок служить і ключем, і «оригіналом».
    public static var russianKeys: [String] {
        var keys = Set(ukrainianPairs.map(\.0))
        for table in tables.values { keys.formUnion(table.keys) }
        return keys.sorted()
    }

    /// Переклад рядка, всередину якого підставляють значення.
    ///
    /// Словник побудовано від російського рядка цілком, і рядок, зібраний на
    /// ходу («Збережено: rst+.html», «призначено 5 із 56»), у ньому не знайдеться
    /// ніколи: ключ у нього щоразу новий. Тому перекладається ЗРАЗОК, а
    /// значення підставляються після перекладу.
    ///
    /// Місце підстановки позначено `%s` — так само, як у файлах перекладу самого
    /// прежняя программа («Действительно удалить Web страницу %s?»): у перекладача
    /// перед очима буде звична позначка, а не наша вигадка.
    ///
    /// Значень може бути менше, ніж позначок, і навпаки: зайве просто не
    /// підставиться. Ронити програму через описку в словнику не можна — це
    /// напис на екрані, а не розрахунок.
    public static func t(_ pattern: String, _ values: String...) -> String {
        var text = t(pattern)
        for value in values {
            guard let place = text.range(of: "%s") else { break }
            text.replaceSubrange(place, with: value)
        }
        return text
    }

    /// Словники за кодом мови. Українська зашита в код; решта приїжджають
    /// файлами `Resources/OurWords/<код>.json` при старті (`register`) —
    /// файли править перекладач без пересборки, і компіляцію вони не тягнуть.
    nonisolated(unsafe) private static var tables: [String: [String: String]] = ["uk": ukrainian]

    /// Підключити словник мови. Пари мови, що вже були, лишаються; нові
    /// лягають поверх. Порожній переклад не вважається перекладом.
    public static func register(_ table: [String: String], for code: String) {
        var merged = tables[code] ?? [:]
        for (key, value) in table where !value.isEmpty { merged[key] = value }
        tables[code] = merged
    }

    /// Мови словника й число рядків у кожній — перевірці покриття.
    public static var coverage: [String: Int] { tables.mapValues(\.count) }

    /// Скільки ключів українського словника перекладено на мову `code`.
    public static func covered(in code: String) -> (translated: Int, total: Int, missing: [String]) {
        let base = Set(ukrainianPairs.map(\.0))
        let table = tables[code] ?? [:]
        let missing = base.filter { table[$0] == nil }.sorted()
        return (base.count - missing.count, base.count, missing)
    }

    /// Слова, записані в словник двічі.
    ///
    /// Повтор більше не ронить програму, але лишається опискою: другий
    /// переклад того самого слова мовчки пропадає, і людина не розуміє,
    /// чому її правки не видно. Самоперевірка про них скаже.
    public static var duplicateWords: [String] {
        var seen: Set<String> = []
        var twice: [String] = []
        for (key, _) in ukrainianPairs where !seen.insert(key).inserted { twice.append(key) }
        return twice
    }
    /// Чи є такий рядок серед РОСІЙСЬКИХ ключів перекладу: якщо він видимий на
    /// екрані при українській мові — переклад не застосувався.
    public static func hasRussianKey(_ text: String) -> Bool {
        guard language == "uk" else { return false }
        guard let table = tables[language], let translated = table[text] else { return false }
        return translated != text
    }

}
