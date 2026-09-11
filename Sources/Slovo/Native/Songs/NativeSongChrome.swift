import AppKit
import SlovoCore

// MARK: - Кнопка панелей Пісенника

/// Кнопка панелей (30) і панелей правки: лише значок і підказка.
///
/// Своя, а не спільна `NativeIconButton`, з однієї причини: у панелей Пісенника
/// кнопки гаснуть («Зберегти» неактивна, поки Пісенник не змінено), а в
/// кнопок вигляду (21)/(22) такого стану немає зовсім.
@MainActor
final class NativeSongButton: NSView {

    var isOn = false { didSet { redrawIfChanged(isOn, oldValue) } }
    var isEnabled = true { didSet { redrawIfChanged(isEnabled, oldValue) } }
    /// Натискання відкриває меню, а не робить дію.
    var menuBuilder: (() -> NSMenu)?

    private let action: () -> Void
    private var painted: [String: NSImage] = [:]
    private let symbol: String

    static let size = NSSize(width: 22, height: 18)

    init(symbol: String, hint: String, action: @escaping () -> Void = {}) {
        self.symbol = symbol
        self.action = action
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        toolTip = hint
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    private func redrawIfChanged(_ new: Bool, _ old: Bool) {
        guard new != old else { return }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            NativeTopDraw.pill(bounds.insetBy(dx: 1, dy: 1), radius: 3,
                               color: NativeTopDraw.selectionFill)
        }
        let role = isOn ? "белый" : (isEnabled ? "обычный" : "тусклый")
        let tint: NSColor = isOn ? .white : (isEnabled ? .labelColor : .tertiaryLabelColor)
        guard let image = NativeTopIcon.symbol(symbol, size: 11, weight: .medium,
                                               tint: tint, role: role) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let menuBuilder {
            NSMenu.popUpContextMenu(menuBuilder(), with: event, for: self)
            return
        }
        action()
    }
}

/// Смуга кнопок: усі три панелі правки виглядають однаково і різняться
/// лише набором кнопок і роздільниками між ними.
@MainActor
final class NativeSongToolStrip: NSView {

    static let height: CGFloat = 22

    /// Кнопка або роздільник.
    enum Item {
        case button(NativeSongButton)
        case divider
    }

    private var items: [Item] = []
    private var dividers: [CGFloat] = []

    override var isFlipped: Bool { true }

