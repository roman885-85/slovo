import AppKit
import SlovoCore

/// Части главного окна сверху вниз — ровно те, что в описи окна.
///
/// Каждая часть это постоянный вид, который живёт всё время работы программы.
/// Нажатие меняет содержимое одной части; остальные не трогаются вовсе. Этим
/// новое окно и отличается от прежнего, где на любое действие пересобирались
/// тела пятнадцати панелей разом.
enum NativeSlot: String, CaseIterable {
    /// Строка меню внутри окна.
    case menuBar
    /// Вкладки режима (18) и ползунок кегля (20).
    case modeTabs
    /// Рабочая область: Библия | Текст | Песни | Медиа.
    case workspace
    /// Окно результатов поиска (5).
    case searchResults
    /// Полоса переводов (7), Поиск (8) и Быстрый выбор (9).
    case translationStrip
    /// Нижний ряд: План | История | Предпросмотр | Управление.
    case bottomRow

    /// Высота части. У рабочей области её нет — она тянется.
    ///
    /// Раскладку окна считает только главный поток, поэтому высоту нижнего
    /// ряда (её тянет оператор) читаем оттуда же.
    @MainActor
    var height: CGFloat? {
        switch self {
        case .menuBar: return 0
        case .modeTabs: return 30
        case .workspace: return nil
        case .searchResults: return 170
        case .translationStrip: return 30
        // Висоту нижнього ряду тягне сам оператор — див. `NativeBottomMetrics`.
        case .bottomRow: return NativeBottomMetrics.rowHeight
        }
    }

    /// Отступы слева и справа.
    var inset: CGFloat {
        switch self {
        case .menuBar, .modeTabs: return 8
        case .workspace: return 0
        case .searchResults, .translationStrip, .bottomRow: return 6
        }
    }

    /// Части, которых по умолчанию не видно: их показывают из меню.
    var startsHidden: Bool { self == .searchResults }
}

/// Ящик под часть окна. Хозяин части кладёт внутрь свой вид и больше о
/// раскладке не думает: размер приходит сам.
final class NativeSlotView: NSView {
    let slot: NativeSlot
    private(set) var content: NSView?

