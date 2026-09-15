import AppKit
import Combine
import SlovoCore

/// Вкладки режима (18) и ползунок размера шрифта списков (20).
///
/// Три вкладки и ползунок — это вся часть. Нажатие на вкладку перекрашивает
/// ДВЕ вкладки: ту, что была выбрана, и ту, что стала. Больше в окне не
/// меняется ничего: рабочую область переставляет её собственный хозяин по
/// поводу `.mode`, а не эта полоса.
///
/// Ползунок привязан к `listFontSize` — к кеглю СПИСКОВ. В прежнем окне он по
/// недосмотру двигал кегль слайда: у автора величина называется
/// `ATB_GUI_FontSize` и подписана «Размер шрифта списков», а зал она не
/// трогает вовсе.
@MainActor
final class NativeModeTabs: NSView {

    private let state: AppState
    private var tabs: [AppState.WorkMode: TabButton] = [:]
    private let smaller = NSImageView()
    private let larger = NSImageView()
    private let slider = NSSlider()
    /// «Оновлення 0.92» — поки на GitHub є новіша версія, ніж ця. Не зникає
    /// після «Пізніше»: пропозицію могли не помітити, а кнопку видно завжди.
    let updateButton = NSButton(title: "", target: nil, action: nil)
    private var updateObserver: Any?
    private var watch: Set<AnyCancellable> = []
    private var tokens: [Signals.Token] = []

