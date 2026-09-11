import AppKit
import SlovoCore

/// Смуга налаштувань указки під живим екраном — на головній сторінці.
///
/// Власник: «настройку вынести на главную страницу программы, результат
/// настройки должен быть наглядно показан». Тому колір, розмір і яскравість
/// стоять тут же, поруч із живим екраном: покрутив — і одразу бачиш пляму
/// на зразку, а натиснув мишею по екрану — і в залі.
///
/// Ті самі значення лежать і в «Параметри → Слайд → Указка»: тут вони не
/// дублюються, а правлять один і той самий запис налаштувань.
@MainActor
final class NativePointerBar: NSView {

    private let colourField: NativeColourField
    private let size = NSSlider(value: 14, minValue: 3, maxValue: 60, target: nil, action: nil)
    private let brightness = NSSlider(value: 45, minValue: 5, maxValue: 100, target: nil, action: nil)
    private let outputs = NSSegmentedControl(labels: ["", "", ""], trackingMode: .selectOne,
                                             target: nil, action: nil)
    private let sample = NativePointerSample()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let brightLabel = NSTextField(labelWithString: "")
    private let state: AppState
    private var tokens: [Signals.Token] = []
    private var observer: NSObjectProtocol?

    init(state: AppState) {
        self.state = state
        colourField = NativeColourField(colour: SlidePointer.shared.baseLook.colour)
        super.init(frame: .zero)

        colourField.onChange = { [weak self] _ in self?.apply() }
        for slider in [size, brightness] {
            slider.isContinuous = true
            slider.controlSize = .mini
            slider.target = self
            slider.action = #selector(slid)
        }
        for label in [sizeLabel, brightLabel] {
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
        }
        outputs.controlSize = .mini
        outputs.font = .systemFont(ofSize: 9)
        outputs.segmentStyle = .rounded
        outputs.target = self
        outputs.action = #selector(outputChosen)

        for view in [colourField, size, brightness, outputs, sample, sizeLabel, brightLabel] as [NSView] {
            addSubview(view)
        }
        applyCaptions()
        show(SlidePointer.shared.baseLook)

        tokens.append(Signals.shared.subscribe(.language) { [weak self] in self?.applyCaptions() })
        // Вид указки міняють і з вікна «Параметри», і з телефона — смуга
        // має показувати те, що зараз чинне.
        observer = NotificationCenter.default.addObserver(forName: SlidePointer.changed, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.show(SlidePointer.shared.baseLook) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func applyCaptions() {
        // Підказки теж перекладаються: вони ставляться раз при побудові, а
        // мову міняють при живій програмі.
        size.toolTip = OurWords.t("Размер пятна — доля высоты кадра")
        brightness.toolTip = OurWords.t("Яркость пятна")
        colourField.toolTip = OurWords.t("Цвет: нажмите, чтобы задать R, G, B")
        sizeLabel.stringValue = OurWords.t("Размер")
        brightLabel.stringValue = OurWords.t("Яркость")
        // Підписи короткі навмисно: колонка живого екрана вузька, а «Проектор»
        // у трьох сегментах обрізається до «Про…». «Зал» — те саме слово, яким
        // проектор називається в усій програмі.
        outputs.setLabel(OurWords.t("Все"), forSegment: 0)
        outputs.setLabel(OurWords.t("Зал"), forSegment: 1)
        outputs.setLabel("NDI", forSegment: 2)
        outputs.toolTip = OurWords.t("Куда выводить указку: везде, только в зал (проектор) или только в NDI")
        toolTip = OurWords.t("Указка: нажмите левой кнопкой по живому экрану и ведите не отпуская")
        needsLayout = true
    }

    /// Показати те, що зараз у налаштуваннях.
    private func show(_ look: SlidePointer.Look) {
        colourField.colour = look.colour
        size.doubleValue = (look.size * 100).rounded()
        brightness.doubleValue = (look.opacity * 100).rounded()
        outputs.selectedSegment = look.toProjector && look.toNDI ? 0 : (look.toProjector ? 1 : 2)
        sample.look = look
        needsLayout = true
    }

    @objc private func slid() { apply() }
    @objc private func outputChosen() { apply() }

    /// Записати вибране: у живу указку і в налаштування програми.
    private func apply() {
        var look = SlidePointer.shared.baseLook
        look.colour = colourField.colour
        look.size = size.doubleValue / 100
        look.opacity = brightness.doubleValue / 100
        switch outputs.selectedSegment {
        case 1: look.toProjector = true;  look.toNDI = false
        case 2: look.toProjector = false; look.toNDI = true
        default: look.toProjector = true; look.toNDI = true
        }
        SlidePointer.shared.apply(look: look)
        sample.look = look

        let store = SettingsStore.shared
        store.settings.options.pointerColour = SlidePointer.Look.hex(look.colour)
        store.settings.options.pointerSize = look.size
        store.settings.options.pointerOpacity = look.opacity
        store.settings.options.pointerProjector = look.toProjector
        store.settings.options.pointerNDI = look.toNDI
        store.saveOutsideEditing()
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 4
        let height = bounds.height
        var x: CGFloat = 0
        sample.frame = NSRect(x: x, y: 0, width: height, height: height)
        x += height + gap
        colourField.frame = NSRect(x: x, y: 1, width: 34, height: height - 2)
        x += 34 + gap
        // Перемикач виводу тримаємо праворуч: він найважливіший і не має
        // з'їжджати з очей, коли колонка вузька.
        let outputsWidth = min(160, max(112, bounds.width * 0.34))
        outputs.frame = NSRect(x: max(x, bounds.width - outputsWidth), y: 0,
                               width: outputsWidth, height: height)
        let free = max(0, outputs.frame.minX - x - gap)
        // Підписи «Розмір» і «Яскравість» ставимо, лише коли є місце: у
        // вузькій колонці важливіші самі повзунки.
        let showLabels = free > 190
        sizeLabel.isHidden = !showLabels
        brightLabel.isHidden = !showLabels
        let labelWidth: CGFloat = showLabels ? 48 : 0
        let sliderWidth = max(0, (free - labelWidth * 2 - gap * 3) / 2)
        if showLabels {
            sizeLabel.frame = NSRect(x: x, y: 2, width: labelWidth, height: height - 4)
            x += labelWidth
        }
        size.frame = NSRect(x: x, y: 1, width: sliderWidth, height: height - 2)
        x += sliderWidth + gap
        if showLabels {
            brightLabel.frame = NSRect(x: x, y: 2, width: labelWidth, height: height - 4)
            x += labelWidth
        }
        brightness.frame = NSRect(x: x, y: 1, width: sliderWidth, height: height - 2)
    }

    /// Самоперевірці: що зараз стоїть у смузі.
    var chosenForCheck: (colour: SlideStyle.RGBA, size: Double, opacity: Double, outputs: Int) {
        (colourField.colour, size.doubleValue / 100, brightness.doubleValue / 100, outputs.selectedSegment)
    }

    /// Самоперевірці: поставити значення так, як це робить людина.
    func setForCheck(colour: SlideStyle.RGBA? = nil, sizePercent: Double? = nil,
                     brightnessPercent: Double? = nil, output: Int? = nil) {
        if let colour { colourField.colour = colour }
        if let sizePercent { size.doubleValue = sizePercent }
        if let brightnessPercent { brightness.doubleValue = brightnessPercent }
        if let output { outputs.selectedSegment = output }
        apply()
    }
}

/// Зразок плями: те саме коло, що ляже на екран.
///
/// Заради нього все й затівалося: власник просив, щоб «результат настройки
/// был наглядно показан», а пляма на стіні видна лише поки тримаєш мишу.
@MainActor
final class NativePointerSample: NSView {

    var look = SlidePointer.Look() { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        // Розмір пляма має в частках висоти кадру; у зразку висота своя,
        // тому й доля та сама — видно, наскільки пляма велика.
        let radius = max(1.5, min(bounds.height, bounds.width) * look.size / 2 * 3)
        let rect = NSRect(x: bounds.midX - radius, y: bounds.midY - radius,
                          width: radius * 2, height: radius * 2)
        NSColor(srgbRed: look.colour.red, green: look.colour.green,
                blue: look.colour.blue, alpha: look.opacity).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor(srgbRed: look.colour.red, green: look.colour.green,
                blue: look.colour.blue, alpha: min(1, look.opacity + 0.4)).setStroke()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }
}
