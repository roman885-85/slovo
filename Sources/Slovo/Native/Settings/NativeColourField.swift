import AppKit
import SlovoCore

/// Поле кольору: квадратик із кольором, а за ним — свої повзунки R, G, B.
///
/// Раніше тут стояв системний `NSColorWell` з палітрою macOS. Власник:
/// «в конструкторе слайдов в настройке цвета текста rgb слайдер имеет
/// неправильный цвет при изменении значений». Палітра малює свої повзунки в
/// тому просторі кольору, який людина вибрала в ній самій, а програма скрізь
/// рахує в sRGB; на «Generic RGB» або «Display P3» ті самі числа дають на
/// екрані інший колір, і повзунок чесно показує не те, що вийде на слайді.
///
/// Тому палітра прибрана. Тут три повзунки 0…255 у sRGB, поле «#RRGGBB» і
/// зразок: що набрано, те й буде намальовано. Смуга кожного повзунка
/// пофарбована своїм каналом — видно, куди тягнути.
@MainActor
final class NativeColourField: NSView {

    /// Колір поля. Ззовні ставиться при перечитуванні значень.
    var colour: SlideStyle.RGBA {
        didSet {
            guard colour != oldValue else { return }
            needsDisplay = true
            editor?.show(colour)
        }
    }

    /// Кличеться на кожну зміну — і повзунком, і полем «#RRGGBB».
    var onChange: ((SlideStyle.RGBA) -> Void)?

    /// Чи відкрито зараз віконце вибору. Перечитування значень не має
    /// смикати поле, поки людина тягне повзунок.
    var isEditing: Bool { popover?.isShown ?? false }

    private var popover: NSPopover?
    private weak var editor: NativeColourEditor?

    init(colour: SlideStyle.RGBA) {
        self.colour = colour
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 22))
        toolTip = OurWords.t("Цвет: нажмите, чтобы задать R, G, B")
        // Підказку ставимо раз при побудові, а мову міняють при живій
        // програмі — перекладаємо її заново.
        languageToken = Signals.shared.subscribe(.language) { [weak self] in
            self?.toolTip = OurWords.t("Цвет: нажмите, чтобы задать R, G, B")
        }
    }

    private var languageToken: Signals.Token?

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        // Шахівка під кольором: без неї напівпрозорий колір не відрізнити
        // від світлого.
        NSColor.white.setFill()
        path.fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        let step: CGFloat = 5
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        var y = box.minY
        var row = 0
        while y < box.maxY {
            var x = box.minX + (row % 2 == 0 ? 0 : step)
            while x < box.maxX {
                NSRect(x: x, y: y, width: step, height: step).intersection(box).fill()
                x += step * 2
            }
            y += step
            row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(srgbRed: colour.red, green: colour.green, blue: colour.blue, alpha: colour.alpha).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        open()
    }

    /// Погашене поле не відкривається — так поводиться і кнопка.
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.4 } }

    /// Відкрити віконце вибору. Відкрито назовні: самоперевірці треба
    /// побачити самі повзунки, а не лише підсумок.
    func open() {
        if let popover, popover.isShown { popover.close(); return }
        let editor = NativeColourEditor(colour: colour) { [weak self] fresh in
            guard let self else { return }
            self.colour = fresh
            self.needsDisplay = true
            self.onChange?(fresh)
        }
        let popover = NSPopover()
        popover.contentViewController = editor
        popover.behavior = .transient
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
        self.editor = editor
    }

    func closeEditor() { popover?.close() }

    /// Самоперевірці: поставити колір так само, як це робить людина повзунком.
    func pickForCheck(_ fresh: SlideStyle.RGBA) {
        colour = fresh
        needsDisplay = true
        onChange?(fresh)
    }
}

/// Віконце вибору кольору: три повзунки, поле «#RRGGBB» і зразок.
@MainActor
final class NativeColourEditor: NSViewController {

