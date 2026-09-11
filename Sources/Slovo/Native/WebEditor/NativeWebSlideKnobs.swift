import AppKit
import SlovoCore

/// Панель ручек оформления веб-слайда — на AppKit.
///
/// Разделы полосой кнопок, а не сегментами: у пяти русских названий длина
/// такая, что на узкой панели последнее обрезается посередине слова, и
/// человек не понимает, что там спрятано.
///
/// Ручки на чужой странице нарочно живые: человек тянет ползунок, и редактор
/// в ответ предлагает завести свою копию. Мёртвый ползунок молчал бы, и
/// человек решил бы, что редактор сломан.
@MainActor
final class NativeWebSlideKnobs: NSView {

    var model: WebSlideEditorModel?
    private let sections = FlowBar()
    private let scroll = NSScrollView()
    private let body = Body()
    private var section: WebSlideSection = .text
    /// Чим був наповнений список рядів минулого разу.
    ///
    /// Власник: «ползунки не всегда следуют за мышью при перетягивании».
    /// Причина була не в повзунку: кожен його крок міняв сторінку, сторінка
    /// кликала оновлення, а оновлення збирало панель заново — і повзунок,
    /// який тримала рука, зникав разом із рядом. Тепер ряди перебираються
    /// тільки тоді, коли справді змінився їх склад; на кожен крок повзунка
    /// вони лише перечитують своє значення.
    private var built = ""

    /// Полоса розділів — з переносом на наступний ряд, щоб останній розділ
    /// не обрізався посеред слова на вузькій панелі.
    typealias FlowBar = NativeFlowBar

    final class Body: NSView {
        var rows: [NSView] = []
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            var top: CGFloat = 6
            for row in rows {
                // Висоту питаємо в самого ряду: підпис під ручкою буває
                // довгим, і на вузькій панелі він займає два-три рядки.
                // Поки висота була однією на всіх, кінець підпису просто
                // зникав — а саме там і сказано, чому ручка не діє.
                let height = (row as? KnobRow)?.height(for: max(0, bounds.width - 16))
                    ?? max(row.intrinsicContentSize.height, 44)
                row.frame = NSRect(x: 8, y: top, width: max(0, bounds.width - 16), height: height)
                top += height + 4
            }
            if abs(frame.height - top) > 0.5 {
                setFrameSize(NSSize(width: bounds.width, height: top + 6))
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(sections)
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let barHeight = sections.height(for: bounds.width - 8)
        sections.frame = NSRect(x: 4, y: 0, width: bounds.width - 8, height: barHeight)
        let top = barHeight + 4
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        body.setFrameSize(NSSize(width: scroll.contentSize.width, height: body.frame.height))
        body.needsLayout = true
    }

    // MARK: - Наполнение

    func refresh() {
        guard let model else { return }
        let available = WebSlideSection.allCases.filter { part in
            model.sheet.knobs.contains { $0.section == part }
        }
        if !available.contains(section) { section = available.first ?? .text }

        // Страница без блока настроек тоже живая: первое же движение ручки
        // заведёт блок и запишет в него ровно эту ручку. Требовать сперва
        // нажать «Добавить настройки» — лишний шаг на пустом месте.
        let editable: Bool
        if case .missing = model.sheet.block, model.current?.isEditable == true {
            editable = true
        } else {
            editable = model.sheet.canAdjust || model.current?.isEditable == false
        }

        let mine = model.sheet.knobs.filter { $0.section == section }
        // Склад рядів: розділ, самі ручки, вписані руками значення і те, чи
        // можна взагалі правити. Числа сюди не входять — від них ряди не
        // міняються, а от вписане руками значення міняє сам вид ряду.
        let signature = ([section.title, editable ? "1" : "0"]
            + available.map(\.title)
            + mine.map { $0.name + (model.sheet.isHandWritten($0) ? "✋" : "")
                + (model.sheet.idleReason($0) ?? "")
                + (model.sheet.limitNote($0) ?? "") }).joined(separator: "\u{1}")
        if signature == built {
            for row in body.rows { (row as? KnobRow)?.reread() }
            return
        }
        built = signature

        var buttons: [NSView] = []
        for part in available {
            let button = NativeForm.button(OurWords.t(part.title)) { [weak self] in
                self?.section = part
                self?.refresh()
            }
            button.contentTintColor = part == section ? .controlAccentColor : nil
            buttons.append(button)
        }
        sections.setButtons(buttons)

        for row in body.rows { row.removeFromSuperview() }
        body.rows = []
        for knob in mine {
            let row = KnobRow(knob: knob, model: model, enabled: editable)
            body.rows.append(row)
            body.addSubview(row)
        }
        body.needsLayout = true
        needsLayout = true
    }

    /// Самоперевірці: скільки рядів стоїть і чи це ті самі об'єкти.
    var rowsForCheck: [NSView] { body.rows }

    /// Самоперевірці: перейти в розділ так, як це робить натискання кнопки.
    func showForCheck(section part: WebSlideSection) {
        section = part
        built = ""
        refresh()
    }

