import AppKit
import Combine
import SlovoCore

/// Нижній ряд головного вікна: План (10) | Історія (11) | Передпоказ (12) |
/// Керування (13).
///
/// Чотири панелі живуть постійно і не знають одна про одну. Зміна вірша доходить
/// лише до передпоказу, правка плану — лише до плану. Нічого спільного,
/// що перезбиралося б «за компанію», тут немає: саме через таку спільну
/// перезбірку колишнє вікно й витрачало дві сотні мілісекунд на натискання.
///
/// Розкладка рахується арифметикою в `layout()`. Ні `HSplitView`, ні
/// обмежень: чотири прямокутники — це чотири додавання.
@MainActor
final class NativeBottomRow: NSView {

    let plan: NativePlanPane
    let history: NativeHistoryPane
    let preview: NativeSlidePreview
    let control: NativeControlPanel
    /// Живий екран: те саме, що зараз на стіні. Стоїть ПОРУЧ із передпоказом,
    /// а не замість нього — власник: «внизу окна программы рядом с окном
    /// предпросмотра окно лайв вывода».
    let mirror: NativeProjectorMirror
    /// Смуга налаштувань указки під живим екраном.
    let pointerBar: NativePointerBar
    /// Смуга наближення до точки фокуса — під нею.
    let focusBar = NativeFocusBar()
    private let mirrorWindowButton = NSButton(title: "⤢", target: nil, action: nil)
    /// Роздільник між передпоказом і живим екраном: за нього тягнуть ширину.
    private let liveDivider = NativeLiveWidthGrip()
    private let liveCaption = NativeBottomCaption()
    /// Чи видно живий екран. Ширина нуль — його немає; тягнуть роздільником.
    var showsMirror: Bool { NativeBottomMetrics.liveWidth > 0 }

    private let state: AppState
    private let desk = DeskModel.shared

    private let planCaption = NativeBottomCaption()
    private let historyCaption = NativeBottomCaption()
    private let previewCaption = NativeBottomCaption()
    private let controlCaption = NativeBottomCaption()

    private var tokens: [Signals.Token] = []
    private var sinks: [AnyCancellable] = []
    private var keyWatch: Any?
    private var focused: NSResponder?