    /// Границы кегля списков — те же, что у Ctrl с колесом (`zoomLists`).
    static let fontRange: ClosedRange<Double> = 9...22

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)

        for mode in AppState.WorkMode.allCases {
            let tab = TabButton(symbol: mode.icon)
            tab.onPress = { [weak self] in self?.select(mode) }
            addSubview(tab)
            tabs[mode] = tab
        }

        for (view, name) in [(smaller, "textformat.size.smaller"), (larger, "textformat.size.larger")] {
            view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
            view.contentTintColor = .secondaryLabelColor
            view.imageScaling = .scaleNone
            addSubview(view)
        }

        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.bezelColor = .controlAccentColor
        updateButton.contentTintColor = .white
        updateButton.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        updateButton.imagePosition = .imageLeading
        updateButton.font = .systemFont(ofSize: 11, weight: .semibold)
        updateButton.target = self
        updateButton.action = #selector(updateTapped)
        addSubview(updateButton)
        updateObserver = NotificationCenter.default.addObserver(forName: AppUpdater.availabilityChanged,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyUpdate() }
        }
        applyUpdate()

        slider.minValue = Self.fontRange.lowerBound
        slider.maxValue = Self.fontRange.upperBound
        slider.doubleValue = state.listFontSize
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(slide(_:))
        addSubview(slider)

        applyTitles(state.language)
        applyMode(state.mode)

        state.$language
            .sink { [weak self] language in self?.applyTitles(language) }
            .store(in: &watch)
        state.$mode
            .sink { [weak self] mode in self?.applyMode(mode) }
            .store(in: &watch)
        // Кегль списков меняют и колесом с Ctrl, и из окна «Параметры».
        // Ползунок обязан стоять там, где величина на самом деле.
        state.$listFontSize
            .sink { [weak self] size in self?.applyFontSize(size) }
            .store(in: &watch)
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            guard let self else { return }
            self.applyTitles(self.state.language)
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    // MARK: - Раскладка

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for mode in AppState.WorkMode.allCases {
            guard let tab = tabs[mode] else { continue }
            let width = tab.fittingWidth
            tab.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width + 4
        }

        let iconSide: CGFloat = 16
        let sliderWidth: CGFloat = 120
        let middle = (bounds.height / 2).rounded()
        var right = bounds.width
        right -= iconSide
        larger.frame = NSRect(x: right, y: middle - iconSide / 2, width: iconSide, height: iconSide)
        right -= sliderWidth + 4
        slider.frame = NSRect(x: right, y: middle - 10, width: sliderWidth, height: 20)
        right -= iconSide + 4
        smaller.frame = NSRect(x: right, y: middle - iconSide / 2, width: iconSide, height: iconSide)
        if !updateButton.isHidden {
            let width = ceil(updateButton.fittingSize.width) + 6
            right -= width + 12
            updateButton.frame = NSRect(x: right, y: middle - 11, width: width, height: 22)
        }
    }

    private func applyUpdate() {
        let release = AppUpdater.available
        updateButton.isHidden = release == nil
        updateButton.title = release.map { OurWords.t("Обновление %s", $0.version) } ?? ""
        updateButton.toolTip = OurWords.t("Вышла новая версия «Слова» — нажмите, чтобы обновить")
        needsLayout = true
    }

    @objc private func updateTapped() {
        guard let release = AppUpdater.available else { return }
        AppUpdater.offer(release, state: state)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        NativeTopIcon.flush()
        for tab in tabs.values { tab.refresh() }
        needsLayout = true
    }

    // MARK: - Состояние

    private func applyTitles(_ language: LanguageFile?) {
        for mode in AppState.WorkMode.allCases {
            tabs[mode]?.title = NativeTopCaptions.modeTitle(mode, in: language)
        }
        slider.toolTip = OurWords.t("Размер шрифта списков (или Ctrl и колесо мыши)")
        applyUpdate()
        needsLayout = true
    }

    /// Перекрасить ровно те вкладки, у которых вид изменился.
    private func applyMode(_ mode: AppState.WorkMode) {
        for (each, tab) in tabs { tab.isChosen = (each == mode) }
    }

    private func applyFontSize(_ size: Double) {
        let clamped = min(Self.fontRange.upperBound, max(Self.fontRange.lowerBound, size))
        guard abs(slider.doubleValue - clamped) > 0.001 else { return }
        slider.doubleValue = clamped
    }

    /// Нажали вкладку. Открыто для замера и самопроверки: щёлкать мышью там
    /// некому, а мерить надо ровно то, что делает нажатие.
    func select(_ mode: AppState.WorkMode) {
        guard state.mode != mode else { return }
        state.mode = mode
        // Повод рассылает мост, а не мы: он сверяет снимок и шлёт `.mode`
        // ровно один раз. Пока мы слали его сами, мост на следующем обороте
        // слал его снова — и вся рабочая область перестраивалась дважды.
        NativeBibleBridge.shared.sync()
    }

    /// Ползунок сдвинули на столько-то. То же, что тянуть его мышью.
    func drag(to size: Double) {
        slider.doubleValue = min(Self.fontRange.upperBound,
                                 max(Self.fontRange.lowerBound, size))
        slide(slider)
    }

    /// Какая вкладка нарисована выбранной. Для самопроверки: важно не то, что
    /// записано в состоянии, а то, что видит человек.
    var chosenMode: AppState.WorkMode? {
        tabs.first { $0.value.isChosen }?.key
    }

    /// Где стоит ползунок.
    var fontSize: Double { slider.doubleValue }

    @objc private func slide(_ sender: NSSlider) {
        let size = sender.doubleValue
        guard abs(state.listFontSize - size) > 0.001 else { return }
        state.listFontSize = size
        Signals.shared.send(.listFontSize)
    }

    // MARK: - Вкладка

    /// Вкладка режима. Рисуется сама: заливка, значок, подпись — три вызова.
    private final class TabButton: NSView {

        var title = "" {
            didSet { guard title != oldValue else { return }; refresh() }
        }
        var isChosen = false {
            didSet { guard isChosen != oldValue else { return }; needsDisplay = true }
        }
        var onPress: (() -> Void)?
        private(set) var fittingWidth: CGFloat = 0

        private let symbol: String
        private var plain = NSAttributedString()
        private var chosen = NSAttributedString()
        private var lineSize = NSSize.zero

        private let iconSize: CGFloat = 12
        private let gap: CGFloat = 4
        private let padding: CGFloat = 10
        private let vertical: CGFloat = 3

        init(symbol: String) {
            self.symbol = symbol
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

        override var isFlipped: Bool { true }

        func refresh() {
            let normal = NativeTopDraw.label(title, size: 12, weight: .regular, color: .labelColor)
            let bold = NativeTopDraw.label(title, size: 12, weight: .semibold, color: .white)
            plain = normal.line
            chosen = bold.line
            // Ширину берём по жирной подписи: иначе вкладки прыгали бы на
            // каждое переключение режима.
            lineSize = NSSize(width: max(normal.size.width, bold.size.width),
                              height: max(normal.size.height, bold.size.height))
            fittingWidth = (padding * 2 + iconSize + gap + lineSize.width).rounded(.up)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let height = (lineSize.height + vertical * 2).rounded(.up)
            let top = ((bounds.height - height) / 2).rounded()
            if isChosen {
                NativeTopDraw.pill(NSRect(x: 0, y: top, width: bounds.width, height: height),
                                   color: NativeTopDraw.selectionFill)
            }
            let color: NSColor = isChosen ? .white : .labelColor
            var x = padding
            if let icon = NativeTopIcon.symbol(symbol, size: iconSize,
                                               weight: isChosen ? .semibold : .regular,
                                               tint: color, role: isChosen ? "белый" : "обычный") {
                let box = NSRect(x: x, y: ((bounds.height - icon.size.height) / 2).rounded(),
                                 width: icon.size.width, height: icon.size.height)
                icon.draw(in: box)
                x += iconSize + gap
            }
            let text = isChosen ? chosen : plain
            text.draw(at: NSPoint(x: x, y: ((bounds.height - lineSize.height) / 2).rounded()))
        }

        override func mouseDown(with event: NSEvent) { onPress?() }
    }
}
