import AppKit
import SlovoCore

/// Отрисовка слайда — одна на всю программу, на CoreGraphics.
///
/// Зачем. Слайд рисовался видами SwiftUI, а кадр для трансляции и веба
/// снимался с них `ImageRenderer`. Отсюда две беды. Первая: раскладку SwiftUI
/// считает только на главном потоке, и каждый кадр в сеть занимал его же —
/// тот, на котором оператор листает стихи. Вторая: смесь двух движков в одном
/// окне уже подводила — AppKit переставил слой видео под слой SwiftUI, и в
/// зале поверх фильма стоял текст.
///
/// Здесь всё рисуется прямо в `CGContext`: и окно слайда, и предпросмотр, и
/// кадр NDI берут этот один код. Разойтись им теперь негде.
///
/// Сами буквы рисует `OutlinedText.draw` — он и раньше был на Core Text
/// внутри `Canvas`, поэтому вид надписи не меняется ни на волос: контур,
/// подбор кегля и тень остались теми же.
///
/// Рисовальщик не привязан к главному потоку: зал, кадр NDI и холст
/// Конструктора рисуются через `SlideRenderQueue` в фоне, чтобы движение
/// ползунка не замораживало окно. Всё, что ему нужно, — значения: заказ
/// приходит с уже найденными картинками (`Order.resolveImages`).
enum SlideDrawing {

    /// Что рисовать. Один заказ на оба случая: со своим шаблоном и без него.
    struct Order: @unchecked Sendable {
        var slide: Slide
        var style: SlideStyle
        var preset: SlidePreset?
        var texts: ConstructorSample = ConstructorSample()
        /// Рисовать ли подложку. `NdiTransparentBackGr` означает «в сеть —
        /// только надпись», и решает это вывод, а не шаблон.
        var drawsBackground = true
        /// Время от начала показа, в секундах: по нему считается появление
        /// объектов шаблона. `nil` — объекты стоят на своих местах.
        var clock: Double?
        var backgroundOverride: String?
        var withSecondTranslation = false
        var imageURL: (String?) -> URL? = { _ in nil }
        var missingFileLabel = "Не найден файл:"

        /// Картинки, найденные заранее на главном потоке: рисовальщик в фоне
        /// не вправе спрашивать `AppState`, где лежит файл шаблона.
        var resolvedImages: [String: URL] = [:]

        /// Найти все картинки заказа сейчас, на главном потоке, и дальше
        /// отвечать по готовой таблице. Зовётся перед отправкой в очередь.
        @MainActor mutating func resolveImages() {
            var names: [String] = []
            if let backgroundOverride { names.append(backgroundOverride) }
            if let preset {
                if let path = preset.background.imagePath { names.append(path) }
                for object in preset.objects {
                    if let path = object.imagePath { names.append(path) }
                    if let path = object.maskPath { names.append(path) }
                }
            }
            for name in names where !name.isEmpty && resolvedImages[name] == nil {
                if let url = imageURL(name) { resolvedImages[name] = url }
            }
            let table = resolvedImages
            imageURL = { name in name.flatMap { table[$0] } }
        }
    }

    // MARK: - Кадр