    init(slot: NativeSlot) {
        self.slot = slot
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    func install(_ view: NSView?) {
        // Прежние виды не снимаем, а прячем. Снятие и возврат рабочей
        // области заставляли AppKit заново строить дерево слоёв всех её
        // списков — треть времени переключения вкладки. Спрятанный вид стоит
        // на месте со своими слоями и ждёт следующего раза; раскладку и
        // отрисовку спрятанные не получают.
        for child in subviews where child !== view { child.isHidden = true }
        content = view
        guard let view else { return }
        if view.superview !== self {
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        view.frame = bounds
        view.isHidden = false
    }

    override func layout() {
        super.layout()
        content?.frame = bounds
    }
}

/// Каркас окна: раскладывает части сверху вниз и рисует разделители.
///
/// Раскладка руками, без Auto Layout, — семь прямоугольников считаются
/// арифметикой за микросекунды и не зависят от решателя ограничений, который
/// на каждое изменение перебирает всё окно.
final class NativeRootView: NSView {

    private(set) var slots: [NativeSlot: NativeSlotView] = [:]
    private var visible: Set<NativeSlot> = []
    /// Где рисовать разделители — считается заодно с раскладкой.
    private var separators: [CGFloat] = []

    // MARK: - Перетаскивание файлов

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        NativeWindowDrop.shared.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        NativeWindowDrop.shared.operation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        NativeWindowDrop.shared.accept(sender)
    }

    /// Смужка, за яку нижній ряд тягнуть угору. Власник: «нижний блок
    /// программы с планом, историей, предпросмотром и управлением можно
    /// растягивать вверх» — щоб живому екрану було де розвернутися.
    private let bottomGrip = NativeBottomHeightGrip()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for slot in NativeSlot.allCases {
            let view = NativeSlotView(slot: slot)
            slots[slot] = view
            addSubview(view)
            if slot.startsHidden {
                view.isHidden = true
            } else {
                visible.insert(slot)
            }
        }
        bottomGrip.onDrag = { [weak self] delta in
            guard let self else { return }
            NativeBottomMetrics.rowHeight = NativeBottomMetrics.rowHeight - delta
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
            self.needsDisplay = true
        }
        addSubview(bottomGrip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    func setVisible(_ shown: Bool, for slot: NativeSlot) {
        guard slot != .workspace else { return }
        let was = visible.contains(slot)
        guard was != shown else { return }
        if shown { visible.insert(slot) } else { visible.remove(slot) }
        slots[slot]?.isHidden = !shown
        needsLayout = true
        needsDisplay = true
    }

    func isVisible(_ slot: NativeSlot) -> Bool { visible.contains(slot) }

    override func layout() {
        super.layout()
        separators.removeAll(keepingCapacity: true)

        let order = NativeSlot.allCases.filter { visible.contains($0) }
        var fixed: CGFloat = 0
        for slot in order where slot != .workspace {
            fixed += slot.height ?? 0
        }
        let lines = CGFloat(max(0, order.count - 1))
        let workspaceHeight = max(80, bounds.height - fixed - lines)

        var y: CGFloat = 0
        for (position, slot) in order.enumerated() {
            if position > 0 {
                separators.append(y)
                y += 1
            }
            let height = slot == .workspace ? workspaceHeight : (slot.height ?? 0)
            let inset = slot.inset
            slots[slot]?.frame = NSRect(x: inset, y: y,
                                        width: max(0, bounds.width - inset * 2), height: height)
            if slot == .bottomRow {
                // Смужка лягає на розділову лінію над рядом: два пункти вгору
                // і два вниз — попасти пальцем можна, а лінію не видно.
                bottomGrip.frame = NSRect(x: 0, y: y - 4, width: bounds.width, height: 8)
                bottomGrip.isHidden = false
            }
            y += height
        }
        if !order.contains(.bottomRow) { bottomGrip.isHidden = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        for y in separators {
            let line = NSRect(x: 0, y: y, width: bounds.width, height: 1)
            if line.intersects(dirtyRect) { line.fill() }
        }
    }
}

/// Смужка над нижнім рядом: тягнеш угору — ряд вищий.
///
/// Свій вид, а не `NSSplitView`: розкладка вікна — це стовпчик із шести
/// прямокутників, і заводити заради однієї межі цілий роздільник із його
/// власними правилами значило б переписати розкладку всього вікна.
@MainActor
final class NativeBottomHeightGrip: NSView {

    /// Скільки пунктів проїхала миша вниз від минулого разу.
    var onDrag: ((CGFloat) -> Void)?
    private var last: CGFloat?

    /// Рахунок згори вниз — як у всієї розкладки вікна: тоді «потягнули
    /// вгору» це від'ємний зсув, і ряд від нього росте.
    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Три крапки посередині, як на роздільниках ширини: смужку у вісім
        // точок без них не видно, і власник просив тягнути «по вертикалі»,
        // не знаючи, що вже можна.
        NSColor.separatorColor.setFill()
        let dot: CGFloat = 2
        var x = bounds.midX - dot * 4
        for _ in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: x, y: bounds.midY - dot / 2, width: dot, height: dot)).fill()
            x += dot * 3
        }
    }

    override func mouseDown(with event: NSEvent) {
        last = convert(event.locationInWindow, from: nil).y
    }

    override func mouseDragged(with event: NSEvent) {
        let now = convert(event.locationInWindow, from: nil).y
        guard let was = last else { last = now; return }
        // Вид рухається разом із межею, тому рахуємо зсув у координатах вікна.
        let delta = now - was
        guard abs(delta) >= 1 else { return }
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) { last = nil }
}