    /// Одна ручка: название, значение и само управление.
    final class KnobRow: NSView {
        private let knob: WebSlideKnob
        private let model: WebSlideEditorModel
        private let title = NSTextField(labelWithString: "")
        private let note = NSTextField(labelWithString: "")
        private var control: NSView?
        /// Показати в елементі нове значення, не пересобирая ряд.
        private var apply: ((String) -> Void)?
        /// Що показано зараз: щоб не смикати елемент дарма.
        private var shown = ""

        init(knob: WebSlideKnob, model: WebSlideEditorModel, enabled: Bool) {
            self.knob = knob
            self.model = model
            super.init(frame: .zero)
            title.font = .systemFont(ofSize: 12)
            addSubview(title)
            note.font = .systemFont(ofSize: 10)
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 3
            note.cell?.wraps = true
            note.cell?.isScrollable = false
            addSubview(note)

            let value = model.sheet.value(knob)
            title.stringValue = OurWords.t(knob.title)
            if model.sheet.isHandWritten(knob) {
                // Значение вписано руками — ползунок его не понимает и не
                // трогает; показываем как есть.
                let written = NSTextField(labelWithString: value + "  ✋")
                written.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                written.textColor = .secondaryLabelColor
                control = written
            } else {
                control = build(value: value, enabled: enabled)
            }
            shown = value
            if let control { addSubview(control) }

            // Причина вместо подсказки, а не вместе с ней: подсказка
            // рассказывает, что ручка делает, а здесь важнее, почему именно
            // тут не сделает ничего.
            if let idle = model.sheet.idleReason(knob) {
                note.stringValue = OurWords.t("Здесь не действует: ") + idle
                note.textColor = .systemOrange
                alphaValue = 0.55
            } else if let limit = model.sheet.limitNote(knob) {
                // Ручка жива, просто вона зараз стеля. Не гасимо її і не
                // ховаємо — кажемо, чому число рухається, а слайд ні.
                note.stringValue = limit
                note.textColor = .systemOrange
            } else {
                note.stringValue = OurWords.t(knob.hint)
                note.textColor = .secondaryLabelColor
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

        /// Самоперевірці: яка ручка і чим її крутять.
        var knobForCheck: WebSlideKnob { knob }
        var controlForCheck: NSView? { control }

        /// Перечитати своє значення зі сторінки.
        ///
        /// Рухає елемент лише тоді, коли значення справді інше: інакше
        /// повзунок, який зараз тягне рука, отримував би своє ж число назад
        /// і смикався під пальцем.
        func reread() {
            let value = model.sheet.value(knob)
            guard value != shown else { return }
            shown = value
            apply?(value)
        }

        override var isFlipped: Bool { true }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: height(for: max(1, bounds.width)))
        }

        /// Скільки місця займе цей ряд при такій ширині.
        func height(for width: CGFloat) -> CGFloat {
            42 + noteHeight(for: width) + 2
        }

        private func noteHeight(for width: CGFloat) -> CGFloat {
            guard !note.stringValue.isEmpty else { return 0 }
            let box = NSRect(x: 0, y: 0, width: max(40, width), height: 200)
            let size = note.cell?.cellSize(forBounds: box) ?? NSSize(width: 0, height: 14)
            return min(46, max(14, ceil(size.height)))
        }

        override func layout() {
            super.layout()
            title.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 16)
            control?.frame = NSRect(x: 0, y: 18, width: bounds.width, height: 22)
            note.frame = NSRect(x: 0, y: 42, width: bounds.width, height: noteHeight(for: bounds.width))
        }

