import AppKit
import SlovoCore

/// 6.4 «Кольорова легенда частин пісень» — форма `SongColorsetForm`, на AppKit.
///
/// Налаштовує кольори й ключові слова, за якими список «Текст» (28) у
/// модулі «Пісні» фарбує куплети, приспіви й інші частини. Слова — не
/// прикраса: за ними частину й розпізнають у файлі пісенника, де вона може
/// бути підписана «Припев», «Refren» або «פזמון».
@MainActor
final class NativeSongColorsetView: NSView, NativeListSource {

    private let state: AppState
    private let store: SettingsStore
    /// Яку кнопку натиснули: `true` — «Ок», `false` — «Скасувати». Записує й
    /// відкочує вікно, а не вид: знімок налаштувань належить вікну.
    private let onFinish: (Bool) -> Void

    private let chunks = NativeTable(detailWidth: 160)
    private let names = NativeTable(detailWidth: 0)
    private let title = NSTextField(labelWithString: "")
    /// Поле кольору — своє, як у конструкторі й у редакторі веб-слайдів.
    /// Системна палітра малює свої повзунки в тому просторі кольору, який у
    /// ній вибрано, а програма скрізь рахує в sRGB: числа ті самі, колір на
    /// екрані інший.
    private let colour = NativeColourField(colour: SlideStyle.RGBA(1, 1, 1, 1))
    private let example = Example()
    private var buttons: [NSButton] = []
    private var selectedChunk = 0
    private var selectedName: Int?

    init(state: AppState, store: SettingsStore, onFinish: @escaping (Bool) -> Void) {
        self.state = state
        self.store = store
        self.onFinish = onFinish
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    private func form(_ key: String, _ fallback: String) -> String {
        state.vb(key, form: "SongColorsetForm", fallback)
    }

    private func formHint(_ key: String, _ fallback: String) -> String {
        state.vbHint(key, form: "SongColorsetForm", fallback)
    }

    // MARK: - Складання

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        chunks.source = self
        chunks.onSelect = { [weak self] _, active, _ in
            guard let self else { return }
            // Номер вибраної назви належить колишній частині: у новій він
            // вказав би на чуже слово.
            if active != self.selectedChunk { self.selectedName = nil }
            self.selectedChunk = active
            self.refresh()
        }
        names.source = NamesSource(owner: self)
        names.onSelect = { [weak self] _, active, _ in self?.selectedName = active; self?.refresh() }

        title.font = .systemFont(ofSize: 11, weight: .medium)
        colour.onChange = { [weak self] value in self?.colourChanged(value) }
        colour.toolTip = formHint("SBChunkColor", "Цвет шрифта Стиха")

        buttons = [
            NativeForm.button("+", hint: formHint("PngSBAdd", "Добавить альтернативное название")) {
                [weak self] in self?.addName()
            },
            NativeForm.button("✎", hint: formHint("PngSBEdit", "Редактировать альтернативное название")) {
                [weak self] in self?.editName()
            },
            NativeForm.button("−", hint: formHint("PngSBRem", "Удалить альтернативное название")) {
                [weak self] in self?.removeName()
            },
            NativeForm.button(form("BBOk", "Ок"), hint: formHint("BBOk", "Сохранить")) {
                [weak self] in self?.onFinish(true)
            },
            NativeForm.button(form("BBCancel", "Отменить"), hint: formHint("BBCancel", "Не сохранять")) {
                [weak self] in self?.onFinish(false)
            },
        ]
        buttons[3].keyEquivalent = "\r"
        buttons[4].keyEquivalent = "\u{1B}"

        for view in [chunks, names, title, colour, example] as [NSView] { addSubview(view) }
        for button in buttons { addSubview(button) }
        example.owner = self
        refresh()
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 16
        chunks.frame = NSRect(x: gap, y: gap, width: 330, height: 250)

        let right = chunks.frame.maxX + 12
        title.frame = NSRect(x: right, y: gap + 2, width: bounds.width - right - gap, height: 18)
        colour.frame = NSRect(x: right, y: title.frame.maxY + 6, width: 44, height: 22)
        names.frame = NSRect(x: right, y: colour.frame.maxY + 8, width: 180, height: 150)
        for (index, button) in buttons.prefix(3).enumerated() {
            button.frame = NSRect(x: names.frame.maxX + 6, y: names.frame.minY + CGFloat(index) * 26,
                                  width: 30, height: 22)
        }
        example.frame = NSRect(x: gap, y: chunks.frame.maxY + 12,
                               width: bounds.width - gap * 2,
                               height: max(0, bounds.height - chunks.frame.maxY - 60))
        let ok = buttons[3], cancel = buttons[4]
        ok.frame = NSRect(x: bounds.width - gap - 90, y: bounds.height - 36, width: 90, height: 24)
        cancel.frame = NSRect(x: ok.frame.minX - 100, y: ok.frame.minY, width: 90, height: 24)
    }

