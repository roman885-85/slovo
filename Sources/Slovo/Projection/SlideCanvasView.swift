import AppKit
import SlovoCore

/// Слайд в окне зала — свой вид AppKit, без SwiftUI.
///
/// Рисует тем же `SlideDrawing`, что и кадр для трансляции: один код на зал,
/// предпросмотр и сеть. Пока это были разные движки, между ними неминуемо
/// заводилась разница — а заметна она только на стене в зале.
///
/// Смена слайда — перекрёстное растворение слоя: `CATransition` показывает
/// старый кадр и новый разом, и фон при этом не проваливается, потому что в
/// обоих кадрах он один и тот же.
@MainActor
final class SlideCanvasView: NSView {

    private let box: SlideBox
    private var drawn: CGImage?
    private var mark: Int?

    init(box: SlideBox) {
        self.box = box
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        // При раскладке рисуем сразу: кадр нужен к первому показу окна, а
        // ждать следующего прохода цикла тут нечего — нажатия нет.
        redraw(animated: false)
    }

    /// Перерисовать — но не сию секунду.
    ///
    /// Кадр в зал рисуется размером с проектор, и делать это прямо в обработке
    /// нажатия значило бы держать клавишу лишние десятки миллисекунд: стих
    /// уже сменился, а окно управления ещё занято. Поэтому отрисовка
    /// откладывается на следующий проход цикла и по дороге склеивается —
    /// подряд пришедшие поводы дают один кадр, а не пять.
    func refresh(animated: Bool = true) {
        wantsAnimation = wantsAnimation || animated
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            let animated = self.wantsAnimation
            self.wantsAnimation = false
            self.redraw(animated: animated)
        }
    }

    private var isScheduled = false
    private var wantsAnimation = false

    /// Сама отрисовка. Отпечаток нужен затем, что повод «обновись» приходит
    /// на каждое движение оператора, а кадр меняется далеко не всегда.
    ///
    /// Рисует не здесь, а очередь в фоне: кадр размером с проектор с тенями
    /// стоит сотню миллисекунд, и на главном потоке это было заморозкой окна
    /// на каждое движение ползунка. Пока кадр готовится, в зале стоит
    /// прежний; пришёл новый — сменяется тем же переходом, что и раньше.
    private func redraw(animated: Bool) {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        // Кадр рисуем в разрешении слайда, а не экрана: на Retina-мониторе
        // это вчетверо больше точек впустую — проектор всё равно покажет
        // 1920×1080, а лишние миллисекунды отнимаются у окна управления.
        let scale = min(window?.backingScaleFactor ?? 1, 2)
        let limit = 1920.0
        let full = CGSize(width: size.width * scale, height: size.height * scale)
        let shrink = min(1, limit / max(full.width, 1))
        let pixels = CGSize(width: max(1, full.width * shrink),
                            height: max(1, full.height * shrink))
        let identity = SlideFrameRenderer.identity(slide: box.slide, style: box.style,
                                                   size: pixels, preset: box.preset,
                                                   drawsBackground: true)
            &+ (box.backgroundOverride?.hashValue ?? 0)
            &+ box.texts.mainText.hashValue &+ box.texts.secondaryText.hashValue
            &+ box.texts.reference.hashValue &+ box.texts.songTitle.hashValue
        guard identity != mark else { return }
        mark = identity

        var order = SlideDrawing.Order(slide: box.slide, style: box.style, preset: box.preset,
                                       texts: box.texts, drawsBackground: true, clock: nil,
                                       backgroundOverride: box.backgroundOverride,
                                       withSecondTranslation: !box.slide.secondaryTexts.isEmpty,
                                       imageURL: box.imageURL)
        order.resolveImages()
        let seconds = box.preset?.transitionDuration ?? box.style.transitionDuration
        let kind = box.preset?.transition ?? box.style.transition
        let easing = box.preset?.transitionEasing ?? box.style.effectiveEasing

        generation &+= 1
        let wanted = generation
        SlideRenderQueue.shared.render(key: "зал", generation: wanted, order: order,
                                       size: pixels, opaque: true) { [weak self] image, done in
            guard let self, done == self.generation, let image else { return }
            self.show(image, animated: animated, kind: kind, seconds: seconds, easing: easing)
        }
    }

    /// Номер последнего заказа: кадр, обогнанный следующим, в зал не идёт.
    private var generation = 0

    private func show(_ image: CGImage, animated: Bool, kind: SlideStyle.Transition,
                      seconds: Double, easing: SlideStyle.Easing) {
        let previous = drawn
        let hadPicture = previous != nil
        drawn = image
        guard let layer else { return }
        if animated, kind != .none, hadPicture, seconds > 0 {
            SlideTransitionAnimator.play(on: layer, from: previous, to: image,
                                         kind: kind, duration: seconds, easing: easing)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            SlideTransitionAnimator.settle(layer, contents: image)
            CATransaction.commit()
        }
    }

    /// Кадр, который сейчас в окне, — его снимает самопроверка.
    var currentImage: CGImage? { drawn }
}
