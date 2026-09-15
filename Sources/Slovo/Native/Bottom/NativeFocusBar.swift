import AppKit
import SlovoCore

/// Смуга наближення під живим екраном: точка фокуса для презентацій і
/// зображень.
///
/// Власник: «масштабирование содержимого для более удобной демонстрации
/// участка, на который нужно обратить внимание (точка фокуса)» і «добавить
/// точки фокуса для презентаций».
///
/// Правило просте: увімкнули наближення, натиснули по живому екрану — цей
/// шматок сторінки став на весь екран у залі. Вимкнули — повернулася вся
/// сторінка. Сама сторінка при цьому не міняється: наближення це лупа, а не
/// правка вмісту.
@MainActor
final class NativeFocusBar: NSView {

    private let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let zoom = NSSlider(value: 200, minValue: SlideFocus.minZoom * 100,
                                maxValue: SlideFocus.maxZoom * 100, target: nil, action: nil)
    private let zoomLabel = NSTextField(labelWithString: "")
    private let centerButton = NSButton(title: "", target: nil, action: nil)
    private var tokens: [Signals.Token] = []
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toggle.controlSize = .mini
        toggle.font = .systemFont(ofSize: 10)
        toggle.target = self
        toggle.action = #selector(toggled)
        zoom.isContinuous = true
        zoom.controlSize = .mini
        zoom.target = self
        zoom.action = #selector(zoomed)
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        zoomLabel.textColor = .secondaryLabelColor
        centerButton.controlSize = .mini
        centerButton.font = .systemFont(ofSize: 10)
        centerButton.bezelStyle = .rounded
        centerButton.target = self
        centerButton.action = #selector(centered)
        for view in [toggle, zoom, zoomLabel, centerButton] as [NSView] { addSubview(view) }
        applyCaptions()
        show()
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in self?.applyCaptions() })
        observer = NotificationCenter.default.addObserver(forName: SlideFocus.changed, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.show() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func applyCaptions() {
        toggle.title = OurWords.t("Приближение")
        toggle.toolTip = OurWords.t("Нажмите по живому экрану — этот кусок страницы станет во весь экран")
        centerButton.title = OurWords.t("В центр")
        centerButton.toolTip = OurWords.t("Вернуть взгляд на середину страницы")
        zoom.toolTip = OurWords.t("Во сколько раз приблизить")
        toolTip = OurWords.t("Нажмите по живому экрану — этот кусок страницы станет во весь экран")
        show()
    }

    private func show() {
        let focus = SlideFocus.shared
        toggle.state = focus.isOn ? .on : .off
        zoom.isEnabled = focus.isOn
        centerButton.isEnabled = focus.isOn
        if abs(zoom.doubleValue - focus.look.zoom * 100) > 0.5 { zoom.doubleValue = focus.look.zoom * 100 }
        zoomLabel.stringValue = String(format: "×%.1f", focus.look.zoom)
        needsLayout = true
    }

    @objc private func toggled() {
        SlideFocus.shared.setOn(toggle.state == .on)
    }

    @objc private func zoomed() {
        SlideFocus.shared.setZoom(zoom.doubleValue / 100)
    }

    @objc private func centered() {
        SlideFocus.shared.center()
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 4
        let height = bounds.height
        var x: CGFloat = 0
        let toggleWidth = min(120, max(70, bounds.width * 0.3))
        toggle.frame = NSRect(x: x, y: 0, width: toggleWidth, height: height)
        x += toggleWidth + gap
        let buttonWidth: CGFloat = 62
        centerButton.frame = NSRect(x: max(x, bounds.width - buttonWidth), y: 0,
                                    width: buttonWidth, height: height)
        let labelWidth: CGFloat = 30
        let free = max(0, centerButton.frame.minX - x - gap - labelWidth)
        zoom.frame = NSRect(x: x, y: 1, width: free, height: height - 2)
        x += free + 2
        zoomLabel.frame = NSRect(x: x, y: 1, width: labelWidth, height: height - 2)
    }

    /// Самоперевірці: що зараз стоїть у смузі.
    var chosenForCheck: (on: Bool, zoom: Double) { (toggle.state == .on, zoom.doubleValue / 100) }

    /// Самоперевірці: поставити значення так, як це робить людина.
    func setForCheck(on: Bool? = nil, zoom value: Double? = nil) {
        if let on { toggle.state = on ? .on : .off; toggled() }
        if let value { zoom.doubleValue = value * 100; zoomed() }
    }
}