    // MARK: - Стан

    private var chunk: SongChunkSetting? {
        let list = store.settings.songChunks
        return list.indices.contains(selectedChunk) ? list[selectedChunk] : nil
    }

    private func refresh() {
        title.stringValue = form("Label1", "Название:") + " "
            + (chunk?.names.first ?? chunk?.key ?? "")
        if let value = chunk?.color, !colour.isEditing {
            colour.colour = SlideStyle.RGBA(value.red, value.green, value.blue, 1)
        }
        // Останню назву видаляти не можна: частина лишиться без жодного
        // слова, за яким її можна впізнати в пісеннику.
        buttons[1].isEnabled = selectedName != nil
        buttons[2].isEnabled = selectedName != nil && (chunk?.names.count ?? 0) > 1
        names.reload()
        example.needsDisplay = true
        needsLayout = true
    }

    private func colourChanged(_ value: SlideStyle.RGBA) {
        guard let key = chunk?.key else { return }
        store.setChunkColor(key, SlideStyle.RGBA(value.red, value.green, value.blue, 1))
        chunks.reload()
        example.needsDisplay = true
    }

    /// Альтернативні назви — з другої: перша показана вище в полі
    /// «Назва». Посібник 6.4 розділяє їх, і кнопки правки й видалення
    /// не мають чіпати основне ім'я частини.
    fileprivate var alternatives: [String] { Array((chunk?.names ?? []).dropFirst()) }

    private func addName() {
        guard let key = chunk?.key, let text = ask(title: form("TextMessages0", "Добавление альт. названия"),
                                                   value: "") else { return }
        store.addChunkName(key, text)
        refresh()
        chunks.reload()
    }

    private func editName() {
        guard let key = chunk?.key, let index = selectedName,
              let names = chunk?.names, names.indices.contains(index + 1),
              let text = ask(title: form("TextMessages2", "Изменение альт. названия"),
                             value: names[index + 1]) else { return }
        store.replaceChunkName(key, at: index + 1, with: text)
        refresh()
        chunks.reload()
    }

    private func removeName() {
        guard let key = chunk?.key, let index = selectedName,
              (chunk?.names.count ?? 0) > 1 else { return }
        store.removeChunkName(key, at: index + 1)
        selectedName = nil
        refresh()
        chunks.reload()
    }

    /// Уведення назви — TextMessages0…2 форми автора.
    private func ask(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = form("TextMessages1", "Введите альтернативное название")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: form("BBOk", "Ок"))
        alert.addButton(withTitle: form("BBCancel", "Отменить"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    // MARK: - Списки

    var rowCount: Int { store.settings.songChunks.count }

    func row(at index: Int) -> NativeRow {
        let chunk = store.settings.songChunks[index]
        var row = NativeRow()
        row.lead = "■"
        row.leadColor = NSColor(srgbRed: chunk.color.red, green: chunk.color.green,
                                blue: chunk.color.blue, alpha: 1)
        row.text = chunk.names.first ?? chunk.key
        row.detail = chunk.names.dropFirst().joined(separator: ", ")
        return row
    }

    /// Джерело для списку альтернативних назв.
    private final class NamesSource: NativeListSource {
        unowned let owner: NativeSongColorsetView
        init(owner: NativeSongColorsetView) { self.owner = owner }
        var rowCount: Int { owner.alternatives.count }
        func row(at index: Int) -> NativeRow {
            var row = NativeRow()
            row.text = owner.alternatives[index]
            return row
        }
    }

    /// Приклад: кольорові написи частин. Подвійне клацання відкриває системну
    /// палітру — так само, як в оригіналі.
    fileprivate final class Example: NSView {
        weak var owner: NativeSongColorsetView?

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.clear.setFill()
            bounds.fill()
            guard let owner else { return }
            var x: CGFloat = 4, y: CGFloat = 4
            for chunk in owner.store.settings.songChunks {
                let text = NSAttributedString(string: chunk.names.first ?? chunk.key, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor(srgbRed: chunk.color.red, green: chunk.color.green,
                                              blue: chunk.color.blue, alpha: 1),
                ])
                let size = text.size()
                if x + size.width + 12 > bounds.width { x = 4; y += size.height + 8 }
                text.draw(at: NSPoint(x: x + 6, y: y + 2))
                x += size.width + 20
            }
        }

        /// Подвійне натискання по зразку раніше відкривало системну палітру
        /// кольорів — і людина правила колір там, де програма його не читає.
        /// Колір частини задають полем угорі; сюди дивляться, що вийшло.
        override func mouseDown(with event: NSEvent) {}
    }
}
