import AppKit
import SlovoCore

/// Окно проекции: полноэкранное на выбранном мониторе, без рамки,
/// поверх всего — но так, чтобы не мешать управляющему окну.
@MainActor
final class ProjectionController: ObservableObject {

    @Published private(set) var isVisible = false
    @Published var targetScreenID: String? {
        didSet { if isVisible { rebuildWindow() } }
    }

    /// Правило из окна «Параметры» (6.1.1): выбранный монитор или ручная
    /// настройка (9) с запасными размерами (7). Пока настройки не применены,
    /// работает прежнее поведение — «любой экран, кроме главного».
    @Published var placement: SlideWindowPlacement? {
        didSet {
            guard placement != oldValue else { return }
            if isVisible { rebuildWindow() }
        }
    }

    private var window: NSWindow?
    /// Які були екрани, коли вікно слайда будувалося, — див. `screenSignature`.
    private var builtScreens: String?
    /// Для самопроверки переходов: есть ли на слое окна уходящий кадр и
    /// движется ли он (по слою представления, а не по модели).
    struct TransitionState {
        var hasOutgoing = false
        var outgoingMoving = false
        var hasBlack = false
    }
    func transitionState() -> TransitionState {
        var state = TransitionState()
        // Служебные слои перехода живут в слое холста, а не окна.
        guard let root = canvas?.layer else { return state }
        for sub in root.sublayers ?? [] {
            if sub.name == "чёрное" { state.hasBlack = true }
            guard sub.name == "уходящий" || sub.name == "входящий" else { continue }
            state.hasOutgoing = true
            if (sub.animationKeys() ?? []).isEmpty == false { state.outgoingMoving = true }
        }
        return state
    }

    /// Для самопроверки: на каком уровне стоит окно слайда и показано ли.
    var slideWindowLevel: Int? { window?.level.rawValue }
    /// Уровень, который получает полноэкранное окно слайда: на машине с
    /// одним дисплеем слайд идёт в обычном окне, и проверить настоящее
    /// нельзя — а пробное окно собирается тем же кодом.
    func probeFullScreenWindowLevel() -> Int {
        guard let screen = NSScreen.main else { return -1 }
        let probe = makeFullScreenSlide(on: screen)
        defer { probe.orderOut(nil) }
        return probe.level.rawValue
    }
    var isSlideWindowVisible: Bool { window?.isVisible ?? false }
    /// Чи є у вікна слайда три кнопки — самоперевірці (власник: «в окне нет
    /// функций закрыть, свернуть и развернуть окно»).
    var slideWindowButtons: (close: Bool, miniaturize: Bool, zoom: Bool)? {
        guard let window else { return nil }
        func has(_ kind: NSWindow.ButtonType) -> Bool {
            guard let button = window.standardWindowButton(kind) else { return false }
            return !button.isHidden
        }
        return (has(.closeButton), has(.miniaturizeButton), has(.zoomButton))
    }
    /// Вікно слайда — безрамкове (справжній проектор) чи звичайне.
    var isSlideWindowFramed: Bool { window?.styleMask.contains(.titled) ?? false }
    /// Номер вікна слайда — самоперевірка звіряє, те саме воно чи перебудоване.
    var slideWindowNumber: Int? { window?.windowNumber }

    /// Екрани, як їх бачить вікно слайда: скільки, де, якого розміру й
    /// масштабу. Робоча частина екрана (`visibleFrame`) сюди не входить:
    /// вона міняється від Dock і рядка меню, а вікну слайда до неї діла нема.
    static func screenSignature() -> String {
        NSScreen.screens.map { screen in
            let f = screen.frame
            return "\(screen.slovoIdentifier)@\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))×\(screen.backingScaleFactor)"
        }.joined(separator: ";")
    }

