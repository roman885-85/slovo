import AppKit
import SlovoCore

/// Дзеркало проектора: те, що зараз на стіні, — в головному вікні. По ньому
/// ведуть указку мишею.
///
/// Власник: «добавить экран вывода на проектор в программу — на нём и будет
/// проводиться манипуляция мышью для указания выделения; дать возможность
/// менять размер этого экрана». Місце — там, де в оригіналі стояла вкладка
/// «Окно Слайда» поруч із передпоказом; розмір — окремим вікном (⤢).
///
/// Дзеркало нічого не малює саме: слайд бере готовим кадром залу
/// (`projection.hallImage`), кадр плеєра — тим самим шаром, що й проектор
/// (`media.attach`), указку — такою самою фігурою. Тому воно дешеве і не
/// розходиться з тим, що бачить зал.
@MainActor
final class NativeProjectorMirror: NSView {

    private let state: AppState
    private let slideLayer = CALayer()
    private let videoLayer = CALayer()
    private let pointerShape = CAShapeLayer()
    private var tokens: [Signals.Token] = []
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private weak var attachedMedia: MediaPlayerModel?
    /// Сторони кадру проектора — за кадром залу; поки кадру немає — 16:9.
    private var aspect: CGFloat = 16.0 / 9.0
    /// Скільки разів дзеркало перечитало кадр — самоперевірці.
    private(set) var refreshCount = 0

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = NativeBottomMetrics.corner
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        slideLayer.contentsGravity = .resizeAspect
        slideLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.isHidden = true
        pointerShape.isHidden = true
        for sublayer in [slideLayer, videoLayer, pointerShape] { layer?.addSublayer(sublayer) }

