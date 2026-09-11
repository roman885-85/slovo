import AppKit

/// Панель із підписом зверху — так підписано всі області оригіналу.
///
/// Підпис малює сама панель, а не окреме поле: поле це ще один
/// вид, ще одна розкладка і ще один шар на кожну з чотирьох колонок, а
/// тексту в ньому одне слово.
@MainActor
final class NativeLabelledPane: NSView {

    /// 3 зверху, рядок 11 пт і 2 просвіти — як у розкладці оригіналу.
    static let captionHeight: CGFloat = 19

    var caption: String = "" {
        didSet {
            guard caption != oldValue else { return }
            needsDisplay = true
        }
    }

    private(set) var content: NSView?

    override var isFlipped: Bool { true }

    func install(_ view: NSView) {
        content?.removeFromSuperview()
        content = view
        addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        content?.frame = NSRect(x: 0, y: Self.captionHeight,
                                width: bounds.width,
                                height: max(0, bounds.height - Self.captionHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !caption.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 11)
        let box = NSRect(x: 6, y: 3, width: max(0, bounds.width - 8), height: 14)
        (caption as NSString).draw(with: box, options: [.usesLineFragmentOrigin],
                                   attributes: [.font: font,
                                                .foregroundColor: NSColor.secondaryLabelColor])
    }
}

// MARK: - Кнопки вигляду (21) і (22)

/// Кнопка панелей (21) і (22): 20×16, значок 11 пт, без підпису.
///
/// У кнопок оригіналу підпису немає зовсім — увесь текст лежить у підказці
/// (`PngSBBookFlow=,~Книги плиткой~`), тому й тут лише значок і `toolTip`.
@MainActor
final class NativeIconButton: NSView {

    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
        }
    }

    var action: (() -> Void)?
    private var image: NSImage?
    /// Готові значки двох кольорів. Значок — символ системи, і кожне його
    /// малювання заново піднімає картинку з каталогу оформлення; на чотири
    /// кнопки вікна це помітна робота, а міняються вони двічі на рік.
    private var painted: [Bool: NSImage] = [:]

    init(symbol: String, hint: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 16))
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: hint)?
            .withSymbolConfiguration(configuration)
        toolTip = hint
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        guard let image else { return }
        let ready = painted[isOn] ?? {
            let made = Self.tinted(image, isOn ? .white : .labelColor)
            painted[isOn] = made
            return made
        }()
        let size = ready.size
        ready.draw(in: NSRect(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }

    /// Значок потрібного кольору. Фарбувати просто в `draw(_:)` не можна: заливка
    /// «поверх непрозорого» зачепила б і підкладку вибраної кнопки, тому
    /// колір накладається в окремій картинці.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    override func mouseDown(with event: NSEvent) { action?() }
}

/// Панель кнопок вигляду: дві кнопки зліва, відступи 4 по горизонталі і 2 по
/// вертикалі — рівно як в оригіналі.
@MainActor
final class NativeIconButtonRow: NSView {

    static let height: CGFloat = 20

    private(set) var buttons: [NativeIconButton] = []

    override var isFlipped: Bool { true }

    func install(_ buttons: [NativeIconButton]) {
        for old in self.buttons { old.removeFromSuperview() }
        self.buttons = buttons
        for button in buttons { addSubview(button) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 4
        for button in buttons {
            button.frame = NSRect(x: x, y: 2, width: 20, height: 16)
            x += 22
        }
    }
}

// MARK: - Чотири колонки з роздільниками

/// Розкладка робочої області: колонки в ряд, між ними роздільники, які
/// можна тягати.
///
/// Своя, а не `NSSplitView`, з двох причин. Перша: розкладка чотирьох
/// прямокутників — це арифметика, і робити її розв'язувачем обмежень нема чого.
/// Друга: у `NSSplitView` під час тягання роздільника розміри міняються
/// пачками, а список книг «плиткою» на кожну зміну ширини перераховує
/// число клітинок у ряду. Тут ширина віддається колонці один раз на рух
/// миші, і зайвих перерахунків немає.
@MainActor
final class NativeColumnsView: NSView {

    struct Column {
        let view: NSView
        let minWidth: CGFloat
        let idealWidth: CGFloat
        /// Нуль — колонка тягнеться і забирає залишок.
        let maxWidth: CGFloat
    }

    private var columns: [Column] = []
    private var widths: [CGFloat] = []
    private var dividers: [CGFloat] = []
    private var dragging: Int?
    private var dragStart: CGFloat = 0
    private var dragWidth: CGFloat = 0

    override var isFlipped: Bool { true }

    func install(_ columns: [Column]) {
        for column in self.columns { column.view.removeFromSuperview() }
        self.columns = columns
        widths = columns.map(\.idealWidth)
        for column in columns { addSubview(column.view) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !columns.isEmpty else { return }
        dividers.removeAll(keepingCapacity: true)

        let gaps = CGFloat(columns.count - 1)
        var fixed: CGFloat = 0
        var flexible: [Int] = []
        for (position, column) in columns.enumerated() {
            if column.maxWidth == 0 {
                flexible.append(position)
            } else {
                widths[position] = min(column.maxWidth, max(column.minWidth, widths[position]))
                fixed += widths[position]
            }
        }
        let rest = max(0, bounds.width - gaps - fixed)
        for position in flexible {
            widths[position] = max(columns[position].minWidth, rest / CGFloat(flexible.count))
        }

        var x: CGFloat = 0
        for (position, column) in columns.enumerated() {
            column.view.frame = NSRect(x: x, y: 0, width: widths[position], height: bounds.height)
            x += widths[position]
            if position < columns.count - 1 {
                dividers.append(x)
                x += 1
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for x in dividers {
            let line = NSRect(x: x, y: 0, width: 1, height: bounds.height)
            if line.intersects(dirtyRect) { line.fill() }
        }
    }

    // MARK: - Тягання роздільника

    override func resetCursorRects() {
        for x in dividers {
            addCursorRect(NSRect(x: x - 3, y: 0, width: 7, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }

    /// Миша біля роздільника дістається нам, а не колонці під нею.
    ///
    /// Роздільник — риска в один піксель між панелями, а панелі стоять
    /// впритул і забирають собі всяке клацання. Тому тягнути колонку
    /// виходило лише над шапками панелей — там, де під курсором немає
    /// підвиду, — і власник вирішив, що роздільники «працюють лише
    /// вгорі вікна». Смуга в чотири пункти по обидва боки риски тепер наша
    /// на всю висоту.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if bounds.contains(local), dividers.contains(where: { abs($0 - local.x) < 4 }) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = dividers.firstIndex(where: { abs($0 - point.x) < 4 }) else { return }
        dragging = index
        dragStart = point.x
        dragWidth = widths[index]
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = dragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let column = columns[index]
        guard column.maxWidth > 0 else { return }
        let wanted = dragWidth + (point.x - dragStart)
        let clamped = min(column.maxWidth, max(column.minWidth, wanted))
        guard clamped != widths[index] else { return }
        widths[index] = clamped
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }
}