/// Главное окно на AppKit.
///
/// Единственное окно программы — ключ
/// командной строки `--appkit` либо `UserDefaults` «useAppKitWindow».
/// Прежнее окно никуда не девается и работает как работало: пока новое не
/// проверено целиком, отбирать у человека рабочую программу нельзя.
@MainActor
final class NativeMainWindowController: NSObject, NSWindowDelegate {

    static let shared = NativeMainWindowController()

    private(set) var window: NSWindow?
    private(set) var root: NativeRootView?
    private weak var state: AppState?
    private var tokens: [Signals.Token] = []

    /// Поднять окно. Второй вызов просто выводит уже открытое вперёд.
    @discardableResult
    func show(state: AppState) -> NSWindow {
        self.state = state
        if let window {
            window.makeKeyAndOrderFront(nil)
            return window
        }

        let root = NativeRootView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        let window = NSWindow(contentRect: root.frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = OurWords.t("Слово")
        window.minSize = NSSize(width: 1120, height: 720)
        window.contentView = root
        window.delegate = self
        window.setFrameAutosaveName("SlovoNativeMain")
        window.isReleasedWhenClosed = false
        self.window = window
        self.root = root
        subscribe()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Положить свой вид в часть окна.
    func install(_ view: NSView?, in slot: NativeSlot) {
        root?.slots[slot]?.install(view)
    }

    /// Ящик части — если хозяину удобнее класть подвиды самому.
    func slotView(_ slot: NativeSlot) -> NativeSlotView? { root?.slots[slot] }

    /// Записать в дневник, что и какого размера стоит в окне.
    ///
    /// «Вид положили» и «человек его видит» — разные вещи: у вида нулевой
    /// высоты и размер есть, и в окне он стоит, а видно его не будет. По
    /// состоянию это не различить, по размерам — сразу. Самопроверка на этом и
    /// обманывалась: говорила «песенник открыт», когда в окне было пусто.
    func traceTree() {
        guard let root else { NativeTrace.say("вікно: кореня немає"); return }
        NativeTrace.say("окно: \(Int(root.bounds.width))×\(Int(root.bounds.height))")
        for slot in NativeSlot.allCases {
            guard let box = root.slots[slot] else {
                NativeTrace.say("  \(slot.rawValue): скриньки немає")
                continue
            }
            let inside = box.subviews.map { child in
                "\(type(of: child)) \(Int(child.frame.width))×\(Int(child.frame.height))"
                    + (child.isHidden ? " СПРЯТАН" : "")
            }
            NativeTrace.say("  \(slot.rawValue): \(NativeTrace.box(box.frame))"
                + (box.isHidden ? " СПРЯТАН" : "")
                + " → " + (inside.isEmpty ? "пусто" : inside.joined(separator: ", ")))
        }
        // И сам вид окна картинкой: по описи не видно, ЧТО нарисовано, а
        // именно там и была поломка — виды стояли на местах и не рисовались.
        NativeTrace.snapshot(root, to: "slovo-window.png")
    }


    func setVisible(_ shown: Bool, for slot: NativeSlot) {
        root?.setVisible(shown, for: slot)
    }

    func isVisible(_ slot: NativeSlot) -> Bool { root?.isVisible(slot) ?? false }

    /// Раскладка окна слушает единственный повод — `layout`. Всё остальное
    /// разбирают сами части: смена стиха не касается ни одного из семи ящиков.
    private func subscribe() {
        tokens.append(Signals.shared.subscribe(.layout) { [weak self] in
            self?.applyLayoutFlags()
        })
        applyLayoutFlags()
    }

    /// Рабочая область режима «Медиа». Заводится при первом заходе в режим и
    /// живёт дальше: файл не должен закрываться от того, что оператор
    /// посмотрел стих.
    private var mediaHost: NSView?
    /// Заслонка «библиотека не открылась / открывается» поверх рабочей
    /// области — с объяснением и кнопкой, как в прежнем окне.
    private var libraryOverlay: NativeLibraryOverlay?
    /// Рабочая область режима «Текст».
    private var textHost: NSView?

    private func applyLayoutFlags() {
        guard let state else { return }
        applyStripVisibility(state: state)
        applyLibraryOverlay(state: state)
    }

    /// Полоса переводов и окно результатов поиска — только там, где они по
    /// делу: у Библии и у Песен (там на месте переводов стоят Песенники, а
    /// поиск ищет по песням). На вкладках текста, медиа, картинок и
    /// презентаций переводам Библии делать нечего — владелец просил, чтобы в
    /// окне было лишь то, что относится к открытой вкладке.
    private func applyStripVisibility(state: AppState) {
        let hasStrip = state.mode == .bible || state.mode == .songs
        setVisible(hasStrip, for: .translationStrip)
        setVisible(hasStrip && DeskModel.shared.isSearchResultsShown, for: .searchResults)
    }

    /// Режимы «Текст» и «Медиа» кладут свой вид в рабочую область так же, как
    /// Библия и Песни кладут свои.
    ///
    /// Плеер раньше жил отдельной полосой поверх окна и открывался только
    /// пунктом меню. Теперь он четвёртая вкладка в ряду — и попадает туда же,
    /// куда все: в рабочую область.
    func applyMode() {
        guard let state else { return }
        applyStripVisibility(state: state)
        switch state.mode {
        case .text:
            NativeTextWorkspace.shared.install()
        case .media:
            NativeMediaWorkspace.shared.install()
        case .pictures:
            NativeShowWorkspace.pictures.install()
        case .presentation:
            NativeShowWorkspace.presentation.install()
        case .screen:
            NativeScreenWorkspace.shared.install(state: state)
        case .bible, .songs:
            break   // рабочую область занимают они сами
        }
    }

    private func applyLibraryOverlay(state: AppState) {
        // Заставку «Відкриваю бібліотеку…» прибираємо, щойно читання скінчилося,
        // хоч би з чим: доти з порожньою текою модулів (збірка «лише програма»)
        // вона лишалася поверх усіх вікон і закривала половину вікна ресурсів.
        if !state.isLoadingLibrary { NativeSplash.hide() }
        let message: String?
        if let error = state.loadError {
            message = error
        } else if state.isLoadingLibrary, state.allModules.isEmpty {
            message = OurWords.t("Открываю библиотеку переводов…")
            NativeSplash.say(OurWords.t("Открываю библиотеку переводов…"))
        } else {
            message = nil
        }
        guard let message else {
            // Библиотека прочитана — заставку убираем.
            NativeSplash.hide()
            libraryOverlay?.removeFromSuperview()
            libraryOverlay = nil
            return
        }
        guard let root else { return }
        let overlay: NativeLibraryOverlay
        if let existing = libraryOverlay {
            overlay = existing
        } else {
            overlay = NativeLibraryOverlay(choose: { [weak self] in
                self?.state?.menuActions.chooseModules()
            }, download: { [weak self] in
                guard let state = self?.state else { return }
                NativeResourcesWindow.show(state: state)
            })
            root.addSubview(overlay)
            libraryOverlay = overlay
        }
        overlay.set(message: message, showsButton: state.loadError != nil)
        overlay.frame = root.slots[.workspace]?.frame ?? root.bounds
    }

    func windowWillClose(_ notification: Notification) {
        // Окно закрыли — программа кончилась: другого главного окна в этом
        // режиме нет.
        NSApp.terminate(nil)
    }
}

/// Заслонка над рабочей областью: библиотека не открылась или открывается.
///
/// В прежнем окне это `LibraryProblemView` с кнопкой «Выбрать папку с
/// модулями…». Без неё при сбитой папке владелец получал пустые колонки без
/// объяснения и без выхода.
final class NativeLibraryOverlay: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: OurWords.t("Выбрать папку с модулями…"), target: nil, action: nil)
    /// Порожня тека модулів у збірці «лише програма» — головна дорога тут:
    /// завантажити переклади з інтернету.
    private let downloadButton = NSButton(title: OurWords.t("Загрузить с GitHub…"), target: nil, action: nil)
    private let choose: () -> Void
    private let download: () -> Void

