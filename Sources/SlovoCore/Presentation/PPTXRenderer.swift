import Foundation
import CoreGraphics
import CoreText
import AppKit

/// Малювання слайда презентації в картинку.
///
/// Картинкою, а не своїм видом на екрані, — навмисно: готовий кадр іде тією
/// ж дорогою, що відео і фото, і тому одразу опиняється скрізь, де потрібен:
/// у вікні слайда, у передпоказі і в трансляції. Жодного нового вікна, жодного
/// нового шару.
///
/// Усе, що прийшло з файла, лежить у частках полотна, тому малювати можна в
/// будь-якому розмірі: мініатюру в список і повний кадр у зал рахує один і той
/// самий код.
public enum PPTXRenderer {

    public static func image(of slide: PPTXDocument.Slide,
                             in document: PPTXDocument,
                             size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info.rawValue) else { return nil }

        // Слайд малюється згори вниз, як його читає людина, а CoreGraphics
        // рахує знизу вгору. Перевертаємо один раз тут, а не в кожному
        // місці: інакше текст неминуче опиниться догори ногами.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        // Білий за умовчанням: у PowerPoint порожній слайд білий, і чорний
        // прямокутник замість нього читався б як поломка.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        draw(fill: slide.background, in: CGRect(origin: .zero, size: size),
             document: document, context: context, size: size)

        for shape in slide.shapes {
            let rect = CGRect(x: shape.frame.minX * size.width,
                              y: shape.frame.minY * size.height,
                              width: shape.frame.width * size.width,
                              height: shape.frame.height * size.height)
            context.saveGState()
            if shape.rotation != 0 || shape.flipH || shape.flipV {
                context.translateBy(x: rect.midX, y: rect.midY)
                if shape.rotation != 0 { context.rotate(by: shape.rotation * .pi / 180) }
                if shape.flipH || shape.flipV {
                    context.scaleBy(x: shape.flipH ? -1 : 1, y: shape.flipV ? -1 : 1)
                }
                context.translateBy(x: -rect.midX, y: -rect.midY)
            }
            draw(shape: shape, in: rect, document: document, context: context, size: size)
            draw(paragraphs: shape.paragraphs, in: rect, context: context, size: size,
                 anchor: shape.anchor, fontScale: shape.fontScale, shadow: shape.textShadow)
            context.restoreGState()
        }
        return context.makeImage()
    }

    /// Фігура: заливка своєю формою і обведення поверх неї.
    ///
    /// Форма важлива: кружечком у презентаціях обводять слово в рядку, і залитий
    /// прямокутник на його місці закриває собою те, заради чого його й малювали.
    private static func draw(shape: PPTXDocument.Shape, in rect: CGRect,
                             document: PPTXDocument, context: CGContext, size: CGSize) {
        let path: CGPath
        switch shape.outline {
        case .ellipse:
            path = CGPath(ellipseIn: rect, transform: nil)
        case .roundedRectangle:
            let radius = min(rect.width, rect.height) * 0.12
            path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .line:
            let line = CGMutablePath()
            line.move(to: CGPoint(x: rect.minX, y: rect.minY))
            line.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path = line
        case .rectangle:
            path = CGPath(rect: rect, transform: nil)
        }

        // Тінь під фігурою чи картинкою. Зсув — у базовому просторі полотна
        // (у CoreGraphics вісь Y іде вгору), тому «вниз» слайда — це мінус.
        context.saveGState()
        if let shadow = shape.shadow {
            context.setShadow(offset: CGSize(width: shadow.offset.width * size.height,
                                             height: -shadow.offset.height * size.height),
                              blur: shadow.blur * size.height, color: shadow.color)
        }
        if case .picture(let part) = shape.fill {
            draw(picture: part, crop: shape.crop, in: rect, document: document, context: context)
        } else if case .solid(let color) = shape.fill {
            context.saveGState()
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath()
            context.restoreGState()
        }
        context.restoreGState()

        if let stroke = shape.strokeColor, shape.strokeWidth > 0 {
            context.saveGState()
            context.addPath(path)
            context.setStrokeColor(stroke)
            context.setLineWidth(max(1, shape.strokeWidth * size.height))
            context.strokePath()
            context.restoreGState()
        }
    }

    // MARK: - Заливка

    private static func draw(fill: PPTXDocument.Fill, in rect: CGRect,
                             document: PPTXDocument, context: CGContext, size: CGSize) {
        switch fill {
        case .none:
            break
        case .solid(let color):
            context.setFillColor(color)
            context.fill(rect)
        case .picture(let part):
            draw(picture: part, crop: PPTXDocument.Crop(left: 0, top: 0, right: 0, bottom: 0),
                 in: rect, document: document, context: context)
        }
    }

    /// Картинка в рамку, з обрізкою, якщо її задано.
    ///
    /// Обрізка — не прикраса: нею в презентаціях беруть шматок фотографії, і
    /// без неї на слайд потрапляє вся картинка цілком, а потрібен був куток.
    private static func draw(picture part: String, crop: PPTXDocument.Crop,
                             in rect: CGRect, document: PPTXDocument, context: CGContext) {
        guard var image = document.image(part: part) else { return }
        if !crop.isEmpty {
            let width = Double(image.width), height = Double(image.height)
            let box = CGRect(x: width * crop.left, y: height * crop.top,
                             width: width * (1 - crop.left - crop.right),
                             height: height * (1 - crop.top - crop.bottom))
            if box.width > 1, box.height > 1, let cut = image.cropping(to: box) { image = cut }
        }
        // Розтягуємо в рамку, як PowerPoint: рамка — це те, що людина бачила,
        // коли ставила картинку, і саме такою вона хоче її на стіні.
        // Раніше картинка вписувалася цілком, і з боків лишалися білі поля з
        // чорною обвідкою — власник: «частини інформації немає, елементи
        // спотворені».
        let place = rect
        context.saveGState()
        // Кадр малюємо в неперевернутих координатах: `CGContext.draw` кладе
        // картинку знизу вгору, а ми перевернули полотно.
        context.translateBy(x: 0, y: place.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: place)
        context.restoreGState()
    }

    // MARK: - Текст

    private static func draw(paragraphs: [PPTXDocument.Paragraph], in rect: CGRect,
                             context: CGContext, size: CGSize,
                             anchor: String, fontScale: Double, shadow: PPTXDocument.Shadow? = nil) {
        guard !paragraphs.isEmpty else { return }
        let text = attributed(paragraphs, canvasHeight: size.height, scale: fontScale)
        guard text.length > 0 else { return }

        // Внутрішні поля напису в PowerPoint за умовчанням 0,1 і 0,05 дюйма;
        // у частках полотна це приблизно один відсоток — так текст не липне до
        // краю рамки, як і в самому PowerPoint.
        let padded = rect.insetBy(dx: size.width * 0.006, dy: size.height * 0.006)
        guard padded.width > 1, padded.height > 1 else { return }

        // Текст у рамку не вміщається — стискаємо, як це робить і слайд
        // Писання: обрізати проповідь на середині слова не можна. Починаємо з
        // того, у скільки стиснув його сам PowerPoint.
        var scale = fontScale
        var line = CTFramesetterCreateWithAttributedString(text)
        var needed = CTFramesetterSuggestFrameSizeWithConstraints(
            line, CFRange(location: 0, length: 0), nil,
            CGSize(width: padded.width, height: .greatestFiniteMagnitude), nil)
        var shrunk = text
        var guard_ = 0
        while needed.height > padded.height, scale > 0.3, guard_ < 12 {
            scale -= 0.08
            guard_ += 1
            shrunk = attributed(paragraphs, canvasHeight: size.height, scale: scale)
            line = CTFramesetterCreateWithAttributedString(shrunk)
            needed = CTFramesetterSuggestFrameSizeWithConstraints(
                line, CFRange(location: 0, length: 0), nil,
                CGSize(width: padded.width, height: .greatestFiniteMagnitude), nil)
        }

        // Куди притиснуто текст. У PowerPoint за умовчанням — верх; притискати все
        // до середини означало б рухати заголовки вниз на кожному слайді.
        let visible = min(needed.height, padded.height)
        let top: Double
        switch anchor {
        case "center": top = padded.midY - visible / 2
        case "bottom": top = padded.maxY - visible
        default:       top = padded.minY
        }
        let box = CGRect(x: padded.minX, y: top, width: padded.width, height: visible)

        context.saveGState()
        if let shadow {
            context.setShadow(offset: CGSize(width: shadow.offset.width * size.height,
                                             height: -shadow.offset.height * size.height),
                              blur: shadow.blur * size.height, color: shadow.color)
        }
        // Рядки CoreText ідуть знизу вгору — на перевернутому полотні це
        // означає ще один переворот, інакше абзаци стануть задом наперед.
        context.translateBy(x: 0, y: box.midY * 2)
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: box, transform: nil)
        let frame = CTFramesetterCreateFrame(line, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func attributed(_ paragraphs: [PPTXDocument.Paragraph],
                                   canvasHeight: Double,
                                   scale: Double = 1) -> NSAttributedString {
        // Кегль записано в пунктах для слайда його власного розміру. Полотно
        // буває будь-яким, тому переводимо через висоту: слайд PowerPoint —
        // це 7,5 дюйма, тобто 540 пунктів.
        let pointsPerCanvas = canvasHeight / 540
        let result = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            switch paragraph.alignment {
            case "center":  style.alignment = .center
            case "right":   style.alignment = .right
            case "justify": style.alignment = .justified
            default:        style.alignment = .left
            }
            style.lineBreakMode = .byWordWrapping
            style.firstLineHeadIndent = paragraph.indent * canvasHeight
            style.headIndent = style.firstLineHeadIndent
            // Табуляція в PowerPoint — дюйм (`defTabSz` 914400 EMU); CoreText за
            // умовчанням ставить її куди дрібніше, і адреса, яку автор відсунув
            // табуляціями до правого краю, у нас стояла посеред рядка.
            style.tabStops = []
            style.defaultTabInterval = 72 * pointsPerCanvas

            if let bullet = paragraph.bullet, !paragraph.runs.isEmpty {
                result.append(NSAttributedString(string: bullet + " ",
                                                 attributes: [.paragraphStyle: style]))
            }
            for run in paragraph.runs {
                let points = run.size * pointsPerCanvas * scale
                var traits: CTFontSymbolicTraits = []
                if run.isBold { traits.insert(.traitBold) }
                if run.isItalic { traits.insert(.traitItalic) }
                let font = font(named: run.fontName, size: max(4, points), traits: traits)
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: run.color,
                    .paragraphStyle: style,
                ]
                if run.isUnderlined { attributes[.underlineStyle] = 1 }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
        }
        return result
    }

    private static func font(named name: String?, size: Double, traits: CTFontSymbolicTraits) -> CTFont {
        // Шрифту презентації може не бути в системі — тоді беремо системний
        // того самого накреслення. Підставити «що-небудь» мовчки не можна: літери
        // розповзуться, і текст не влізе в рамку.
        let base: CTFont
        if let name, !name.isEmpty {
            base = CTFontCreateWithName(name as CFString, size, nil)
        } else {
            base = CTFontCreateUIFontForLanguage(.system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }
}
