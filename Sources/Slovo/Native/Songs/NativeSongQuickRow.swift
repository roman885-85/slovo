import AppKit
import SlovoCore

/// Рядок із полем швидкого вибору і кнопками поруч — поля (31) і (32).
///
/// Поле тут те саме, що в Біблії (`NativeQuickField`): підфарбування у
/// фокусі, пошук на кожен знак, нічого всередині, крім тексту. Свого тут
/// лише розкладка: у поля Пісні справа стоять дві кнопки переходу
/// `PSBFindPrevSong` і `PSBFindNextSong`, а в поля Частини їх немає.
@MainActor
final class NativeSongQuickRow: NSView {

    static let height: CGFloat = 25

    let field = NativeQuickField()
    private var buttons: [NativeSongButton] = []

    init(buttons: [NativeSongButton] = []) {
        self.buttons = buttons
        super.init(frame: .zero)
        addSubview(field)
        for button in buttons { addSubview(button) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    override func layout() {
        super.layout()
        let tail = CGFloat(buttons.count) * (NativeSongButton.size.width + 2)
        field.frame = NSRect(x: 6, y: (bounds.height - NativeQuickField.height) / 2,
                             width: max(20, bounds.width - 12 - tail),
                             height: NativeQuickField.height)
        var x = field.frame.maxX + 2
        for button in buttons {
            button.frame = NSRect(x: x, y: (bounds.height - NativeSongButton.size.height) / 2,
                                  width: NativeSongButton.size.width,
                                  height: NativeSongButton.size.height)
            x += NativeSongButton.size.width + 2
        }
    }
}

/// Шапка робочої зони: вкладки Пісенників (33), позначка «змінений» і панель
/// інструментів Пісенника (30).
///
/// Смуга вкладок жадібна, і, якщо її не осадити, вона з'їдає місце панелі —
/// тому ширина рахується з кінця: спершу панель і позначка, залишок вкладкам.
@MainActor
final class NativeSongHeader: NSView {

    static let height: CGFloat = 30

    let tabs = NativeSongBookTabs()
    let toolbar = NativeSongToolStrip()
    /// Ширина, яку просить панель інструментів. Рахує її той, хто кладе
    /// туди кнопки: число кнопок міняється разом із режимом правки.
    var toolbarWidth: CGFloat = 120 { didSet { needsLayout = true } }
    var isModified = false {
        didSet {
            guard isModified != oldValue else { return }
            needsLayout = true
            needsDisplay = true
        }
    }
    var modifiedTitle = OurWords.t("изменён")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(tabs)
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    private var badgeWidth: CGFloat {
        guard isModified else { return 0 }
        return NativeTopDraw.label(modifiedTitle, size: 10, weight: .semibold,
                                   color: .labelColor).size.width + 14
    }

    /// Чи стоять закладки Пісенників тут. Коли вони пішли на смугу перекладів
    /// (7) — а там їм і місце, — шапка їх не розкладає: чужий вид, чужий
    /// клопіт.
    var keepsTabs = true { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        let badge = badgeWidth
        let toolbarBox = NSRect(x: bounds.width - toolbarWidth - 4,
                                y: (bounds.height - NativeSongToolStrip.height) / 2,
                                width: toolbarWidth, height: NativeSongToolStrip.height)
        toolbar.frame = toolbarBox
        guard keepsTabs else { return }
        tabs.frame = NSRect(x: 4, y: (bounds.height - NativeSongBookTabs.height) / 2,
                            width: max(40, toolbarBox.minX - badge - 12),
                            height: NativeSongBookTabs.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard isModified else { return }
        // Операторові важливо бачити, що Пісенник ще не збережено: кнопка (30.6)
        // активна саме в цьому стані.
        let line = NativeTopDraw.label(modifiedTitle, size: 10, weight: .semibold,
                                       color: .labelColor)
        let box = NSRect(x: keepsTabs ? tabs.frame.maxX + 4 : 6, y: (bounds.height - 16) / 2,
                         width: line.size.width + 10, height: 16)
        NSColor.systemOrange.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        line.line.draw(at: NSPoint(x: box.minX + 5,
                                   y: box.minY + (box.height - line.size.height) / 2))
    }
}