    private let red = NativeChannelSlider(channel: 0)
    private let green = NativeChannelSlider(channel: 1)
    private let blue = NativeChannelSlider(channel: 2)
    private let numbers = [NSTextField(labelWithString: ""), NSTextField(labelWithString: ""),
                           NSTextField(labelWithString: "")]
    private let hex = NSTextField(string: "")
    private let sample = NSView()
    private var alpha: Double
    private let report: (SlideStyle.RGBA) -> Void
    /// Поки значення ставимо самі, зворотний виклик не потрібен.
    private var quiet = false

    init(colour: SlideStyle.RGBA, report: @escaping (SlideStyle.RGBA) -> Void) {
        self.alpha = colour.alpha
        self.report = report
        super.init(nibName: nil, bundle: nil)
        show(colour)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 132))
        sample.wantsLayer = true
        sample.layer?.cornerRadius = 4
        sample.layer?.borderWidth = 1
        sample.layer?.borderColor = NSColor.separatorColor.cgColor
        root.addSubview(sample)

        let titles = ["R", "G", "B"]
        for (index, slider) in [red, green, blue].enumerated() {
            // Смуга повзунка пофарбована так, який колір вийде, коли тягнути
            // саме її: два інші канали стоять на своїх місцях, а цей іде від
            // нуля до 255. Власник: «если ползунки цветов находятся не в
            // положении ноль, то они показывают не правильное свое значение
            // цвета внутри ползунка» — рівно тому, що системна палітра малює
            // смугу в своєму просторі кольору й не зважає на решту каналів.
            slider.onChange = { [weak self] _ in self?.slid() }
            root.addSubview(slider)
            let title = NSTextField(labelWithString: titles[index])
            title.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            title.tag = 100 + index
            root.addSubview(title)
            numbers[index].font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            numbers[index].alignment = .right
            root.addSubview(numbers[index])
        }
        hex.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hex.target = self
        hex.action = #selector(typed)
        root.addSubview(hex)
        view = root
        layout(root)
        redraw()
    }

    private func layout(_ root: NSView) {
        let left: CGFloat = 10, width: CGFloat = 230
        sample.frame = NSRect(x: left, y: 100, width: width, height: 24)
        var y: CGFloat = 74
        for index in 0..<3 {
            root.viewWithTag(100 + index)?.frame = NSRect(x: left, y: y, width: 14, height: 16)
            [red, green, blue][index].frame = NSRect(x: left + 18, y: y - 3, width: width - 18 - 40, height: 22)
            numbers[index].frame = NSRect(x: left + width - 36, y: y, width: 36, height: 16)
            y -= 24
        }
        hex.frame = NSRect(x: left, y: 6, width: 100, height: 20)
    }

    /// Поставити значення ззовні — коли колір змінили не тут.
    func show(_ colour: SlideStyle.RGBA) {
        quiet = true
        alpha = colour.alpha
        red.value = (colour.red * 255).rounded()
        green.value = (colour.green * 255).rounded()
        blue.value = (colour.blue * 255).rounded()
        quiet = false
        if isViewLoaded { redraw() }
    }

    private var current: SlideStyle.RGBA {
        SlideStyle.RGBA(red.value / 255, green.value / 255, blue.value / 255, alpha)
    }

    private func slid() {
        redraw()
        guard !quiet else { return }
        report(current)
    }

    @objc private func typed() {
        guard let parsed = SlidePointer.Look.colour(fromHex: hex.stringValue) else { redraw(); return }
        quiet = true
        red.value = (parsed.red * 255).rounded()
        green.value = (parsed.green * 255).rounded()
        blue.value = (parsed.blue * 255).rounded()
        quiet = false
        redraw()
        report(current)
    }

    private func redraw() {
        let value = current
        sample.layer?.backgroundColor = CGColor(srgbRed: value.red, green: value.green,
                                                blue: value.blue, alpha: 1)
        for (index, slider) in [red, green, blue].enumerated() {
            // Смуга кожного повзунка перемальовується під поточний колір:
            // рухаєш зелений — червона і синя смуги міняються теж, бо
            // результат буде інший.
            slider.base = value
            numbers[index].stringValue = String(Int(slider.value.rounded()))
        }
        let text = SlidePointer.Look.hex(value)
        if hex.stringValue.uppercased() != text.uppercased() { hex.stringValue = text }
    }
}

