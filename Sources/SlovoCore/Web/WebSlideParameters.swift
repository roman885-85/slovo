import Foundation

/// Оформлення веб-слайда повзунками.
///
/// Текстового поля з розміткою мало: людина, яка ніколи не писала HTML,
/// не стане шукати в чужому файлі рядок `padding: 20px`. Тому оформлення
/// винесено в набір змінних CSS з людськими підписами — їх рухають
/// повзунками, а сторінка лишається сторінкою.
///
/// Будова одна на всі сторінки, і наші, і авторські. У файл дописуються
/// два блоки `<style>` перед `</head>` і більше нічого: `vars` — лише
/// значення, `bind` — правила, які ці значення прикладають до ролей.
/// Розмітку не чіпаємо зовсім: ролі дістаються селекторами за тим, що в
/// сторінці вже є (`#content`, `#content1`, `.contentTitle`, наші
/// `.quote/.reference`). Звідси обіцянка, заради якої все й затівалося:
/// у чужому файлі не міняється жодного байта, крім наших двох блоків.
///
/// Головне правило, якому підпорядковано всі параметри: значення має
/// лягати на **значення змінної**, а не на наявність правила. Логічне —
/// готовим словом CSS (`none`/`block`), вимикач — множником `1|0`.
/// Щойно параметр вимагатиме іншого набору правил, передпоказ почне
/// перезавантажувати сторінку на кожен рух повзунка і заблимає.

// MARK: - Один параметр

public struct WebSlideParameter: Sendable, Hashable, Identifiable {

    /// Розділ панелі. Порядок розділів — порядок у списку.
    public enum Group: String, Sendable, Hashable, CaseIterable {
        case text, stroke, reference, second, next, numbers, layout, plate, background, appear

        /// Незмінний підпис — за ним розділ знаходять у панелі. Переклад
        /// показують людині, а звіряють за цим: перекладений підпис
        /// роз'їжджається з мовою, і ручки їхали в чужий розділ.
        public var key: String {
            switch self {
            case .text:       return "Текст"
            case .stroke:     return "Обводка и тень"
            case .reference:  return "Адрес"
            case .second:     return "Второй перевод"
            case .next:       return "Следующий стих"
            case .numbers:    return "Номера стихов"
            case .layout:     return "Расположение"
            case .plate:      return "Подложка под текстом"
            case .background: return "Фон страницы"
            case .appear:     return "Появление слайда"
            }
        }

        public var title: String { OurWords.t(key) }

        private var unusedTitle: String {
            switch self {
            case .text:       return OurWords.t("Текст")
            case .stroke:     return OurWords.t("Обводка и тень")
            case .reference:  return OurWords.t("Адрес")
            case .second:     return OurWords.t("Второй перевод")
            case .next:       return OurWords.t("Следующий стих")
            case .numbers:    return OurWords.t("Номера стихов")
            case .layout:     return OurWords.t("Расположение")
            case .plate:      return OurWords.t("Подложка под текстом")
            case .background: return OurWords.t("Фон страницы")
            case .appear:     return OurWords.t("Появление слайда")
            }
        }
    }

    /// Один пункт вибору.
    public struct Option: Sendable, Hashable {
        /// Що ляже в змінну — уже готове значення CSS.
        public let value: String
        /// Що прочитає людина. Зберігається російською, а назовні виходить мовою
        /// інтерфейсу: підписи наші, в автора їх немає, і перекладати їх нікому,
        /// крім нас самих.
        public let titleSource: String
        public var title: String { OurWords.t(titleSource) }
        /// Що редактор дописує разом із цим вибором.
        ///
        /// Деякі зрозумілі людині вибори («адреса в правому нижньому куті»)
        /// у CSS — це дві різні властивості. Розкласти їх на дві змінні і
        /// писати обидві разом чесніше, ніж городити в блоці прив'язки набір
        /// правил під кожен випадок: правила вимагали б перезавантаження
        /// сторінки, а змінні доїжджають до передпоказу на льоту.
        public let implies: [String: String]

        public init(_ value: String, _ title: String, implies: [String: String] = [:]) {
            self.value = value
            self.titleSource = title
            self.implies = implies
        }
    }

    /// Вид значення — ним панель вибирає, що показати: повзунок, піпетку
    /// чи список.
    public enum Kind: Sendable, Hashable {
        /// Колір `#rrggbb`.
        case color
        /// Колір трійкою «R G B» — коли прозорість окремим параметром.
        case colorRGB
        /// Число; `unit` порожня — число без одиниці, інакше довжина («5vw»).
        case number(min: Double, max: Double, step: Double, unit: String)
        /// Частка 0…1 — показується відсотками.
        case fraction(min: Double, max: Double)
        case choice([Option])
        /// Так/ні. Обидва значення — готові слова CSS, а не `true`/`false`.
        case toggle(on: String, off: String, onTitle: String, offTitle: String)
        /// `none` або `url("…")` — картинка або градієнт.
        case link
    }

    public let name: String
    public let titleSource: String
    public var title: String { OurWords.t(titleSource) }
    public let group: Group
    public let kind: Kind
    public let defaultValue: String
    public let hintSource: String
    public var hint: String { OurWords.t(hintSource) }
    /// Чи показувати в панелі.
    ///
    /// Хибність стоїть у змінних-супутників: їх пише не людина, а вибір із
    /// сусіднього списку (див. `Option.implies`). У файлі вони живуть нарівні з
    /// усіма — інакше круговий прогін губив би їх при наступному записі.
    public let showsInPanel: Bool

    public var id: String { name }

    public init(_ name: String,
                _ title: String,
                group: Group,
                kind: Kind,
                default defaultValue: String,
                hint: String,
                showsInPanel: Bool = true) {
        self.name = name
        self.titleSource = title
        self.group = group
        self.kind = kind
        self.defaultValue = defaultValue
        self.hintSource = hint
        self.showsInPanel = showsInPanel
    }

    // MARK: Розбір і перевірка значення

    /// Чи годиться рядок як значення цього параметра.
    ///
    /// Негодний рядок не привід відкидати файл: людина могла вписати в блок
    /// щось своє руками. Панель гасить такий повзунок і показує сирий
    /// текст — але значення лишається у файлі неторканим.
    public func isValid(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard WebSlideParameters.isWritable(value) else { return false }
        switch kind {
        case .color:
            return WebSlideParameters.isHexColor(value)
        case .colorRGB:
            return WebSlideParameters.isColorTriple(value)
        case .number(_, _, _, let unit):
            return WebSlideParameters.number(value, unit: unit) != nil
        case .fraction:
            return WebSlideParameters.number(value, unit: "") != nil
        case .choice(let options):
            return options.contains { $0.value == value }
        case .toggle(let on, let off, _, _):
            return value == on || value == off
        case .link:
            return value == "none" || value.hasPrefix("url(") || value.contains("gradient(")
        }
    }

    /// Число зі значення — для повзунка.
    public func number(from raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .number(_, _, _, let unit): return WebSlideParameters.number(value, unit: unit)
        case .fraction:                  return WebSlideParameters.number(value, unit: "")
        default:                         return nil
        }
    }

    /// Число назад у значення — з тією самою одиницею, що в параметра.
    ///
    /// Ціле пишемо без хвоста: `6`, а не `6.0`. Людина відкриває цей блок
    /// очима, і зайві нулі вона читає як «програма насмітила».
    public func text(from value: Double) -> String {
        switch kind {
        case .number(_, _, _, let unit): return WebSlideParameters.digits(clamped(value)) + unit
        case .fraction:                  return WebSlideParameters.digits(clamped(value))
        default:                         return defaultValue
        }
    }

    /// Загнати число в межі параметра.
    public func clamped(_ value: Double) -> Double {
        switch kind {
        case .number(let low, let high, _, _): return min(max(value, low), high)
        case .fraction(let low, let high):     return min(max(value, low), high)
        default:                               return value
        }
    }

    /// Чи лягає параметр прямо на CSS.
    ///
    /// П'ять не лягають. Добір кегля і перехід робить скрипт прив'язки — без
    /// нього вони не працюють зовсім. Точка прив'язки, режим фону і місце адреси
    /// у CSS не потрапляють зовсім: це запис людського вибору, а роботу за
    /// них роблять супутники (`Option.implies`).
    public var isBoundToCSS: Bool {
        !["--sl-fit", "--sl-transition", "--sl-anchor", "--sl-bg-mode", "--sl-ref-place"].contains(name)
    }

    /// До якого місця сторінки ручку прикладено.
    ///
    /// Заведено заради одного питання, яке досі поставити було нікому:
    /// «а чи є в ЦІЙ сторінці те, чим ручка розпоряджається?». В автора
    /// адреса живе не окремим блоком, а рядком усередині тексту; окремого
    /// другого перекладу в його сторінках немає зовсім. Повзунок «Колір адреси» на
    /// такій сторінці рухається і чесно пишеться у файл — а на екрані не
    /// міняється нічого, і людина винить редактор. Роль дозволяє панелі
    /// сказати правду: прикласти нікуди.
    public var role: Role {
        switch name {
        // Добір кегля і перехід слайда робить скрипт, якого в чужій
        // сторінці немає і завести його нам нічим: договір — два блоки
        // `<style>` і жодного байта більше.
        case "--sl-fit", "--sl-transition":
            return .script
        // Смуга підкладки, напрямок другого перекладу і просвіт — це
        // властивості зовнішнього блоку, а не самого тексту.
        // Ширина підкладки живе на самому тексті: «за розміром тексту» має
        // працювати і там, де сцени в сторінці немає, — інакше ручка гасла як
        // «тут не діє», а підкладка лишалася на всю ширину.
        case "--sl-second-place", "--sl-ref-gap":
            return .stage
        // Видимість і кегль наступного вірша дістаються лише своїй
        // розмітці: чужому блоку ми міняємо колір і риску, але не відбираємо в
        // нього ні автодобору кегля, ні права бути видимим.
        case "--sl-next-display", "--sl-next-size":
            return .nextOwn
        default:
            break
        }
        switch group {
        case .text, .stroke, .plate, .appear: return .quote
        case .reference:  return .reference
        case .second:     return .second
        case .next:       return .next
        case .numbers:    return .number
        case .layout:     return .stage
        case .background: return .page
        }
    }

    /// Місце в сторінці, яким розпоряджається ручка.
    public enum Role: String, Sendable, Hashable, CaseIterable {
        case page, stage, quote, reference, second, next, nextOwn, number, script

        /// Як пояснити людині, чого в сторінці бракує.
        public var missing: String {
            switch self {
            case .page:      return OurWords.t("в странице нет тела <body> — это не целая страница")
            case .stage:     return OurWords.t("в странице не нашлось блока, который держит текст")
            case .quote:     return OurWords.t("в странице не нашлось блока с текстом стиха")
            case .reference: return OurWords.t("в этой странице адрес не отдельным блоком, а строкой внутри текста")
            case .second:    return OurWords.t("в этой странице второй перевод идёт тем же блоком, что и первый")
            case .next:      return OurWords.t("в этой странице нет блока для следующего стиха")
            case .nextOwn:   return OurWords.t("следующий стих здесь — блок автора: цвет и черту мы ему поменяем, "
                                 + "а кегль он подбирает сам, и прятать его мы не станем")
            case .number:    return OurWords.t("номера стихов выделяет скрипт, а в этой странице его нет")
            case .script:    return OurWords.t("это делает скрипт, а мы дописываем в страницу только оформление")
            }
        }
    }
}

// MARK: - Набір значень однієї сторінки

/// Що записано в блоці налаштувань однієї сторінки.
///
/// Зберігається сирими рядками, а не розібраними числами, і це навмисно:
/// значення, яке ми не зрозуміли, зобов'язане повернутися у файл рівно таким,
/// яким прийшло. Інакше файл, зроблений іншою версією програми, тихо
/// втратить половину налаштувань при першому ж русі повзунка.
public struct WebSlideSettings: Sendable, Hashable {

    private var stored: [String: String]
    /// Порядок появи — за ним дописуються незнайомі змінні.
    private var appearance: [String]

    public init() {
        stored = [:]
        appearance = []
    }

    public init(_ pairs: [(String, String)]) {
        stored = [:]
        appearance = []
        for (name, value) in pairs { set(name, value) }
    }

    /// Рівність рахується за значеннями, порядок до уваги не береться.
    ///
    /// Порядок — підказка для запису, а не частина налаштувань: круговий прогін
    /// «розібрати → записати → розібрати» переставляє знайомі змінні в
    /// порядок каталогу, і це не розбіжність.
    public static func == (lhs: WebSlideSettings, rhs: WebSlideSettings) -> Bool {
        lhs.stored == rhs.stored
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(stored)
    }

