import Foundation
import CoreGraphics
import SlovoCore

/// Ручки оформления — общий язык панели.
///
/// Страницы веб-слайдов хранят оформление двумя разными способами, и оба
/// живут: наши десять заготовок держат значения в собственном блоке
/// «Настройки страницы», а на любую другую страницу — в том числе на чужую
/// из комплекта программы — редактор надевает блоки `Слово: настройки` и
/// `Слово: привязка` из `WebSlideParameters`. Способы придуманы под разные
/// задачи и оба нужны: свой блок читается человеком и не спорит с каскадом
/// заготовки, чужой — приделывается к странице, устройства которой мы не
/// знаем.
///
/// Панель об этом различии знать не должна: ползунок есть ползунок. Поэтому
/// оба каталога приводятся здесь к одному виду `WebSlideKnob`, а разница
/// прячется в `WebSlideSheet` — он же умеет прочитать значения из страницы и
/// записать их обратно.

// MARK: - Раздел панели

/// Раздел панели оформления.
///
/// Разделов пять, и они одни и те же для страниц обоих устройств: человек,
/// открыв соседнюю страницу, не должен искать знакомый ползунок заново.
/// Внутри раздела ручки идут подзаголовками того каталога, откуда взяты, —
/// «Адрес», «Обводка и тень» и прочие остаются на виду.
enum WebSlideSection: String, CaseIterable, Identifiable, Hashable {
    case content, text, layout, background, behaviour

    var id: String { rawValue }

    var title: String {
        switch self {
        case .content:    return OurWords.t("Что показывать")
        case .text:       return OurWords.t("Текст")
        case .layout:     return OurWords.t("Расположение")
        case .background: return OurWords.t("Фон и прозрачность")
        case .behaviour:  return OurWords.t("Поведение")
        }
    }

    var icon: String {
        switch self {
        case .content:    return "list.bullet.rectangle"
        case .text:       return "textformat"
        case .layout:     return "square.grid.3x3"
        case .background: return "photo"
        case .behaviour:  return "wand.and.rays"
        }
    }

    /// В какой раздел ложится группа каталога.
    ///
    /// Возвращает пустоту у незнакомой группы намеренно: самопроверка
    /// требует, чтобы каждая группа обоих каталогов была разложена явно.
    /// Молчаливая свалка «прочее» скрыла бы новую группу, добавленную в
    /// каталог, и её ручки тихо оказались бы не там, где их ищут.
    static func of(group: String) -> WebSlideSection? {
        switch group {
        case "Содержимое", "Адрес", "Второй перевод", "Следующий стих", "Номера стихов":
            return .content
        case "Шрифт", "Текст", "Обводка и тень":
            return .text
        case "Расположение":
            return .layout
        case "Фон", "Фон страницы", "Подложка под текстом":
            return .background
        case "Поведение", "Появление слайда":
            return .behaviour
        default:
            return nil
        }
    }
}

// MARK: - Одна ручка

/// Ручка оформления в том виде, в каком её показывает панель.
struct WebSlideKnob: Identifiable, Hashable {

    struct Choice: Hashable {
        let value: String
        let title: String
    }

    enum Kind: Hashable {
        /// Ползунок. Единица дописывается к числу при записи: у заготовок
        /// она пустая (число голое), у общего каталога бывает «vw», «vh», «%».
        case number(min: Double, max: Double, step: Double, unit: String)
        case color
        case colorRGB
        case choice([Choice])
        case toggle(on: String, off: String, onTitle: String, offTitle: String)
        /// Строка: ссылка на картинку, разделитель, надпись заставки.
        case text
    }

    let name: String
    let title: String
    /// Подзаголовок внутри раздела — название группы в исходном каталоге.
    let group: String
    let section: WebSlideSection
    let hint: String
    let kind: Kind

    var id: String { name }

    // MARK: Значение туда и обратно