    init(choose: @escaping () -> Void, download: @escaping () -> Void) {
        self.choose = choose
        self.download = download
        super.init(frame: .zero)
        downloadButton.target = self
        downloadButton.action = #selector(fetch)
        downloadButton.bezelStyle = .rounded
        downloadButton.keyEquivalent = "\r"
        addSubview(downloadButton)
        // Никакого `wantsLayer`: один слойный вид переводит на слои всё окно
        // разом, и самописная отрисовка соседей — меню, вкладки, заголовки
        // колонок — остаётся пустой. Ровно так и сломалось: заслонка мелькала
        // при каждом запуске на время загрузки, а окно после неё стояло
        // наполовину ненарисованным. Фон рисуем обычным путём.
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(pick)
        button.bezelStyle = .rounded
        addSubview(label)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    @objc private func pick() { choose() }
    @objc private func fetch() { download() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }

    func set(message: String, showsButton: Bool) {
        label.stringValue = message
        button.isHidden = !showsButton
        downloadButton.isHidden = !showsButton
    }

    override func layout() {
        super.layout()
        let width = min(bounds.width - 80, 520)
        let height = label.sizeThatFits(NSSize(width: width, height: 400)).height
        label.frame = NSRect(x: (bounds.width - width) / 2,
                             y: bounds.midY - height / 2 + 14,
                             width: width, height: height)
        let size = button.intrinsicContentSize
        let second = downloadButton.intrinsicContentSize
        let total = second.width + 12 + size.width
        downloadButton.frame = NSRect(x: (bounds.width - total) / 2,
                                      y: label.frame.minY - second.height - 12,
                                      width: second.width, height: second.height)
        button.frame = NSRect(x: downloadButton.frame.maxX + 12,
                              y: label.frame.minY - size.height - 12,
                              width: size.width, height: size.height)
    }
}

/// Признак, по которому поднимается новое окно.
@MainActor
enum NativeLaunch {

