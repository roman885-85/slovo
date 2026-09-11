import AppKit
import SlovoCore

/// Малювання слайда просто в картинку — без жодного виду.
///
/// Передпоказ (12) оновлюється на кожне натискання: стрілка, клацання по вірші,
/// куплет пісні. Колишнє вікно будувало заради цього дерево видів SwiftUI —
/// `GeometryReader`, `ZStack`, `VStack`, три `Canvas` і два переходи, — і
/// перезбирало його разом з усім вікном. Тут роботи рівно стільки: два
/// проходи Core Text і підстановка готової картинки в шар. Ні розкладки, ні
/// звіряння колекцій, ні перезбирання сусідів.
///
/// Текст і підкладка малюються ОКРЕМО навмисно. Розчиняється лише напис, а
/// картинка під ним стоїть непрозорою: поки фон їхав у перехід разом із
/// текстом, на середині зміни опинялися два напівпрозорі шари і яскравість
/// провалювалася — власник бачив це як ривок.
///
/// Розкладка повторює `SlideView`, аж до дрібниць: передпоказ зобов'язаний
/// показувати те саме, що піде в зал, інакше він не передпоказ.
@MainActor
enum NativeSlideRender {

    /// Що вважати зміною тексту. За цим відбитком грається розчинення —
    /// зміна шрифту або кегля переходом не вважається, інакше повзунок налаштувань
    /// перетворювався б на блимання.
    static func textIdentity(slide: Slide) -> Int {
        var hasher = Hasher()
        hasher.combine(slide.isBlank)
        hasher.combine(slide.mainText)
        hasher.combine(slide.secondaryTexts)
        hasher.combine(slide.reference)
        return hasher.finalize()
    }

    /// Що вважати приводом перемалювати напис: до тексту додаються
    /// оформлення і розмір.
    static func drawIdentity(slide: Slide, style: SlideStyle, size: CGSize) -> Int {
        var hasher = Hasher()
        hasher.combine(textIdentity(slide: slide))
        hasher.combine(style.main)
        hasher.combine(style.secondary)
        hasher.combine(style.reference)
        hasher.combine(style.verticalAlignment)
        hasher.combine(style.horizontalInset)
        hasher.combine(style.verticalInset)
        hasher.combine(style.lineSpacing)
        hasher.combine(Int(size.width.rounded()))
        hasher.combine(Int(size.height.rounded()))
        return hasher.finalize()
    }

    /// Відбиток підкладки: колір, картинка, затемнення і розмір.
    static func backdropIdentity(style: SlideStyle, size: CGSize) -> Int {
        var hasher = Hasher()
        hasher.combine(style.backgroundColor)
        hasher.combine(style.backgroundImagePath ?? "")
        hasher.combine(style.dimBackground)
        hasher.combine(Int(size.width.rounded()))
        hasher.combine(Int(size.height.rounded()))
        return hasher.finalize()
    }

    /// Наскільки розмити тінь напису. Віддається назовні, бо тінь
    /// кладе шар, а не растр: розмиття навколо кожної літери на кожне
    /// натискання — третина всієї роботи, а на око воно рівно те саме.
    ///
    /// Радіус береться найбільший із показаних шматків: у шару тінь одна.
    static func shadowRadius(slide: Slide, style: SlideStyle, size: CGSize) -> CGFloat {
        guard !slide.isBlank else { return 0 }
        var radius: Double = 0
        if !slide.mainText.isEmpty { radius = max(radius, style.main.shadowRadius) }
        if !slide.secondaryTexts.isEmpty { radius = max(radius, style.secondary.shadowRadius) }
        if !slide.reference.isEmpty { radius = max(radius, style.reference.shadowRadius) }
        return CGFloat(radius) * size.height
    }

    // MARK: - Підкладка