    public subscript(name: String) -> String? { stored[name] }

    public mutating func set(_ name: String, _ value: String) {
        if stored[name] == nil { appearance.append(name) }
        stored[name] = value
    }

    public mutating func remove(_ name: String) {
        stored[name] = nil
        appearance.removeAll { $0 == name }
    }

    /// Значення параметра: своє, а якщо не задано — за умовчанням.
    public func value(_ parameter: WebSlideParameter) -> String {
        stored[parameter.name] ?? parameter.defaultValue
    }

    /// Чи задано значення руками так, що повзунок його не розуміє.
    public func isManual(_ parameter: WebSlideParameter) -> Bool {
        guard let raw = stored[parameter.name] else { return false }
        return !parameter.isValid(raw)
    }

    /// Поставити значення параметра разом з його супутниками.
    public mutating func choose(_ parameter: WebSlideParameter, value: String) {
        set(parameter.name, value)
        if case .choice(let options) = parameter.kind,
           let option = options.first(where: { $0.value == value }) {
            for (name, companion) in option.implies.sorted(by: { $0.key < $1.key }) {
                set(name, companion)
            }
        }
    }

    /// Змінні, яких немає в каталозі, — з новішої версії програми.
    public var unknownNames: [String] {
        appearance.filter { WebSlideParameters.parameter(named: $0) == nil }
    }

    public var names: [String] { appearance }
    public var isEmpty: Bool { stored.isEmpty }
    public var count: Int { stored.count }

    /// Дописати все, чого в наборі немає, значеннями за умовчанням.
    ///
    /// Потрібно рівно один раз — коли блок налаштувань заводиться в сторінці, де
    /// його не було. Далі порожнє значення означає «не задано», і дописувати
    /// його не можна: тоді кожен рух повзунка роздував би блок.
    public func applyingDefaults() -> WebSlideSettings {
        var copy = self
        for parameter in WebSlideParameters.all where copy.stored[parameter.name] == nil {
            copy.set(parameter.name, parameter.defaultValue)
        }
        return copy
    }

    /// Що змінилося проти колишнього набору — цим живиться передпоказ.
    public func changes(since old: WebSlideSettings) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in stored where old.stored[name] != value {
            result[name] = value
        }
        // Прибране повертаємо до значення за умовчанням: у живій сторінці
        // змінну вже виставлено, і просто забути про неї не можна.
        for (name, _) in old.stored where stored[name] == nil {
            result[name] = WebSlideParameters.parameter(named: name)?.defaultValue ?? "initial"
        }
        return result
    }

    /// Порядок запису: спершу каталог, потім незнайоме — як прийшло.
    public var writingOrder: [(name: String, value: String)] {
        var result: [(String, String)] = []
        var written = Set<String>()
        for parameter in WebSlideParameters.all {
            if let value = stored[parameter.name] {
                result.append((parameter.name, value))
                written.insert(parameter.name)
            }
        }
        for name in appearance where !written.contains(name) {
            if let value = stored[name] {
                result.append((name, value))
                written.insert(name)
            }
        }
        return result
    }
}

// MARK: - Розбір сторінки

/// Що вдалося вичитати зі сторінки.
public struct WebSlideDocument: Sendable {

    public enum Block: Sendable, Equatable {
        /// Блок знайдено і він цілий.
        case present(version: Int, extras: Int)
        /// Блоку в сторінці немає — його можна завести.
        case missing
        /// Мітки переплутано або блок розірвано; записувати не можна.
        case damaged(reason: String)
    }

    public let block: Block
    public let settings: WebSlideSettings
    /// Чи є куди вставляти блок.
    public let hasHead: Bool
    /// Чи є блок прив'язки.
    public let hasBinding: Bool
    /// Оголошення `--sl-*`, знайдені поза блоком: людина правила руками.
    public let outsideNames: [String]
    /// Перенос рядка цього файла — в авторських сторінок CRLF.
    public let newline: String

    /// Чи можна рухати повзунки.
    public var isAdjustable: Bool {
        switch block {
        case .damaged: return false
        case .present(let version, _): return version <= WebSlideParameters.version
        case .missing: return hasHead
        }
    }

    /// Рядок стану для людини — чому повзунки такі, які є.
    public var note: String? {
        switch block {
        case .damaged(let reason):
            return OurWords.t("Блок настроек повреждён: %s. Ползунки выключены, чтобы не испортить остальное.", reason)
        case .missing:
            return hasHead
                ? OurWords.t("В этой странице ещё нет настроек: первое движение ползунка заведёт их.")
                : OurWords.t("Это не целая страница: в ней нет </head>, вставлять настройки некуда.")
        case .present(let version, let extras):
            if version > WebSlideParameters.version {
                return OurWords.t("Эту страницу настраивала более новая версия программы. "
                    + "Чтобы не испортить настройки, ползунки выключены; текст правится как обычно.")
            }
            var parts: [String] = []
            if extras > 0 {
                parts.append(OurWords.t("блоков настроек в файле %s, работает последний", "\(extras + 1)"))
            }
            if !outsideNames.isEmpty {
                parts.append(OurWords.t("вне блока правлено руками: ") + outsideNames.joined(separator: ", "))
            }
            let unknown = settings.unknownNames
            if !unknown.isEmpty {
                parts.append(OurWords.t("настроек от другой версии: %s", "\(unknown.count)"))
            }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
    }
}

/// Чим скінчився запис.
public enum WebSlideWriteOutcome: Sendable {
    case written(String)
    /// Записувати не можна — причина словами, її показують людині.
    case refused(String)

    public var html: String? {
        if case .written(let text) = self { return text }
        return nil
    }
}

// MARK: - Каталог, розбір, запис, готовий CSS

public enum WebSlideParameters {

    /// Версія блоку. Росте, коли міняється набір змінних або прив'язка.
    public static let version = 6

    // MARK: Мітки

    /// Не private: за ним і самоперевірка відрізняє сторінку з блоком.
    public static let varsAttribute = "data-slovo=\"vars\""
    static let bindAttribute = "data-slovo=\"bind\""
    static let liveAttribute = "data-slovo=\"live\""
    static let styleClose = "</style>"
    /// Мітка на випадок, якщо людина перенесла блок зі `<style>` кудись іще.
    /// Узяти блок налаштувань з колишньої сторінки і покласти його у свіжу
    /// заготовку: каркас оновиться, а вибрані власником значення
    /// лишаться. Немає блоку — віддаємо свіжу як є.
    public static func carryOverSettings(from old: String, into fresh: String) -> String {
        guard let oldBlock = settingsBlockRange(in: old),
              let freshBlock = settingsBlockRange(in: fresh) else { return fresh }
        // Значення власника головніші, але ручки, яких у його сторінці ще
        // не було (нові ефекти, наприклад), мають приїхати зі свіжими
        // умовчаннями — інакше оновлення проходить повз нього.
        let mine = values(in: String(old[oldBlock]))
        var merged = ""
        var seen: Set<String> = []
        for line in String(fresh[freshBlock]).split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let name = variableName(in: text), let value = mine[name] {
                merged += "  \(name): \(value);\n"
                seen.insert(name)
            } else {
                merged += text + "\n"
            }
        }
        // Ручки, які власник завів сам, а в заготовці їх немає.
        let extra = mine.keys.filter { !seen.contains($0) }.sorted()
        if !extra.isEmpty, let close = merged.range(of: "}", options: .backwards) {
            let added = extra.map { "  \($0): \(mine[$0] ?? "");" }.joined(separator: "\n") + "\n"
            merged.replaceSubrange(close.lowerBound..<close.lowerBound, with: added)
        }
        var result = fresh
        result.replaceSubrange(freshBlock, with: merged.trimmingCharacters(in: .newlines))
        return result
    }