    /// Понимает ли ручка это значение.
    ///
    /// Непонятное значение — не беда: человек мог вписать в блок своё. Панель
    /// такую ручку гасит и показывает сырую строку, но из файла её не трёт.
    func understands(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard WebSlideParameters.isWritable(value) else { return false }
        switch kind {
        case .number:
            return number(from: value) != nil
        case .color:
            return WebSlideKnob.isHexColor(value)
        case .colorRGB:
            return WebSlideKnob.isColorTriple(value)
        case .choice(let list):
            return list.contains { $0.value == value }
        case .toggle(let on, let off, _, _):
            return value == on || value == off
        case .text:
            return true
        }
    }

    func number(from raw: String) -> Double? {
        guard case .number(_, _, _, let unit) = kind else { return nil }
        let value = raw.trimmingCharacters(in: .whitespaces)
        if unit.isEmpty { return Double(value) }
        guard value.hasSuffix(unit) else { return Double(value) }
        return Double(value.dropLast(unit.count))
    }

    func text(from value: Double) -> String {
        guard case .number(_, _, _, let unit) = kind else { return "" }
        return WebSlideKnob.digits(clamped(value)) + unit
    }

    func clamped(_ value: Double) -> Double {
        guard case .number(let low, let high, _, _) = kind else { return value }
        return min(max(value, low), high)
    }

    /// Ползунок без значения в файле должен на чём-то стоять.
    var fallbackNumber: Double {
        guard case .number(let low, let high, _, _) = kind else { return 0 }
        return low <= 0 && high >= 0 ? 0 : low
    }

    // MARK: Разбор строк

    /// Число в текст без хвостовых нулей: человек читает блок глазами, и
    /// «6.0» он прочтёт как «программа насорила».
    static func digits(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 {
            return String(Int(value.rounded()))
        }
        return String(format: "%g", value)
    }

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
}

// MARK: - Перевод каталогов

extension WebSlideKnob {

    /// Ручка заготовки.
    init(_ parameter: WebSlideTemplates.Parameter) {
        let kind: Kind
        switch parameter.kind {
        case .number(let low, let high, let step):
            kind = .number(min: low, max: high, step: step, unit: "")
        case .color:
            kind = .color
        case .colorRGB:
            kind = .colorRGB
        case .choice(let options):
            kind = .choice(options.map { Choice(value: $0.value, title: $0.label) })
        case .toggle(let on, let off):
            // У заготовок подписи выключателя не заданы: они всюду означают
            // «показывать» или «нет», и придумывать им отдельные слова не о чем.
            kind = .toggle(on: on, off: off, onTitle: OurWords.t("Да"), offTitle: OurWords.t("Нет"))
        case .text:
            kind = .text
        }
        self.init(name: parameter.id,
                  title: parameter.label,
                  group: parameter.group,
                  section: WebSlideSection.of(group: parameter.group) ?? .behaviour,
                  hint: parameter.hint,
                  kind: kind)
    }

    /// Ручка общего каталога.
    init(_ parameter: WebSlideParameter) {
        let kind: Kind
        switch parameter.kind {
        case .number(let low, let high, let step, let unit):
            kind = .number(min: low, max: high, step: step, unit: unit)
        case .fraction(let low, let high):
            kind = .number(min: low, max: high, step: 0.05, unit: "")
        case .color:
            kind = .color
        case .colorRGB:
            kind = .colorRGB
        case .choice(let options):
            kind = .choice(options.map { Choice(value: $0.value, title: $0.title) })
        case .toggle(let on, let off, let onTitle, let offTitle):
            kind = .toggle(on: on, off: off, onTitle: onTitle, offTitle: offTitle)
        case .link:
            kind = .text
        }
        self.init(name: parameter.name,
                  title: parameter.title,
                  group: parameter.group.title,
                  section: WebSlideSection.of(group: parameter.group.key) ?? .behaviour,
                  hint: parameter.hint,
                  kind: kind)
    }
}

// MARK: - Перетаскивание

/// Чем в этой странице двигается блок текста.
///
/// Имена разные у двух устройств, и панель их не знает: она спрашивает
/// «можно ли тащить» и отдаёт долю от ширины и высоты кадра.
struct WebSlidePlacement: Hashable {
    /// Прижим по горизонтали и вертикали — у заготовок это две отдельные ручки.
    var horizontal: String? = nil
    var vertical: String? = nil
    /// Одна ручка на девять точек — так устроен общий каталог.
    var anchor: String? = nil
    /// Тонкий сдвиг сверх точки привязки, в сотых долях кадра.
    var offsetX: String? = nil
    var offsetY: String? = nil