    func install(_ items: [Item]) {
        for case .button(let old) in self.items { old.removeFromSuperview() }
        self.items = items
        for case .button(let button) in items { addSubview(button) }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        dividers.removeAll(keepingCapacity: true)
        var x: CGFloat = 4
        for item in items {
            switch item {
            case .button(let button):
                button.frame = NSRect(x: x, y: 2, width: NativeSongButton.size.width,
                                      height: NativeSongButton.size.height)
                x += NativeSongButton.size.width + 1
            case .divider:
                dividers.append(x + 3)
                x += 8
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        for x in dividers {
            NSRect(x: x, y: 4, width: 1, height: bounds.height - 8).fill()
        }
    }
}

// MARK: - Смуга вкладок Пісенників (33)

/// Вкладки вибору Пісенника — як у посібнику 5.3.7, а не випадний список.
///
/// Уся смуга це один вид: підписи міряються один раз на зміну складу і
/// малюються прямо у свої прямокутники. Два десятки кнопок-підвидів на
/// кожне відкриття збірника — це два десятки розкладок там, де потрібна
/// арифметика за готовими ширинами.
@MainActor
final class NativeSongBookTabs: NSView {

    static let height: CGFloat = 22

    struct Tab {
        let id: String
        let long: String
        let short: String
        let tooltip: String
        let url: URL
    }

    var onSelect: ((String) -> Void)?
    var onMenu: ((String) -> NSMenu?)?

    private(set) var longNames = true
    private var tabs: [Tab] = []

    /// Скільки вкладок зараз на смузі — для самоперевірки.
    var tabCount: Int { tabs.count }
    private var widths: [CGFloat] = []
    private var offset: CGFloat = 0
    private var currentID = ""
    private var placeholder = OurWords.t("Песенников нет")

    private let font = NSFont.systemFont(ofSize: 12)
    private let boldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Смуга малює закладки сама і ховає зайві зсувом. Із SDK macOS 14
        // види за умовчанням не ріжуть рисунок по своїх межах, і
        // недомальована закладка вилазила за смугу — на підпис «Пошук:»
        // сусіднього поля. На старих системах межа різалася і так.
        if #available(macOS 14, *) { clipsToBounds = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    func setTabs(_ tabs: [Tab], current: String, longNames: Bool, placeholder: String) {
        self.tabs = tabs
        self.currentID = current
        self.longNames = longNames
        self.placeholder = placeholder
        measure()
        scrollToCurrent()
        needsDisplay = true
    }

    /// Змінився лише вибір — ширини колишні, міряти заново нічого.
    func setCurrent(_ id: String) {
        guard id != currentID else { return }
        currentID = id
        scrollToCurrent()
        needsDisplay = true
    }

    private func measure() {
        widths = tabs.map { tab in
            let text = label(tab)
            let used = tab.id == currentID ? boldFont : font
            return ceil((text as NSString).size(withAttributes: [.font: used]).width) + 16
        }
    }

    private func label(_ tab: Tab) -> String {
        guard !longNames else { return tab.long }
        return tab.short.isEmpty ? tab.long : tab.short
    }

    private func rect(at index: Int) -> NSRect {
        var x: CGFloat = 2 - offset
        for position in 0..<index { x += widths[position] + 2 }
        return NSRect(x: x, y: 2, width: widths[index], height: bounds.height - 4)
    }

    private var contentWidth: CGFloat {
        widths.reduce(4) { $0 + $1 + 2 }
    }

    private func scrollToCurrent() {
        guard let index = tabs.firstIndex(where: { $0.id == currentID }) else { return }
        let box = rect(at: index)
        if box.minX < 0 {
            offset += box.minX - 4
        } else if box.maxX > bounds.width {
            offset += box.maxX - bounds.width + 4
        }
        clampOffset()
    }

    private func clampOffset() {
        offset = max(0, min(offset, max(0, contentWidth - bounds.width)))
    }

    override func layout() {
        super.layout()
        clampOffset()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !tabs.isEmpty else {
            let line = NativeTopDraw.label(placeholder, size: 12, weight: .regular,
                                           color: .secondaryLabelColor)
            line.line.draw(at: NSPoint(x: 6, y: (bounds.height - line.size.height) / 2))
            return
        }
        for index in tabs.indices {
            let box = rect(at: index)
            guard box.maxX > 0, box.minX < bounds.width else { continue }
            let isCurrent = tabs[index].id == currentID
            NativeTopDraw.pill(box, radius: 4,
                               color: isCurrent ? NativeTopDraw.selectionFill
                                                : .controlBackgroundColor)
            let line = NativeTopDraw.label(label(tabs[index]), size: 12,
                                           weight: isCurrent ? .semibold : .regular,
                                           color: isCurrent ? .white : .labelColor)
            line.line.draw(at: NSPoint(x: box.minX + 8,
                                       y: box.minY + (box.height - line.size.height) / 2))
        }
    }

    // MARK: - Миша

    private func index(at point: NSPoint) -> Int? {
        for index in tabs.indices where rect(at: index).contains(point) { return index }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else { return }
        onSelect?(tabs[index].id)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point), let menu = onMenu?(tabs[index].id) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// «Вращение колеса мыши над этим списком прокручивает список
    /// Песенников, если они не помещаются на панели» (5.3.7).
    override func scrollWheel(with event: NSEvent) {
        let step = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard step != 0 else { return }
        offset -= step
        clampOffset()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        removeAllToolTips()
        for index in tabs.indices {
            let box = rect(at: index)
            guard box.maxX > 0, box.minX < bounds.width else { continue }
            _ = addToolTip(box, owner: tabs[index].tooltip as NSString, userData: nil)
        }
    }
}

// MARK: - Заголовок колонки

/// Підпис над списком: «Група:», «Пісня:», «Текст:».
@MainActor
final class NativeSongColumnTitle: NSView {

    static let height: CGFloat = 19

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard !text.isEmpty else { return }
        let line = NativeTopDraw.label(text, size: 11, weight: .semibold,
                                       color: .secondaryLabelColor)
        line.line.draw(at: NSPoint(x: 8, y: (bounds.height - line.size.height) / 2))
    }
}

/// Стовпець із частин, укладених згори вниз: підпис, панель правки, поле
/// швидкого вибору, список.
///
/// Розкладка руками, як і всюди в новому вікні: чотири прямокутники рахуються
/// арифметикою, і схована панель правки просто не займає висоти.
@MainActor
final class NativeSongColumn: NSView {

    struct Piece {
        let view: NSView
        /// Нуль — частина забирає весь залишок по висоті.
        let height: CGFloat
    }

    private var pieces: [Piece] = []
    private var separators: [CGFloat] = []

    override var isFlipped: Bool { true }

    func install(_ pieces: [Piece]) {
        for piece in self.pieces { piece.view.removeFromSuperview() }
        self.pieces = pieces
        for piece in pieces { addSubview(piece.view) }
        needsLayout = true
    }

    /// Показати або сховати частину. Розкладка перераховується сама.
    func setVisible(_ shown: Bool, at position: Int) {
        guard pieces.indices.contains(position), pieces[position].view.isHidden == shown else { return }
        pieces[position].view.isHidden = !shown
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        separators.removeAll(keepingCapacity: true)
        let live = pieces.filter { !$0.view.isHidden }
        let fixed = live.reduce(0) { $0 + $1.height }
        let lines = CGFloat(max(0, live.count - 1))
        let rest = max(30, bounds.height - fixed - lines)

        var y: CGFloat = 0
        for (position, piece) in live.enumerated() {
            if position > 0 {
                separators.append(y)
                y += 1
            }
            let height = piece.height == 0 ? rest : piece.height
            piece.view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        for y in separators {
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        }
    }
}
