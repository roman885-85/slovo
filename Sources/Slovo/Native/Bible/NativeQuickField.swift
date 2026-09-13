import AppKit
import SlovoCore

/// Поле швидкого вибору (6), пошуку (8) і адреси (9).
///
/// Висота 19, шрифт 11, заокруглення 3, рамка `secondary` 0.35 — у фокусі 0.6.
/// Усередині поля нічого, крім тексту: ні хрестика очищення, ні лічильника — на
/// знімках оригіналу їх немає.
///
/// У фокусі поле фарбується «Кольором активного поля вводу» з налаштувань
/// користувача (`ActiveInputFieldColor`), а колір тексту добирається за
/// яскравістю заливки: в автора підфарбування завжди світле, бо програма
/// живе у світлій темі Windows, а в нас тема буває й темною.
@MainActor
final class NativeQuickField: NSView, NSTextFieldDelegate {

    static let height: CGFloat = 19

    /// Набрали знак. Іде на кожну літеру — окремої кнопки «застосувати» в
    /// полів оригіналу немає.
    var onChange: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    /// Курсор увійшов у поле або пішов із нього.
    var onFocus: ((Bool) -> Void)?

    /// Заливка поля у фокусі і колір тексту поверх неї.
    var activeFill: NSColor = .textBackgroundColor
    var activeText: NSColor = .labelColor
    /// Рамка червона — «Адресу не знайдено» (ErrorMessages11).
    var isRejected = false {
        didSet {
            guard isRejected != oldValue else { return }
            needsDisplay = true
        }
    }

    private let field = NSTextField()
    /// Правка йде від нас, а не від людини, — зворотний виклик не потрібен.
    private var isSettingText = false

    /// Сірий підказ у порожньому полі: що сюди набирати. Власник:
    /// «незрозуміле призначення і робота пункту — швидкий вибір».
    var placeholder: String {
        get { field.placeholderString ?? "" }
        set { field.placeholderString = newValue }
    }

    var text: String {
        get { field.stringValue }
        set {
            guard field.stringValue != newValue else { return }
            isSettingText = true
            field.stringValue = newValue
            isSettingText = false
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        field.target = self
        field.action = #selector(submitted)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    /// Поле вводу всередині — самоперевірці: колір курсора й висота рядка.
    var editorField: NSTextField { field }

    var isFocused: Bool {
        guard let window, let responder = window.firstResponder as? NSTextView else { return false }
        return responder.delegate === field || window.fieldEditor(false, for: field) === responder
    }

    /// Поставити курсор у поле.
    ///
    /// Нічого не робимо, коли курсор уже тут або поле сховане. Повторне
    /// `makeFirstResponder` посеред набору починає правку заново й виділяє
    /// весь текст — наступна літера його затирала («І» → «в»); а сховане поле
    /// (Біблія, поки відкрито пісні) забирало курсор у видимого, і далі
    /// набиралося вже туди. Власник: «вводиться тільки перший символ».
    func focus() {
        guard let window, !isFocused, !isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(field)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // Поле вводу стоїть усередині рамки: 4 по горизонталі, текст по центру.
        let height = ceil(field.font?.pointSize ?? 11) + 4
        field.frame = NSRect(x: 4, y: (bounds.height - height) / 2,
                             width: max(0, bounds.width - 8), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = isFocused
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: 3, yRadius: 3)
        (focused ? activeFill : NSColor.textBackgroundColor).setFill()
        shape.fill()
        if isRejected {
            NSColor.systemRed.setStroke()
            shape.lineWidth = 2
        } else {
            NSColor.secondaryLabelColor.withAlphaComponent(focused ? 0.6 : 0.35).setStroke()
            shape.lineWidth = 1
        }
        shape.stroke()
        drawCount += 1
        // Колір тексту ставимо лише тоді, коли він справді інший. Доти він
        // ставився на кожному перемалюванні — а головне вікно перемальовує
        // смугу часто. Кожне таке призначення скидає редактору поля його
        // атрибути, і курсор, що саме проявлявся, починав з нуля: очима його
        // не було видно взагалі. Власник: «курсор у всіх полях відсутній».
        let wanted = focused ? activeText : NSColor.labelColor
        if field.textColor != wanted { field.textColor = wanted }
    }

    /// Скільки разів поле перемалювалося — самоперевірці.
    private(set) var drawCount = 0

    // MARK: - Ввід

    func controlTextDidChange(_ obj: Notification) {
        guard !isSettingText else { return }
        isRejected = false
        onChange?(field.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        needsDisplay = true
        onFocus?(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        needsDisplay = true
        onFocus?(false)
    }

    @objc private func submitted() {
        onSubmit?(field.stringValue)
    }
}

/// Підпис поруч із полем: «Пошук:», «Швидк. вибір:», «Знайдено:».
@MainActor
final class NativeCaption: NSView {

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
        }
    }
    var weight: NSFont.Weight = .regular
    var color: NSColor = .secondaryLabelColor

    override var isFlipped: Bool { true }

    /// Ширина, яку підпис просить під себе.
    var fittingWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: weight)]).width) + 2
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 11, weight: weight)
        let height = ceil(font.ascender - font.descender + font.leading)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: NSRect(x: 0, y: (bounds.height - height) / 2,
                                             width: bounds.width, height: height),
                                options: [.usesLineFragmentOrigin],
                                attributes: [.font: font, .foregroundColor: color,
                                             .paragraphStyle: style])
    }
}