        tokens.append(Signals.shared.subscribe([.slide, .live, .mode, .layout]) { [weak self] _ in self?.refresh() })
        observer = NotificationCenter.default.addObserver(forName: SlidePointer.changed, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.applyPointer() }
        }
        toolTip = OurWords.t("Указку ведут мышью по зеркалу проектора в нижнем ряду или пальцем по слайду на телефоне.")
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            self?.toolTip = OurWords.t("Указку ведут мышью по зеркалу проектора в нижнем ряду или пальцем по слайду на телефоне.")
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        timer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else {
            if let media = attachedMedia { media.detach(videoLayer); attachedMedia = nil }
            return
        }
        // Кадр залу домальовується у фоні і свого приводу не шле; чотирьох
        // поглядів на секунду досить, а коштує погляд нічого — той самий CGImage.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refresh()
    }

    private func tick() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    /// Прямокутник кадру всередині виду: сторони проектора, поля по краях.
    var frameRect: CGRect {
        let width = bounds.width, height = bounds.height
        guard width > 0, height > 0 else { return .zero }
        var size = CGSize(width: width, height: width / aspect)
        if size.height > height { size = CGSize(width: height * aspect, height: height) }
        return CGRect(x: (width - size.width) / 2, y: (height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Перечитати кадр залу, кадр плеєра і указку.
    func refresh() {
        refreshCount &+= 1
        let image = state.projection.hallImage
        if let image, image.height > 0 { aspect = CGFloat(image.width) / CGFloat(image.height) }
        let rect = frameRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slideLayer.frame = rect
        slideLayer.contents = image
        // Кадр плеєра — за тим самим правилом, що й на проекторі.
        let shown = state.isLive && state.media.isVideoOnScreen
        if shown {
            if attachedMedia !== state.media {
                attachedMedia?.detach(videoLayer)
                attachedMedia = state.media
                state.media.attach(videoLayer)
            }
            videoLayer.isHidden = false
        } else {
            if let media = attachedMedia { media.detach(videoLayer); attachedMedia = nil }
            videoLayer.isHidden = true
        }
        videoLayer.frame = rect
        applyPointer()
        CATransaction.commit()
    }

    private func applyPointer() {
        guard let mark = SlidePointer.shared.mark else { pointerShape.isHidden = true; return }
        let look = SlidePointer.shared.look
        let rect = frameRect
        let radius = max(2, look.size * rect.height / 2)
        let center = CGPoint(x: rect.minX + mark.x * rect.width, y: rect.minY + (1 - mark.y) * rect.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointerShape.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                     width: radius * 2, height: radius * 2), transform: nil)
        pointerShape.fillColor = CGColor(red: look.colour.red, green: look.colour.green,
                                         blue: look.colour.blue, alpha: look.opacity)
        pointerShape.strokeColor = CGColor(red: look.colour.red, green: look.colour.green,
                                           blue: look.colour.blue, alpha: min(1, look.opacity + 0.4))
        pointerShape.lineWidth = max(1.5, radius * 0.08)
        pointerShape.isHidden = false
        CATransaction.commit()
    }

    /// Самоперевірці: чи є в дзеркалі кадр залу і чи видно указку.
    var showsHallImage: Bool { slideLayer.contents != nil }
    /// Чи стоїть у дзеркалі кадр плеєра — картинка, сторінка презентації
    /// або фільм. По ньому теж ведуть указкою, і перевірити це інакше нічим.
    var showsPlayerFrame: Bool { !videoLayer.isHidden }
    var pointerVisible: Bool { !pointerShape.isHidden }

    // MARK: - Миша

    /// Указка живе рівно поки тримають ліву кнопку.
    ///
    /// Власник: «при нажатии левой кнопкой мыши по окну лайв активируется
    /// указка и активна, пока не отпустить кнопку мыши». Раніше пляма
    /// вмикалася від самого руху миші над екраном, і випадково проведена
    /// рука засвічувала зал.
    override func resetCursorRects() {
        addCursorRect(frameRect, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // Стежимо лише за виходом курсора: рух миші указкою більше не веде.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        press(at: convert(event.locationInWindow, from: nil))
    }

    /// Натискання: указка з'явилася, а якщо ввімкнено наближення — сторінка
    /// поїхала туди, куди тицьнули. Далі, поки ведуть, рухається лише пляма:
    /// інакше картинка їхала б під рукою і в залі закачало б.
    func press(at location: CGPoint) {
        holding = true
        if SlideFocus.shared.isOn, let spot = fraction(at: location) {
            SlideFocus.shared.move(toShown: spot.x, spot.y)
        }
        point(at: location)
    }

    override func mouseDragged(with event: NSEvent) {
        guard holding else { return }
        point(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        holding = false
        SlidePointer.shared.hide(from: "мышь")
    }

    /// Кнопку відпустили за межами вікна — пляму все одно гасимо.
    override func mouseExited(with event: NSEvent) {
        guard holding, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        holding = false
        SlidePointer.shared.hide(from: "мышь")
    }

    /// Точка виду → частки кадру (вісь Y униз, як на стіні і на телефоні).
    /// Поза кадром — `nil`.
    private func fraction(at location: CGPoint) -> (x: Double, y: Double)? {
        let rect = frameRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return (min(1, max(0, (location.x - rect.minX) / rect.width)),
                min(1, max(0, 1 - (location.y - rect.minY) / rect.height)))
    }

    /// Указка. Поки кнопку тримають, точку притискаємо до краю кадру, а не
    /// гасимо пляму: рука виїхала на поле, а указка потрібна далі.
    func point(at location: CGPoint) {
        guard let spot = fraction(at: location) else { return }
        SlidePointer.shared.move(to: spot.x, spot.y, from: "мышь")
    }

    // MARK: - Колесо і трекпад

    /// Колесо миші наближає й віддаляє, а точка наближення — та, на яку
    /// дивиться курсор.
    ///
    /// Власник: «добавить функцию масштабирования мышью, с помощью колесика
    /// мыши, точка масштабирования от текущего места положения мыши».
    /// Наближення при цьому вмикається саме: людина крутить колесо, щоб
    /// наблизити, а не щоб спершу поставити галочку.
    override func scrollWheel(with event: NSEvent) {
        // Трекпад сипле дрібними кроками сотнями за секунду, миша дає
        // великий крок на кожен зубець. Тому в кроки колеса переводимо
        // по-різному, інакше на трекпаді сторінка стрибала б на всю
        // кратність від одного руху пальця.
        let raw = Double(event.scrollingDeltaY)
        let steps = event.hasPreciseScrollingDeltas ? raw / 40 : raw / 3
        guard abs(steps) > 0.0001 else { return }
        magnify(by: pow(1.18, steps), at: convert(event.locationInWindow, from: nil))
    }

    /// Щипок двома пальцями на трекпаді — те саме наближення.
    ///
    /// Власник: «также добавить функционал для трекпада макбуков». На
    /// ноутбуці колеса немає, і щипок тут природніший за будь-яку кнопку.
    override func magnify(with event: NSEvent) {
        let change = Double(event.magnification)
        guard abs(change) > 0.0001 else { return }
        magnify(by: 1 + change, at: convert(event.locationInWindow, from: nil))
    }

    /// Подвійний дотик двома пальцями — скинути наближення.
    /// Трекпадна пара до середньої кнопки миші.
    override func smartMagnify(with event: NSEvent) {
        resetZoom()
    }

    /// Натискання на коліщатко — вихідний стан.
    ///
    /// Власник: «исходное состояние масштаба по нажатию третьей кнопи мыши
    /// (нажатие на колесико мыши)».
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        resetZoom()
    }

    /// Спільна частина: у скільки разів і навколо якої точки.
    private func magnify(by factor: Double, at location: CGPoint) {
        guard let spot = fraction(at: location) else { return }
        let focus = SlideFocus.shared
        // Поки наближення вимкнено, видно цілу сторінку — і рахувати треба
        // від ×1, а не від того числа, яке лишилося в пам'яті з минулого
        // разу. Інакше перший же поворот колеса стрибав би на ×2,4.
        let now = focus.isOn ? focus.look.zoom : SlideFocus.minZoom
        let wanted = now * factor
        // Крутнули назад до самого кінця — наближення знімається зовсім.
        // Тримати ×1 увімкненим немає сенсу: це та сама ціла сторінка, але
        // з галочкою, яку потім не розуміють, навіщо знімати.
        if wanted <= SlideFocus.minZoom + 0.001 {
            if focus.isOn { focus.reset() }
            return
        }
        // Погляд ведемо ДО вмикання: поки наближення вимкнено, частки миші
        // міряються від цілої сторінки — саме від того, що людина бачить.
        focus.zoom(to: wanted, aroundShown: spot.x, spot.y)
        if !focus.isOn { focus.setOn(true) }
    }

    /// Вихідний стан: наближення зняте, погляд посередині.
    private func resetZoom() { SlideFocus.shared.reset() }

    /// Самоперевірці: крутнути колесо так, як це робить рука.
    func wheelForCheck(by factor: Double, at location: CGPoint) {
        magnify(by: factor, at: location)
    }

    /// Самоперевірці: натиснути на коліщатко.
    func middleClickForCheck() { resetZoom() }

    /// Чи тримають зараз кнопку — самоперевірці.
    private(set) var holding = false

    /// Самоперевірці: провести указкою так, як це робить рука. Точку фокуса
    /// не чіпає — її ставить саме натискання, а не ведення.
    func dragForCheck(to location: CGPoint) {
        holding = true
        point(at: location)
    }

    /// Самоперевірці: натиснути так, як це робить рука.
    func pressForCheck(at location: CGPoint) { press(at: location) }

    func releaseForCheck() {
        holding = false
        SlidePointer.shared.hide(from: "мышь")
    }
}

/// Дзеркало проектора окремим вікном — щоб міняти його розмір, як просив
/// власник. Плавуче: тримається над головним вікном, поки йде служіння.
@MainActor
final class NativeProjectorMirrorWindow: NSObject, NSWindowDelegate {

    static let shared = NativeProjectorMirrorWindow()

    private var window: NSPanel?
    private(set) var mirror: NativeProjectorMirror?

    var isOpen: Bool { window?.isVisible ?? false }

    func show(state: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = OurWords.t("Зеркало проектора")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 180)
        panel.delegate = self
        let mirror = NativeProjectorMirror(state: state)
        mirror.layer?.cornerRadius = 0
        panel.contentView = mirror
        panel.center()
        panel.setFrameAutosaveName("ProjectorMirror")
        self.window = panel
        self.mirror = mirror
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    /// Розмір вікна — самоперевірці.
    func resize(to size: NSSize) {
        guard let window else { return }
        window.setContentSize(size)
        window.layoutIfNeeded()
        mirror?.layoutSubtreeIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        SlidePointer.shared.hide(from: "мышь")
        window = nil
        mirror = nil
    }
}