    /// Для самоперевірки: поводитися так, ніби екрани справді змінилися.
    func rebuildAsIfScreensChanged() {
        builtScreens = nil
        rebuildWindowIfNeeded()
    }
    private let content = SlideBox()

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindowIfNeeded() }
        }
    }

    /// Экраны, на которые можно вывести слайд.
    var availableScreens: [NSScreen] { NSScreen.screens }

    /// Экран по умолчанию — любой, кроме того, где сейчас окно управления.
    private var preferredScreen: NSScreen? {
        // Номер монитора из настроек (5) старше запомненного идентификатора:
        // это то, что человек выбрал в окне «Параметры» последним.
        if case let .monitor(number, _, _) = placement {
            let index = number - 1
            if NSScreen.screens.indices.contains(index) { return NSScreen.screens[index] }
            // (7): «если установленного в (5) монитора не окажется, то окно
            // слайда отобразится на главном мониторе с размерами, указанными
            // в этом поле» — экран главный, размеры подставит makeWindowed…
            return NSScreen.screens.first ?? NSScreen.main
        }
        if let id = targetScreenID,
           let match = NSScreen.screens.first(where: { $0.slovoIdentifier == id }) {
            return match
        }
        let main = NSScreen.main
        return NSScreen.screens.first { $0 != main } ?? main
    }

    /// (9) «Ручная настройка»: окно ставится по своим координатам, даже если
    /// монитора там сейчас нет — ровно ради этого случая панель и сделана.
    private var manualFrame: NSRect? {
        guard case let .manual(left, top, width, height) = placement else { return nil }
        return SettingsCoordinates.frame(left: left, top: top, width: width, height: height)
    }

    /// Размеры (7) «по умолчанию» — когда выбранного монитора нет и слайд
    /// уходит окном на главный экран.
    private var fallbackSize: NSSize? {
        guard case let .monitor(number, width, height) = placement,
              !NSScreen.screens.indices.contains(number - 1) else { return nil }
        return NSSize(width: CGFloat(width), height: CGFloat(height))
    }

    func update(slide: Slide, style: SlideStyle,
                preset: SlidePreset? = nil, texts: ConstructorSample = ConstructorSample(),
                backgroundOverride: String? = nil,
                imageURL: ((String?) -> URL?)? = nil) {
        content.slide = slide
        content.style = style
        content.preset = preset
        content.texts = texts
        content.backgroundOverride = backgroundOverride
        if let imageURL { content.imageURL = imageURL }
        canvas?.refresh()
        // Сховане рукою вікно вертається саме: у зал пішов слайд — його
        // мають побачити. Порожній слайд не рахуємо: гасіння не привід.
        if hiddenByHand, !slide.isBlank {
            hiddenByHand = false
            window?.orderFrontRegardless()
            NativeTrace.say("проектор: у зал пішов слайд — вікно слайда повернуто")
        }
    }

    /// Что сейчас нарисовано в окне зала — для самопроверки.
    var hallImage: CGImage? { canvas?.currentImage }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        visible ? rebuildWindow() : closeWindow()
    }

    func toggle() { setVisible(!isVisible) }

    // MARK: -

    private func rebuildWindowIfNeeded() {
        // Власник: «сворачиваю или разворачиваю окно других программ … и на
        // проекторе пропадает изображение (на ndi все работает)». macOS шле
        // «змінилися параметри екранів» і тоді, коли згортають чи
        // розгортають чуже вікно (Dock, рядок меню), — а програма щоразу
        // перебудовувала вікно слайда, і нове стояло чорним до наступного
        // слайда. Перебудовуємо лише тоді, коли самі екрани інші.
        let screens = Self.screenSignature()
        guard screens != builtScreens else {
            NativeTrace.say("проектор: сповіщення про екрани, а екрани ті самі — вікно слайда лишаю")
            return
        }
        NativeTrace.say("проектор: екранів \(NSScreen.screens.count), вікно слайда "
                        + (isVisible ? "перебудовую" : "не показане — не чіпаю"))
        guard isVisible else { return }
        rebuildWindow()
    }

    /// Отдельного монитора может не быть — на репетиции, дома, при настройке.
    /// Накрывать единственный экран безрамочным окном поверх всего нельзя:
    /// управлять программой станет нечем. В этом случае показываем слайд
    /// обычным окном, как «Окно слайда» в прежней программе.
    private var shouldRunWindowed: Bool {
        NSScreen.screens.count < 2
    }

    private func rebuildWindow() {
        // Плеєр запам'ятовуємо до закриття: `closeWindow` його забуває, і
        // кадр у нове вікно не вертався — рядок нижче не спрацьовував ніколи.
        let keptMedia = attachedMedia
        closeWindow()
        builtScreens = Self.screenSignature()
        guard let screen = preferredScreen else { return }

        let window: NSWindow
        if let frame = manualFrame {
            window = makeManualSlide(frame: frame)
        } else if let size = fallbackSize {
            window = makeWindowedSlide(on: screen, size: size)
        } else {
            window = shouldRunWindowed ? makeWindowedSlide(on: screen) : makeFullScreenSlide(on: screen)
        }

        // Слайд и видео живут в ОДНОМ окне: текст Библии, песня и фильм
        // приходят в зал одним и тем же экраном. Прежде кадр показывался
        // отдельным окном поверх слайда — оно ложилось не туда при смене
        // мониторов, спорило за порядок с окном управления и на одном экране
        // накрывало собой всё. Теперь это слой внутри окна слайда.
        let size = window.contentRect(forFrameRect: window.frame).size
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.autoresizingMask = [.width, .height]

        let canvas = SlideCanvasView(box: content)
        canvas.frame = container.bounds
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        self.canvas = canvas

        // Кадр — отдельным ВИДОМ поверх слайда, а не слоем, добавленным
        // руками в чужой короб. AppKit расставляет слои по порядку подвидов
        // и добавленный слой переставил ПОД слой SwiftUI: слайд закрывал
        // видео собой. Проверено опытом на этой машине — в середине короба
        // вместо кадра оказывался слайд.
        let video = VideoView(frame: container.bounds)
        // Слой просим сразу: у вида, добавленного в чужой короб, он заводится
        // не раньше первой отрисовки, и кадру было бы некуда лечь. Ровно на
        // этом самопроверка и поймала: вид на месте, а в зале ничего.
        video.wantsLayer = true
        video.autoresizingMask = [.width, .height]
        video.isHidden = true
        video.layer?.opacity = 0
        container.addSubview(video, positioned: .above, relativeTo: canvas)

        window.contentView = container
        window.orderFrontRegardless()
        self.window = window
        self.videoView = video
        self.videoLayer = video.layer
        // Указка — выше кадра и слайда: она показывает место на том, что
        // сейчас на стене, будь то стих или страница презентации.
        let pointer = PointerOverlay(frame: container.bounds)
        pointer.autoresizingMask = [.width, .height]
        container.addSubview(pointer, positioned: .above, relativeTo: video)
        self.pointerView = pointer
        // Окно пересобрали посреди показа — слайд и кадр обязаны вернуться на
        // место сразу, а не со следующим слайдом.
        canvas.refresh()
        if let media = keptMedia { applyVideo(media) }
        applyPointer(pointerMark, look: pointerLook)
        if let web = hostedWeb {
            let wanted = webShown
            hostedWeb = nil
            hostWeb(web, shown: wanted)
        }
    }

    /// Вид, в котором живёт кадр плеера. Своим слоем: только так порядок
    /// «кадр поверх слайда» держится и после каждой раскладки.
    private final class VideoView: NSView {
        override func makeBackingLayer() -> CALayer {
            let layer = CALayer()
            layer.contentsGravity = .resizeAspect
            layer.backgroundColor = NSColor.black.cgColor
            return layer
        }
    }

    /// Слой указки: пятно фигурой, а не картинкой — двигать его стоит
    /// ничего, и слайд под ним не перерисовывается.
    final class PointerOverlay: NSView {
        let shape = CAShapeLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(shape)
            isHidden = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }
        /// Мышь в зале указке не нужна — пусть проходит к слою под ней.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func show(_ mark: SlidePointer.Mark, look: SlidePointer.Look) {
            let width = bounds.width, height = bounds.height
            let radius = max(2, look.size * height / 2)
            let center = CGPoint(x: mark.x * width, y: (1 - mark.y) * height)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.path = CGPath(ellipseIn: rect, transform: nil)
            shape.fillColor = CGColor(red: look.colour.red, green: look.colour.green,
                                      blue: look.colour.blue, alpha: look.opacity)
            shape.strokeColor = CGColor(red: look.colour.red, green: look.colour.green,
                                        blue: look.colour.blue, alpha: min(1, look.opacity + 0.4))
            shape.lineWidth = max(1.5, radius * 0.08)
            isHidden = false
            CATransaction.commit()
            lastCenter = center
        }
        /// Где пятно нарисовано последним — самопроверке.
        private(set) var lastCenter: CGPoint?
    }

    private var pointerView: PointerOverlay?
    private var pointerMark: SlidePointer.Mark?
    private var pointerLook = SlidePointer.Look()

    /// Показать или убрать указку на стене. `nil` — убрать.
    func applyPointer(_ mark: SlidePointer.Mark?, look: SlidePointer.Look) {
        pointerMark = mark
        pointerLook = look
        guard let pointerView else { return }
        guard let mark else { pointerView.isHidden = true; return }
        pointerView.show(mark, look: look)
    }

    /// Стоит ли указка на стене и где — самопроверке.
    var pointerShown: Bool { pointerView.map { !$0.isHidden } ?? false }
    var pointerCenter: CGPoint? { pointerShown ? pointerView?.lastCenter : nil }

    /// Слой кадра поверх слайда — в том же окне.
    private var videoLayer: CALayer?
    private var videoView: VideoView?
    private var canvas: SlideCanvasView?

    /// Стоит ли кадр поверх слайда — это проверяет самопроверка: порядок
    /// здесь уже один раз молча перевернулся, и в зале остался текст.
    var isVideoOverSlide: Bool {
        guard let videoView, let canvas, let content = window?.contentView,
              let videoAt = content.subviews.firstIndex(of: videoView),
              let canvasAt = content.subviews.firstIndex(of: canvas) else { return false }
        // Выше слайда — а не «самый верхний»: над кадром теперь живёт слой
        // указки, и он там по праву.
        return videoAt > canvasAt
    }

    /// Указка выше кадра и слайда — иначе пятно пряталось бы под картинкой.
    var isPointerOverVideo: Bool {
        guard let pointerView, let content = window?.contentView,
              let pointerAt = content.subviews.firstIndex(of: pointerView) else { return false }
        let videoAt = videoView.flatMap { content.subviews.firstIndex(of: $0) } ?? -1
        return pointerAt > videoAt
    }

    /// Виден ли кадр в зале сейчас.
    var isVideoShown: Bool { videoView.map { !$0.isHidden } ?? false }

    /// Идёт ли сейчас плавный переход кадра. Самопроверке надо отличить
    /// «появилось плавно» от «появилось разом»: владелец просил именно
    /// плавность, и проверять её словами нельзя.
    var isFading: Bool { (videoView?.layer ?? videoLayer)?.animation(forKey: "плавность") != nil }

    /// Что лежит в слое кадра. Нужно самопроверке: «видно» и «видно именно
    /// то» — разные вещи, и путаницу «вместо фильма прежняя картинка» иначе
    /// не поймать.
    var shownContents: Any? { videoView?.layer?.contents }
    private weak var attachedMedia: MediaPlayerModel?

    /// Вид встроенного проигрывателя YouTube — в окне зала.
    ///
    /// Кадр YouTube не достать буфером, как у фильма: ролик рисует чужой
    /// iframe. Поэтому в зал ставится сам вид проигрывателя. Когда ролик не
    /// показывают, вид не прячется, а уходит ПОД слайд: спрятанный WebKit
    /// перестаёт рисовать, и снимков для панели и трансляции не будет.
    private var hostedWeb: NSView?
    private var webShown = false

    /// Виден ли в зале встроенный проигрыватель — для самопроверки.
    var isWebShown: Bool { webShown && hostedWeb?.superview != nil }

    func hostWeb(_ view: NSView?, shown: Bool) {
        if hostedWeb !== view {
            hostedWeb?.removeFromSuperview()
            hostedWeb = view
            webShown = false
        }
        guard let view = hostedWeb, let container = window?.contentView, let canvas else { return }
        if view.superview !== container {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            container.addSubview(view, positioned: .below, relativeTo: canvas)
        }
        guard shown != webShown else { return }
        webShown = shown
        if shown {
            // Поверх кадра фильма: у него сейчас те же снимки, но редкие.
            container.addSubview(view, positioned: .above, relativeTo: videoView ?? canvas)
            if let layer = view.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 0
                CATransaction.commit()
                fade(layer, to: 1)
            }
        } else {
            let seconds = Defaults.mediaFadeSeconds
            let sink = { [weak self, weak view] in
                guard let self, let view, !self.webShown, let canvas = self.canvas,
                      view.superview === self.window?.contentView else { return }
                self.window?.contentView?.addSubview(view, positioned: .below, relativeTo: canvas)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                view.layer?.opacity = 1
                CATransaction.commit()
            }
            guard seconds > 0, let layer = view.layer else { sink(); return }
            fade(layer, to: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { sink() }
        }
    }

    /// Показать в зале кадр плеера или вернуть слайд.
    ///
    /// Условие «видно ли кадр» считает сам плеер (`isVideoOnScreen`): там же
    /// живут затемнение, «скрыть слайд» и «пустой слайд», и второго мнения
    /// об этом быть не должно.
    func applyVideo(_ media: MediaPlayerModel?) {
        // Слой берём у вида, а не из запомненного: запомненный мог достаться
        // от прежнего окна, а кадр обязан лечь в нынешнее.
        guard let layer = videoView?.layer ?? videoLayer else { return }
        let wanted = media?.isVideoOnScreen ?? false
        if wanted, let media {
            if attachedMedia !== media {
                attachedMedia.map { $0.detach(layer) }
                attachedMedia = media
                media.attach(layer)
            }
            layer.isHidden = false
            videoView?.isHidden = false
            fade(layer, to: 1)
        } else {
            // Уходит кадр не мгновенно, а на глазах: резкая смена в зале
            // читается как сбой. Слой прячем ПОСЛЕ затухания — иначе гасить
            // будет нечего.
            let hide = { [weak self] in
                guard self?.attachedMedia == nil else { return }   // за это время могли показать снова
                layer.isHidden = true
                self?.videoView?.isHidden = true
            }
            attachedMedia?.detach(layer)
            attachedMedia = nil
            let seconds = Defaults.mediaFadeSeconds
            guard seconds > 0, !layer.isHidden else { hide(); return }
            fade(layer, to: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { hide() }
        }
    }

    /// Плавное появление и уход кадра.
    ///
    /// Длительность — своя настройка; ноль означает «как было», разом. Держим
    /// её здесь, а не в плеере: гасить и зажигать приходится и картинке, у
    /// которой своего хода нет.
    private func fade(_ layer: CALayer, to opacity: Float) {
        let seconds = Defaults.mediaFadeSeconds
        guard seconds > 0 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = opacity
            CATransaction.commit()
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = opacity
        animation.duration = seconds
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = opacity
        layer.add(animation, forKey: "плавность")
    }

    private func makeFullScreenSlide(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false,
                              screen: screen)
        window.isOpaque = true
        window.backgroundColor = .black
        // Уровень «экрана презентации» — тот, на котором Keynote показывает
        // слайды: выше строки меню и Dock на любом дисплее. На уровне
        // заставки владелец видел на проекторе системную строку меню —
        // «просто окно вывода, как в оригинале».
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.setFrame(screen.frame, display: true)
        return window
    }

    /// (9) Окно по заданным координатам: без рамки и поверх всего, как
    /// полноэкранное, — оно и есть слайд, просто не на весь монитор.
    private func makeManualSlide(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        // Уровень «экрана презентации» — тот, на котором Keynote показывает
        // слайды: выше строки меню и Dock на любом дисплее. На уровне
        // заставки владелец видел на проекторе системную строку меню —
        // «просто окно вывода, как в оригинале».
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.setFrame(frame, display: true)
        return window
    }

    /// Хрестик у вікні слайда ховає його, а не закриває: показ у залі живе
    /// далі, і вікно вертається з наступним слайдом.
    @MainActor private final class SlideWindowGuard: NSObject, NSWindowDelegate {
        weak var owner: ProjectionController?
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            owner?.hideSlideWindowByHand()
            return false
        }
    }

    private lazy var slideWindowGuard: SlideWindowGuard = {
        let guardian = SlideWindowGuard()
        guardian.owner = self
        return guardian
    }()

    /// Вікно слайда сховане людиною — вернеться з наступним показом.
    private var hiddenByHand = false

    func hideSlideWindowByHand() {
        hiddenByHand = true
        window?.orderOut(nil)
        NativeTrace.say("проектор: вікно слайда сховано хрестиком — вернеться з наступним слайдом")
    }

    private func makeWindowedSlide(on screen: NSScreen, size requested: NSSize? = nil) -> NSWindow {
        let width = min(screen.visibleFrame.width * 0.5, 960)
        let size = requested ?? NSSize(width: width, height: (width / 16 * 9).rounded())
        let origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 40,
                             y: screen.visibleFrame.maxY - size.height - 40)

        // Кнопки вікна — усі три. Спершу їх не було зовсім: у автора вікно
        // слайда живе завжди («окно всегда активно и включено без
        // возможности закрытия»), і я сховав закриття разом зі згортанням та
        // розгортанням. Вийшло гірше: власник — «в окне нет функций закрыть,
        // свернуть и развернуть окно», бо на машині з одним екраном це
        // звичайне вікно, і прибрати його з-перед очей не було чим.
        //
        // Тепер і те, і те: згортання й розгортання — як у будь-якого вікна,
        // а хрестик НЕ вбиває вікно, лише ховає його. Показ у зал живий,
        // вікно вертається само, щойно в зал піде наступний слайд.
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false,
                              screen: screen)
        window.title = OurWords.t("Окно слайда")
        window.delegate = slideWindowGuard
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .floating
        window.isReleasedWhenClosed = false
        // Соотношение сторон держим только у нашего запасного окна. Размеры
        // (7) заданы человеком (у пользователя 1024×768) — подгонять их под
        // 16:9 значит не выполнить настройку.
        if requested == nil { window.aspectRatio = NSSize(width: 16, height: 9) }
        return window
    }

    private func closeWindow() {
        hiddenByHand = false
        if window != nil { NativeTrace.say("проектор: вікно слайда прибрано") }
        if let videoLayer { attachedMedia?.detach(videoLayer) }
        videoLayer = nil
        // Иначе пересобранное окно решит, что слой уже подключён к этому же
        // плееру, и новый слой останется пустым.
        attachedMedia = nil
        // Вид проигрывателя остаётся нашим — окно пересоберётся и вернёт его.
        hostedWeb?.removeFromSuperview()
        window?.orderOut(nil)
        window = nil
    }
}

/// Наблюдаемая коробка со слайдом: окно проекции живёт вне обычного дерева
/// SwiftUI, поэтому обновления ему нужно доставлять явно.
@MainActor
final class SlideBox: ObservableObject {
    @Published var slide: Slide = .blank
    @Published var style = SlideStyle()
    /// Свой шаблон из Конструктора. Пусто — слайд собирается по-старому,
    /// из `SlideStyle`: так выглядят авторские шаблоны `.sch`.
    @Published var preset: SlidePreset?
    @Published var texts = ConstructorSample()
    /// Фон, выбранный человеком: он важнее фона шаблона.
    @Published var backgroundOverride: String?
    /// Как искать картинки объектов. Живёт в коробке, потому что окно
    /// проекции стоит вне обычного дерева видов и своего состояния не имеет.
    var imageURL: (String?) -> URL? = { _ in nil }
}

extension NSScreen {
    /// Устойчивый идентификатор монитора — по нему запоминаем выбор.
    var slovoIdentifier: String {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? localizedName
    }

    var slovoTitle: String {
        "\(localizedName) — \(Int(frame.width))×\(Int(frame.height))"
    }
}