    /// Нарисовать слайд в картинку.
    static func image(_ order: Order, size: CGSize, opaque: Bool) -> CGImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info.rawValue) else { return nil }
        let canvas = CGSize(width: Double(width), height: Double(height))
        if opaque {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: canvas))
        }
        draw(order, in: context, size: canvas)
        return context.makeImage()
    }

    /// Нарисовать слайд в готовый контекст — в его неперевёрнутых координатах.
    ///
    /// Внутри система координат переворачивается один раз: слайд считается
    /// сверху вниз, как его читает человек, и разворачивать её в каждом
    /// месте значило бы рано или поздно поставить надпись вверх ногами.
    static func draw(_ order: Order, in context: CGContext, size: CGSize) {
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(origin: .zero, size: size))

        if let preset = order.preset {
            drawBackground(preset: preset, order: order, in: context, size: size)
            if !order.slide.isBlank {
                drawObjects(preset: preset, order: order, in: context, size: size)
            }
        } else {
            drawBackground(style: order.style, order: order, in: context, size: size)
            if !order.slide.isBlank {
                drawStack(order: order, in: context, size: size)
            }
        }
        context.restoreGState()
    }

    // MARK: - Подложка

    private static func drawBackground(style: SlideStyle, order: Order,
                                       in context: CGContext, size: CGSize) {
        guard order.drawsBackground else { return }
        context.setFillColor(color(style.backgroundColor))
        context.fill(CGRect(origin: .zero, size: size))
        guard let path = order.backgroundOverride ?? style.backgroundImagePath,
              let image = SlideImageStore.shared.image(atPath: path) else { return }
        drawBackdrop(image, path: path, mode: .fill,
                     in: CGRect(origin: .zero, size: size), context: context)
        // Затемнение фона — настройка оригинала (`dimBackground`).
        guard style.dimBackground > 0 else { return }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: style.dimBackground))
        context.fill(CGRect(origin: .zero, size: size))
    }

    private static func drawBackground(preset: SlidePreset, order: Order,
                                       in context: CGContext, size: CGSize) {
        // Прозрачная подложка — для NDI: картинку под текст кладёт микшер,
        // и наш фон там только мешает.
        guard order.drawsBackground, !preset.background.isTransparent else { return }
        context.setFillColor(color(preset.background.color))
        context.fill(CGRect(origin: .zero, size: size))
        guard let url = order.imageURL(order.backgroundOverride ?? preset.background.imagePath),
              let image = SlideImageStore.shared.image(atPath: url.path) else { return }
        drawBackdrop(image, path: url.path, mode: preset.background.fillMode,
                     in: CGRect(origin: .zero, size: size), context: context)
    }

    // MARK: - Текст без шаблона

    /// Стопка «стих — второй перевод — адрес», как её ставил `VStack`.
    ///
    /// Числа те же, что были у видов: промежуток `высота × межстрочный × 0,35`,
    /// высота блока `высота × кегль × 3,4`, отступ адреса `высота × 0,02`.
    /// Их нельзя «округлить по-своему»: слайд обязан выглядеть точно так же,
    /// как вчера, — иначе на служении это заметят.
    private static func drawStack(order: Order, in context: CGContext, size: CGSize) {
        let style = order.style
        let slide = order.slide
        var blocks: [(text: String, layer: SlideStyle.TextLayer, height: Double, gapAbove: Double)] = []
        let spacing = size.height * style.lineSpacing * 0.35

        if !slide.mainText.isEmpty {
            blocks.append((slide.mainText, style.main, size.height * style.main.fontSize * 3.4, 0))
        }
        for text in slide.secondaryTexts where !text.isEmpty {
            blocks.append((text, style.secondary, size.height * style.secondary.fontSize * 3.4,
                           blocks.isEmpty ? 0 : spacing))
        }
        if !slide.reference.isEmpty {
            blocks.append((slide.reference, style.reference,
                           size.height * style.reference.fontSize * 3.4,
                           (blocks.isEmpty ? 0 : spacing) + size.height * 0.02))
        }
        guard !blocks.isEmpty else { return }

        let box = CGRect(x: size.width * style.horizontalInset,
                         y: size.height * style.verticalInset,
                         width: size.width * (1 - style.horizontalInset * 2),
                         height: size.height * (1 - style.verticalInset * 2))
        let total = blocks.reduce(0) { $0 + $1.height + $1.gapAbove }
        var top: Double
        switch style.verticalAlignment {
        case .top:    top = box.minY
        case .center: top = box.midY - total / 2
        case .bottom: top = box.maxY - total
        }

        for block in blocks {
            top += block.gapAbove
            let rect = CGRect(x: box.minX, y: top, width: box.width, height: block.height)
            drawText(block.text, layer: block.layer, lineSpacing: style.lineSpacing,
                     alignment: .center, verticalAlignment: .center, minimumScale: 0.35,
                     shadow: nil, in: rect, canvasHeight: size.height, context: context)
            top += block.height
        }
    }

    // MARK: - Объекты шаблона

    private static func drawObjects(preset: SlidePreset, order: Order,
                                    in context: CGContext, size: CGSize) {
        for object in preset.objects {
            let values = object.variant(withSecondTranslation: order.withSecondTranslation)
            guard values.isVisible else { continue }
            let auto = ConstructorAutoSize.size(of: object, values: values, sample: order.texts,
                                                canvas: size, imageURL: order.imageURL)
            let rect = values.frame.resolved(auto: auto, in: size).rect(in: size)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }

            // Появление объекта: то же, что считает панель «Анимация».
            let step = progress(of: values.animation, clock: order.clock)
            let scale = values.animation.animatesScale
                ? values.animation.startScale + (1 - values.animation.startScale) * step : 1
            let fade = values.animation.animatesOpacity
                ? values.animation.startOpacity + (1 - values.animation.startOpacity) * step : 1
            let shift = entrance(values.animation, canvas: size)

            context.saveGState()
            context.setAlpha(values.opacity * fade)
            context.translateBy(x: shift.x * (1 - step), y: shift.y * (1 - step))
            if scale != 1 {
                context.translateBy(x: rect.midX, y: rect.midY)
                context.scaleBy(x: scale, y: scale)
                context.translateBy(x: -rect.midX, y: -rect.midY)
            }
            if object.kind == .image {
                drawObjectImage(object, values: values, order: order, rect: rect, context: context)
            } else {
                let line = order.texts.text(for: object)
                if !line.isEmpty {
                    drawText(line, layer: object.text, lineSpacing: object.lineSpacing,
                             alignment: alignment(values.alignment),
                             verticalAlignment: values.verticalAlignment,
                             minimumScale: object.minimumScale,
                             shadow: values.shadow,
                             in: rect, canvasHeight: size.height, context: context)
                }
            }
            context.restoreGState()
        }
    }

    private static func drawObjectImage(_ object: SlideObject, values: ObjectVariant,
                                        order: Order, rect: CGRect, context: CGContext) {
        guard let url = order.imageURL(object.imagePath),
              let picture = SlideImageStore.shared.image(atPath: url.path) else { return }
        var image = picture
        // Маска у автора — обычная картинка в градациях серого: белое
        // остаётся, чёрное вырезается.
        if let maskURL = order.imageURL(object.maskPath),
           let mask = SlideImageStore.shared.image(atPath: maskURL.path),
           let masked = applyMask(mask, to: picture) {
            image = masked
        }
        context.saveGState()
        if values.shadow.isVisible {
            // Мерки те же, что у конструктора: разойдись они — и тень на
            // холсте была бы одна, а на проекторе другая.
            let metrics = values.shadow.metrics(fontSize: 0, objectHeight: rect.height)
            var tint = color(values.shadow.color)
            if let faded = tint.copy(alpha: values.shadow.opacity) { tint = faded }
            context.setShadow(offset: CGSize(width: metrics.offset.width, height: -metrics.offset.height),
                              blur: metrics.blur, color: tint)
        }
        drawPicture(image, mode: .fill, in: rect, context: context)
        context.restoreGState()
    }

    /// Готовые подложки: фотография фона, уже приведённая к размеру кадра.
    ///
    /// Без этого каждый стих заново растягивал снимок на весь холст — а это
    /// четыре мегапикселя на кадр, и на нажатие клавиши уходило под пятьдесят
    /// миллисекунд вместо трёх. Ключ — файл, размер и правило заполнения:
    /// разойдись хоть одно, и подложку надо считать заново.
    private struct BackdropKey: Hashable {
        let path: String
        let width: Int
        let height: Int
        let mode: String
    }
    /// Под замком: подложки считают и зал, и кадр NDI, и они рисуются
    /// одновременно на разных потоках.
    nonisolated(unsafe) private static var backdrops: [BackdropKey: CGImage] = [:]
    private static let backdropLock = NSLock()

    private static func readyBackdrop(_ key: BackdropKey) -> CGImage? {
        backdropLock.lock(); defer { backdropLock.unlock() }
        return backdrops[key]
    }

    private static func remember(_ image: CGImage, for key: BackdropKey) {
        backdropLock.lock(); defer { backdropLock.unlock() }
        // Держим немного: на служении фонов в ходу два-три, а каждый — это
        // несколько мегабайт.
        if backdrops.count >= 6 { backdrops.removeAll() }
        backdrops[key] = image
    }

    /// Фон кадра — из готовых, если он уже считался.
    private static func drawBackdrop(_ image: CGImage, path: String, mode: SlidePreset.FillMode,
                                     in rect: CGRect, context: CGContext) {
        let key = BackdropKey(path: path, width: Int(rect.width.rounded()),
                              height: Int(rect.height.rounded()), mode: "\(mode)")
        if let ready = readyBackdrop(key) {
            context.saveGState()
            context.translateBy(x: 0, y: rect.midY * 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(ready, in: rect)
            context.restoreGState()
            return
        }
        let width = max(1, Int(rect.width.rounded())), height = max(1, Int(rect.height.rounded()))
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let scratch = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info.rawValue) else {
            drawPicture(image, mode: mode, in: rect, context: context)
            return
        }
        scratch.translateBy(x: 0, y: Double(height))
        scratch.scaleBy(x: 1, y: -1)
        drawPicture(image, mode: mode, in: CGRect(x: 0, y: 0, width: Double(width), height: Double(height)),
                    context: scratch)
        guard let ready = scratch.makeImage() else {
            drawPicture(image, mode: mode, in: rect, context: context)
            return
        }
        remember(ready, for: key)
        context.saveGState()
        context.translateBy(x: 0, y: rect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(ready, in: rect)
        context.restoreGState()
    }

    /// Картинка в рамку по правилу заполнения шаблона.
    private static func drawPicture(_ image: CGImage, mode: SlidePreset.FillMode,
                                    in rect: CGRect, context: CGContext) {
        let source = CGSize(width: Double(image.width), height: Double(image.height))
        guard source.width > 0, source.height > 0 else { return }
        var place = rect
        switch mode {
        case .stretch:
            place = rect
        case .center:
            place = CGRect(x: rect.midX - source.width / 2, y: rect.midY - source.height / 2,
                           width: source.width, height: source.height)
        case .fit:
            let scale = min(rect.width / source.width, rect.height / source.height)
            place = CGRect(x: rect.midX - source.width * scale / 2,
                           y: rect.midY - source.height * scale / 2,
                           width: source.width * scale, height: source.height * scale)
        case .fill, .tile:
            let scale = max(rect.width / source.width, rect.height / source.height)
            place = CGRect(x: rect.midX - source.width * scale / 2,
                           y: rect.midY - source.height * scale / 2,
                           width: source.width * scale, height: source.height * scale)
        }
        context.saveGState()
        context.clip(to: rect)
        // Кадр рисуется в неперевёрнутых координатах: `CGContext.draw` кладёт
        // картинку снизу вверх, а холст у нас перевёрнут.
        context.translateBy(x: 0, y: place.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: place)
        context.restoreGState()
    }

    /// Яркость маски становится прозрачностью картинки.
    private static func applyMask(_ mask: CGImage, to image: CGImage) -> CGImage? {
        guard let provider = mask.dataProvider else { return nil }
        guard let grey = CGImage(maskWidth: mask.width, height: mask.height,
                                 bitsPerComponent: mask.bitsPerComponent,
                                 bitsPerPixel: mask.bitsPerPixel,
                                 bytesPerRow: mask.bytesPerRow,
                                 provider: provider, decode: nil,
                                 shouldInterpolate: true) else { return nil }
        return image.masking(grey)
    }

    // MARK: - Надпись

    private static func drawText(_ text: String, layer: SlideStyle.TextLayer,
                                 lineSpacing: Double, alignment: NSTextAlignment,
                                 verticalAlignment: SlideStyle.VerticalAlignment,
                                 minimumScale: Double, shadow: ObjectShadow?,
                                 in rect: CGRect, canvasHeight: Double, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        OutlinedText.draw(text: text, layer: layer, lineSpacing: lineSpacing,
                          alignment: alignment, height: canvasHeight,
                          minimumScale: minimumScale,
                          verticalAlignment: verticalAlignment, shadow: shadow,
                          in: rect.size, context: context)
        context.restoreGState()
    }

    // MARK: - Появление объекта

    /// Доля пройденного пути: от нуля до единицы.
    private static func progress(of animation: ObjectAnimation, clock: Double?) -> Double {
        guard animation.isAnimated else { return 1 }
        guard let clock else { return 1 }
        let start = animation.delay / 1000
        let length = max(0.001, animation.duration / 1000)
        let step = min(1, max(0, (clock - start) / length))
        // Тот же ход, что у `easeOut` в живом показе: быстро в начале, мягко
        // в конце. Иначе кадры в сети шли бы ровно, а зал видел ускорение.
        return 1 - pow(1 - step, 2)
    }

    private static func entrance(_ animation: ObjectAnimation, canvas: CGSize) -> CGPoint {
        switch animation.direction {
        case .none:
            return .zero
        case .point:
            return CGPoint(x: (animation.pointX - 0.5) * canvas.width,
                           y: (animation.pointY - 0.5) * canvas.height)
        default:
            let offset = animation.direction.offset
            return CGPoint(x: offset.x * canvas.width, y: offset.y * canvas.height)
        }
    }

    // MARK: - Мелочи

    private static func alignment(_ value: ParagraphAlignment) -> NSTextAlignment {
        switch value {
        case .leading:  return .left
        case .center:   return .center
        case .trailing: return .right
        }
    }

    static func color(_ rgba: SlideStyle.RGBA) -> CGColor {
        CGColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}