/// Повзунок одного каналу кольору: смуга показує, що вийде.
///
/// Свій, а не `NSSlider`: системна смуга фарбується однією фарбою і нічого
/// не знає про два інші канали. Тут смуга — це справжній перехід від «цей
/// канал у нулі» до «цей канал на максимумі» при тих значеннях, які зараз
/// стоять у сусідів. Видно не «де ручка», а «який буде колір».
@MainActor
final class NativeChannelSlider: NSView {

    /// Значення каналу, 0…255.
    var value: Double = 0 {
        didSet {
            let clamped = min(255, max(0, value))
            if clamped != value { value = clamped; return }
            if value != oldValue { needsDisplay = true }
        }
    }

    /// Решта кольору — з нею малюється смуга.
    var base = SlideStyle.RGBA(0, 0, 0, 1) { didSet { needsDisplay = true } }

    var onChange: ((Double) -> Void)?

    private let channel: Int

    init(channel: Int) {
        self.channel = channel
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
        // Своє кільце навколо ручки замість системної рамки навколо всього
        // виду: рамка тут закривала б саму смугу.
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 22) }

    override var acceptsFirstResponder: Bool { true }

    /// Півширини ручки: у ці поля смуга не заходить, щоб ручка на краю не
    /// виїжджала за вид.
    private var inset: CGFloat { 7 }

    private var trackRect: CGRect {
        CGRect(x: inset, y: bounds.midY - 4, width: max(1, bounds.width - inset * 2), height: 8)
    }

    private func colour(at share: Double) -> CGColor {
        var parts = [base.red, base.green, base.blue]
        parts[channel] = min(1, max(0, share))
        return CGColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let track = trackRect
        let path = NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4)

        context.saveGState()
        path.addClip()
        // Перехід малюємо сходинками: одна `CGGradient` на два кольори тут
        // збрехала б на середині — між чорним і чистим каналом колір іде не
        // по прямій, коли сусіди не в нулі.
        let steps = max(8, Int(track.width / 2))
        for step in 0..<steps {
            let share = Double(step) / Double(steps - 1)
            context.setFillColor(colour(at: share))
            let x = track.minX + track.width * CGFloat(step) / CGFloat(steps)
            context.fill(CGRect(x: x, y: track.minY, width: track.width / CGFloat(steps) + 1,
                                height: track.height))
        }
        context.restoreGState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        // Ручка: біле кільце з тонкою рамкою — видно і на світлій, і на
        // темній частині смуги.
        let x = track.minX + track.width * CGFloat(min(255, max(0, value)) / 255)
        let knob = CGRect(x: x - 6, y: bounds.midY - 6, width: 12, height: 12)
        let circle = NSBezierPath(ovalIn: knob)
        NSColor.white.setFill()
        circle.fill()
        (window?.firstResponder === self ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        circle.lineWidth = window?.firstResponder === self ? 2 : 1
        circle.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        take(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        take(convert(event.locationInWindow, from: nil))
    }

    private func take(_ point: CGPoint) {
        let track = trackRect
        let share = min(1, max(0, (point.x - track.minX) / track.width))
        let fresh = (Double(share) * 255).rounded()
        guard fresh != value else { return }
        value = fresh
        onChange?(fresh)
    }

    /// Стрілками — по одиниці, з Shift — по десять. Точне число набирають у
    /// полі «#RRGGBB», а стрілками доводять на око.
    override func keyDown(with event: NSEvent) {
        let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        let fresh: Double
        switch event.keyCode {
        case 123, 125: fresh = max(0, value - step)
        case 124, 126: fresh = min(255, value + step)
        default: super.keyDown(with: event); return
        }
        guard fresh != value else { return }
        value = fresh
        onChange?(fresh)
    }

    /// Самоперевірці: поставити значення так, як це робить рука.
    func setForCheck(_ fresh: Double) {
        value = fresh
        onChange?(fresh)
    }
}
