import AppKit
import SlovoCore

/// Окно «Выбор языка» — раздел 7.3, форма `SelectLangForm`, на AppKit.
///
/// В форме автора всего три подписи: `Label1` над списком и кнопки `PBBOk` и
/// `PBBCancel`. Список — все переводы из папки `Language` с флажками
/// `Language/*.png`. Выбор применяется по «Ок», как в оригинале: щелчок по
/// строке в модальном окне ничего не меняет до подтверждения.
@MainActor
final class NativeSelectLangView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private let state: AppState
    private let originals: URL
    private let onClose: () -> Void
    private let form = "SelectLangForm"

    private let caption = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var buttons: [NSButton] = []
    private var languages: [LanguageFile] = []

    init(state: AppState, originals: URL, onClose: @escaping () -> Void) {
        self.state = state
        self.originals = originals
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 420))
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Все переводы: и оригинальные, и свои, сохранённые в окне 7.1.
        languages = InterfaceLanguageStore.languages(originals: originals)

        caption.stringValue = state.text("Label1", form: form,
                                         default: "Выберите язык интерфейса программы")
        caption.font = .systemFont(ofSize: 12)
        addSubview(caption)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("lang"))
        column.width = 300
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        // Двойной щелчок — быстрый путь: выбрать и закрыть.
        table.target = self
        table.doubleAction = #selector(apply)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)

        buttons = [
            NativeForm.button(state.text("PBBCancel", form: form, default: "Отмена")) { [weak self] in
                self?.onClose()
            },
            NativeForm.button(state.text("PBBOk", form: form, default: "Ок")) { [weak self] in
                self?.apply()
            },
        ]
        buttons[1].keyEquivalent = "\r"
        buttons[0].keyEquivalent = "\u{1B}"
        for button in buttons { addSubview(button) }

        if let index = languages.firstIndex(where: {
            $0.code.caseInsensitiveCompare(state.language?.code ?? "") == .orderedSame
        }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 12
        caption.frame = NSRect(x: gap, y: gap, width: bounds.width - gap * 2, height: 18)
        scroll.frame = NSRect(x: gap, y: caption.frame.maxY + 6, width: bounds.width - gap * 2,
                              height: max(0, bounds.height - caption.frame.maxY - 56))
        var right = bounds.width - gap
        for button in buttons.reversed() {
            let width = max(80, button.intrinsicContentSize.width + 24)
            button.frame = NSRect(x: right - width, y: bounds.height - 36, width: width, height: 24)
            right -= width + 8
        }
    }

    // MARK: - Список

    func numberOfRows(in tableView: NSTableView) -> Int { languages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard languages.indices.contains(row) else { return nil }
        let language = languages[row]
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        let flag = NSImageView(frame: NSRect(x: 2, y: 4, width: 18, height: 13))
        // Флаг может отсутствовать у своего перевода — место под него всё
        // равно держим, иначе строки разъезжаются.
        flag.image = InterfaceLanguageStore.flag(code: language.code, originals: originals)
        flag.imageScaling = .scaleProportionallyUpOrDown
        box.addSubview(flag)
        let name = NSTextField(labelWithString: language.displayName)
        name.font = .systemFont(ofSize: 13)
        name.frame = NSRect(x: 26, y: 2, width: 220, height: 18)
        box.addSubview(name)
        let code = NSTextField(labelWithString: language.code)
        code.font = .systemFont(ofSize: 11)
        code.textColor = .secondaryLabelColor
        code.alignment = .right
        code.frame = NSRect(x: 250, y: 3, width: 46, height: 16)
        box.addSubview(code)
        return box
    }

    // MARK: - Применение

    @objc private func apply() {
        let row = table.selectedRow
        guard languages.indices.contains(row) else { return }
        let chosen = languages[row].code

        // Свой перевод (7.1 (3)) лежит в папке «Слова», а каталог языков
        // главного окна собран из папки VisioBible. Пока в `AppState` нет
        // вставки на склеенную папку, `setLanguage` для такого кода молча
        // ничего не делает — и человек остаётся при старом языке, не понимая
        // почему. Проверяем результат и говорим прямо.
        InterfaceLanguageStore.mergedDirectory(originals: originals)
        state.setLanguage(code: chosen)

        guard state.language?.code.caseInsensitiveCompare(chosen) != .orderedSame else {
            onClose()
            return
        }
        let alert = NSAlert()
        alert.messageText = state.text("Label1", form: form,
                                       default: "Выберите язык интерфейса программы")
        alert.informativeText = """
            Перевод «\(languages[row].displayName)» сохранён в папке «Слова», но главное \
            окно читает переводы из папки VisioBible и этого файла пока не видит.

            Файл лежит здесь:
            \(InterfaceLanguageStore.fileURL(code: chosen).path)
            """
        alert.addButton(withTitle: OurWords.t("Закрыть"))
        alert.runModal()
    }
}
