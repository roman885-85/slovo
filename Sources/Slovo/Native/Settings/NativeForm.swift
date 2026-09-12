import AppKit
import SlovoCore

/// Набор форменных видов для окна «Параметры» — на AppKit.
///
/// Девять вкладок оригинала — это плотные формы Delphi: рамка с подписью,
/// внутри ряды «подпись — поле». Здесь ровно то же самое, но своими видами:
/// каждый ряд сам считает свою высоту, а группа складывает ряды сверху вниз.
///
/// Связь с настройками — замыканиями `get`/`set`: они пишут прямо в снимок
/// `SettingsStore`, как это делали связки SwiftUI. Кто и когда сохранит
/// снимок на диск, решает по-прежнему кнопка «Ок».
/// Вкладка «Параметрів», у якої є свій список рядків.
///
/// Після скидання або ввезення налаштувань поля перечитуються самі
/// (`NativeForm.refreshValues`), а таблиці — ні: рядки їм дає джерело, і про
/// зміну воно має дізнатися окремо.
@MainActor
protocol NativeSettingsRows: AnyObject {
    func reloadRows()
}

@MainActor
enum NativeForm {

    /// Enter у полі — це «записати набране», а не «натиснути кнопку за
    /// умовчанням».
    ///
    /// Власник: «у налаштуваннях слайда після деяких змін вискакує вікно про
    /// збереження, і якщо натиснути зберегти — вікно з налаштуваннями
    /// закривається, хоч повного редагування ще не було». Причина не в
    /// збереженні: Enter після набраного числа перехоплювала кнопка вікна
    /// («Закрити» в Конструкторі, «Ок» у «Параметрах») — вона стоїть кнопкою
    /// за умовчанням, а кнопки за умовчанням отримують Enter раніше за поле,
    /// у якому стоїть курсор. Виходило «набрав число — вікно зачинилося».
    ///
    /// Тепер, коли правлять поле, Enter лише закінчує правку: число лягає
    /// у шаблон, вікно лишається відкритим. Коли ж курсор не в полі, Enter
    /// працює як завжди.
    static func endsFieldEditing(on event: NSEvent, in window: NSWindow?) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn, let window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor
        else { return false }
        window.makeFirstResponder(nil)
        return true
    }


    /// Связка со значением настройки.
    struct Tie<Value> {
        let get: () -> Value
        let set: (Value) -> Void

        init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
            self.get = get
            self.set = set
        }
    }

    // MARK: - Ряд

    /// Ряд формы: подпись слева, управления справа.
    final class Row: NSView {
        private let label = NSTextField(labelWithString: "")
        private let content = NSStackView()
        private let labelWidth: CGFloat

        /// - Parameter stretch: первый вид занимает всю оставшуюся ширину —
        ///   для списков и коробок, которым незачем стоять в 460 пикселях
        ///   посреди окна в 880.
        init(_ title: String, width: CGFloat = 150, stretch: Bool = false, _ views: [NSView]) {
            labelWidth = title.isEmpty ? 0 : width
            super.init(frame: .zero)
            if stretch, let first = views.first {
                content.distribution = .fill
                first.setContentHuggingPriority(.init(1), for: .horizontal)
                first.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            }
            label.stringValue = title
            label.font = .systemFont(ofSize: 11)
            label.alignment = .right
            addSubview(label)
            content.orientation = .horizontal
            content.spacing = 6
            content.alignment = .centerY
            for view in views { content.addArrangedSubview(view) }
            addSubview(content)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

        override var isFlipped: Bool { true }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: max(22, content.fittingSize.height))
        }

        override func layout() {
            super.layout()
            let height = bounds.height
            label.frame = NSRect(x: 0, y: (height - 16) / 2, width: labelWidth, height: 16)
            let left = labelWidth == 0 ? 0 : labelWidth + 8
            content.frame = NSRect(x: left, y: 0, width: max(0, bounds.width - left), height: height)
        }
    }

    // MARK: - Группа

    /// Рамка с подписью в левом верхнем углу — `TGroupBox` Delphi.
    /// Взято не для красоты: в оригинале настройки сгруппированы именно так,
    /// и человек ищет нужное по этим рамкам.
    final class Group: NSView {
        private let title = NSTextField(labelWithString: "")
        private var rows: [NSView] = []

        init(_ caption: String, _ rows: [NSView]) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.cornerRadius = 4
            title.stringValue = caption
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = .secondaryLabelColor
            addSubview(title)
            self.rows = rows
            for row in rows { addSubview(row) }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

        override var isFlipped: Bool { true }

        /// Высота считается по рядам: обрезать ряд нельзя — за ним стоит
        /// настройка, и невидимую человек не найдёт.
        var neededHeight: CGFloat {
            var height: CGFloat = 24
            for row in rows { height += max(row.intrinsicContentSize.height, 22) + 6 }
            return height + 6
        }

        override func layout() {
            super.layout()
            title.frame = NSRect(x: 10, y: 4, width: bounds.width - 20, height: 16)
            var top: CGFloat = 24
            for row in rows {
                let height = max(row.intrinsicContentSize.height, 22)
                row.frame = NSRect(x: 10, y: top, width: bounds.width - 20, height: height)
                top += height + 6
            }
        }
    }

    // MARK: - Страница

    /// Страница вкладки: группы сверху вниз, с прокруткой.
    final class Page: NSView {
        private let scroll = NSScrollView()
        private let body = Body()

        final class Body: NSView {
            var groups: [Group] = []
            override var isFlipped: Bool { true }
            override func layout() {
                super.layout()
                var top: CGFloat = 12
                for group in groups {
                    let height = group.neededHeight
                    group.frame = NSRect(x: 12, y: top, width: max(0, bounds.width - 24), height: height)
                    top += height + 10
                }
                if abs(frame.height - (top + 12)) > 0.5 {
                    setFrameSize(NSSize(width: bounds.width, height: top + 12))
                }
            }
        }

        init(_ groups: [Group]) {
            super.init(frame: .zero)
            body.groups = groups
            for group in groups { body.addSubview(group) }
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
            body.setFrameSize(NSSize(width: scroll.contentSize.width, height: body.frame.height))
            body.needsLayout = true
        }

        /// Высота содержимого после раскладки — самопроверке: пустая
        /// страница видна по ней вернее, чем по числу видов.
        var bodyHeight: CGFloat {
            body.layoutSubtreeIfNeeded()
            return body.frame.height
        }
    }

    // MARK: - Управления

    /// Галочка.
    static func check(_ title: String, _ tie: Tie<Bool>, hint: String? = nil) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: Trampoline.shared,
                              action: #selector(Trampoline.fire(_:)))
        button.font = .systemFont(ofSize: 11)
        button.state = tie.get() ? .on : .off
        button.toolTip = hint
        Trampoline.shared.bind(button) { [weak button] in
            guard let button else { return }
            tie.set(button.state == .on)
        }
        Trampoline.shared.bindRefresh(button) { [weak button] in button?.state = tie.get() ? .on : .off }
        return button
    }

    /// Перечитать значения всех управлений в дереве из их связок — без
    /// пересборки. Конструктор раньше на каждое движение ползунка собирал
    /// панель из сорока полей заново; теперь поля стоят, а меняются числа.
    static func refreshValues(in view: NSView) {
        // Поле кольору — свій вид, а не `NSControl`, і його теж треба
        // перечитувати: інакше після правки з іншого місця воно показувало б
        // колишній колір.
        if view is NSControl || view is NativeColourField { Trampoline.shared.refresh(view) }
        for child in view.subviews { refreshValues(in: child) }
    }

    /// Переключатель из нескольких положений — `TRadioGroup` оригинала.
    static func choice(_ titles: [String], _ tie: Tie<Int>) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        for (index, title) in titles.enumerated() {
            let button = NSButton(radioButtonWithTitle: title,
                                  target: Trampoline.shared, action: #selector(Trampoline.fire(_:)))
            button.font = .systemFont(ofSize: 11)
            button.state = tie.get() == index ? .on : .off
            Trampoline.shared.bind(button) { tie.set(index) }
            Trampoline.shared.bindRefresh(button) { [weak button] in button?.state = tie.get() == index ? .on : .off }
            stack.addArrangedSubview(button)
        }
        return stack
    }

    /// Выпадающий список.
    static func popup(_ titles: [String], _ tie: Tie<Int>, width: CGFloat = 240) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 22), pullsDown: false)
        popup.font = .systemFont(ofSize: 11)
        popup.addItems(withTitles: titles.isEmpty ? [""] : titles)
        popup.selectItem(at: min(max(0, tie.get()), max(0, popup.numberOfItems - 1)))
        popup.target = Trampoline.shared
        popup.action = #selector(Trampoline.fire(_:))
        Trampoline.shared.bind(popup) { [weak popup] in
            guard let popup else { return }
            tie.set(popup.indexOfSelectedItem)
        }
        Trampoline.shared.bindRefresh(popup) { [weak popup] in
            guard let popup else { return }
            popup.selectItem(at: min(max(0, tie.get()), max(0, popup.numberOfItems - 1)))
        }
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
        return popup
    }

    /// Поле для числа.
    /// Дробное число: толщина контура в 2,25 пт целым полем не задать —
    /// владелец видел, как на мелком тексте буквы сливаются, потому что
    /// меньше 1 % высоты (≈11 пикселей) выбрать было нельзя.
    static func decimal(_ tie: Tie<Double>, range: ClosedRange<Double>, step: Double = 0.25,
                        width: CGFloat = 80) -> NSTextField {
        func show(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
        }
        let field = NSTextField(string: show(tie.get()))
        field.font = .systemFont(ofSize: 11)
        field.alignment = .right
        field.target = Trampoline.shared
        field.action = #selector(Trampoline.fire(_:))
        Trampoline.shared.bind(field) { [weak field] in
            guard let field else { return }
            let typed = Double(field.stringValue.replacingOccurrences(of: ",", with: ".")) ?? tie.get()
            let stepped = step > 0 ? (typed / step).rounded() * step : typed
            let value = min(max(stepped, range.lowerBound), range.upperBound)
            tie.set(value)
            field.stringValue = show(value)
        }
        // Поле, в котором сейчас печатают, не трогаем: иначе перечитывание
        // значения посреди набора стирало бы недописанное число.
        Trampoline.shared.bindRefresh(field) { [weak field] in
            guard let field, field.currentEditor() == nil else { return }
            field.stringValue = show(tie.get())
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    static func number(_ tie: Tie<Int>, range: ClosedRange<Int>, width: CGFloat = 80) -> NSTextField {
        let field = NSTextField(string: "\(tie.get())")
        field.font = .systemFont(ofSize: 11)
        field.alignment = .right
        field.target = Trampoline.shared
        field.action = #selector(Trampoline.fire(_:))
        Trampoline.shared.bind(field) { [weak field] in
            guard let field else { return }
            let value = min(max(Int(field.stringValue) ?? tie.get(), range.lowerBound), range.upperBound)
            tie.set(value)
            field.stringValue = "\(value)"
        }
        Trampoline.shared.bindRefresh(field) { [weak field] in
            guard let field, field.currentEditor() == nil else { return }
            field.stringValue = "\(tie.get())"
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    /// Поле для строки.
    static func text(_ tie: Tie<String>, width: CGFloat = 260) -> NSTextField {
        let field = NSTextField(string: tie.get())
        field.font = .systemFont(ofSize: 11)
        field.target = Trampoline.shared
        field.action = #selector(Trampoline.fire(_:))
        Trampoline.shared.bind(field) { [weak field] in
            guard let field else { return }
            tie.set(field.stringValue)
        }
        Trampoline.shared.bindRefresh(field) { [weak field] in
            guard let field, field.currentEditor() == nil else { return }
            field.stringValue = tie.get()
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    /// Ползунок с подписью значения.
    static func slider(_ tie: Tie<Double>, range: ClosedRange<Double>,
                       format: @escaping (Double) -> String, width: CGFloat = 200) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        let slider = NSSlider(value: tie.get(), minValue: range.lowerBound, maxValue: range.upperBound,
                              target: Trampoline.shared, action: #selector(Trampoline.fire(_:)))
        let caption = NSTextField(labelWithString: format(tie.get()))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        Trampoline.shared.bind(slider) { [weak slider, weak caption] in
            guard let slider else { return }
            tie.set(slider.doubleValue)
            caption?.stringValue = format(slider.doubleValue)
        }
        Trampoline.shared.bindRefresh(slider) { [weak slider, weak caption] in
            guard let slider else { return }
            let value = tie.get()
            if abs(slider.doubleValue - value) > 0.0001 { slider.doubleValue = value }
            caption?.stringValue = format(value)
        }
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(slider)
        stack.addArrangedSubview(caption)
        return stack
    }

    /// Выбор цвета.
    /// Поле кольору — своє, а не системний `NSColorWell`.
    ///
    /// Палітра macOS малює повзунки в тому просторі кольору, який вибрано в
    /// ній самій, а програма скрізь рахує в sRGB: на «Generic RGB» ті самі
    /// числа дають на слайді інший колір. Власник побачив це як «rgb слайдер
    /// має неправильний колір при зміні значень». Тепер повзунки наші, у
    /// sRGB, і що набрано — те й буде намальовано.
    static func colour(_ tie: Tie<SlideStyle.RGBA>) -> NativeColourField {
        let field = NativeColourField(colour: tie.get())
        field.onChange = { value in tie.set(value) }
        Trampoline.shared.bindRefresh(field) { [weak field] in
            guard let field, !field.isEditing else { return }
            field.colour = tie.get()
        }
        return field
    }

    /// Кнопка с действием.
    static func button(_ title: String, hint: String? = nil, _ action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: Trampoline.shared, action: #selector(Trampoline.fire(_:)))
        button.font = .systemFont(ofSize: 11)
        button.bezelStyle = .rounded
        button.toolTip = hint
        // Знак вместо слова («+», «−», «✎», «☀»…) 11-м кеглем читается как
        // пустая кнопка — владелец так и сказал: «кнопка без надписи».
        // Знакомые знаки рисуем системными значками, подсказка остаётся.
        if let symbol = symbolNames[title],
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: hint ?? title) {
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.setAccessibilityLabel(hint ?? title)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        }
        Trampoline.shared.bind(button) { action() }
        return button
    }

    /// Какие знаки на кнопках чем рисовать.
    static let symbolNames: [String: String] = [
        "+": "plus", "＋": "plus", "−": "minus", "-": "minus",
        "↑": "arrow.up", "↓": "arrow.down", "↗": "arrow.up.right", "↳": "arrow.turn.down.right",
        "🔍": "magnifyingglass", "⤓": "square.and.arrow.down", "⤓…": "square.and.arrow.down.on.square",
        "✎": "pencil", "☀": "display", "⧉": "doc.on.doc", "🗑": "trash",
        "☑": "checkmark.square", "☐": "square",
    ]

    /// Пояснення з переносом — для довгих речень. Звичайна підпись в один
    /// рядок ховала кінець за краєм вікна, а сховане людина не прочитає.
    /// Ширина переносу — як у «Медіа» (`toolStatus`): рядок форми вміщує її
    /// у вікні параметрів.
    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 4
        label.preferredMaxLayoutWidth = 600
        return label
    }

    /// Подпись.
    static func label(_ text: String, secondary: Bool = true) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        if secondary { label.textColor = .secondaryLabelColor }
        return label
    }

    /// Приёмник действий: у `NSControl` цель хранится слабой ссылкой, и
    /// отдельный объект на каждое управление система освободила бы сразу.
    /// Один общий держит их все и знает, чьё действие звать.
    @MainActor
    final class Trampoline: NSObject {
        static let shared = Trampoline()
        /// Действие хранится вместе со слабой ссылкой на элемент: ключ —
        /// адрес объекта, а адреса освободившихся элементов система выдаёт
        /// новым. Без сверки элемент, вставший на место прежнего, мог
        /// сработать чужим действием — цвет ушёл бы не в ту связку.
        private var actions: [ObjectIdentifier: (control: WeakControl, body: () -> Void)] = [:]
        /// Как перечитать значение управления из его связки. Хранится тем же
        /// ключом, что и действие; освободившиеся управления забираются
        /// вместе с действиями по мере накопления.
        private var refreshers: [ObjectIdentifier: (control: WeakControl, body: () -> Void)] = [:]

        /// Слабе посилання на елемент. Тримаємо `NSView`, а не `NSControl`:
        /// поле кольору тепер своє (`NativeColourField`), а не системний
        /// `NSColorWell`, і перечитувати його значення треба так само.
        private final class WeakControl {
            weak var control: NSView?
            init(_ control: NSView) { self.control = control }
        }

        func bind(_ control: NSControl, _ action: @escaping () -> Void) {
            actions[ObjectIdentifier(control)] = (WeakControl(control), action)
        }

        func bindRefresh(_ control: NSView, _ body: @escaping () -> Void) {
            refreshers[ObjectIdentifier(control)] = (WeakControl(control), body)
            // Окна пересобирают формы много раз за жизнь; мёртвые записи
            // вычищаем изредка, чтобы словарь не рос без конца.
            if refreshers.count % 512 == 0 {
                refreshers = refreshers.filter { $0.value.control.control != nil }
                actions = actions.filter { $0.value.control.control != nil }
            }
        }

        func refresh(_ control: NSView) {
            guard let entry = refreshers[ObjectIdentifier(control)], entry.control.control === control else { return }
            entry.body()
        }

        @objc func fire(_ sender: NSControl) {
            guard let entry = actions[ObjectIdentifier(sender)], entry.control.control === sender else { return }
            entry.body()
        }
    }
}
