import AppKit
import QuartzCore
import SlovoCore

/// Попередній перегляд слайда (12).
///
/// Тут немає жодного виду: усе вікно передпоказу — це три шари.
/// Підкладка стоїть унизу і міняється сама по собі, два написи нагорі
/// перехресно гаснуть при зміні слайда. Розчинення грає Core Animation
/// на своєму боці, і головному потоку воно не коштує нічого: наша робота —
/// намалювати картинку один раз і підставити її в шар.
///
/// Чому не `SlideView` у `NSHostingView`: передпоказ оновлюється на кожне
/// натискання, а будь-яке оновлення виду SwiftUI — це перезбирання тіла, розкладка
/// і звіряння. Власник це й побачив: «при выводе куплета зависает на 10-20
/// секунд».
///
/// Кадр плеєра («Отображать видео в окне предпросмотра», `CBShowVideoOnPreview`)
/// лягає окремим шаром поверх напису — тим самим, що і у вікні залу.
@MainActor
final class NativeSlidePreview: NSView {

    /// Показ іде в зал — рамка червона і вдвічі товща, як у колишньому вікні.
    var isLive = false {
        didSet {
            guard isLive != oldValue else { return }
            applyBorder()
        }
    }

    private let backdrop = CALayer()
    private let textLayers = [CALayer(), CALayer()]
    /// Який із двох шарів напису зараз нагорі.
    private var front = 0

    private var backdropIdentity = 0
    private var drawIdentity = 0
    /// Скільки разів `show` дійшов до малювання — самоперевірка так бачить, що
    /// передпоказ у вікні «Параметри» живий. `drawIdentity` для цього не
    /// годиться: це ключ-хеш, і на шляху свого шаблону він не міняється.
    private(set) var drawCount = 0
    private var textIdentity = 0
    private var lastSize = CGSize.zero

    /// Шар плеєра. Заводиться в ту мить, коли відео вперше знадобилося:
    /// у більшості служінь його немає зовсім.
    private var videoLayer: CALayer?
    private weak var attachedMedia: MediaPlayerModel?