    /// Пари «ім'я: значення» з тексту блоку налаштувань.
    private static func values(in block: String) -> [String: String] {
        var table: [String: String] = [:]
        for line in block.split(separator: "\n") {
            let text = String(line)
            guard let name = variableName(in: text),
                  let colon = text.range(of: ":", range: (text.range(of: name)?.upperBound ?? text.startIndex)..<text.endIndex) else { continue }
            var value = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value.removeLast() }
            table[name] = value.trimmingCharacters(in: .whitespaces)
        }
        return table
    }

    /// Ім'я змінної в рядку виду «  --sl-щось: значення;».
    private static func variableName(in line: String) -> String? {
        guard let start = line.range(of: "--sl-") else { return nil }
        let tail = line[start.lowerBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        return String(tail[tail.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
    }

    /// Межі блоку налаштувань — від маркера початку до маркера кінця.
    private static func settingsBlockRange(in page: String) -> Range<String.Index>? {
        guard let start = markerRange(varsMarkers, in: page),
              let end = markerRange(varsEndMarkers, in: page, range: start.upperBound..<page.endIndex),
              let head = page.range(of: ":root", options: .backwards, range: page.startIndex..<start.lowerBound)
                    ?? page.range(of: "/*", options: .backwards, range: page.startIndex..<start.lowerBound),
              let tail = page.range(of: "}", range: end.upperBound..<page.endIndex) else { return nil }
        return head.lowerBound..<tail.upperBound
    }

    public static let varsMarker = "── Слово: налаштування ──"
    public static let varsEndMarker = "── кінець налаштувань ──"
    public static let bindMarker = "── Слово: прив'язка ──"
    public static let bindEndMarker = "── кінець прив'язки ──"
    public static let liveMarker = "── Слово: живі налаштування ──"
    public static let liveEndMarker = "── кінець живих налаштувань ──"

    /// Дужки, за якими панель упізнає наш блок. Їх не перекладають ніколи.
    ///
    /// Раніше панель шукала російські слова підпису — «Настройки страницы».
    /// Підпис переклали українською, і блок «пропав» разом в усіх десяти
    /// заготовках: повзунків не стало. Слова міняються, ці дужки — ні.
    public static let varsToken = "[slovo-vars]"
    public static let varsEndToken = "[/slovo-vars]"

    /// Як мітка писалася в попередніх випусках.
    ///
    /// Підпис блоку переклали українською, а сторінки власника лишилися з
    /// колишньою: шукати треба будь-яку з них, інакше його власна сторінка
    /// відкриється без повзунків і він утратить свої налаштування.
    public static let varsMarkers = [varsMarker, "── Слово: настройки ──"]
    public static let varsEndMarkers = [varsEndMarker, "── конец настроек ──"]

    /// Перше входження будь-якої з міток. Окремою функцією тому, що місць
    /// пошуку сім, і досить забути про стару мітку в одному з них.
    public static func markerRange<S: StringProtocol>(_ needles: [String], in text: S,
                                                      options: String.CompareOptions = [],
                                                      range: Range<S.Index>? = nil) -> Range<S.Index>? {
        let scope = range ?? text.startIndex..<text.endIndex
        for needle in needles {
            if let found = text.range(of: needle, options: options, range: scope) { return found }
        }
        return nil
    }

    // MARK: - Каталог

    public static let all: [WebSlideParameter] =
        textParameters + strokeParameters + referenceParameters + secondParameters
        + nextParameters + numberParameters + layoutParameters + plateParameters
        + backgroundParameters + appearParameters + animationParameters

    public static func parameter(named name: String) -> WebSlideParameter? {
        index[name]
    }

    private static let index: [String: WebSlideParameter] = {
        var map: [String: WebSlideParameter] = [:]
        for parameter in all { map[parameter.name] = parameter }
        return map
    }()

    /// Усе за умовчанням — з цього починається нова сторінка.
    public static var defaults: WebSlideSettings {
        WebSlideSettings().applyingDefaults()
    }

    public static func parameters(of group: WebSlideParameter.Group) -> [WebSlideParameter] {
        all.filter { $0.group == group && $0.showsInPanel }
    }

    // MARK: Текст

    private static let textParameters: [WebSlideParameter] = [
        .init("--sl-font", "Шрифт", group: .text,
              kind: .choice([
                  .init("\"Helvetica Neue\", Arial, sans-serif", "Без засечек"),
                  .init("Georgia, \"Times New Roman\", serif", "С засечками"),
                  .init("\"Arial Narrow\", \"Helvetica Neue Condensed\", sans-serif", "Узкий"),
                  .init("Menlo, \"SF Mono\", monospace", "Моноширинный"),
                  .init("-apple-system, system-ui, sans-serif", "Системный"),
                  .init("\"Snell Roundhand\", cursive", "Рукописный"),
              ]),
              default: "\"Helvetica Neue\", Arial, sans-serif",
              hint: "Шрифт берётся из тех, что есть в браузере, а не из папки Fonts."),

        .init("--sl-unit", "От чего мерить кегль", group: .text,
              kind: .choice([
                  .init("1vw", "От ширины экрана"),
                  .init("1vh", "От высоты экрана"),
              ]),
              default: "1vw",
              hint: "От ширины — как в наших заготовках. От высоты — как в оформлении слайда программы."),

        .init("--sl-size", "Размер текста", group: .text,
              kind: .number(min: 1.5, max: 20, step: 0.1, unit: ""),
              default: "6",
              hint: "Доли той стороны экрана, что выбрана выше."),

        .init("--sl-weight", "Насыщенность", group: .text,
              kind: .number(min: 100, max: 900, step: 10, unit: ""),
              default: "700",
              hint: "400 — обычный, 700 — полужирный. Тонкие начертания есть не у всякого шрифта."),

        .init("--sl-stretch", "Ширина букв", group: .text,
              kind: .choice([
                  .init("condensed", "Сжатые"),
                  .init("semi-condensed", "Слегка сжатые"),
                  .init("normal", "Обычные"),
                  .init("semi-expanded", "Слегка широкие"),
                  .init("expanded", "Широкие"),
                  .init("ultra-expanded", "Самые широкие"),
              ]),
              default: "normal",
              hint: "Работает только у шрифтов, где такие начертания есть."),

        .init("--sl-italic", "Курсив", group: .text,
              kind: .toggle(on: "italic", off: "normal", onTitle: "Курсивом", offTitle: "Прямой"),
              default: "normal",
              hint: "Длинный текст курсивом читается с дальнего ряда хуже."),

        .init("--sl-caps", "Прописными", group: .text,
              kind: .toggle(on: "uppercase", off: "none", onTitle: "ВСЕ ПРОПИСНЫЕ", offTitle: "Как есть"),
              default: "none",
              hint: "Меняет только вид, сам текст остаётся прежним."),

        .init("--sl-tracking", "Разрядка", group: .text,
              kind: .number(min: -0.05, max: 0.2, step: 0.01, unit: "em"),
              default: "0em",
              hint: "Расстояние между буквами. Отрицательное сжимает."),

        .init("--sl-line", "Междустрочие", group: .text,
              kind: .number(min: 0.9, max: 2.2, step: 0.05, unit: ""),
              default: "1.25",
              hint: "Во сколько раз строка выше кегля."),

        .init("--sl-color", "Цвет текста", group: .text,
              kind: .color, default: "#ffffff",
              hint: "На проекторе чистый белый часто засвечивает — попробуйте чуть темнее."),

        .init("--sl-text-opacity", "Непрозрачность текста", group: .text,
              kind: .fraction(min: 0, max: 1), default: "1",
              hint: "1 — текст как есть, 0 — совсем прозрачный."),

        .init("--sl-align", "Выравнивание", group: .text,
              kind: .choice([
                  .init("left", "По левому краю"),
                  .init("center", "По центру"),
                  .init("right", "По правому краю"),
                  .init("justify", "По ширине"),
              ]),
              default: "center",
              hint: "«По ширине» — как в книге, у автора так сделана страница для Библии."),

        .init("--sl-width", "Ширина колонки", group: .text,
              kind: .number(min: 20, max: 100, step: 1, unit: "%"),
              default: "90%",
              hint: "Узкая колонка читается легче: глаз не бегает через весь экран."),

        .init("--sl-fit", "Подбирать кегль под длину", group: .text,
              kind: .toggle(on: "1", off: "0", onTitle: "Подбирать", offTitle: "Не подбирать"),
              default: "0",
              hint: "Делает скрипт самой страницы. В чужую страницу мы дописываем только оформление, поэтому на ней ручка погашена."),
    ]

    // MARK: Обведення і тінь

    private static let strokeParameters: [WebSlideParameter] = [
        .init("--sl-stroke-on", "Обводка", group: .stroke,
              kind: .toggle(on: "1", off: "0", onTitle: "Есть", offTitle: "Нет"),
              default: "0",
              hint: "Выключатель отдельный от толщины: снятая галочка не стирает подобранное."),

        .init("--sl-stroke", "Толщина обводки", group: .stroke,
              kind: .number(min: 0, max: 1.5, step: 0.05, unit: ""),
              default: "0.4",
              hint: "В сотых долях высоты экрана. Толстая обводка съедает тонкие буквы."),

        .init("--sl-stroke-color", "Цвет обводки", group: .stroke,
              kind: .color, default: "#000000",
              hint: "Обводка нужна там, где под текстом светлая картинка."),

        .init("--sl-shadow-on", "Тень", group: .stroke,
              kind: .toggle(on: "1", off: "0", onTitle: "Есть", offTitle: "Нет"),
              default: "1",
              hint: "Тень отделяет текст от фона надёжнее обводки и меньше портит буквы."),

        .init("--sl-shadow-offset", "Смещение тени", group: .stroke,
              kind: .number(min: 0, max: 8, step: 0.1, unit: ""),
              default: "2.7",
              hint: "Проценты от кегля — те же числа, что в оформлении слайда программы."),

        .init("--sl-shadow-blur", "Сглаживание тени", group: .stroke,
              kind: .number(min: 0, max: 25, step: 0.5, unit: ""),
              default: "7",
              hint: "Проценты от кегля."),

        .init("--sl-shadow-opacity", "Прозрачность тени", group: .stroke,
              kind: .fraction(min: 0, max: 1), default: "0.55",
              hint: "0 — тени не видно, 1 — совсем плотная."),

        .init("--sl-shadow-rgb", "Цвет тени", group: .stroke,
              kind: .colorRGB, default: "0 0 0",
              hint: "Прозрачность у тени своя, поэтому цвет хранится тройкой чисел."),
    ]

    // MARK: Адреса

    private static let referenceParameters: [WebSlideParameter] = [
        .init("--sl-ref-display", "Показывать адрес", group: .reference,
              kind: .toggle(on: "block", off: "none", onTitle: "Показывать", offTitle: "Скрыть"),
              default: "block",
              hint: "На песнях адрес обычно скрывают."),

        .init("--sl-ref-size", "Размер адреса", group: .reference,
              kind: .fraction(min: 0.2, max: 1), default: "0.45",
              hint: "Доля от размера основного текста."),

        .init("--sl-ref-color", "Цвет адреса", group: .reference,
              kind: .color, default: "#ffd98a",
              hint: "Отличный от текста цвет помогает не путать адрес со стихом."),

        .init("--sl-ref-italic", "Курсив у адреса", group: .reference,
              kind: .toggle(on: "italic", off: "normal", onTitle: "Курсивом", offTitle: "Прямой"),
              default: "italic",
              hint: ""),

        .init("--sl-ref-place", "Где адрес", group: .reference,
              kind: .choice([
                  .init("under", "Под текстом",
                        implies: ["--sl-ref-order": "2", "--sl-ref-self": "center"]),
                  .init("above", "Над текстом",
                        implies: ["--sl-ref-order": "-1", "--sl-ref-self": "center"]),
                  .init("bottom-right", "Справа внизу",
                        implies: ["--sl-ref-order": "2", "--sl-ref-self": "flex-end"]),
                  .init("bottom-left", "Слева внизу",
                        implies: ["--sl-ref-order": "2", "--sl-ref-self": "flex-start"]),
              ]),
              default: "under",
              hint: "Углы считаются от колонки с текстом, а не от края экрана."),

        .init("--sl-ref-order", "Порядок адреса", group: .reference,
              kind: .choice([.init("-1", "Перед текстом"), .init("2", "После текста")]),
              default: "2",
              hint: "Пишется вместе с выбором «где адрес».",
              showsInPanel: false),

        .init("--sl-ref-self", "Прижим адреса", group: .reference,
              kind: .choice([
                  .init("flex-start", "К левому краю"),
                  .init("center", "По центру"),
                  .init("flex-end", "К правому краю"),
              ]),
              default: "center",
              hint: "Пишется вместе с выбором «где адрес».",
              showsInPanel: false),

        .init("--sl-ref-gap", "Отступ адреса", group: .reference,
              kind: .number(min: 0, max: 8, step: 0.1, unit: "vh"),
              default: "1.5vh",
              hint: "Просвет между текстом и адресом."),
    ]

    // MARK: Другий переклад

    private static let secondParameters: [WebSlideParameter] = [
        .init("--sl-second-display", "Показывать второй перевод", group: .second,
              kind: .toggle(on: "block", off: "none", onTitle: "Показывать", offTitle: "Скрыть"),
              // Теж не ховаємо за умовчанням — з тієї самої причини. Порожній блок
              // і так схлопується правилом `.empty { display: none }`.
              default: "block",
              hint: "Второй перевод приходит из программы в Var1; если он выключен, блок пуст."),

        .init("--sl-second-size", "Размер второго", group: .second,
              kind: .fraction(min: 0.4, max: 1), default: "0.8",
              hint: "Доля от основного текста."),

        .init("--sl-second-color", "Цвет второго", group: .second,
              kind: .color, default: "#cfe0ff",
              hint: ""),

        .init("--sl-second-italic", "Курсив у второго", group: .second,
              kind: .toggle(on: "italic", off: "normal", onTitle: "Курсивом", offTitle: "Прямой"),
              default: "italic",
              hint: ""),

        .init("--sl-second-place", "Как ставить второй", group: .second,
              kind: .choice([
                  .init("column", "Под основным"),
                  .init("row", "Рядом, двумя колонками"),
              ]),
              default: "column",
              hint: "В два столбца адрес встаёт в тот же ряд — проверьте его на предпросмотре."),
    ]

    // MARK: Наступний вірш

    private static let nextParameters: [WebSlideParameter] = [
        .init("--sl-next-display", "Показывать следующий", group: .next,
              kind: .toggle(on: "block", off: "none", onTitle: "Показывать", offTitle: "Скрыть"),
              // За умовчанням НЕ ховаємо: сторінка, якій ми надягли блок
              // налаштувань, зобов'язана виглядати рівно як до цього. Заготовки,
              // яким наступний вірш не потрібен, вимикають його в себе самі.
              default: "block",
              hint: "Это для экрана служителя, а не для зала."),

        .init("--sl-next-size", "Размер следующего", group: .next,
              kind: .fraction(min: 0.2, max: 0.8), default: "0.35",
              hint: "Доля от основного текста."),

        .init("--sl-next-color", "Цвет следующего", group: .next,
              kind: .color, default: "#7f8fa6",
              hint: "Приглушённый цвет, чтобы не спорил с текущим стихом."),

        .init("--sl-next-rule", "Разделитель", group: .next,
              kind: .number(min: 0, max: 0.5, step: 0.05, unit: "vh"),
              default: "0.1vh",
              hint: "Толщина черты над следующим стихом. Ноль — черты нет."),
    ]

    // MARK: Номери віршів

    private static let numberParameters: [WebSlideParameter] = [
        .init("--sl-num-display", "Показывать номера стихов", group: .numbers,
              kind: .toggle(on: "inline", off: "none", onTitle: "Показывать", offTitle: "Скрыть"),
              default: "none",
              hint: "Номера выделяет из текста скрипт страницы. Там, где его нет, ручка погашена."),

        .init("--sl-num-size", "Размер номера", group: .numbers,
              kind: .fraction(min: 0.4, max: 0.9), default: "0.6",
              hint: "Доля от размера того текста, где номер стоит."),

        .init("--sl-num-color", "Цвет номера", group: .numbers,
              kind: .color, default: "#ffd98a",
              hint: ""),
    ]

    // MARK: Розташування

    private static let layoutParameters: [WebSlideParameter] = [
        .init("--sl-anchor", "Где текст на экране", group: .layout,
              kind: .choice([
                  .init("top-left", "Сверху слева",
                        implies: ["--sl-h": "flex-start", "--sl-v": "flex-start"]),
                  .init("top-center", "Сверху по центру",
                        implies: ["--sl-h": "center", "--sl-v": "flex-start"]),
                  .init("top-right", "Сверху справа",
                        implies: ["--sl-h": "flex-end", "--sl-v": "flex-start"]),
                  .init("center-left", "Посередине слева",
                        implies: ["--sl-h": "flex-start", "--sl-v": "center"]),
                  .init("center-center", "По центру",
                        implies: ["--sl-h": "center", "--sl-v": "center"]),
                  .init("center-right", "Посередине справа",
                        implies: ["--sl-h": "flex-end", "--sl-v": "center"]),
                  .init("bottom-left", "Снизу слева",
                        implies: ["--sl-h": "flex-start", "--sl-v": "flex-end"]),
                  .init("bottom-center", "Снизу по центру",
                        implies: ["--sl-h": "center", "--sl-v": "flex-end"]),
                  .init("bottom-right", "Снизу справа",
                        implies: ["--sl-h": "flex-end", "--sl-v": "flex-end"]),
              ]),
              default: "center-center",
              hint: "Девять точек привязки. Перетаскивание мышью встаёт на ближайшую."),

        .init("--sl-h", "Прижим по горизонтали", group: .layout,
              kind: .choice([
                  .init("flex-start", "К левому краю"),
                  .init("center", "По центру"),
                  .init("flex-end", "К правому краю"),
              ]),
              default: "center",
              hint: "Обычно ставится выбором точки привязки."),

        .init("--sl-v", "Прижим по вертикали", group: .layout,
              kind: .choice([
                  .init("flex-start", "К верху"),
                  .init("center", "По середине"),
                  .init("flex-end", "К низу"),
                  .init("space-between", "Растянуть по высоте"),
              ]),
              default: "center",
              hint: "«Растянуть» разводит текст и адрес по краям — так сделан экран служителя."),

        .init("--sl-offset-x", "Сдвиг вправо", group: .layout,
              kind: .number(min: -40, max: 40, step: 0.5, unit: ""),
              default: "0",
              hint: "Сотые доли ширины экрана. Отрицательное двигает влево."),

        .init("--sl-offset-y", "Сдвиг вниз", group: .layout,
              kind: .number(min: -40, max: 40, step: 0.5, unit: ""),
              default: "0",
              hint: "Сотые доли высоты экрана. Отрицательное двигает вверх."),

        .init("--sl-pad-x", "Поля по бокам", group: .layout,
              kind: .number(min: 0, max: 20, step: 0.5, unit: "vw"),
              default: "5vw",
              hint: ""),

        .init("--sl-pad-y", "Поля сверху и снизу", group: .layout,
              kind: .number(min: 0, max: 20, step: 0.5, unit: "vh"),
              default: "4vh",
              hint: ""),

        .init("--sl-safe", "Запас на телевизор", group: .layout,
              kind: .number(min: 0, max: 10, step: 0.5, unit: "%"),
              default: "0%",
              hint: "Старые телевизоры срезают края кадра. Запас отодвигает текст от края."),
    ]


    // MARK: Поява і зникнення

    /// Двадцять ефектів; текст і підкладка вибирають їх незалежно —
    /// власник просив, щоб підкладка жила своїм життям.
    private static let animationParameters: [WebSlideParameter] = [
        .init("--sl-anim-in", "Как появляется текст", group: .appear,
              kind: .choice([
                  .init("none", "без эффекта"),
                  .init("vhod-rastvorenie", "растворение"),
                  .init("vhod-snizu", "выезд снизу"),
                  .init("vhod-sverhu", "выезд сверху"),
                  .init("vhod-sleva", "выезд слева"),
                  .init("vhod-sprava", "выезд справа"),
                  .init("vhod-naplyv", "наплыв"),
                  .init("vhod-otdalenie", "отдаление"),
                  .init("vhod-razmytie", "размытие"),
                  .init("vhod-perevorot", "переворот"),
                  .init("vhod-povorot", "поворот"),
                  .init("vhod-otskok", "отскок"),
                  .init("vhod-pruzhina", "пружина"),
                  .init("vhod-shtorka-vpravo", "шторка вправо"),
                  .init("vhod-shtorka-vlevo", "шторка влево"),
                  .init("vhod-shtorka-vniz", "шторка вниз"),
                  .init("vhod-shtorka-vverh", "шторка вверх"),
                  .init("vhod-zanaves", "занавес"),
                  .init("vhod-lupa", "лупа"),
                  .init("vhod-kachaniye", "качание"),
                  .init("vhod-svechenie", "свечение"),
                  .init("vhod-padenie", "падение"),
                  .init("vhod-vypolzanie", "выползание"),
                  .init("vhod-szhatie", "сжатие"),
                  .init("vhod-razvorot", "разворот"),
                  .init("vhod-mercanie", "мерцание"),
                  .init("vhod-volna", "волна"),
              ]),
              default: "vhod-rastvorenie",
              hint: "Играет при выводе нового текста; длительность — «Длительность перехода»."),

        .init("--sl-anim-out", "Как исчезает текст", group: .appear,
              kind: .choice([
                  .init("none", "без эффекта"),
                  .init("vyhod-rastvorenie", "растворение"),
                  .init("vyhod-snizu", "выезд снизу"),
                  .init("vyhod-sverhu", "выезд сверху"),
                  .init("vyhod-sleva", "выезд слева"),
                  .init("vyhod-sprava", "выезд справа"),
                  .init("vyhod-naplyv", "наплыв"),
                  .init("vyhod-otdalenie", "отдаление"),
                  .init("vyhod-razmytie", "размытие"),
                  .init("vyhod-perevorot", "переворот"),
                  .init("vyhod-povorot", "поворот"),
                  .init("vyhod-otskok", "отскок"),
                  .init("vyhod-pruzhina", "пружина"),
                  .init("vyhod-shtorka-vpravo", "шторка вправо"),
                  .init("vyhod-shtorka-vlevo", "шторка влево"),
                  .init("vyhod-shtorka-vniz", "шторка вниз"),
                  .init("vyhod-shtorka-vverh", "шторка вверх"),
                  .init("vyhod-zanaves", "занавес"),
                  .init("vyhod-lupa", "лупа"),
                  .init("vyhod-kachaniye", "качание"),
                  .init("vyhod-svechenie", "свечение"),
                  .init("vyhod-padenie", "падение"),
                  .init("vyhod-vypolzanie", "выползание"),
                  .init("vyhod-szhatie", "сжатие"),
                  .init("vyhod-razvorot", "разворот"),
                  .init("vyhod-mercanie", "мерцание"),
                  .init("vyhod-volna", "волна"),
              ]),
              default: "vyhod-rastvorenie",
              hint: "Играет, когда текст уходит: перед следующим или при пустом экране."),

        .init("--sl-plate-in", "Как появляется подложка", group: .appear,
              kind: .choice([
                  .init("none", "без эффекта"),
                  .init("vhod-rastvorenie", "растворение"),
                  .init("vhod-snizu", "выезд снизу"),
                  .init("vhod-sverhu", "выезд сверху"),
                  .init("vhod-sleva", "выезд слева"),
                  .init("vhod-sprava", "выезд справа"),
                  .init("vhod-naplyv", "наплыв"),
                  .init("vhod-otdalenie", "отдаление"),
                  .init("vhod-razmytie", "размытие"),
                  .init("vhod-perevorot", "переворот"),
                  .init("vhod-povorot", "поворот"),
                  .init("vhod-otskok", "отскок"),
                  .init("vhod-pruzhina", "пружина"),
                  .init("vhod-shtorka-vpravo", "шторка вправо"),
                  .init("vhod-shtorka-vlevo", "шторка влево"),
                  .init("vhod-shtorka-vniz", "шторка вниз"),
                  .init("vhod-shtorka-vverh", "шторка вверх"),
                  .init("vhod-zanaves", "занавес"),
                  .init("vhod-lupa", "лупа"),
                  .init("vhod-kachaniye", "качание"),
                  .init("vhod-svechenie", "свечение"),
                  .init("vhod-padenie", "падение"),
                  .init("vhod-vypolzanie", "выползание"),
                  .init("vhod-szhatie", "сжатие"),
                  .init("vhod-razvorot", "разворот"),
                  .init("vhod-mercanie", "мерцание"),
                  .init("vhod-volna", "волна"),
              ]),
              default: "none",
              hint: "Подложка может выезжать иначе, чем текст, — или стоять неподвижно."),

        .init("--sl-plate-out", "Как исчезает подложка", group: .appear,
              kind: .choice([
                  .init("none", "без эффекта"),
                  .init("vyhod-rastvorenie", "растворение"),
                  .init("vyhod-snizu", "выезд снизу"),
                  .init("vyhod-sverhu", "выезд сверху"),
                  .init("vyhod-sleva", "выезд слева"),
                  .init("vyhod-sprava", "выезд справа"),
                  .init("vyhod-naplyv", "наплыв"),
                  .init("vyhod-otdalenie", "отдаление"),
                  .init("vyhod-razmytie", "размытие"),
                  .init("vyhod-perevorot", "переворот"),
                  .init("vyhod-povorot", "поворот"),
                  .init("vyhod-otskok", "отскок"),
                  .init("vyhod-pruzhina", "пружина"),
                  .init("vyhod-shtorka-vpravo", "шторка вправо"),
                  .init("vyhod-shtorka-vlevo", "шторка влево"),
                  .init("vyhod-shtorka-vniz", "шторка вниз"),
                  .init("vyhod-shtorka-vverh", "шторка вверх"),
                  .init("vyhod-zanaves", "занавес"),
                  .init("vyhod-lupa", "лупа"),
                  .init("vyhod-kachaniye", "качание"),
                  .init("vyhod-svechenie", "свечение"),
                  .init("vyhod-padenie", "падение"),
                  .init("vyhod-vypolzanie", "выползание"),
                  .init("vyhod-szhatie", "сжатие"),
                  .init("vyhod-razvorot", "разворот"),
                  .init("vyhod-mercanie", "мерцание"),
                  .init("vyhod-volna", "волна"),
              ]),
              default: "none",
              hint: "Играет, когда в зале пустой экран."),
    ]

    // MARK: Підкладка

    private static let plateParameters: [WebSlideParameter] = [
        .init("--sl-plate-rgb", "Цвет подложки", group: .plate,
              kind: .colorRGB, default: "0 0 0",
              hint: "Прозрачность у подложки отдельная, поэтому цвет хранится тройкой чисел."),

        .init("--sl-plate-opacity", "Прозрачность подложки", group: .plate,
              kind: .fraction(min: 0, max: 1), default: "0.3",
              hint: "0,3 — как на страницах автора. 0 — подложки нет вовсе."),

        .init("--sl-plate-full", "Ширина подложки", group: .plate,
              kind: .choice([
                  .init("1", "Полосой во всю ширину"),
                  .init("0", "По размеру текста"),
              ]),
              default: "0",
              hint: "Ровно то, чем страницы автора CF и CF1 отличаются друг от друга."),

        .init("--sl-plate-pad-x", "Поля подложки по бокам", group: .plate,
              kind: .number(min: 0, max: 10, step: 0.25, unit: "vw"),
              default: "2vw",
              hint: ""),

        .init("--sl-plate-pad-y", "Поля подложки сверху и снизу", group: .plate,
              kind: .number(min: 0, max: 10, step: 0.25, unit: "vh"),
              default: "2vh",
              hint: ""),

        .init("--sl-plate-radius", "Скругление углов", group: .plate,
              kind: .number(min: 0, max: 6, step: 0.1, unit: "vh"),
              default: "1.6vh",
              hint: "У автора это 16 точек; в долях высоты скругление не меняется от разрешения."),

        .init("--sl-plate-blur", "Размытие под подложкой", group: .plate,
              kind: .number(min: 0, max: 4, step: 0.1, unit: "vh"),
              default: "0vh",
              hint: "Размывает то, что видно сквозь подложку. В видеомикшере может не сработать."),

        .init("--sl-plate-border", "Рамка подложки", group: .plate,
              kind: .number(min: 0, max: 0.8, step: 0.05, unit: "vh"),
              default: "0vh",
              hint: ""),

        .init("--sl-plate-border-color", "Цвет рамки", group: .plate,
              kind: .color, default: "#ffffff",
              hint: ""),

        .init("--sl-plate-shadow", "Тень подложки", group: .plate,
              kind: .number(min: 0, max: 5, step: 0.1, unit: "vh"),
              default: "0vh",
              hint: ""),
    ]

    // MARK: Фон

    private static let backgroundParameters: [WebSlideParameter] = [
        .init("--sl-bg-mode", "Чем залит фон", group: .background,
              kind: .choice([
                  .init("transparent", "Прозрачный, для видеомикшера",
                        implies: ["--sl-page-opacity": "0", "--sl-bg-image": "none"]),
                  .init("solid", "Однотонный",
                        implies: ["--sl-page-opacity": "1", "--sl-bg-image": "none"]),
                  .init("image", "Картинкой",
                        implies: ["--sl-page-opacity": "1"]),
                  .init("gradient", "Переходом цвета",
                        implies: ["--sl-page-opacity": "1",
                                  "--sl-bg-image": "linear-gradient(180deg, rgb(var(--sl-page-rgb)), rgb(0 0 0))"]),
              ]),
              default: "solid",
              hint: "Прозрачный в браузере выглядит белым, а в OBS или vMix — прозрачным."),

        .init("--sl-page-rgb", "Цвет фона", group: .background,
              kind: .colorRGB, default: "11 26 51",
              hint: "Тройкой чисел, потому что прозрачность фона отдельная."),

        .init("--sl-page-opacity", "Плотность фона", group: .background,
              kind: .fraction(min: 0, max: 1), default: "1",
              hint: "0 — фон прозрачный, для наложения поверх картинки камеры."),

        .init("--sl-bg-image", "Картинка фона", group: .background,
              kind: .link, default: "none",
              hint: "Ссылка вида url(\"…\"). Слово none — картинки нет."),

        .init("--sl-bg-fit", "Как вписать картинку", group: .background,
              kind: .choice([
                  .init("cover", "Заполнить экран", implies: ["--sl-bg-repeat": "no-repeat"]),
                  .init("contain", "Вписать целиком", implies: ["--sl-bg-repeat": "no-repeat"]),
                  .init("auto", "Замостить", implies: ["--sl-bg-repeat": "repeat"]),
              ]),
              default: "cover",
              hint: "«Заполнить» обрезает края, «вписать» оставляет поля."),

        .init("--sl-bg-repeat", "Повтор картинки", group: .background,
              kind: .choice([.init("no-repeat", "Без повтора"), .init("repeat", "Повторять")]),
              default: "no-repeat",
              hint: "Пишется вместе с выбором «как вписать картинку».",
              showsInPanel: false),

        .init("--sl-bg-pos", "Куда двинуть картинку", group: .background,
              kind: .choice([
                  .init("left top", "Влево вверх"),
                  .init("center top", "По центру вверх"),
                  .init("right top", "Вправо вверх"),
                  .init("left center", "Влево"),
                  .init("center center", "По центру"),
                  .init("right center", "Вправо"),
                  .init("left bottom", "Влево вниз"),
                  .init("center bottom", "По центру вниз"),
                  .init("right bottom", "Вправо вниз"),
              ]),
              default: "center center",
              hint: ""),

        .init("--sl-bg-blur", "Размытие фона", group: .background,
              kind: .number(min: 0, max: 5, step: 0.1, unit: "vh"),
              default: "0vh",
              hint: "Размытая фотография не спорит с текстом."),

        .init("--sl-dim", "Затемнение фона", group: .background,
              kind: .fraction(min: 0, max: 1), default: "0.45",
              hint: "Слой поверх картинки. 0 — картинка как есть."),

        .init("--sl-dim-rgb", "Цвет затемнения", group: .background,
              kind: .colorRGB, default: "0 0 0",
              hint: "Белый цвет даёт не затемнение, а осветление."),
    ]

    // MARK: Поява

    private static let appearParameters: [WebSlideParameter] = [
        .init("--sl-transition", "Как сменяется слайд", group: .appear,
              kind: .choice([
                  .init("none", "Без перехода"),
                  .init("fade", "Растворение"),
                  .init("slideLeft", "Сдвиг влево"),
                  .init("slideUp", "Сдвиг вверх"),
                  .init("zoom", "Наплыв"),
              ]),
              default: "fade",
              hint: "Делает скрипт самой страницы. В чужую страницу мы дописываем только оформление, поэтому на ней ручка погашена."),

        .init("--sl-fade", "Длительность перехода", group: .appear,
              kind: .number(min: 0, max: 1.5, step: 0.05, unit: "s"),
              default: "0.35s",
              hint: "Резкая подмена текста на большом экране читается как рывок."),
    ]

    // MARK: - Готовий CSS

    /// Одне оголошення — ним користується і запис у файл, і перенесення значення.
    public static func declaration(_ name: String, _ value: String) -> String {
        "\(name): \(value);"
    }

    /// Увесь набір одним правилом `:root` — тіло блоку налаштувань.
    public static func rootCSS(_ settings: WebSlideSettings, indent: String = "  ") -> String {
        var lines = [":root {"]
        for pair in settings.writingOrder {
            lines.append(indent + declaration(pair.name, pair.value))
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    /// Скрипт для живого передпоказу: та сама пачка значень, але в сторінку
    /// без перезавантаження.
    ///
    /// Інлайновий стиль на `documentElement` б'є будь-яке правило `:root` у
    /// будь-якому листі, тому живе значення завжди головніше за файл, а після
    /// перезавантаження картина сходиться — у файлі вже лежить те саме.
    public static func previewScript(_ changes: [String: String]) -> String {
        guard !changes.isEmpty else { return "" }
        var lines = ["var s = document.documentElement.style;"]
        for name in changes.keys.sorted() {
            guard let value = changes[name], isWritable(value) else { continue }
            lines.append("s.setProperty('\(escapeForScript(name))','\(escapeForScript(value))');")
        }
        // Частина ручок рахується не з CSS: добір кегля під довжину вірша,
        // лапки, переноси рядків. Сама по собі зміна змінної їх не
        // чіпає, і головний повзунок «Розмір тексту» в передпоказі
        // виглядав мертвим. Просимо сторінку перерахуватися — якщо вона вміє.
        lines.append("if (window.slovoRefresh) { try { window.slovoRefresh(); } catch (e) {} }")
        return lines.joined(separator: "\n")
    }

    private static func escapeForScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "'", with: "\\'")
    }

    // MARK: Селектори ролей

    /// Чим у сторінці дістаються ролі.
    ///
    /// Список складається один раз, коли заводиться копія, за тим, що в
    /// сторінці реально є. Тут — те, що накриває і наші заготовки, і
    /// всі шість сторінок автора; своє ім'я роль отримує атрибутом
    /// `data-slovo`, але лише якщо людина сама погодилася його поставити.
    public struct RoleSelectors: Sendable, Hashable {
        public var page: String
        public var stage: String
        public var quote: String
        public var reference: String
        public var second: String
        public var next: String
        public var number: String
        /// Чим стає сцена в сторінці, де окремого блоку під текст
        /// немає зовсім.
        ///
        /// Така сторінка в автора одна — `VBWebSlide.html`: у ній усього
        /// один `#content`, і він же текст. Без запасного правила весь розділ
        /// «Розташування» на ній мертвий: поля, зсув і перетягування мишею не
        /// роблять нічого. Сценою в цьому випадку служить саме тіло сторінки.
        public var stageFallback: String
        /// Чужі блоки, які ми впізнали за ім'ям.
        ///
        /// Їм дістається лише вигляд — колір і риска. Ні `display`, ні `order`,
        /// ні кегль: на екрані служителя автор сам добирає кегль під
        /// висоту блоку, а `display` у нього тримає обрізку трикрапкою.
        /// Відібрати в чужої сторінки те, заради чого її написано, ми не маємо права,
        /// навіть якщо повзунок від цього стане на ній бездіяльним.
        public var nextForeign: String

        public init(page: String, stage: String, quote: String, reference: String,
                    second: String, next: String, number: String,
                    stageFallback: String = "", nextForeign: String = "") {
            self.page = page
            self.stage = stage
            self.quote = quote
            self.reference = reference
            self.second = second
            self.next = next
            self.number = number
            self.stageFallback = stageFallback
            self.nextForeign = nextForeign
        }

        /// З чого зібрано запасний селектор сцени — він же список справжніх
        /// сцен. Тримаємо одним рядком, щоб список не роз'їхався надвоє.
        static let stageNames = ".slide, .strip, .stage, .background, #text-container, [data-slovo=\"stage\"]"

        public static let standard = RoleSelectors(
            page: "body",
            stage: stageNames,
            quote: ".quote, .content, #content, #content1, #content2, #text-content, [data-slovo=\"quote\"]",
            reference: ".reference, .contentTitle, [data-slovo=\"reference\"]",
            second: ".second, [data-slovo=\"second\"]",
            // `#bottom-content` тут стояв і ховав на авторському екрані
            // служителя рівно те, заради чого цей екран існує. Своїми
            // вимикачами розпоряджаємося лише своєю розміткою; чужий блок
            // із наступним віршем стоїть нижче, у `nextForeign`, і видимість
            // йому не міняється ніколи.
            next: ".next, [data-slovo=\"next\"]",
            number: ".sl-num",
            // Два запасні селектори для сторінок без сцени. `:has()` старий
            // WebKit (macOS 11, Safari 14) не знає і викидає правило
            // цілком, тому поруч — мітка, яку ставить наш скрипт.
            stageFallback: "body:not(:has(\(stageNames))), body[data-slovo-nostage]",
            nextForeign: "#bottom-container")

        /// Що з переліченого в цій розмітці і справді є.
        ///
        /// Дивимося в текст сторінки цілком, разом зі скриптами: в автора
        /// `.contentTitle` народжується рядком у `contentText +=`, і до першого
        /// слайда такого елемента в розмітці немає. Вважати роль відсутньою
        /// лише тому, що сторінка ще не отримала вірша, — значить гасити
        /// повзунки рівно там, де вони потрібні.
        public func present(in source: String) -> Set<WebSlideParameter.Role> {
            // Свої блоки знімаємо: у правилах прив'язки ці самі селектори і
            // написано, і сторінка, якій ми щойно надягли налаштування,
            // «знаходила» б у собі всі ролі разом — за нашим же текстом.
            // Ім'я `source`, а не `page`: `page` тут уже зайнято селектором
            // тіла сторінки, і тінь над ним коштувала б ролі «фон».
            let html = WebSlideParameters.stripBlocks(html: source)
            var found: Set<WebSlideParameter.Role> = []
            let pairs: [(WebSlideParameter.Role, String)] = [
                (.page, page),
                (.stage, stage + ", " + page),   // тіла сторінки досить: сцена підставиться запасним правилом
                (.quote, quote),
                (.reference, reference),
                (.second, second),
                (.next, next + (nextForeign.isEmpty ? "" : ", " + nextForeign)),
                (.nextOwn, next),
                (.number, number),
            ]
            for (role, selectors) in pairs where WebSlideParameters.markup(html, matches: selectors) {
                found.insert(role)
            }
            return found
        }
    }

    /// Чи є в розмітці хоч один елемент під цей список селекторів.
    ///
    /// Розбираємо рівно те, з чого списки й складено: `#ім'я`, `.ім'я`,
    /// `[ім'я="значення"]` і голе ім'я тега. Справжній розбір CSS тут був би
    /// не точнішим: селектори наші, інших у списках не буває.
    public static func markup(_ html: String, matches selectors: String) -> Bool {
        markup(live(html), rawMatches: selectors)
    }

    /// Сторінка без закоментованих рядків.
    ///
    /// В автора половина варіантів оформлення лежить закоментованою: у
    /// «пісенній» сторінці рядок з `class="contentTitle"` вимкнено двома
    /// скісними, і адреси на екрані не буває. Вважати такий рядок розміткою —
    /// значить обіцяти людині живий повзунок «Колір адреси» там, де адреси
    /// немає зовсім.
    private static func live(_ html: String) -> String {
        var kept: [Substring] = []
        for line in html.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let head = line.drop(while: { $0 == " " || $0 == "\t" })
            if head.hasPrefix("//") || head.hasPrefix("/*") || head.hasPrefix("*") { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    private static func markup(_ html: String, rawMatches selectors: String) -> Bool {
        for piece in selectors.split(separator: ",") {
            let one = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !one.isEmpty, !one.contains(":") else { continue }
            if one.hasPrefix("#") {
                let name = String(one.dropFirst())
                if html.range(of: "id=\"\(name)\"", options: .caseInsensitive) != nil { return true }
                if html.range(of: "id='\(name)'", options: .caseInsensitive) != nil { return true }
            } else if one.hasPrefix(".") {
                if hasClass(String(one.dropFirst()), in: html) { return true }
            } else if one.hasPrefix("[") {
                if html.range(of: one, options: .caseInsensitive) != nil { return true }
            } else if html.range(of: "<\(one)", options: .caseInsensitive) != nil {
                return true
            }
        }
        return false
    }

    /// Чи стоїть таке ім'я класу хоч в одному `class="…"`.
    ///
    /// Цілим словом, а не шматком: інакше `.content` знаходилося б усередині
    /// `contentTitle`, і роль вважалася б знайденою там, де її немає.
    private static func hasClass(_ name: String, in html: String) -> Bool {
        var search = html.startIndex..<html.endIndex
        while let hit = html.range(of: "class=", options: .caseInsensitive, range: search) {
            search = hit.upperBound..<html.endIndex
            var cursor = hit.upperBound
            while cursor < html.endIndex, html[cursor] == " " { cursor = html.index(after: cursor) }
            guard cursor < html.endIndex, html[cursor] == "\"" || html[cursor] == "'" else { continue }
            let quote = html[cursor]
            let from = html.index(after: cursor)
            guard let to = html[from...].firstIndex(of: quote) else { continue }
            if html[from..<to].split(whereSeparator: { $0 == " " || $0 == "\t" }).contains(where: { $0 == name }) {
                return true
            }
        }
        return false
    }

    /// Правила, які прикладають значення до ролей.
    ///
    /// `!important` тут не від молодецтва. У `VBWebSlide.html` фон задано просто в
    /// атрибуті `style` у `<body>`, а інлайн б'є будь-який лист стилів.
    /// Єдина альтернатива — вичистити чужий атрибут, тобто торкнути
    /// чужу розмітку. Ми свідомо псуємо каскад у файлі, який самі ж
    /// і завели, але не торкаємося жодного авторського байта.
    /// Один зв'язок: які змінні його живлять, до чого прикладається і що
    /// пише.
    ///
    /// Раніше прив'язка була одним шматком тексту і накривала сторінку цілком:
    /// шістдесят правил з `!important` поверх чужого оформлення. Людина брала
    /// сторінку за основу — і отримувала не її, а нашу перезбірку. Тепер правило
    /// пишеться лише під ту ручку, яку і справді торкнули: не торкали —
    /// сторінка лишається рівно такою, якою була.
    struct Bond {
        let names: [String]
        let selector: String
        let declaration: String
    }

    static func bonds(roles: RoleSelectors) -> [Bond] {
        let size = "calc(var(--sl-size, 6) * var(--sl-unit, 1vw))"
        let shadow = "calc(var(--sl-shadow-offset, 2.7) * 0.01em) calc(var(--sl-shadow-offset, 2.7) * 0.01em)"
            + " calc(var(--sl-shadow-blur, 7) * 0.01em)"
            + " rgb(var(--sl-shadow-rgb, 0 0 0) / calc(var(--sl-shadow-opacity, .55) * var(--sl-shadow-on, 1)))"
        // Зсув лише через translate і лише у vw/vh: відсотки в
        // translate рахуються від розміру самого блоку, і тоді вузький блок
        // відстає від миші, а широкий обганяє.
        let move = "translate(calc(var(--sl-offset-x, 0) * 1vw), calc(var(--sl-offset-y, 0) * 1vh))"
        // Розкладка сцени тримається на кількох ручках разом: торкнули будь-яку —
        // сцені потрібен флекс і висота, інакше вирівнювати буде нічого.
        let layout = ["--sl-h", "--sl-v", "--sl-second-place", "--sl-pad-x", "--sl-pad-y",
                      "--sl-safe", "--sl-ref-gap", "--sl-offset-x", "--sl-offset-y"]
        let stage = roles.stage
        let fallback = roles.stageFallback

        var bonds: [Bond] = []
        func bond(_ names: [String], _ selector: String, _ declaration: String) {
            bonds.append(Bond(names: names, selector: selector, declaration: declaration))
        }

        // Псевдоніми старих коротких імен: шість наших заготовок написано
        // проти них.
        bond(["--sl-color"], ":root", "--text: var(--sl-color);")
        bond(["--sl-ref-color"], ":root", "--accent: var(--sl-ref-color);")
        bond(["--sl-size", "--sl-unit"], ":root", "--size: \(size);")
        bond(["--sl-bg-image"], ":root", "--background: var(--sl-bg-image);")
        bond(["--sl-dim"], ":root", "--dim: var(--sl-dim);")

        // Фон сторінки
        bond(["--sl-page-rgb", "--sl-page-opacity"], roles.page,
             "background-color: rgb(var(--sl-page-rgb, 11 26 51) / var(--sl-page-opacity, 1)) !important;")
        bond(["--sl-bg-image"], roles.page, "background-image: var(--sl-bg-image) !important;")
        bond(["--sl-bg-fit"], roles.page, "background-size: var(--sl-bg-fit) !important;")
        bond(["--sl-bg-pos"], roles.page, "background-position: var(--sl-bg-pos) !important;")
        bond(["--sl-bg-repeat"], roles.page, "background-repeat: var(--sl-bg-repeat) !important;")

        // Пелена і розмиття — окремим шаром під текстом.
        let veil = ["--sl-dim", "--sl-dim-rgb", "--sl-bg-blur"]
        // Чотири сторони окремо, а не лише `inset`: Safari 14.0 (Big Sur
        // до 11.3) короткого запису не знає, і пелена там не розтягувалася.
        for declaration in ["content: \"\" !important;", "position: fixed !important;",
                            "top: 0 !important;", "right: 0 !important;",
                            "bottom: 0 !important;", "left: 0 !important;",
                            "inset: 0 !important;", "z-index: -1 !important;",
                            "pointer-events: none !important;"] {
            bond(veil, roles.page + "::before", declaration)
        }
        bond(veil, roles.page + "::before",
             "background: rgb(var(--sl-dim-rgb, 0 0 0) / var(--sl-dim, 0)) !important;")
        // Розмиття — з приставкою -webkit- і без: Safari до 18-го розуміє
        // лише приставку, решта браузерів — лише без неї.
        bond(["--sl-bg-blur"], roles.page + "::before",
             "-webkit-backdrop-filter: blur(var(--sl-bg-blur, 0px)) !important;")
        bond(["--sl-bg-blur"], roles.page + "::before",
             "backdrop-filter: blur(var(--sl-bg-blur, 0px)) !important;")

        // Сцена і її запасні види — тіла сторінки. Кожен запасний селектор
        // іде своїм правилом: список з незрозумілим браузеру селектором він
        // викинув би весь, разом зі зрозумілими.
        let fallbacks = fallback.components(separatedBy: ", ").filter { !$0.isEmpty }
        for selector in [stage] + fallbacks {
            bond(layout, selector, "display: flex !important;")
            bond(layout, selector, "min-height: 100vh !important;")
            bond(layout, selector, "flex-direction: var(--sl-second-place, column) !important;")
            bond(layout, selector, "flex-wrap: wrap !important;")
            bond(["--sl-h"], selector, "align-items: var(--sl-h, center) !important;")
            bond(["--sl-v"], selector, "justify-content: var(--sl-v, center) !important;")
            bond(["--sl-ref-gap"], selector, "gap: var(--sl-ref-gap, 1.5vh) !important;")
            bond(["--sl-pad-x", "--sl-pad-y", "--sl-safe"], selector,
                 "padding: calc(var(--sl-pad-y, 0vh) + var(--sl-safe, 0%)) calc(var(--sl-pad-x, 0vw) + var(--sl-safe, 0%)) !important;")
            bond(["--sl-offset-x", "--sl-offset-y"], selector, "transform: \(move) !important;")
        }
        bond(["--sl-text-opacity"], stage, "opacity: var(--sl-text-opacity, 1) !important;")
        bond(["--sl-plate-rgb", "--sl-plate-opacity", "--sl-plate-full"], stage,
             "background-color: rgb(var(--sl-plate-rgb, 0 0 0) / calc(var(--sl-plate-opacity, .3) * var(--sl-plate-full, 0))) !important;")

        // Текст вірша
        let quote = roles.quote
        bond(["--sl-second-display", "--sl-ref-order", "--sl-next-display"], quote, "order: 0 !important;")
        bond(["--sl-font"], quote, "font-family: var(--sl-font) !important;")
        bond(["--sl-size", "--sl-unit"], quote, "font-size: \(size) !important;")
        bond(["--sl-weight"], quote, "font-weight: var(--sl-weight) !important;")
        bond(["--sl-stretch"], quote, "font-stretch: var(--sl-stretch) !important;")
        bond(["--sl-italic"], quote, "font-style: var(--sl-italic) !important;")
        bond(["--sl-caps"], quote, "text-transform: var(--sl-caps) !important;")
        bond(["--sl-tracking"], quote, "letter-spacing: var(--sl-tracking) !important;")
        bond(["--sl-line"], quote, "line-height: var(--sl-line) !important;")
        bond(["--sl-color"], quote, "color: var(--sl-color) !important;")
        bond(["--sl-align"], quote, "text-align: var(--sl-align) !important;")
        bond(["--sl-width"], quote, "max-width: var(--sl-width) !important;")
        bond(["--sl-shadow-on", "--sl-shadow-offset", "--sl-shadow-blur",
              "--sl-shadow-opacity", "--sl-shadow-rgb"], quote, "text-shadow: \(shadow) !important;")
        bond(["--sl-stroke-on", "--sl-stroke"], quote,
             "-webkit-text-stroke-width: calc(var(--sl-stroke, .4) * var(--sl-stroke-on, 0) * 1vh) !important;")
        bond(["--sl-stroke-color", "--sl-stroke-on"], quote,
             "-webkit-text-stroke-color: var(--sl-stroke-color, #000000) !important;")
        bond(["--sl-plate-rgb", "--sl-plate-opacity", "--sl-plate-full"], quote,
             "background-color: rgb(var(--sl-plate-rgb, 0 0 0) / calc(var(--sl-plate-opacity, .3) * (1 - var(--sl-plate-full, 0)))) !important;")
        bond(["--sl-plate-pad-x", "--sl-plate-pad-y"], quote,
             "padding: var(--sl-plate-pad-y, 2vh) var(--sl-plate-pad-x, 2vw) !important;")
        // «За розміром тексту» — блок стискається до рядків; «смугою» — не вужче
        // за всю ширину. Одним CSS без розгалужень: мінімальна ширина — частка
        // від вибору, а сама ширина завжди за вмістом.
        bond(["--sl-plate-full"], quote, "width: fit-content !important;")
        bond(["--sl-plate-full"], quote, "box-sizing: border-box !important;")
        bond(["--sl-plate-full"], quote,
             "min-width: calc(var(--sl-plate-full, 0) * 100%) !important;")
        bond(["--sl-plate-radius"], quote, "border-radius: var(--sl-plate-radius) !important;")
        bond(["--sl-plate-border", "--sl-plate-border-color"], quote,
             "border: var(--sl-plate-border, 0) solid var(--sl-plate-border-color, #ffffff) !important;")
        bond(["--sl-plate-shadow"], quote,
             "box-shadow: 0 var(--sl-plate-shadow) calc(var(--sl-plate-shadow) * 2) rgb(0 0 0 / .45) !important;")
        bond(["--sl-plate-blur"], quote, "-webkit-backdrop-filter: blur(var(--sl-plate-blur)) !important;")
        bond(["--sl-plate-blur"], quote, "backdrop-filter: blur(var(--sl-plate-blur)) !important;")
        // Тривалість переходу пишеться лише тоді, коли її торкнули. Поки
        // вона стояла в прив'язці завжди, наша третина секунди лягала поверх
        // чужого скрипту зміни слайда, і старий текст устигав побути на
        // екрані разом із новим.
        bond(["--sl-fade"], quote, "transition-duration: var(--sl-fade) !important;")
        // Поява і зникнення: у тексту і в підкладки свої ефекти.
        bond(["--sl-anim-in", "--sl-fade"], quote,
             "animation: var(--sl-anim-in, none) var(--sl-fade, .35s) ease both !important;")
        bond(["--sl-anim-out"], quote + ".uhodit",
             "animation: var(--sl-anim-out, none) var(--sl-fade, .35s) ease both !important;")
        bond(["--sl-plate-in", "--sl-fade"], stage,
             "animation: var(--sl-plate-in, none) var(--sl-fade, .35s) ease both !important;")
        bond(["--sl-plate-out"], stage + ".uhodit",
             "animation: var(--sl-plate-out, none) var(--sl-fade, .35s) ease both !important;")

        // Другий переклад
        let second = roles.second
        bond(["--sl-second-display"], second, "order: 1 !important;")
        bond(["--sl-second-display"], second, "display: var(--sl-second-display) !important;")
        bond(["--sl-second-size"], second, "font-size: calc(\(size) * var(--sl-second-size)) !important;")
        bond(["--sl-second-color"], second, "color: var(--sl-second-color) !important;")
        bond(["--sl-second-italic"], second, "font-style: var(--sl-second-italic) !important;")
        bond(["--sl-line"], second, "line-height: var(--sl-line) !important;")
        bond(["--sl-width"], second, "max-width: var(--sl-width) !important;")

        // Адреса
        let reference = roles.reference
        bond(["--sl-ref-order"], reference, "order: var(--sl-ref-order) !important;")
        bond(["--sl-ref-self"], reference, "align-self: var(--sl-ref-self) !important;")
        bond(["--sl-ref-display"], reference, "display: var(--sl-ref-display) !important;")
        bond(["--sl-ref-size"], reference, "font-size: calc(\(size) * var(--sl-ref-size)) !important;")
        bond(["--sl-ref-color"], reference, "color: var(--sl-ref-color) !important;")
        bond(["--sl-ref-italic"], reference, "font-style: var(--sl-ref-italic) !important;")
        bond(["--sl-ref-gap"], reference, "margin-top: var(--sl-ref-gap) !important;")

        // Наступний вірш — свій і чужий
        let next = roles.next
        bond(["--sl-next-display"], next, "order: 3 !important;")
        bond(["--sl-next-display"], next, "display: var(--sl-next-display) !important;")
        bond(["--sl-next-size"], next, "font-size: calc(\(size) * var(--sl-next-size)) !important;")
        bond(["--sl-next-color"], next, "color: var(--sl-next-color) !important;")
        bond(["--sl-next-rule", "--sl-next-color"], next,
             "border-top: var(--sl-next-rule, 0) solid var(--sl-next-color, #7f8fa6) !important;")
        if !roles.nextForeign.isEmpty {
            // Чужому блоку — лише колір і риска: кегль автор добирає сам,
            // а `display` у нього тримає обрізку трикрапкою.
            bond(["--sl-next-color"], roles.nextForeign, "color: var(--sl-next-color) !important;")
            bond(["--sl-next-rule", "--sl-next-color"], roles.nextForeign,
                 "border-top: var(--sl-next-rule, 0) solid var(--sl-next-color, #7f8fa6) !important;")
        }

        // Номери віршів
        let number = roles.number
        bond(["--sl-num-display"], number, "display: var(--sl-num-display) !important;")
        bond(["--sl-num-size"], number, "font-size: calc(1em * var(--sl-num-size)) !important;")
        bond(["--sl-num-color"], number, "color: var(--sl-num-color) !important;")
        bond(["--sl-num-display", "--sl-num-size"], number, "vertical-align: super !important;")
        return bonds
    }

    /// Правила, які прикладають значення до ролей.
    ///
    /// `only` — ті змінні, що й справді записані в сторінці. Усе
    /// інше не пишеться зовсім: чужа сторінка зобов'язана лишитися собою.
    /// `nil` — писати все (наші заготовки, де ручки оголошено заздалегідь).
    public static func bindingCSS(roles: RoleSelectors = .standard,
                                  only: Set<String>? = nil) -> String {
        var order: [String] = []
        var rules: [String: [String]] = [:]
        for bond in bonds(roles: roles) {
            if let only, !bond.names.contains(where: only.contains) { continue }
            if rules[bond.selector] == nil { order.append(bond.selector); rules[bond.selector] = [] }
            rules[bond.selector]?.append(bond.declaration)
        }
        guard !order.isEmpty else {
            return OurWords.t("/* Ничего не правили — страница осталась собой. */")
        }
        return order.map { selector in
            "\(selector) {\n  " + (rules[selector] ?? []).joined(separator: "\n  ") + "\n}"
        }.joined(separator: "\n")
    }

    // MARK: - Блоки цілком

    /// Блок значень — те, що переписується на кожен рух повзунка.
    public static func varsElement(_ settings: WebSlideSettings) -> String {
        """
        <style \(varsAttribute)>
        /* \(varsMarker) v\(version) ────────────────────────────────────
           \(OurWords.t("Эти строки пишет редактор, когда двигают ползунки."))
           \(OurWords.t("Править руками можно, но пишите строго по одной «--имя: значение;»."))
           \(OurWords.t("Всё прочее внутри блока редактор сотрёт при следующей правке.")) */
        \(rootCSS(settings))
        /* \(varsEndMarker) */
        </style>
        """
    }

    /// Живі налаштування: сторінка слухає ті самі кадри, що й текст слайда, і
    /// застосовує надіслані змінні тут же.
    ///
    /// Без цього правка повзунка доходила до залу лише після перезавантаження
    /// сторінки в браузері — а сторінка зазвичай відкрита в OBS, і чіпати її під
    /// час служіння ніхто не стане. Тепер оператор рухає повзунок і
    /// одразу бачить підсумок на трансляції.
    ///
    /// Порт пишемо той самий, що й автор у своїх сторінках: сервер підміняє його
    /// на справжній при віддачі файла.
    public static func liveElement() -> String {
        """
        <script \(liveAttribute)>
        /* \(liveMarker) v\(version) ── \(OurWords.t("редактор переписывает блок целиком")) ── */
        (function () {
          /* У вікні передпоказу з'єднання підмінено: там свій WebSocket,
             и он отдаёт слайд ТОМУ, кто подключился последним. Наш второй
             сокет перехватывал этот слайд у самой страницы, и предпросмотр
             оставался пустым. В предпросмотре живые настройки не нужны —
             редактор кладёт их напрямую, — поэтому там мы молчим. */
          /* Сторінка без сцени: позначаємо тіло, і правила сцени лягають на
             него. Старый WebKit не понимает :has(), а метку понимает любой. */
          try {
            if (!document.querySelector(\(jsQuoted(RoleSelectors.stageNames)))) {
              document.body.setAttribute("data-slovo-nostage", "");
            }
          } catch (e) {}
          if (window.slovoPreview) return;
          function connect() {
            var socket;
            try { socket = new WebSocket("ws://" + location.hostname + ":8100/ws"); }
            catch (e) { return; }
            socket.onmessage = function (event) {
              var data;
              try { data = JSON.parse(event.data); } catch (e) { return; }
              var vars = data && data.SlovoVars;
              if (!vars) return;
              for (var name in vars) {
                if (name.indexOf("--sl-") === 0) {
                  document.documentElement.style.setProperty(name, vars[name]);
                }
              }
            };
            socket.onclose = function () { setTimeout(connect, 2000); };
          }
          /* Підключаємося після самої сторінки: хай її з'єднання буде
             первым, а наше — вторым. */
          if (document.readyState === "complete") { setTimeout(connect, 300); }
          else { window.addEventListener("load", function () { setTimeout(connect, 300); }); }
        })();
        /* \(liveEndMarker) */
        </script>
        """
    }

    /// Рядок у лапках для JavaScript.
    private static func jsQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Блок прив'язки — переписується лише при зміні версії програми,
    /// але ніколи при русі повзунка.
    public static func bindElement(roles: RoleSelectors = .standard,
                                   only: Set<String>? = nil) -> String {
        """
        <style \(bindAttribute)>
        /* \(bindMarker) v\(version) ── \(OurWords.t("редактор переписывает блок целиком")) ── */
        \(bindingCSS(roles: roles, only: only))
        /* \(bindEndMarker) */
        </style>
        """
    }

    // MARK: - Придатність значення до запису

    /// Що у значенні означає біду.
    ///
    /// Крапка з комою і фігурна дужка обривають оголошення, кутові дужки
    /// закривають `<style>` — адреса картинки з лапкою і `</style>` усередині
    /// зламала б сторінку цілком. Пара `/*` уміє закоментувати решту
    /// блоку. Усе інше — включно з двокрапкою, без якої не буває адреси
    /// `https://`, — дозволено: білий список із самих латинських літер відкинув би
    /// і звичайне посилання, і ім'я шрифту кирилицею.
    public static func isWritable(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        for character in value {
            if character.isNewline { return false }
            if ";{}<>\\".contains(character) { return false }
        }
        if value.contains("/*") || value.contains("*/") { return false }
        return true
    }

    /// Ім'я змінної: `--` і далі літери, цифри, дефіс, підкреслення.
    public static func isVariableName(_ name: String) -> Bool {
        guard name.hasPrefix("--"), name.count > 2, name.count <= 80 else { return false }
        return name.dropFirst(2).allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    // MARK: - Розбір

    public static func parse(html: String) -> WebSlideDocument {
        let ends = newline(of: html)
        let head = html.range(of: "</head>", options: [.caseInsensitive]) != nil
        let bindFound = !elements(in: html, attribute: bindAttribute).isEmpty

        let varsElements = elements(in: html, attribute: varsAttribute)
        var inner: Range<String.Index>?
        var whole: Range<String.Index>?
        var extras = 0
        var damage: String?

        if let last = varsElements.last {
            // Кілька блоків — працює останній: він перемагає за порядком
            // у каскаді, а отже саме його людина й бачить на екрані.
            inner = last.inner
            whole = last.element
            extras = varsElements.count - 1
        } else if html.range(of: varsAttribute) != nil {
            damage = OurWords.t("открывающая метка есть, а закрывающего </style> нет")
        } else if let markerStart = markerRange(varsMarkers, in: html, options: [.backwards]) {
            // Людина могла винести блок зі <style> — шукаємо за самою міткою.
            if let markerEnd = markerRange(varsEndMarkers, in: html,
                                           range: markerStart.upperBound..<html.endIndex) {
                inner = markerStart.upperBound..<markerEnd.lowerBound
                whole = lineStart(html, markerStart.lowerBound)..<markerEnd.upperBound
            } else {
                damage = OurWords.t("нет метки «%s»", "\(varsEndMarker)")
            }
        }

        if let reason = damage {
            return WebSlideDocument(block: .damaged(reason: reason),
                                    settings: WebSlideSettings(),
                                    hasHead: head,
                                    hasBinding: bindFound,
                                    outsideNames: [],
                                    newline: ends)
        }

        guard let innerRange = inner, let wholeRange = whole else {
            return WebSlideDocument(block: .missing,
                                    settings: WebSlideSettings(),
                                    hasHead: head,
                                    hasBinding: bindFound,
                                    outsideNames: outsideNames(html, skipping: []),
                                    newline: ends)
        }

        let settings = declarations(in: html[innerRange])
        let version = readVersion(html[innerRange]) ?? self.version
        let skip = elements(in: html, attribute: bindAttribute).map { $0.element } + [wholeRange]

        return WebSlideDocument(block: .present(version: version, extras: extras),
                                settings: settings,
                                hasHead: head,
                                hasBinding: bindFound,
                                outsideNames: outsideNames(html, skipping: skip),
                                newline: ends)
    }

    /// Що сторінка задає сама — хоч би де оголошення в ній лежали.
    ///
    /// Потрібно там, де блоку налаштувань ще немає. Сторінка все одно живе за
    /// якимись значеннями, і вони записані в ній самій; брати замість них
    /// заводські — значить міняти вигляд сторінки в ту мить, коли людина всього
    /// лише зробила копію або торкнула перший повзунок. Раніше виходило саме
    /// так: копія відкривалася з чужими числами і переставала бути схожою на
    /// ту сторінку, з якої її зняли.
    public static func declared(in html: String) -> WebSlideSettings {
        declarations(in: html[html.startIndex...])
    }

    /// Рядки-налаштування з тіла блоку.
    ///
    /// Визнається лише «--ім'я: значення;» цілим рядком. Коментарі,
    /// вкладені правила і сміття пропускаються мовчки: блок усе одно
    /// збирається заново, і про це прямо написано в самому блоці.
    private static func declarations(in text: Substring) -> WebSlideSettings {
        var settings = WebSlideSettings()
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--"), trimmed.hasSuffix(";") else { continue }
            let body = trimmed.dropLast()
            guard let colon = body.firstIndex(of: ":") else { continue }
            let name = String(body[body.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard isVariableName(name), isWritable(value) else { continue }
            settings.set(name, value)
        }
        return settings
    }

    private static func readVersion(_ text: Substring) -> Int? {
        guard let marker = markerRange(varsMarkers, in: text) else { return nil }
        var rest = text[marker.upperBound...].drop(while: { $0 == " " })
        guard rest.first == "v" else { return nil }
        rest = rest.dropFirst()
        let digits = rest.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Наші змінні, знайдені поза блоком: людина правила файл руками.
    private static func outsideNames(_ html: String, skipping: [Range<String.Index>]) -> [String] {
        var found: [String] = []
        var search = html.startIndex..<html.endIndex
        while let hit = html.range(of: "--sl-", range: search) {
            search = hit.upperBound..<html.endIndex
            if skipping.contains(where: { $0.contains(hit.lowerBound) }) { continue }
            // `var(--sl-…)` у блоці прив'язки — не правка, а його робота.
            let tail = html[hit.upperBound...].prefix(while: {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            })
            let after = html[hit.upperBound...].dropFirst(tail.count).drop(while: { $0 == " " })
            guard after.first == ":" else { continue }
            let name = "--sl-" + tail
            if !found.contains(name) { found.append(name) }
        }
        return found
    }

    // MARK: - Запис

    /// Записати налаштування в сторінку.
    ///
    /// Замінюється рівно відрізок між мітками; усе за його межами навіть не
    /// читається — файл збирається як «початок + новий блок + кінець». Тому
    /// жодного пошуку і заміни окремих оголошень у чужому CSS тут немає і
    /// бути не може.
    public static func write(html: String,
                             settings: WebSlideSettings,
                             roles: RoleSelectors = .standard) -> WebSlideWriteOutcome {
        for pair in settings.writingOrder where !isWritable(pair.value) {
            let title = parameter(named: pair.name)?.title ?? pair.name
            return .refused("Значение «\(title)» записать нельзя: в нём есть знак, "
                            + "который оборвал бы правило и сломал страницу.")
        }

        let document = parse(html: html)
        if case .damaged(let reason) = document.block {
            return .refused(OurWords.t("Блок настроек повреждён (%s). Нажмите «Переписать блок заново», если готовы потерять его нынешнее содержимое.", "\(reason)"))
        }

        let ends = document.newline
        var result = html

        // Кожен блок шукається заново за вже зміненим рядком: тримати
        // діапазони, отримані до правки, не можна — після першої ж заміни
        // вони вказують не туди.
        if let bind = elements(in: result, attribute: bindAttribute).last {
            let indent = indentation(result, before: bind.element.lowerBound)
            result.replaceSubrange(bind.element, with: reindent(bindElement(roles: roles, only: Set(settings.names)), indent: indent, newline: ends))
        }

        // Зайві копії живого блоку прибираємо з кінця: їх міг наплодити
        // попередній випуск, що не вмів його знаходити.
        while elements(in: result, attribute: liveAttribute, tag: "script").count > 1,
              let extra = elements(in: result, attribute: liveAttribute, tag: "script").first {
            result.removeSubrange(extra.element)
        }
        if let live = elements(in: result, attribute: liveAttribute, tag: "script").last {
            let indent = indentation(result, before: live.element.lowerBound)
            result.replaceSubrange(live.element, with: reindent(liveElement(), indent: indent, newline: ends))
        } else if let bind = elements(in: result, attribute: bindAttribute).last {
            let indent = indentation(result, before: bind.element.lowerBound)
            let text = ends + indent + reindent(liveElement(), indent: indent, newline: ends)
            result.insert(contentsOf: text, at: bind.element.upperBound)
        }

        if let vars = elements(in: result, attribute: varsAttribute).last {
            let indent = indentation(result, before: vars.element.lowerBound)
            result.replaceSubrange(vars.element, with: reindent(varsElement(settings), indent: indent, newline: ends))
            if elements(in: result, attribute: bindAttribute).isEmpty,
               let again = elements(in: result, attribute: varsAttribute).last {
                let text = ends + indent + reindent(bindElement(roles: roles, only: Set(settings.names)), indent: indent, newline: ends)
                    + ends + indent + reindent(liveElement(), indent: indent, newline: ends)
                result.insert(contentsOf: text, at: again.element.upperBound)
            }
            return .written(result)
        }

        // Блоку немає — заводимо обидва перед </head>, нічого не чіпаючи.
        guard let head = result.range(of: "</head>", options: [.caseInsensitive]) else {
            return .refused(OurWords.t("Это не целая страница: в ней нет </head>, вставлять настройки некуда."))
        }
        let point = lineStart(result, head.lowerBound)
        let indent = indentation(result, before: head.lowerBound)
        let text = indent + reindent(varsElement(settings), indent: indent, newline: ends) + ends
            + indent + reindent(bindElement(roles: roles, only: Set(settings.names)), indent: indent, newline: ends) + ends
            + indent + reindent(liveElement(), indent: indent, newline: ends) + ends
        result.insert(contentsOf: text, at: point)
        return .written(result)
    }

    /// Переписати пошкоджений блок заново — лише по кнопці.
    ///
    /// Замінюється від відкривального тега до найближчого наступного `</style>`.
    /// Якщо закривального тега немає зовсім, межею служить `</head>` або
    /// `<body`: далі цього місця вже починається розмітка, і вирізати її
    /// не можна за жодного пошкодження блоку.
    public static func repair(html: String,
                              settings: WebSlideSettings,
                              roles: RoleSelectors = .standard) -> WebSlideWriteOutcome {
        let start = html.range(of: varsAttribute) ?? markerRange(varsMarkers, in: html)
        guard let marker = start else {
            return write(html: html, settings: settings, roles: roles)
        }
        guard let open = html.range(of: "<style", options: [.caseInsensitive, .backwards],
                                    range: html.startIndex..<marker.lowerBound) else {
            return .refused("Метка настроек лежит вне <style> — перепишите блок вручную.")
        }

        let tail = marker.upperBound..<html.endIndex
        var cut: Range<String.Index>?
        if let close = html.range(of: styleClose, options: [.caseInsensitive], range: tail) {
            cut = open.lowerBound..<close.upperBound
        } else {
            let stops = [html.range(of: "</head>", options: [.caseInsensitive], range: tail),
                         html.range(of: "<body", options: [.caseInsensitive], range: tail)]
            if let stop = stops.compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) {
                cut = open.lowerBound..<stop.lowerBound
            }
        }
        guard let range = cut else {
            return .refused(OurWords.t("Блок настроек не закрыт, а конца головы страницы в файле нет — вырезать наугад нельзя."))
        }

        let ends = newline(of: html)
        let indent = indentation(html, before: open.lowerBound)
        var result = html
        result.replaceSubrange(range, with: reindent(varsElement(settings), indent: indent, newline: ends) + ends)
        return write(html: result, settings: settings, roles: roles)
    }

    /// Прибрати обидва наші блоки — тим самим слідом, яким вони вставлялися.
    ///
    /// Потрібно самоперевірці: сторінка автора після запису і зняття блоків
    /// зобов'язана збігтися з вихідною побайтно. Якщо не збіглася — ми торкнули
    /// чужу розмітку, і це помилка, а не дрібниця оформлення.
    public static func stripBlocks(html: String) -> String {
        var result = html
        for (attribute, tag) in [(bindAttribute, "style"), (varsAttribute, "style"), (liveAttribute, "script")] {
            while let element = elements(in: result, attribute: attribute, tag: tag).last {
                var from = element.element.lowerBound
                var to = element.element.upperBound
                let start = lineStart(result, from)
                if result[start..<from].allSatisfy({ $0 == " " || $0 == "\t" }) { from = start }
                if let next = result[to...].first, next.isNewline {
                    to = result.index(after: to)
                }
                result.removeSubrange(from..<to)
            }
        }
        return result
    }

    /// Розмітка без значень — за нею передпоказ вирішує, перезавантажуватися чи
    /// обійтися підстановкою змінних.
    ///
    /// Поки цей рядок не змінився, сторінку перезавантажувати нема чого: усе
    /// інше доїжджає через `setProperty`, і передпоказ не блимає.
    public static func structure(html: String) -> String {
        // Діапазони переводимо у зсуви і вичищаємо з кінця: тримати індекси
        // рядка через його ж правку не можна, а порожній блок знаходився б знову і
        // знову — цикл за «поки знаходиться» тут зациклився б назавжди.
        let places = elements(in: html, attribute: varsAttribute).map {
            (html.distance(from: html.startIndex, to: $0.inner.lowerBound),
             html.distance(from: html.startIndex, to: $0.inner.upperBound))
        }
        var result = html
        for (from, to) in places.reversed() where to > from {
            let low = result.index(result.startIndex, offsetBy: from)
            let high = result.index(result.startIndex, offsetBy: to)
            result.replaceSubrange(low..<high, with: "")
        }
        return result
    }

    // MARK: - Дрібна робота з рядком

    /// Перенос рядка цього файла: у сторінок автора CRLF, у наших LF.
    ///
    /// Записати свій блок з чужими переносами рядка — значить переписати
    /// файл цілком в очах будь-якої системи контролю версій і будь-якого diff.
    public static func newline(of text: String) -> String {
        var crlf = 0
        var lf = 0
        for character in text where character.isNewline {
            if character == "\r\n" { crlf += 1 } else { lf += 1 }
        }
        return crlf > lf ? "\r\n" : "\n"
    }

    private static func lineStart(_ text: String, _ index: String.Index) -> String.Index {
        var current = index
        while current > text.startIndex {
            let previous = text.index(before: current)
            if text[previous].isNewline { return current }
            current = previous
        }
        return text.startIndex
    }

    private static func indentation(_ text: String, before index: String.Index) -> String {
        let start = lineStart(text, index)
        let prefix = text[start..<index]
        return prefix.allSatisfy { $0 == " " || $0 == "\t" } ? String(prefix) : ""
    }

    /// Блок написано з переносами рядка LF і без відступу — приводимо до файла.
    ///
    /// Перший рядок відступу не отримує: він стає туди, де відступ уже
    /// є — на місце колишнього блоку або перед `</head>`.
    private static func reindent(_ block: String, indent: String, newline ends: String) -> String {
        let lines = block.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return lines.enumerated()
            .map { $0.offset == 0 || $0.element.isEmpty ? String($0.element) : indent + $0.element }
            .joined(separator: ends)
    }

    /// Усі елементи `<style …атрибут…>…</style>` по порядку.
    /// Наші блоки в сторінці. `tag` — бо блоків стало два види:
    /// стилі і скрипт живих налаштувань. Поки тут було зашито `<style>`, скрипт
    /// не знаходився, і кожен запис додавав у сторінку ще один його
    /// список: в одному файлі їх набралося сім.
    private static func elements(in html: String,
                                 attribute: String,
                                 tag: String = "style") -> [(element: Range<String.Index>, inner: Range<String.Index>)] {
        let opening = "<" + tag
        let closing = "</" + tag + ">"
        var result: [(Range<String.Index>, Range<String.Index>)] = []
        var search = html.startIndex..<html.endIndex
        while let hit = html.range(of: attribute, options: [.caseInsensitive], range: search) {
            search = hit.upperBound..<html.endIndex
            guard let open = html.range(of: opening, options: [.caseInsensitive, .backwards],
                                        range: html.startIndex..<hit.lowerBound) else { continue }
            // Між початком тега і атрибутом не має бути кінця тега:
            // інакше ми знайшли атрибут у чужому тексті, а не у відкривальному тезі.
            if html.range(of: closing, options: [.caseInsensitive],
                          range: open.upperBound..<hit.lowerBound) != nil { continue }
            guard let close = html.range(of: ">", range: hit.upperBound..<html.endIndex) else { continue }
            // Від атрибута до кінця тега не має починатися нового тега:
            // інакше атрибут трапився в чужому тексті, а не у відкривальному тезі.
            if close.lowerBound > hit.upperBound,
               html.range(of: "<", range: hit.upperBound..<close.lowerBound) != nil { continue }
            guard let end = html.range(of: closing, options: [.caseInsensitive],
                                       range: close.upperBound..<html.endIndex) else { continue }
            result.append((open.lowerBound..<end.upperBound, close.upperBound..<end.lowerBound))
            search = end.upperBound..<html.endIndex
        }
        return result
    }

    // MARK: Розбір значень

    static func isHexColor(_ value: String) -> Bool {
        guard value.hasPrefix("#") else { return false }
        let digits = value.dropFirst()
        guard [3, 4, 6, 8].contains(digits.count) else { return false }
        return digits.allSatisfy { $0.isHexDigit }
    }

    static func isColorTriple(_ value: String) -> Bool {
        let parts = value.split(separator: " ").filter { !$0.isEmpty }
        guard parts.count == 3 else { return false }
        return parts.allSatisfy {
            guard let number = Double($0) else { return false }
            return number >= 0 && number <= 255
        }
    }

    static func number(_ value: String, unit: String) -> Double? {
        if unit.isEmpty { return Double(value) }
        guard value.hasSuffix(unit) else { return nil }
        return Double(value.dropLast(unit.count))
    }

    /// Число в текст без хвостових нулів.
    static func digits(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 {
            return String(Int(value.rounded()))
        }
        return String(format: "%g", value)
    }
}
