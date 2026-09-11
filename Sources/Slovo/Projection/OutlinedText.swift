import AppKit
import SlovoCore

/// Надпись с контуром и автоподбором кегля, нарисованная за один проход.
///
/// Раньше контур собирался из восьми смещённых копий `Text`, и у каждой был
/// свой `minimumScaleFactor`. На слайде с двумя переводами и адресом это
/// давало под тридцать независимых раскладок текста — при каждой перерисовке,
/// в предпросмотре и в окне проекции одновременно. Отсюда и «стихи
/// переключаются с огромной задержкой».
///
/// Core Text умеет обводку сам: отрицательный `strokeWidth` означает
/// «залить и обвести». Получается один проход, настоящий контур вместо
/// восьми теней и заметно чище на краях букв.
enum OutlinedText {

    /// Стоимость подбора кегля без самой отрисовки — для замеров.
    static func measureCost(text: String, layer: SlideStyle.TextLayer,
                            height: CGFloat, width: CGFloat, lineSpacing: Double) -> CGFloat {
        let size = CGSize(width: width, height: height * 0.5)
        var low = max(6, height * layer.fontSize * 0.35)
        var high = height * layer.fontSize
        var best = low
        for _ in 0..<6 {
            let middle = (low + high) / 2
            let candidate = attributed(text, size: middle, layer: layer, slideHeight: height,
                                       lineSpacing: lineSpacing, alignment: .center)
            if fits(candidate, in: size) { best = middle; low = middle } else { high = middle }
        }
        return best
    }

    // MARK: - Отрисовка

    /// Не `private`: этим же кодом рисует надписи общий рисовальщик слайда.
    /// Разведи их — и текст на проекторе разойдётся с текстом в трансляции.
    static func draw(text: String, layer: SlideStyle.TextLayer, lineSpacing: Double,
                             alignment: NSTextAlignment, height: CGFloat,
                             minimumScale: Double,
                             verticalAlignment: SlideStyle.VerticalAlignment = .center,
                             shadow: ObjectShadow? = nil,
                             in size: CGSize, context cg: CGContext) {
        let requested = height * layer.fontSize
        let smallest = max(6, requested * minimumScale)

        func build(_ size: CGFloat) -> NSAttributedString {
            attributed(text, size: size, layer: layer, slideHeight: height,
                       lineSpacing: lineSpacing, alignment: alignment, shadow: shadow)
        }

        // Подбираем кегль делением пополам: перебор по одному пункту на
        // длинном стихе делал бы двадцать замеров вместо шести.
        var low = smallest
        var high = requested
        var best = smallest
        var bestString = build(smallest)

        if fits(bestString, in: size) {
            for _ in 0..<6 {
                let middle = (low + high) / 2
                let candidate = build(middle)
                if fits(candidate, in: size) {
                    best = middle
                    bestString = candidate
                    low = middle
                } else {
                    high = middle
                }
            }
        }
        _ = best

        let bounds = bestString.boundingRect(with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        let top: CGFloat
        switch verticalAlignment {
        case .top:    top = 0
        case .center: top = (size.height - bounds.height) / 2
        case .bottom: top = size.height - bounds.height
        }
        let target = CGRect(origin: CGPoint(x: 0, y: top),
                            size: CGSize(width: size.width, height: bounds.height))

        let graphics = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        bestString.draw(with: target, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Жирное и курсивное начертание — через дескриптор шрифта, а не через
    /// `NSFontManager`: тот живёт на главном потоке, а надпись теперь
    /// рисуется и в фоне. Нет такого начертания у семейства — остаётся
    /// обычное, как было и раньше.
    static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func fits(_ string: NSAttributedString, in size: CGSize) -> Bool {
        let bounds = string.boundingRect(with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        return bounds.height <= size.height
    }

    private static func attributed(_ text: String, size: CGFloat, layer: SlideStyle.TextLayer,
                                   slideHeight: CGFloat, lineSpacing: Double,
                                   alignment: NSTextAlignment,
                                   shadow objectShadow: ObjectShadow? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = size * lineSpacing
        paragraph.lineBreakMode = .byWordWrapping

        let font = styled(NSFont(name: layer.fontName, size: size) ?? NSFont.systemFont(ofSize: size),
                          bold: layer.isBold, italic: layer.isItalic)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor(rgba: layer.color),
        ]

        // Отрицательная ширина обводки — «обвести И залить». Положительная
        // залила бы только контур, и буквы стали бы пустыми внутри.
        //
        // Core Text задаёт её в процентах от кегля, а у нас толщина хранится
        // в долях высоты слайда — пересчитываем через реальные точки, иначе
        // на крупном тексте контур будет волосяным, а на мелком раздутым.
        let outlinePoints = layer.outlineWidth * slideHeight
        if outlinePoints > 0.2, size > 0 {
            attributes[.strokeColor] = NSColor(rgba: layer.outlineColor)
            attributes[.strokeWidth] = -(outlinePoints / size) * 100
        }
        // Тень объекта из конструктора перебивает общую из слоя текста:
        // у неё есть и смещение, и свой цвет, а в слое хранится только радиус.
        if let objectShadow, objectShadow.isVisible {
            let metrics = objectShadow.metrics(fontSize: size, objectHeight: size)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(rgba: objectShadow.color)
                .withAlphaComponent(objectShadow.opacity)
            shadow.shadowBlurRadius = metrics.blur
            shadow.shadowOffset = NSSize(width: metrics.offset.width,
                                         // Координаты тени в AppKit снизу
                                         // вверх, а рисуем мы в перевёрнутом
                                         // контексте: без минуса тень уехала
                                         // бы вверх, а не вниз.
                                         height: -metrics.offset.height)
            attributes[.shadow] = shadow
        } else if layer.shadowRadius > 0 {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = layer.shadowRadius * slideHeight
            shadow.shadowOffset = .zero
            attributes[.shadow] = shadow
        }
        return NSAttributedString(string: text, attributes: attributes)
    }
}

extension NSColor {
    convenience init(rgba: SlideStyle.RGBA) {
        self.init(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}