    /// Чи стоїть зараз шар плеєра. Ним самоперевірка відрізняє «налаштування
    /// ввімкнено» від «відео і справді дійшло до передпоказу».
    var isVideoMounted: Bool { videoLayer != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = NativeBottomMetrics.corner
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderWidth = 1

        backdrop.contentsGravity = .resize
        backdrop.masksToBounds = true
        layer?.addSublayer(backdrop)
        for text in textLayers {
            text.contentsGravity = .resize
            text.opacity = 0
            layer?.addSublayer(text)
        }
        applyBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    // Вид навмисно НЕ перевернутий: підвидів у нього немає, а перевернутому виду
    // AppKit перевертає і геометрію шару — картинка лягла б догори ногами.

    override func layout() {
        super.layout()
        let box = bounds
        // Шари не беруть участі в розкладці видів: розставляємо самі і без
        // неявної анімації — інакше вікно при розтягуванні «пливе».
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = box
        for text in textLayers { text.frame = box }
        videoLayer?.frame = box
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorder()
    }

    /// Відбиток намальованого свого шаблону і номер останнього замовлення
    /// черги: кадр, обігнаний наступним, не показується.
    private var presetIdentity = 0
    private var presetGeneration = 0

    private func showPreset(slide: Slide, preset: SlidePreset, texts: ConstructorSample,
                            backgroundOverride: String?,
                            imageURL: @escaping (String?) -> URL?,
                            size: CGSize, resized: Bool) {
        var hasher = Hasher()
        hasher.combine(slide)
        hasher.combine(preset)
        // Тексти об'єктів — теж у відбиток: той самий слайд з іншими
        // підписами (назва перекладу, пісні) зобов'язаний перемалюватися.
        hasher.combine(texts)
        hasher.combine(backgroundOverride)
        hasher.combine(Int(size.width.rounded()))
        hasher.combine(Int(size.height.rounded()))
        let key = hasher.finalize()
        guard key != presetIdentity || resized else { return }
        presetIdentity = key
        backdropIdentity = 0
        drawIdentity = 0
        textIdentity = 0

        // Малює черга у фоні — тим самим малювальником, що й зал. Кадр у
        // два рази більший за вид: на Retina інакше буде мило.
        var order = SlideDrawing.Order(slide: slide, style: SlideStyle(), preset: preset, texts: texts,
                                       drawsBackground: true, clock: nil,
                                       backgroundOverride: backgroundOverride,
                                       withSecondTranslation: !slide.secondaryTexts.isEmpty,
                                       imageURL: imageURL)
        order.resolveImages()
        let pixels = CGSize(width: max(2, size.width * 2), height: max(2, size.height * 2))
        // Зміна зі своїм шаблоном ішла ривком: передпоказ підміняв картинку
        // разом, а зал у цей же час розчиняв одне в іншому. Оператор
        // бачив одне, зал інше. Тепер і тут перехід той самий і тієї самої
        // довжини — береться із самого шаблону.
        let fades = !resized && preset.transition != .none && preset.transitionDuration > 0.01
        let duration = preset.transitionDuration
        presetGeneration &+= 1
        let wanted = presetGeneration
        SlideRenderQueue.shared.render(key: "предпросмотр-\(ObjectIdentifier(self).hashValue)",
                                       generation: wanted, order: order, size: pixels, opaque: false) {
            [weak self] picture, done in
            guard let self, done == self.presetGeneration else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(!fades)
            if fades {
                CATransaction.setAnimationDuration(duration)
                let cross = CATransition()
                cross.type = .fade
                cross.duration = duration
                self.backdrop.add(cross, forKey: "смена")
            }
            self.backdrop.contentsGravity = .resize
            self.backdrop.contents = picture
            for text in self.textLayers {
                text.contents = nil
                text.opacity = 0
            }
            CATransaction.commit()
        }
    }

    // MARK: - Оновлення

    /// Показати слайд. Другий виклик з тим самим вмістом не робить нічого —
    /// ні малювання, ні переходу.
    func show(slide: Slide, style: SlideStyle,
              preset: SlidePreset? = nil,
              texts: ConstructorSample = ConstructorSample(),
              backgroundOverride: String? = nil,
              imageURL: @escaping (String?) -> URL? = { _ in nil }) {
        let size = bounds.size
        guard size.width > 2, size.height > 2 else { return }
        drawCount &+= 1
        let resized = size != lastSize
        lastSize = size
        showing = .slide(slide)

        // Свій шаблон малюється тими самими засобами, що й зал: інакше людина
        // правила б одне, а бачила в передпоказі інше. Тут це не дорого
        // — кадр будується на зміну слайда, а не на кожен показ.
        if let preset {
            showPreset(slide: slide, preset: preset, texts: texts,
                       backgroundOverride: backgroundOverride,
                       imageURL: imageURL, size: size, resized: resized)
            return
        }
        presetIdentity = 0

        let backdropKey = NativeSlideRender.backdropIdentity(style: style, size: size)
        if backdropKey != backdropIdentity || resized {
            backdropIdentity = backdropKey
            let picture = NativeSlideRender.backdrop(style: style, size: size)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdrop.contentsGravity = .resize
            backdrop.contents = picture
            CATransaction.commit()
        }

        let drawKey = NativeSlideRender.drawIdentity(slide: slide, style: style, size: size)
        guard drawKey != drawIdentity || resized else { return }
        drawIdentity = drawKey

        let textKey = NativeSlideRender.textIdentity(slide: slide)
        // Змінилося лише оформлення (кегль, колір, розмір вікна) — підміняємо
        // картинку мовчки. Розчинення грається на зміну тексту, а не на
        // рух повзунка налаштувань.
        let fades = textKey != textIdentity && !resized && style.transition != .none
        textIdentity = textKey

        let picture = NativeSlideRender.text(slide: slide, style: style, size: size)
        applyShadow(NativeSlideRender.shadowRadius(slide: slide, style: style, size: size))
        guard fades else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            textLayers[front].contents = picture
            textLayers[front].opacity = picture == nil ? 0 : 1
            textLayers[front].transform = CATransform3DIdentity
            textLayers[1 - front].contents = nil
            textLayers[1 - front].opacity = 0
            CATransaction.commit()
            return
        }

        let outgoing = textLayers[front]
        let incoming = textLayers[1 - front]
        front = 1 - front

        let kind = style.transition
        let size3 = bounds.size
        let duration = max(0.05, style.transitionDuration)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incoming.contents = picture
        incoming.opacity = SlideTransitionAnimator.fadesIn(kind) ? 0 : (picture == nil ? 0 : 1)
        incoming.transform = SlideTransitionAnimator.enterTransform(kind, size: size3)
        incoming.mask = nil
        outgoing.mask = nil
        outgoing.filters = nil
        // Накриття і шторка: новий шар поверх старого.
        incoming.zPosition = 1
        outgoing.zPosition = 0
        if let wipe = SlideTransitionAnimator.wipe(kind, size: size3) {
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            mask.frame = wipe.from
            incoming.mask = mask
            let grow = CABasicAnimation(keyPath: "frame")
            grow.fromValue = NSValue(rect: wipe.from)
            grow.toValue = NSValue(rect: wipe.to)
            grow.duration = duration
            grow.timingFunction = SlideTransitionAnimator.timing(style.effectiveEasing)
            grow.fillMode = .forwards
            grow.isRemovedOnCompletion = false
            mask.add(grow, forKey: "шторка")
            mask.frame = wipe.to
        }
        if SlideTransitionAnimator.blurs(kind), let filter = CIFilter(name: "CIGaussianBlur") {
            filter.name = "blur"
            filter.setValue(0, forKey: kCIInputRadiusKey)
            outgoing.filters = [filter]
            let radius = CABasicAnimation(keyPath: "filters.blur.inputRadius")
            radius.fromValue = 0
            radius.toValue = 12
            radius.duration = duration
            outgoing.add(radius, forKey: "размытие")
        }
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(SlideTransitionAnimator.timing(style.effectiveEasing))
        if SlideTransitionAnimator.isThroughBlack(kind) {
            // Через чорне: старий гасне в першій половині, новий проявляється у другій.
            let out = CAKeyframeAnimation(keyPath: "opacity")
            out.values = [1, 0, 0]; out.keyTimes = [0, 0.5, 1]; out.duration = duration
            outgoing.add(out, forKey: "гаснет")
            let inn = CAKeyframeAnimation(keyPath: "opacity")
            inn.values = [0, 0, 1]; inn.keyTimes = [0, 0.5, 1]; inn.duration = duration
            incoming.add(inn, forKey: "проявляется")
        }
        incoming.opacity = picture == nil ? 0 : 1
        incoming.transform = CATransform3DIdentity
        if SlideTransitionAnimator.fadesOut(kind) { outgoing.opacity = 0 }
        outgoing.transform = SlideTransitionAnimator.leaveTransform(kind, size: size3)
        CATransaction.commit()
        // Старий шар без гасіння (зсуви, накриття, шторки) ховаємо після
        // закінчення, інакше він лишився б під новим назавжди.
        let leaving = outgoing
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            leaving.opacity = 0
            leaving.mask = nil
            leaving.filters = nil
            leaving.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    /// Звідки приходить новий напис. Той, що йде, рухається в той самий бік —
    /// інакше перехід читається як тремтіння.

    // MARK: - Кадр плеєра поверх слайда

    /// Налаштування «Отображать видео в окне предпросмотра» (`CBShowVideoOnPreview`).
    /// Шар плеєра заводиться один раз і потім лише показується і ховається.
    /// Картинка замість слайда — для вкладок показу. Наступний `show`
    /// перемалює все заново: відбитки скинуто.
    func showStill(_ image: CGImage?) {
        drawCount &+= 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.contents = image
        backdrop.contentsGravity = .resizeAspect
        for layer in textLayers { layer.contents = nil; layer.opacity = 0 }
        CATransaction.commit()
        backdropIdentity = 0
        drawIdentity = 0
        textIdentity = 0
        // І відбиток свого шаблону теж. Без цього рядка передпоказ після
        // картинки презентації відмовлявся малювати ТОЙ САМИЙ вірш за своїм
        // шаблоном: ключ збігався з колишнім, і `showPreset` виходив, не торкнувши
        // шарів. Власник бачив це як «предпросмотр показывает слайд,
        // который уже закрыт, и отстаёт на один».
        presetIdentity = 0
        showing = image.map { .still($0) } ?? .nothing
    }

    /// Що зараз стоїть у передпоказі. Самоперевірці і «туру» по вікнах
    /// цього не побачити інакше: шари — це картинки, а не стан.
    enum Showing {
        case nothing
        case still(CGImage)
        case slide(Slide)

        var described: String {
            switch self {
            case .nothing: return "пусто"
            case .still(let image): return "картинка \(image.width)×\(image.height)"
            case .slide(let slide):
                return slide.isBlank ? "пустой слайд" : "слайд «\(slide.reference)»: \(slide.mainText.prefix(30))"
            }
        }
    }
    private(set) var showing: Showing = .nothing

    /// Намальований кадр слайда за своїм шаблоном — самоперевірці: за ним
    /// видно, чи є на картинці текст, а не лише фон.
    var renderedPicture: CGImage? {
        guard let contents = backdrop.contents else { return nil }
        return (contents as! CGImage)
    }

    func applyVideo(_ media: MediaPlayerModel) {
        // Як у залі: коли там текст або фільм зупинено, кадр у
        // передпоказі не тримаємо — інакше він висів до перезапуску.
        let wanted = media.videoToPreview && media.hasVideo && media.mediaURL != nil
            && !media.screenSuppression.contains(.slideTookOver)
            && !media.screenSuppression.contains(.stopped)
        guard wanted else {
            if let videoLayer, let attachedMedia {
                attachedMedia.detach(videoLayer)
                videoLayer.removeFromSuperlayer()
            }
            videoLayer = nil
            attachedMedia = nil
            return
        }
        guard videoLayer == nil else { return }
        let video = CALayer()
        video.frame = bounds
        video.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(video)
        media.attach(video)
        videoLayer = video
        attachedMedia = media
    }

    // MARK: -

    /// Тінь напису. Її кладе Core Animation за прозорістю шару — на
    /// боці відеокарти і без жодної мілісекунди головного потоку.
    private func applyShadow(_ radius: CGFloat) {
        for text in textLayers {
            text.shadowColor = NSColor.black.cgColor
            text.shadowOffset = .zero
            text.shadowRadius = radius
            text.shadowOpacity = radius > 0 ? 0.55 : 0
        }
    }

    private func applyBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = isLive ? 2 : 1
            layer?.borderColor = isLive
                ? NSColor.systemRed.cgColor
                : NSColor.separatorColor.cgColor
        }
    }
}