    /// Колір, картинка «на всю широчінь» і плівка затемнення поверх неї.
    static func backdrop(style: SlideStyle, size: CGSize) -> CGImage? {
        image(size: size, opaque: true) { cg in
            cg.setFillColor(NSColor(rgba: style.backgroundColor).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))

            guard let path = style.backgroundImagePath,
                  let picture = ImageCache.image(atPath: path),
                  let bitmap = cgImage(of: picture) else { return }

            // «На всю широчінь» — той самий `aspectRatio(contentMode: .fill)`:
            // картинка накриває слайд цілком, зайве йде за край.
            let source = CGSize(width: bitmap.width, height: bitmap.height)
            guard source.width > 0, source.height > 0 else { return }
            let scale = max(size.width / source.width, size.height / source.height)
            let drawn = CGSize(width: source.width * scale, height: source.height * scale)
            cg.draw(bitmap, in: CGRect(x: (size.width - drawn.width) / 2,
                                       y: (size.height - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))

            guard style.dimBackground > 0 else { return }
            cg.setFillColor(NSColor.black.withAlphaComponent(style.dimBackground).cgColor)
            cg.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Напис

    /// Текст слайда на прозорому фоні: головний, другі переклади й адреса.
    static func text(slide: Slide, style: SlideStyle, size: CGSize) -> CGImage? {
        guard !slide.isBlank else { return nil }
        let blocks = blocks(slide: slide, style: style, size: size)
        guard !blocks.isEmpty else { return nil }

        return image(size: size, opaque: false) { cg in
            // Растрове полотно рахує вгору, а розкладка тексту — вниз.
            // Перевертаємо осі до того, як заводити графічний контекст:
            // інакше `flipped: true` збреше, і напис стане догори ногами.
            cg.saveGState()
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            let graphics = NSGraphicsContext(cgContext: cg, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            for block in blocks {
                draw(text: block.text, layer: block.layer, style: style,
                     in: block.rect, slideHeight: size.height)
            }
            NSGraphicsContext.restoreGraphicsState()
            cg.restoreGState()
        }
    }

    /// Куди ліг кожен шматок тексту. Винесено окремо, бо цим же
    /// рахує самоперевірка — звіряти розкладку за картинкою нічим.
    struct Block {
        let text: String
        let layer: SlideStyle.TextLayer
        let rect: CGRect
    }

    static func blocks(slide: Slide, style: SlideStyle, size: CGSize) -> [Block] {
        guard !slide.isBlank, size.width > 1, size.height > 1 else { return [] }

        var pieces: [(String, SlideStyle.TextLayer, CGFloat)] = []
        if !slide.mainText.isEmpty { pieces.append((slide.mainText, style.main, 0)) }
        for text in slide.secondaryTexts {
            pieces.append((text, style.secondary, 0))
        }
        if !slide.reference.isEmpty {
            // Адреса відбита зверху на 2 % висоти — так само, як у `SlideView`.
            pieces.append((slide.reference, style.reference, size.height * 0.02))
        }
        guard !pieces.isEmpty else { return [] }

        let spacing = size.height * style.lineSpacing * 0.35
        let contentWidth = max(1, size.width * (1 - style.horizontalInset * 2))
        var heights = pieces.map { size.height * $0.1.fontSize * 3.4 }
        var total = heights.reduce(0, +) + spacing * CGFloat(pieces.count - 1)
        total += pieces.reduce(0) { $0 + $1.2 }

        // Якщо шматків більше, ніж влазить, стискаємо їх порівну: в автора
        // слайд із двома перекладами й адресою теж не виходить за краї.
        let available = max(1, size.height * (1 - style.verticalInset * 2))
        if total > available {
            let shrink = available / total
            heights = heights.map { $0 * shrink }
            total = available
        }

        // Поля в частках — це обмеження розміру, а не відступ: у `SlideView`
        // блок тексту притискається виключкою до краю всього слайда. Повторюємо
        // це, а не «як правильніше»: передпоказ зобов'язаний збігтися із залом.
        var y: CGFloat
        switch style.verticalAlignment {
        case .top:    y = 0
        case .center: y = (size.height - total) / 2
        case .bottom: y = size.height - total
        }

        let x = (size.width - contentWidth) / 2
        var result: [Block] = []
        result.reserveCapacity(pieces.count)
        for (index, piece) in pieces.enumerated() {
            y += piece.2
            result.append(Block(text: piece.0, layer: piece.1,
                                rect: CGRect(x: x, y: y, width: contentWidth, height: heights[index])))
            y += heights[index] + spacing
        }
        return result
    }

    // MARK: - Один шматок тексту

    /// Напис із контуром і добором кегля.
    ///
    /// Контур малює Core Text за один прохід — від'ємною товщиною, як у
    /// `OutlinedText`. А от кегль добирається інакше, і це головна різниця за
    /// швидкістю. В автора і в колишньому вікні на кожен напис ішло сім
    /// повних розкладок тексту; замір показав по дві мілісекунди на кожну,
    /// тобто більше за кадр на один вірш. Тут замірів три-чотири, а самі вони
    /// не перераховують літери заново — приміряються шириною рамки
    /// (див. `NativeSlideTextBox`).
    ///
    /// Короткий напис — адреса, куплет у два рядки — обходиться зовсім одним
    /// заміром: якщо весь кегль улазить, добирати нічого.
    private static func draw(text: String, layer: SlideStyle.TextLayer, style: SlideStyle,
                             in rect: CGRect, slideHeight: CGFloat) {
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let box = NativeSlideTextBox.shared
        box.begin(text: text, layer: layer, slideHeight: slideHeight,
                  lineSpacing: style.lineSpacing, width: rect.width)

        let requested = slideHeight * layer.fontSize
        let smallest = max(6, requested * 0.35)
        var best = requested
        var bestHeight = box.height(at: requested)

        // Короткий напис — адреса, куплет у два рядки — улазить у весь
        // кегль одразу, і добирати нічого. Так буває найчастіше, і це
        // єдиний замір на весь напис.
        if bestHeight > rect.height {
            // Висота набраного тексту росте приблизно як квадрат кегля:
            // і рядків стає більше, і кожен вищий. Звідси перша
            // здогадка — вона зазвичай влучає з точністю до відсотка, і
            // половинок після неї потрібно не шість, а дві.
            let guess = min(requested, max(smallest, requested * sqrt(rect.height / bestHeight)))
            var low = smallest
            var high = requested
            best = smallest
            bestHeight = -1

            let guessed = box.height(at: guess)
            if guessed <= rect.height {
                best = guess
                bestHeight = guessed
                low = guess
            } else {
                high = guess
            }
            for _ in 0..<2 {
                let middle = (low + high) / 2
                let height = box.height(at: middle)
                if height <= rect.height {
                    best = middle
                    bestHeight = height
                    low = middle
                } else {
                    high = middle
                }
            }
            // Не влізло навіть у найдрібніший кегль — малюємо ним, але висоту
            // все одно треба знати, щоб поставити напис посередині.
            if bestHeight < 0 { bestHeight = box.height(at: smallest) }
        }

        box.draw(at: CGPoint(x: rect.minX, y: rect.minY + (rect.height - bestHeight) / 2),
                 size: best)
    }

    // MARK: - Дрібниці

    /// Готовий растр потрібного розміру. Масштаб — точка в точку: передпоказ
    /// менший за долоню, і вдвічі більший растр на Retina коштував би вчетверо
    /// дорожче заради різниці, якої на ньому не видно.
    private static func image(size: CGSize, opaque: Bool,
                              _ body: (CGContext) -> Void) -> CGImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let info = opaque
            ? CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info) else { return nil }
        body(context)
        return context.makeImage()
    }

    private static func cgImage(of picture: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: picture.size)
        return picture.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

/// Один текстовий набір на всю програму: ним і міряють, і малюють.
///
/// `NSAttributedString.boundingRect` і `draw(with:)` виглядають безневинно, але
/// кожен виклик заводить своє сховище, розкладач і рамку тексту, а головне —
/// заново перетворює літери на накреслення. Добір кегля робить кілька замірів
/// на напис, написів на слайді до трьох, і все це на кожне натискання.
///
/// Тут набір один. Текст у нього кладуть ОДИН раз і одним кеглем, а кеглі
/// кандидатів приміряють не шрифтом, а шириною рамки. Так можна: набір у кеглі
/// S по ширині W ламається на рядки рівно так само, як набір у кеглі S₀ по
/// ширині W·S₀/S, — уся різниця в множнику S/S₀. Накреслення при зміні ширини
/// не перераховуються, а це й була найдорожча частина.
///
/// Малюється напис уже справжнім кеглем і справжньою шириною — один
/// чесний прохід у самому кінці.
///
/// Спокуса довести прийом до кінця і МАЛЮВАТИ теж пробним набором, розтягнувши
/// полотно в S/S₀ разів, перевірено і відкинуто за заміром: зміна кегля в наборі
/// коштує 1.16 мс, а розтягнуте полотно відбирає більше, ніж ця зміна, — у
/// Core Graphics під довільним множником не годиться запас готових
/// накреслень, і кожна літера малюється заново. У справжньому вікні вийшло 5.99 мс
/// проти 5.20 на зміну вірша і 11.2 проти 9.3 на слайд із двома перекладами й
/// адресою. Картинка при цьому майже та сама (розходиться 0.55 % точок по краях
/// літер), тож переробка була б чистим програшем.
@MainActor
final class NativeSlideTextBox {

    static let shared = NativeSlideTextBox()

    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)

    private var range = NSRange(location: 0, length: 0)
    private var base: NSFont = .systemFont(ofSize: 12)
    private var lineSpacing: Double = 0
    /// Товщина обведення в точках. Core Text чекає її часткою кегля, тому
    /// перераховується на кожен кегль заново.
    private var outlinePoints: CGFloat = 0
    /// Кегль, яким текст лежить у наборі, і справжня ширина рамки.
    private var probeSize: CGFloat = 12
    private var realWidth: CGFloat = 1
    private var appliedSize: CGFloat = 0
    private var appliedWidth: CGFloat = 0

    /// Знайдені накреслення. Пошук шрифту за іменем і перетворення його на жирний
    /// або курсивний — робота для одного разу, а не для кожного заміру.
    private static var fonts: [String: NSFont] = [:]

    private init() {
        // Нуль замість звичайних п'яти точок: `boundingRect` рахує без поля, і
        // без цього дібраний кегль розходився б із показаним.
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    /// Покласти в набір новий напис. Кегль тут пробний — той, яким
    /// надпись просили нарисовать; кандидаты примеряются шириной.
    func begin(text: String, layer: SlideStyle.TextLayer, slideHeight: CGFloat,
               lineSpacing: Double, width: CGFloat) {
        base = Self.font(name: layer.fontName, bold: layer.isBold, italic: layer.isItalic)
        self.lineSpacing = lineSpacing
        outlinePoints = layer.outlineWidth * slideHeight
        probeSize = max(1, slideHeight * layer.fontSize)
        realWidth = max(1, width)

        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(rgba: layer.color),
        ]
        // Отрицательная ширина обводки — «обвести И залить». Положительная
        // залила бы только контур, и буквы стали бы пустыми внутри.
        if outlinePoints > 0.2 {
            attributes[.strokeColor] = NSColor(rgba: layer.outlineColor)
        }
        // Тень в растр не рисуется намеренно: размывать её вокруг каждой буквы
        // стоит трети всей отрисовки. На предпросмотре её кладёт Core Animation
        // одним махом на всю надпись — см. `NativeSlideRender.shadowRadius`.

        storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        range = NSRange(location: 0, length: storage.length)
        appliedSize = 0
        appliedWidth = 0
        apply(size: probeSize, width: realWidth)
    }

    /// Высота надписи при этом кегле — примерка шириной, без пересчёта букв.
    func height(at size: CGFloat) -> CGFloat {
        guard size > 0, range.length > 0 else { return 0 }
        apply(size: probeSize, width: realWidth * probeSize / size)
        return ceil(layout.usedRect(for: container).height * size / probeSize)
    }

    /// Нарисовать в текущем графическом контексте, левым верхним углом в точку.
    /// Здесь кегль уже настоящий: примерка кончилась.
    func draw(at origin: CGPoint, size: CGFloat) {
        guard range.length > 0 else { return }
        apply(size: size, width: realWidth)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: origin)
    }

