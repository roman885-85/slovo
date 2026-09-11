import AppKit

/// Содержимое одной строки списка — ровно то, что видно, и ничего сверх.
///
/// Это главное решение всего основания. Сейчас список песен получает 3400
/// значений `Song`, каждое с семью строками и массивом всех частей с полным
/// текстом; профилировщик показал, что 70 % главного потока уходит на
/// `swift_retain` и `initializeWithCopy for Song`, а замер — что подмена
/// `Song` на тройку «номер, название, подзаголовок» ускоряет выбор песни в
/// пятнадцать раз. Поэтому строка знает только то, что нарисуют, и строится
/// по требованию — на видимые два десятка строк, а не на весь сборник.
struct NativeRow {

    /// Узкая колонка слева: номер стиха, номер песни, сокращение книги.
    /// Пусто — колонка не рисуется.
    var lead: String = ""

    /// Главный текст строки.
    var text: String = ""

    /// Приписка: подзаголовок песни, число глав в книге. Куда её положить —
    /// решает `NativeListMetrics.detailWidth`.
    var detail: String = ""

    /// Цвет номера. Пусто — цвет по умолчанию из `NativeListMetrics`.
    var leadColor: NSColor?

    /// Цвет главного текста. У книг он свой на каждый раздел канона.
    var textColor: NSColor?

    /// Заливка невыбранной строки или клетки.
    var fill: NSColor?

    /// Черта под строкой. У автора она красная и стоит под каждым десятым
    /// стихом (настройка `SeparatorTenLine`).
    var rule: NSColor?

    /// Текст не переносится, лишнее срезается многоточием («Текст в одну
    /// линию», кнопка (21)).
    var singleLine = false

    /// Главный текст полужирный.
    var bold = false

    /// Всплывающая подсказка. Пусто — подсказки нет.
    var tooltip: String = ""

    init() {}

    /// Обычная строка списка: номер и текст.
    init(lead: String = "", text: String, detail: String = "",
         leadColor: NSColor? = nil, textColor: NSColor? = nil,
         fill: NSColor? = nil, rule: NSColor? = nil,
         singleLine: Bool = false, bold: Bool = false, tooltip: String = "") {
        self.lead = lead
        self.text = text
        self.detail = detail
        self.leadColor = leadColor
        self.textColor = textColor
        self.fill = fill
        self.rule = rule
        self.singleLine = singleLine
        self.bold = bold
        self.tooltip = tooltip
    }
}

/// Откуда список берёт данные.
///
/// Никаких массивов: только число строк и строка по номеру. Список спрашивает
/// столько раз, сколько строк видно на экране, — обычно два десятка, сколько
/// бы их ни было всего.
@MainActor
protocol NativeListSource: AnyObject {
    /// Сколько строк всего.
    var rowCount: Int { get }

    /// Что нарисовать в строке с этим номером. Вызывается только для видимых.
    func row(at index: Int) -> NativeRow

    /// Меню правой кнопки для строки. Строится в момент щелчка, а не на
    /// каждую строку списка: замер показал, что меню на каждой строке стоит
    /// пятой части времени в песнях и вчетверо дороже прокрутки в стихах.
    func menu(at index: Int) -> NSMenu?
}

extension NativeListSource {
    func menu(at index: Int) -> NSMenu? { nil }
}

/// Отступы и ширины колонок списка. Одни на весь список, не на строку.
struct NativeListMetrics {

    /// Одни метрики на все списки окна «Параметры»: одна колонка номера,
    /// одни поля, одна ширина приписки. Владелец: «вид списков корявый» —
    /// у каждой вкладки были свои.
    static func settings(detailWidth: CGFloat = 200) -> NativeListMetrics {
        NativeListMetrics(leadWidth: 26, detailWidth: detailWidth,
                          padding: NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8))
    }

    /// Ширина колонки номера. 0 — номер идёт вплотную к тексту по своей ширине.
    var leadWidth: CGFloat = 0

    /// Ширина правой колонки приписки. 0 — приписка идёт второй строкой
    /// под текстом мелким шрифтом (так показывают подзаголовок песни).
    var detailWidth: CGFloat = 0

    var padding = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)

    /// Просвет между главным текстом и припиской снизу.
    var lineGap: CGFloat = 1

    /// Выключка главного текста. Список глав у автора выключен по центру.
    var align: NSTextAlignment = .natural

    /// Выключка номера. У стихов номер прижат вправо.
    var leadAlign: NSTextAlignment = .right

    /// Насколько кегль номера отличается от кегля списка.
    var leadFontDelta: CGFloat = -2

    /// Насколько кегль главного текста отличается от кегля списка.
    var textFontDelta: CGFloat = 1

    /// Насколько кегль приписки отличается от кегля списка.
    var detailFontDelta: CGFloat = -3

    /// Цвет номера по умолчанию.
    var leadColor: NSColor = .secondaryLabelColor

    /// Цвет текста по умолчанию.
    var textColor: NSColor = .labelColor

    /// Цвет приписки по умолчанию.
    var detailColor: NSColor = .secondaryLabelColor

    /// Заливка выбранной строки. У автора это подсветка выбора в 85 % силы.
    var selectionColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.85)

    /// Цвет текста выбранной строки.
    var selectedTextColor: NSColor = .white

    /// Фон самого списка.
    var background: NSColor = .textBackgroundColor

    static let verses: NativeListMetrics = {
        var m = NativeListMetrics()
        m.leadWidth = 26
        m.leadColor = NSColor(calibratedRed: 0.72, green: 0.16, blue: 0.16, alpha: 1)
        return m
    }()

    static let books: NativeListMetrics = {
        var m = NativeListMetrics()
        m.leadWidth = 46
        m.leadAlign = .left
        m.leadFontDelta = 0
        m.padding = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        m.textFontDelta = 0
        return m
    }()

    static let chapters: NativeListMetrics = {
        var m = NativeListMetrics()
        m.align = .center
        m.textFontDelta = 0
        m.padding = NSEdgeInsets(top: 3, left: 2, bottom: 3, right: 2)
        return m
    }()

    static let songs: NativeListMetrics = {
        var m = NativeListMetrics()
        m.leadWidth = 42
        m.leadFontDelta = -1
        m.padding = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        m.textFontDelta = 0
        return m
    }()
}
