import AppKit
import Combine
import SlovoCore

/// Робоча область модуля «Текст» (5.2) — на AppKit.
///
/// Повторює оригінал згори донизу: підпис «Заголовок:» і вузьке однорядкове
/// поле (23), одразу за полем дві пласкі кнопки (24), під ними підпис
/// «Текст:» і велике поле введення (25) на всю решту висоти. Чотирьох
/// колонок тут немає не з домислу: у `VisioBible.ini` у секції `[Text]` усі
/// ширини списків нульові, тоді як у `[Bible]` вони справжні.
///
/// Заголовок набирається темно-червоним, текст — синім, як в автора: за
/// кольором видно, в якому з двох полів курсор, навіть боковим зором.
@MainActor
final class NativeTextWorkspace: NSView, NSTextFieldDelegate, NSTextViewDelegate {

    static let shared = NativeTextWorkspace()

    private weak var state: AppState?
    private let model = TextModuleModel.shared

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let title = NSTextField()
    private let body = NSTextView()
    private let scroll = NSScrollView()
    private var addButton: NSButton!
    private var clearButton: NSButton!
    private var observers: [AnyCancellable] = []
    private var tokens: [Signals.Token] = []

    private init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    // MARK: - Підключення

    func attach(state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        model.attach(state)
        // Текст міг приїхати з «Біблії» або лишитися з минулого запуску:
        // показуємо його одразу, а не після першої правки.
        observers.append(model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.pull() }
        })
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in self?.applyCaptions() })
        applyCaptions()
        pull()
    }

    func install() {
        NativeMainWindowController.shared.install(self, in: .workspace)
        model.refreshPreview()
        pull()
    }

    // MARK: - Складання

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        for label in [titleLabel, bodyLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }

        title.font = .systemFont(ofSize: 14)
        title.textColor = Self.titleColor
        title.delegate = self
        title.isBezeled = true
        title.bezelStyle = .roundedBezel
        addSubview(title)

        addButton = toolButton("note.text.badge.plus", #selector(addToPlan))
        clearButton = toolButton("doc", #selector(clearText))
        addSubview(addButton)
        addSubview(clearButton)

        body.font = .systemFont(ofSize: 15)
        body.textColor = Self.bodyColor
        body.delegate = self
        body.isRichText = false
        body.allowsUndo = true
        body.backgroundColor = .textBackgroundColor
        body.textContainerInset = NSSize(width: 4, height: 4)
        body.autoresizingMask = [.width]
        body.isVerticallyResizable = true
        body.textContainer?.widthTracksTextView = true

        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.borderType = .lineBorder
        addSubview(scroll)
    }

    private func toolButton(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                                ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        return button
    }

    private func applyCaptions() {
        titleLabel.stringValue = state?.text("Label4", default: "Заголовок:") ?? "Заголовок:"
        bodyLabel.stringValue = state?.text("Label10", default: "Текст:") ?? "Текст:"
        addButton.toolTip = state?.hint("SBAddTextToPlan", default: "Добавить в план")
        clearButton.toolTip = state?.hint("SBClearText", default: "Очистить текст")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        let width = bounds.width - gap * 2
        titleLabel.frame = NSRect(x: gap, y: gap, width: width, height: 14)
        // Ширину поля знято з оригіналу: заголовок займає приблизно
        // чверть вікна, а не весь рядок.
        let titleWidth = min(320, max(160, width * 0.3))
        title.frame = NSRect(x: gap, y: titleLabel.frame.maxY + 2, width: titleWidth, height: 24)
        addButton.frame = NSRect(x: title.frame.maxX + 6, y: title.frame.minY + 2, width: 22, height: 20)
        clearButton.frame = NSRect(x: addButton.frame.maxX + 4, y: addButton.frame.minY, width: 22, height: 20)
        bodyLabel.frame = NSRect(x: gap, y: title.frame.maxY + 6, width: width, height: 14)
        scroll.frame = NSRect(x: gap, y: bodyLabel.frame.maxY + 2, width: width,
                              height: max(0, bounds.height - bodyLabel.frame.maxY - 2 - gap))
    }

    // MARK: - Обмін із моделлю

    /// З моделі в поля. Ставимо тільки при розбіжності: інакше курсор
    /// стрибав би в кінець на кожному натисканні клавіші.
    private func pull() {
        if title.stringValue != model.document.title { title.stringValue = model.document.title }
        if body.string != model.document.body { body.string = model.document.body }
        addButton.isEnabled = !model.document.isEmpty
        clearButton.isEnabled = !model.document.isEmpty
        if focusMark != model.focusRequest {
            focusMark = model.focusRequest
            // F6 «Установить фокус на Стихи/Текст» (N22): у цьому режимі
            // клавіша ставить курсор у поле тексту.
            window?.makeFirstResponder(body)
        }
    }

    private var focusMark = 0

    func controlTextDidChange(_ notification: Notification) {
        model.document.title = title.stringValue
        addButton.isEnabled = !model.document.isEmpty
        clearButton.isEnabled = !model.document.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        model.document.body = body.string
        addButton.isEnabled = !model.document.isEmpty
        clearButton.isEnabled = !model.document.isEmpty
    }

    @objc private func addToPlan() { model.addToPlan() }

    @objc private func clearText() {
        model.clear()
        title.stringValue = ""
        body.string = ""
        pull()
    }

    // MARK: - Кольори оригіналу

    /// Значень по парі на кожен колір: у темному оформленні macOS вихідні
    /// відтінки автора на темній підкладці нечитабельні.
    private static let titleColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.95, green: 0.55, blue: 0.48, alpha: 1)
            : NSColor(srgbRed: 0.60, green: 0.11, blue: 0.06, alpha: 1)
    }

    private static let bodyColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.62, green: 0.75, blue: 1.00, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.13, blue: 0.72, alpha: 1)
    }
}