    init(state: AppState) {
        self.state = state
        plan = NativePlanPane(state: state)
        history = NativeHistoryPane(state: state)
        preview = NativeSlidePreview(frame: .zero)
        mirror = NativeProjectorMirror(state: state)
        pointerBar = NativePointerBar(state: state)
        control = NativeControlPanel(state: state)
        super.init(frame: .zero)

        for view in [planCaption, historyCaption, previewCaption, liveCaption, controlCaption] {
            addSubview(view)
        }
        addSubview(plan)
        addSubview(history)
        addSubview(preview)
        addSubview(mirror)
        addSubview(pointerBar)
        addSubview(focusBar)
        addSubview(control)
        liveDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            // Тягнемо вліво — живий екран ширшає.
            NativeBottomMetrics.liveWidth = NativeBottomMetrics.liveWidth - delta
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        addSubview(liveDivider)
        mirrorWindowButton.controlSize = .mini
        mirrorWindowButton.font = .systemFont(ofSize: 11)
        mirrorWindowButton.isBordered = false
        mirrorWindowButton.target = self
        mirrorWindowButton.action = #selector(openMirrorWindow)
        addSubview(mirrorWindowButton)
        applyMirrorChoice()

        tokens.append(Signals.shared.subscribe([.slide, .layout]) { [weak self] _ in
            self?.refreshPreview()
        })
        tokens.append(Signals.shared.subscribe(.live) { [weak self] in
            guard let self else { return }
            self.preview.isLive = self.state.isLive
        })
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in self?.applyCaptions() })

        // Кадр плеєра поверх слайда («Відображати відео у вікні передпоказу»).
        // Свого приводу в цього немає і заводити його нема чого: перевірка коштує
        // трьох порівнянь, а шар заводиться один раз за все служіння.
        // objectWillChange приходить ДО присвоєння — читаємо стан наступним оборотом.
        sinks.append(state.media.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshVideo() }
        })
        // Повідомлення «план не прочитався» показуємо одразу: в оригіналі це
        // теж вікно з однією кнопкою, а не рядок у кутку.
        sinks.append(desk.$planWarning.dropFirst().sink { [weak self] warning in
            guard let warning, !warning.isEmpty else { return }
            self?.showPlanWarning(warning)
        })

        applyCaptions()
        preview.isLive = state.isLive
        refreshVideo()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    /// Підняти нижній ряд у новому вікні. Повертає готовий ряд — його тримає
    /// той, хто покликав, разом із перекладачем приводів.
    @discardableResult
    static func install(state: AppState) -> NativeBottomRow {
        let row = NativeBottomRow(state: state)
        NativeMainWindowController.shared.install(row, in: .bottomRow)
        return row
    }

    // MARK: - Розкладка

    override func layout() {
        super.layout()
        let padding = NativeBottomMetrics.padding
        let gap = NativeBottomMetrics.gap
        let captionHeight = NativeBottomMetrics.captionHeight
        let top = padding
        let contentY = top + captionHeight + NativeBottomMetrics.captionGap
        let contentHeight = max(0, bounds.height - contentY - padding)

        var planWidth = NativeBottomMetrics.planWidth
        var historyWidth = NativeBottomMetrics.historyWidth
        let controlWidth = NativeBottomMetrics.controlWidth
        // Живий екран стоїть поруч із передпоказом і має свою ширину: її
        // тягне оператор роздільником між ними. Нуль — екрана немає.
        var liveWidth = NativeBottomMetrics.liveWidth
        var dividerWidth = liveWidth > 0 ? NativeBottomMetrics.dividerWidth : 0
        var previewWidth = bounds.width - planWidth - historyWidth - controlWidth
            - liveWidth - dividerWidth - gap * 3

        // Вікну тісно: спершу стискаються списки, і лише до своїх меж.
        // Передпоказ віддає місце передостаннім, живий екран — останнім: по
        // ньому ведуть указку, і відбирати в нього ширину без потреби не можна.
        if previewWidth < NativeBottomMetrics.previewMinWidth {
            var lack = NativeBottomMetrics.previewMinWidth - previewWidth
            let fromPlan = min(lack, planWidth - NativeBottomMetrics.planMinWidth)
            planWidth -= fromPlan
            lack -= fromPlan
            let fromHistory = min(lack, historyWidth - NativeBottomMetrics.historyMinWidth)
            historyWidth -= fromHistory
            lack -= fromHistory
            if lack > 0, liveWidth > 0 {
                // Далі забирати нема звідки — вужчаємо живий екран, а якщо і
                // його межа скінчилася, ховаємо його зовсім.
                let fromLive = min(lack, liveWidth - NativeBottomMetrics.liveMinWidth)
                liveWidth -= fromLive
                lack -= fromLive
                if lack > 0 { liveWidth = 0; dividerWidth = 0 }
            }
        } else if previewWidth > NativeBottomMetrics.previewMinWidth {
            // Вікну просторо. Зайве віддаємо спискам, а не порожнечі справа від
            // слайда: слайд тримає 4:3 і впирається у висоту ряду, тож
            // ширини йому все одно не треба. Так розтягувалося й колишнє вікно.
            //
            // Першою добирає Історія: у ній рядки найдовші у вікні
            // («1-я Паралипоменон 7:18- 18 …»), і обривається вона першою.
            var spare = previewWidth - NativeBottomMetrics.previewMinWidth
            let toHistory = min(spare, NativeBottomMetrics.historyMaxWidth - historyWidth)
            historyWidth += toHistory
            spare -= toHistory
            planWidth += min(spare, NativeBottomMetrics.planMaxWidth - planWidth)
        }
        previewWidth = max(0, bounds.width - planWidth - historyWidth - controlWidth
                           - liveWidth - dividerWidth - gap * 3)

        var x: CGFloat = 0
        func place(_ caption: NSView, _ content: NSView, width: CGFloat) {
            caption.frame = NSRect(x: x + 6, y: top, width: max(0, width - 6), height: captionHeight)
            content.frame = NSRect(x: x, y: contentY, width: width, height: contentHeight)
            x += width + gap
        }

        place(planCaption, plan, width: planWidth)
        place(historyCaption, history, width: historyWidth)

        // Слайд тримає сторони 4:3 і притиснутий вліво — так само, як у колишньому вікні.
        previewCaption.frame = NSRect(x: x + 6, y: top, width: max(0, previewWidth - 6),
                                      height: captionHeight)
        let slideHeight = min(contentHeight, previewWidth * 3 / 4)
        preview.frame = NSRect(x: x, y: contentY,
                               width: slideHeight * 4 / 3, height: slideHeight)
        x += previewWidth

        // Роздільник між передпоказом і живим екраном.
        liveDivider.isHidden = dividerWidth <= 0
        if dividerWidth > 0 {
            liveDivider.frame = NSRect(x: x, y: contentY, width: dividerWidth, height: contentHeight)
            x += dividerWidth
        } else {
            x += gap
        }

        // Живий екран: підпис із кнопкою окремого вікна, сам екран і смуга
        // налаштувань указки під ним.
        let hasLive = liveWidth > 0
        mirror.isHidden = !hasLive
        pointerBar.isHidden = !hasLive
        focusBar.isHidden = !hasLive
        liveCaption.isHidden = !hasLive
        mirrorWindowButton.isHidden = !hasLive
        if hasLive {
            let buttonWidth: CGFloat = 18
            liveCaption.frame = NSRect(x: x + 6, y: top,
                                       width: max(0, liveWidth - 6 - buttonWidth - 4), height: captionHeight)
            mirrorWindowButton.frame = NSRect(x: x + liveWidth - buttonWidth, y: top - 2,
                                              width: buttonWidth, height: captionHeight + 4)
            // Під екраном дві смуги: указка і наближення. Ряд тягнеться
            // вгору, тож місце під них є; коли ряд зовсім низький, смуги
            // з'їдають екран, а не зникають — інакше ручки було б не знайти.
            let barHeight = NativeBottomMetrics.pointerBarHeight
            let screenHeight = max(0, contentHeight - barHeight * 2 - 4)
            mirror.frame = NSRect(x: x, y: contentY, width: liveWidth, height: screenHeight)
            pointerBar.frame = NSRect(x: x, y: contentY + screenHeight + 2,
                                      width: liveWidth, height: barHeight)
            focusBar.frame = NSRect(x: x, y: contentY + screenHeight + barHeight + 4,
                                    width: liveWidth, height: barHeight)
            x += liveWidth + gap
        }

        place(controlCaption, control, width: controlWidth)
    }

    // MARK: - Оновлення

    /// Єдина робота нижнього ряду на зміну вірша: перемалювати слайд
    /// передпоказу. Решта трьох панелей про це не дізнається зовсім.
    func refreshPreview() {
        // Вкладки показу готують картинку, а не текст: вона й має бути в
        // передпоказі — те, що піде в зал. Нічого не вибрано — порожньо, а
        // не вірш з іншої вкладки: він з цієї вкладки в зал не піде.
        if state.mode == .pictures || state.mode == .presentation {
            preview.showStill(state.previewStill)
            return
        }
        // «Екран»: те, що захоплюють, видно на живому екрані поруч — там же
        // по ньому ведуть указкою. Другий такий самий кадр у передпоказі був
        // би тим самим удруге, а вірш із чужої вкладки тут і поготів зайвий.
        if state.mode == .screen {
            preview.showStill(nil)
            return
        }
        // «Медіа» без кадру плеєра і картинки: показувати нічого — «Показати»
        // тут нічого в зал не виведе, і вірш з іншої вкладки в
        // передпоказі лише збивав з пантелику (зауваження 3).
        if state.mode == .media, !state.media.isVideoOnScreen, state.media.still == nil, state.media.mediaURL == nil {
            preview.showStill(nil)
            return
        }
        preview.show(slide: state.previewSlide, style: state.previewStyle,
                     preset: state.preset(for: .preview), texts: state.previewTexts,
                     backgroundOverride: state.previewBackgroundOverride,
                     imageURL: { [weak state] name in state?.presetImageURL(name) })
    }

    private func refreshVideo() {
        preview.applyVideo(state.media)
    }

    private func applyCaptions() {
        planCaption.stringValue = state.text("Label3D15", default: "План:")
        historyCaption.stringValue = state.text("Label3D3", default: "История:")
        previewCaption.stringValue = state.text("Label3D2", default: "Предварительный просмотр")
        liveCaption.stringValue = OurWords.t("Живой экран (то, что в зале)")
        controlCaption.stringValue = state.text("Label3D1", default: "Управление:")
        mirrorWindowButton.toolTip = OurWords.t("Открыть живой экран отдельным окном")
    }

    // MARK: - Дзеркало проектора

    @objc private func openMirrorWindow() {
        NativeProjectorMirrorWindow.shared.show(state: state)
    }

    /// Показати живий екран поруч із передпоказом — або прибрати його.
    /// Те саме робить роздільник, коли його дотягнути до краю.
    func setShowsMirror(_ shows: Bool) {
        NativeBottomMetrics.liveWidth = shows ? NativeBottomMetrics.liveDefaultWidth : 0
        applyMirrorChoice()
        applyCaptions()
    }

    private func applyMirrorChoice() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        if showsMirror { mirror.refresh() } else { SlidePointer.shared.hide(from: "мышь") }
    }

    private func showPlanWarning(_ text: String) {
        let alert = NSAlert()
        alert.messageText = OurWords.t("Файл плана")
        alert.informativeText = text
        alert.addButton(withTitle: OurWords.t("Закрыть"))
        alert.runModal()
        desk.planWarning = nil
    }

    // MARK: - Клавіатура і фокус

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyWatch { NSEvent.removeMonitor(keyWatch); self.keyWatch = nil }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification,
                                                  object: nil)
        guard let window else { return }
        refreshPreview()

        // Клавіша Del не віддана спискам навмисно: у програмі вона значить різне
        // в різних місцях, і списку знати про це нізвідки. Сторож ловить її
        // лише коли клавіатура і справді в Плану або в Історії.
        keyWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(key: event) else { return event }
            return nil
        }
        // Хто тримає клавіатуру, AppKit повідомляє лише цим сповіщенням.
        // Роботи на нього — одне порівняння покажчиків.
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidUpdate),
                                               name: NSWindow.didUpdateNotification, object: window)
    }

    @objc private func windowDidUpdate(_ notification: Notification) { refreshFocus() }

    private func refreshFocus() {
        let responder = window?.firstResponder
        guard responder !== focused else { return }
        focused = responder
        let view = responder as? NSView
        plan.setFocused(view?.isDescendant(of: plan.list) ?? false)
        history.setFocused(view?.isDescendant(of: history.list) ?? false)
    }

    private func handle(key event: NSEvent) -> Bool {
        // 51 — Backspace, 117 — Delete уперед. В автора працюють обидві.
        guard event.keyCode == 51 || event.keyCode == 117 else { return false }
        guard let view = window?.firstResponder as? NSView else { return false }
        if view.isDescendant(of: plan.list) {
            plan.deleteSelected()
            return true
        }
        if view.isDescendant(of: history.list) {
            history.deleteSelected()
            return true
        }
        return false
    }
}

/// Роздільник між передпоказом і живим екраном: за нього тягнуть ширину.
///
/// Власник просив «его можно растягивать по горизонтали и вертикали для
/// большего удобства работы с указкой»: по горизонталі — цим роздільником,
/// по вертикалі — смужкою над усім нижнім рядом.
@MainActor
final class NativeLiveWidthGrip: NSView {

    /// Скільки пунктів проїхала миша вправо від минулого разу.
    var onDrag: ((CGFloat) -> Void)?
    private var last: CGFloat?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Три крапки посередині: інакше смужку в один піксель не видно і
        // ніхто не здогадається, що її можна тягнути.
        NSColor.separatorColor.setFill()
        let dot: CGFloat = 2
        var y = bounds.midY - dot * 4
        for _ in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - dot / 2, y: y, width: dot, height: dot)).fill()
            y += dot * 3
        }
    }

    override func mouseDown(with event: NSEvent) {
        last = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        let now = convert(event.locationInWindow, from: nil).x
        guard let was = last else { last = now; return }
        let delta = now - was
        guard abs(delta) >= 1 else { return }
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) { last = nil }
}
