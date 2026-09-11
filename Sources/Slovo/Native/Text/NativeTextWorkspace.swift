import AppKit
import Combine
import SlovoCore

/// Рабочая область модуля «Текст» (5.2) — на AppKit.
///
/// Повторяет оригинал сверху вниз: подпись «Заголовок:» и узкое однострочное
/// поле (23), сразу за полем две плоские кнопки (24), под ними подпись
/// «Текст:» и большое поле ввода (25) во всю оставшуюся высоту. Четырёх
/// колонок здесь нет не по домыслу: в `VisioBible.ini` у секции `[Text]` все
/// ширины списков нулевые, тогда как у `[Bible]` они настоящие.
///
/// Заголовок набирается тёмно-красным, текст — синим, как у автора: по цвету
/// видно, в каком из двух полей курсор, даже боковым зрением.
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

    // MARK: - Подключение

    func attach(state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        model.attach(state)
        // Текст мог приехать из «Библии» или остаться с прошлого запуска:
        // показываем его сразу, а не после первой правки.
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

    // MARK: - Сборка

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
        // Ширина поля снята с оригинала: заголовок занимает примерно
        // четверть окна, а не всю строку.
        let titleWidth = min(320, max(160, width * 0.3))
        title.frame = NSRect(x: gap, y: titleLabel.frame.maxY + 2, width: titleWidth, height: 24)
        addButton.frame = NSRect(x: title.frame.maxX + 6, y: title.frame.minY + 2, width: 22, height: 20)
        clearButton.frame = NSRect(x: addButton.frame.maxX + 4, y: addButton.frame.minY, width: 22, height: 20)
        bodyLabel.frame = NSRect(x: gap, y: title.frame.maxY + 6, width: width, height: 14)
        scroll.frame = NSRect(x: gap, y: bodyLabel.frame.maxY + 2, width: width,
                              height: max(0, bounds.height - bodyLabel.frame.maxY - 2 - gap))
    }

    // MARK: - Обмен с моделью

    /// Из модели в поля. Ставим только при расхождении: иначе курсор
    /// прыгал бы в конец на каждом нажатии клавиши.
    private func pull() {
        if title.stringValue != model.document.title { title.stringValue = model.document.title }
        if body.string != model.document.body { body.string = model.document.body }
        addButton.isEnabled = !model.document.isEmpty
        clearButton.isEnabled = !model.document.isEmpty
        if focusMark != model.focusRequest {
            focusMark = model.focusRequest
            // F6 «Установить фокус на Стихи/Текст» (N22): в этом режиме
            // клавиша ставит курсор в поле текста.
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

    // MARK: - Цвета оригинала

    /// Значений по паре на каждый цвет: в тёмном оформлении macOS исходные
    /// оттенки автора на тёмной подложке нечитаемы.
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