    var canDrag: Bool {
        anchor != nil || (horizontal != nil && vertical != nil)
    }

    static let none = WebSlidePlacement()

    /// Девять точек: доля ширины и высоты кадра.
    static func fraction(column: Int, row: Int) -> CGPoint {
        CGPoint(x: [0.0, 0.5, 1.0][min(max(column, 0), 2)],
                y: [0.0, 0.5, 1.0][min(max(row, 0), 2)])
    }

    /// Куда встанет блок, если отпустить мышь в этой точке кадра.
    ///
    /// Точка привязки выбирается ближайшая — так текст попадает ровно в край
    /// или ровно в середину, а не «почти». Остаток уходит в тонкий сдвиг, и
    /// маленький остаток гасится: иначе после перетаскивания в углу
    /// оставалось бы `-0.5vw`, которого никто не просил.
    static func drop(at point: CGPoint) -> (column: Int, row: Int, offsetX: Double, offsetY: Double) {
        let column = nearest(point.x)
        let row = nearest(point.y)
        let base = fraction(column: column, row: row)
        return (column, row, snap((point.x - base.x) * 100), snap((point.y - base.y) * 100))
    }

    private static func nearest(_ value: Double) -> Int {
        if value < 0.25 { return 0 }
        if value < 0.75 { return 1 }
        return 2
    }

    /// Остаток меньше двух с половиной сотых кадра считаем попаданием.
    private static func snap(_ value: Double) -> Double {
        let limited = min(max(value, -40), 40)
        return abs(limited) < 2.5 ? 0 : (limited * 2).rounded() / 2
    }

    // MARK: Кадр предпросмотра

    /// Кадр 16:9, вписанный в отведённое место.
    ///
    /// Считается здесь, а не в самом виде, ровно затем, чтобы самопроверка
    /// могла спросить то же самое при других размерах окна: пока это была
    /// частная функция вида, «попадает ли мышь туда, куда целились» никто
    /// проверить не мог, а промах на узком окне выглядит как испорченное
    /// перетаскивание.
    static func frame(in size: CGSize) -> CGSize {
        let ratio = 16.0 / 9.0
        let width = min(size.width, size.height * ratio)
        let height = width / ratio
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    /// Точка мыши в долях кадра.
    ///
    /// За края кадра выходить разрешаем на половину кадра: человек тянет
    /// блок к самому краю и проскакивает, и обрывать его ровно по границе —
    /// значит терять последний сантиметр движения. Дальше пределы всё равно
    /// обрежет сам ползунок сдвига.
    static func fraction(of location: CGPoint, in side: CGSize) -> CGPoint {
        CGPoint(x: min(max(location.x / max(side.width, 1), -0.5), 1.5),
                y: min(max(location.y / max(side.height, 1), -0.5), 1.5))
    }

    /// Значения прижима для заготовки.
    static let flexValues = ["flex-start", "center", "flex-end"]
    /// Значения точки привязки общего каталога: сперва вертикаль, потом горизонталь.
    static func anchorValue(column: Int, row: Int) -> String {
        let rows = ["top", "center", "bottom"]
        let columns = ["left", "center", "right"]
        return rows[min(max(row, 0), 2)] + "-" + columns[min(max(column, 0), 2)]
    }

    static func column(ofFlex value: String) -> Int {
        max(0, flexValues.firstIndex(of: value) ?? 1)
    }

    static func place(ofAnchor value: String) -> (column: Int, row: Int) {
        let parts = value.split(separator: "-", maxSplits: 1).map(String.init)
        let rows = ["top": 0, "center": 1, "bottom": 2]
        let columns = ["left": 0, "center": 1, "right": 2]
        let row = parts.first.flatMap { rows[$0] } ?? 1
        let column = parts.count > 1 ? (columns[parts[1]] ?? 1) : 1
        return (column, row)
    }
}