        private func build(value: String, enabled: Bool) -> NSView {
            switch knob.kind {
            case let .number(low, high, step, _):
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = 6
                let slider = NSSlider(value: Double(value.filter { "0123456789.-".contains($0) }) ?? low,
                                      minValue: low, maxValue: high,
                                      target: NativeForm.Trampoline.shared,
                                      action: #selector(NativeForm.Trampoline.fire(_:)))
                let caption = NSTextField(labelWithString: value)
                caption.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                caption.textColor = .secondaryLabelColor
                NativeForm.Trampoline.shared.bind(slider) { [weak self, weak slider, weak caption] in
                    guard let self, let slider else { return }
                    let stepped = (slider.doubleValue / step).rounded() * step
                    let text = stepped == stepped.rounded()
                        ? String(Int(stepped)) : String(format: "%.2f", stepped)
                    caption?.stringValue = text
                    self.shown = text
                    self.model.change(self.knob, to: text)
                }
                apply = { [weak slider, weak caption] text in
                    caption?.stringValue = text
                    let number = Double(text.filter { "0123456789.-".contains($0) }) ?? low
                    if let slider, abs(slider.doubleValue - number) > step / 2 {
                        slider.doubleValue = number
                    }
                }
                slider.isEnabled = enabled
                stack.addArrangedSubview(slider)
                stack.addArrangedSubview(caption)
                return stack

            case .color, .colorRGB:
                // Своє поле, а не системний `NSColorWell`. Власник:
                // «при смене цвета и выбора в меню цвета в rgb sliders, если
                // ползунки цветов находятся не в положении ноль, то они
                // показывают не правильное свое значение цвета внутри
                // ползунка». Палітра malює свої повзунки в тому просторі
                // кольору, який у ній вибрано, а сторінка живе в sRGB —
                // числа ті самі, колір інший. Тут показано те, що вийде.
                let field = NativeColourField(colour: WebSlideKnobColour.parse(value))
                field.isEnabled = enabled
                field.onChange = { [weak self] colour in
                    guard let self else { return }
                    let text: String
                    if case .colorRGB = self.knob.kind {
                        text = WebSlideKnobColour.triple(colour)
                    } else {
                        text = WebSlideKnobColour.hex(colour)
                    }
                    self.shown = text
                    self.model.change(self.knob, to: text)
                }
                apply = { [weak field] text in
                    guard let field, !field.isEditing else { return }
                    field.colour = WebSlideKnobColour.parse(text)
                }
                return field

            case .choice(let options):
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.addItems(withTitles: options.map { OurWords.t($0.title) })
                if let index = options.firstIndex(where: { $0.value == value }) {
                    popup.selectItem(at: index)
                }
                popup.isEnabled = enabled
                popup.target = NativeForm.Trampoline.shared
                popup.action = #selector(NativeForm.Trampoline.fire(_:))
                NativeForm.Trampoline.shared.bind(popup) { [weak self, weak popup] in
                    guard let self, let popup else { return }
                    let index = popup.indexOfSelectedItem
                    guard options.indices.contains(index) else { return }
                    self.shown = options[index].value
                    self.model.change(self.knob, to: options[index].value)
                }
                apply = { [weak popup] text in
                    guard let popup, let index = options.firstIndex(where: { $0.value == text }) else { return }
                    popup.selectItem(at: index)
                }
                return popup

            case let .toggle(on, off, onTitle, offTitle):
                let button = NSButton(checkboxWithTitle: OurWords.t(value == on ? onTitle : offTitle),
                                      target: NativeForm.Trampoline.shared,
                                      action: #selector(NativeForm.Trampoline.fire(_:)))
                button.state = value == on ? .on : .off
                button.isEnabled = enabled
                NativeForm.Trampoline.shared.bind(button) { [weak self, weak button] in
                    guard let self, let button else { return }
                    button.title = OurWords.t(button.state == .on ? onTitle : offTitle)
                    self.shown = button.state == .on ? on : off
                    self.model.change(self.knob, to: button.state == .on ? on : off)
                }
                apply = { [weak button] text in
                    guard let button else { return }
                    button.state = text == on ? .on : .off
                    button.title = OurWords.t(text == on ? onTitle : offTitle)
                }
                return button

            case .text:
                let field = NSTextField(string: value)
                field.font = .systemFont(ofSize: 12)
                field.isEditable = enabled
                field.target = NativeForm.Trampoline.shared
                field.action = #selector(NativeForm.Trampoline.fire(_:))
                NativeForm.Trampoline.shared.bind(field) { [weak self, weak field] in
                    guard let self, let field else { return }
                    self.shown = field.stringValue
                    self.model.change(self.knob, to: field.stringValue)
                }
                apply = { [weak field] text in
                    // У поле, в якому зараз друкують, не лізем.
                    guard let field, field.currentEditor() == nil else { return }
                    field.stringValue = text
                }
                return field
            }
        }
    }
}

/// Колір ручки в записі сторінки: «#RRGGBB» або «r, g, b».
///
/// Обидва записи живуть у сторінках поруч: у CSS колір пишуть шістнадцятковим,
/// а в змінних для `rgb(...)` — трьома числами. Панель читає обидва, а пише
/// той, який ця ручка й носила.
enum WebSlideKnobColour {

    static func parse(_ text: String) -> SlideStyle.RGBA {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        if cleaned.hasPrefix("#") {
            var value: UInt64 = 0
            guard Scanner(string: String(cleaned.dropFirst())).scanHexInt64(&value) else {
                return SlideStyle.RGBA(1, 1, 1, 1)
            }
            return SlideStyle.RGBA(Double((value >> 16) & 0xFF) / 255,
                                   Double((value >> 8) & 0xFF) / 255,
                                   Double(value & 0xFF) / 255, 1)
        }
        // «r, g, b» і «r g b» — у сторінках трапляються обидва.
        let parts = cleaned.split(whereSeparator: { $0 == "," || $0 == " " })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 3 else { return SlideStyle.RGBA(1, 1, 1, 1) }
        return SlideStyle.RGBA(parts[0] / 255, parts[1] / 255, parts[2] / 255, 1)
    }

    static func hex(_ colour: SlideStyle.RGBA) -> String {
        String(format: "#%02X%02X%02X", Int((colour.red * 255).rounded()),
               Int((colour.green * 255).rounded()), Int((colour.blue * 255).rounded()))
    }

    static func triple(_ colour: SlideStyle.RGBA) -> String {
        "\(Int((colour.red * 255).rounded())), \(Int((colour.green * 255).rounded())), "
            + "\(Int((colour.blue * 255).rounded()))"
    }
}