    private func apply(size: CGFloat, width: CGFloat) {
        let width = max(1, width)
        if size != appliedSize {
            appliedSize = size
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineSpacing = size * lineSpacing
            paragraph.lineBreakMode = .byWordWrapping

            storage.beginEditing()
            storage.addAttribute(.font, value: Self.sized(base, size), range: range)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            if outlinePoints > 0.2, size > 0 {
                storage.addAttribute(.strokeWidth, value: -(outlinePoints / size) * 100, range: range)
            }
            storage.endEditing()
        }
        if width != appliedWidth {
            appliedWidth = width
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
    }

    /// Тот же шрифт другого кегля. Копия описания вместо поиска по имени:
    /// поиск стоил около миллисекунды, а замеров на слайд — несколько.
    private static func sized(_ font: NSFont, _ size: CGFloat) -> NSFont {
        CTFontCreateCopyWithAttributes(font, size, nil, nil)
    }

    /// Шрифт нужного начертания. Кегль потом меняется копией описания.
    static func font(name: String, bold: Bool, italic: Bool) -> NSFont {
        let key = "\(name)#\(bold)#\(italic)"
        if let ready = fonts[key] { return ready }
        var font = NSFont(name: name, size: 100) ?? NSFont.systemFont(ofSize: 100)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
        fonts[key] = font
        return font
    }
}
