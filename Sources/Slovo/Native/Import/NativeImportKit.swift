import AppKit

// Дрібниці, з яких складено сторінки майстра імпорту (4.2).
//
// Тут немає нічого розумного: підпис, що вміє переноситися по словах і
// знає свою висоту, рамка із заголовком і стовпчик з того й іншого. Усе це
// потрібне тому, що сторінки майстра — не форма налаштувань: на них сусідять
// абзаци тексту, списки й кнопки, і висота абзацу залежить від ширини вікна.
// `NativeForm.Group` рахує висоту ряду до розкладки, коли ширини ще немає,
// і абзац у два рядки в нього зрізається рівно навпіл.

/// Вид, що вміє сказати свою висоту за заданої ширини. Абзац, рамка й
/// відступ рахують її самі — решту питають про їхній власний розмір.
@MainActor
protocol ImportMeasurable: NSView {
    func height(forWidth width: CGFloat) -> CGFloat
}

/// Підпис, що переноситься по словах. Висоту рахує за справжньою шириною.
@MainActor
final class ImportText: NSTextField, ImportMeasurable {

    init(_ value: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
         secondary: Bool = false, monospaced: Bool = false, colour: NSColor? = nil) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        isSelectable = true
        drawsBackground = false
        // Перенесення по словах вмикається саме так: один рядок — властивість
        // комірки, а не поля, і без `usesSingleLineMode = false` довгий абзац
        // мовчки перетворюється на рядок із трикрапкою.
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        lineBreakMode = .byWordWrapping
        font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
        textColor = colour ?? (secondary ? .secondaryLabelColor : .labelColor)
        stringValue = value
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let cell else { return 18 }
        let bounds = NSRect(x: 0, y: 0, width: max(20, width), height: .greatestFiniteMagnitude)
        return ceil(cell.cellSize(forBounds: bounds).height)
    }
}

/// Рядок в одну лінію: зайве зрізається трикрапкою посередині — так шляхи
/// лишаються впізнаваними з обох кінців.
@MainActor
func importPathLabel(_ value: String) -> NSTextField {
    let field = NSTextField(labelWithString: value)
    field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    field.textColor = .secondaryLabelColor
    field.lineBreakMode = .byTruncatingMiddle
    field.isSelectable = true
    field.toolTip = value
    return field
}

/// Стовпчик видів згори донизу. Висоту кожного питає за справжньою шириною.
@MainActor
class ImportStack: NSView {

    var spacing: CGFloat = 8
    var insets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    private(set) var items: [NSView] = []

    override var isFlipped: Bool { true }

    func set(_ views: [NSView]) {
        for view in items { view.removeFromSuperview() }
        items = views
        for view in views { addSubview(view) }
        needsLayout = true
    }

    /// Висота виду за цієї ширини.
    func height(of view: NSView, width: CGFloat) -> CGFloat {
        if let measurable = view as? ImportMeasurable { return measurable.height(forWidth: width) }
        if let spacer = view as? ImportSpacer { return spacer.wanted }
        let size = view.intrinsicContentSize
        if size.height > 0 && size.height != NSView.noIntrinsicMetric { return size.height }
        return max(22, view.fittingSize.height)
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let inner = max(20, width - insets.left - insets.right)
        var total = insets.top + insets.bottom
        for (index, view) in items.enumerated() where !view.isHidden {
            total += height(of: view, width: inner)
            if index < items.count - 1 { total += spacing }
        }
        return total
    }

    override func layout() {
        super.layout()
        let inner = max(20, bounds.width - insets.left - insets.right)
        var top = insets.top
        for view in items where !view.isHidden {
            let height = height(of: view, width: inner)
            view.frame = NSRect(x: insets.left, y: top, width: inner, height: height)
            top += height + spacing
        }
    }
}

/// Розпірка: порожнє місце заданої висоти.
@MainActor
final class ImportSpacer: NSView {
    let wanted: CGFloat
    init(_ height: CGFloat) {
        wanted = height
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }
}

/// Рамка з підписом — `TGroupBox` оригіналу. Своя, а не `NativeForm.Group`:
/// усередині може стояти абзац, і висота рахується за шириною.
@MainActor
final class ImportBox: NSView, ImportMeasurable {

    private let caption = NSTextField(labelWithString: "")
    private let body = ImportStack()

    init(_ title: String, _ rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.cornerRadius = 4
        caption.stringValue = title
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        addSubview(caption)
        body.spacing = 4
        body.set(rows)
        addSubview(body)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    func height(forWidth width: CGFloat) -> CGFloat {
        22 + body.height(forWidth: width - 20) + 10
    }

    override func layout() {
        super.layout()
        caption.frame = NSRect(x: 10, y: 4, width: max(0, bounds.width - 20), height: 15)
        let inner = max(20, bounds.width - 20)
        body.frame = NSRect(x: 10, y: 22, width: inner, height: body.height(forWidth: inner))
    }
}

/// Рядок «підпис — значення» для зведення.
@MainActor
final class ImportPair: NSView {

    private let name = NSTextField(labelWithString: "")
    private let value: NSTextField

    init(_ title: String, _ text: String) {
        value = importPathLabel(text)
        super.init(frame: .zero)
        name.stringValue = title
        name.font = .systemFont(ofSize: 11)
        addSubview(name)
        addSubview(value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 16) }

    override func layout() {
        super.layout()
        name.frame = NSRect(x: 0, y: 0, width: 170, height: 16)
        value.frame = NSRect(x: 178, y: 0, width: max(0, bounds.width - 178), height: 16)
    }
}

/// Стовпчик у прокрутці. Майстер показує і опис на сотню рядків, і зведення
/// після перенесення — обидва вищі за вікно.
@MainActor
final class ImportScroll: NSView {

    private let scroll = NSScrollView()
    let body = ImportStack()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        body.insets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let width = scroll.contentSize.width
        body.setFrameSize(NSSize(width: width, height: body.height(forWidth: width)))
        body.needsLayout = true
    }

    /// Перерахувати висоту вмісту — після кожної зміни рядків.
    func refreshHeight() {
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}