    private static var modeToken: Signals.Token?

    /// Просили ли замер основания.
    static var wantsBench: Bool {
        CommandLine.arguments.contains("--appkit-bench")
    }

    /// Поднять окно программы и созвать в него все части.
    static func start(state: AppState) {
        NativeMainWindowController.shared.show(state: state)

        // Части кладут себя в ящики окна сами — их надо только позвать.
        // Без этого окно поднималось пустым: всё было написано и собрано, а
        // соединить его мог только ведущий.
        NativeTop.install(state: state)
        NativeBibleWorkspace.shared.attach(state: state)
        NativeSongsWorkspace.shared.attach(state: state)
        _ = NativeBottom.install(state: state)
        // Три клавиши без пункта меню — выбор фонов и режим правки Песенника.
        NativeWindowHotkeys.shared.install(state: state)
        NativeShowWorkspace.pictures.attach(state: state)
        NativeShowWorkspace.presentation.attach(state: state)
        NativeMediaWorkspace.shared.attach(state: state)
        NativeTextWorkspace.shared.attach(state: state)
        if let root = NativeMainWindowController.shared.root {
            NativeWindowDrop.shared.install(state: state, in: root)
        }

        // Режим «Текст»: Библия и Песни занимают рабочую область сами,
        // третий режим — забота окна.
        modeToken = Signals.shared.subscribe(.mode) {
            NativeMainWindowController.shared.applyMode()
        }
        NativeMainWindowController.shared.applyMode()

        if wantsBench { NativeBench.start(state: state) }
        // Через пару секунд после подъёма записать, что и какого размера в
        // окне стоит. Дневник читают, когда владелец говорит «пусто».
        Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated { NativeMainWindowController.shared.traceTree() }
        }
    }

    /// Поднять своё окно поверх и отдать ему внимание.
    static func raiseOwnWindow() {
        guard let ours = NativeMainWindowController.shared.window else { return }
        ours.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
