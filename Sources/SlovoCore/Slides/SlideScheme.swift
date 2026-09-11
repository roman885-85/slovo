import Foundation

/// Шаблон оформлення слайда — «розмітка» оригіналу з теки `Templates`.
///
/// У файлі `<Ім'я>.sch` лежить XML: корінь `VisioBibleScheme`, усередині один
/// `Scheme` зі спільними для слайда обведенням і тінню Цитати, а далі список
/// `Object` — рамки тексту і картинки прикрас. Шрифтів у шаблоні немає:
/// оригінал бере їх із `VisioBible.ini`, а `.sch` задає лише кольори,
/// геометрію рамок і анімацію. Тому шаблон не заміняє `SlideStyle`,
/// а накладається поверх нього — див. `slideStyle(base:designHeight:)`.
///
/// Числа Delphi пише з комою (`2,84999990463257`), кольори — `TColor`
/// виду `0x00BBGGRR`, відсотки — від розміру слайда. Усе це приведено
/// до нормальних величин уже тут, щоб далі по коду не пам'ятати про
/// ці особливості.
public struct SlideScheme: Sendable, Hashable, Codable {

    /// Що за елемент лежить на слайді — номери з атрибута `Type`.
    ///
    /// Усі чотирнадцять видів, які вміє класти на слайд конструктор
    /// оригіналу. У 22 авторських шаблонах трапляються лише 0, 1, 2, 3, 5, 6,
    /// 7 і 13, але шаблон можна принести й чужий (4.2.3), а незнайомий номер
    /// раніше перетворювався на порожній напис.
    ///
    /// Номери відновлено за самою програмою: у `TSlideConstructorForm`
    /// пункти меню «Додати об'єкт» оголошено партіями — спершу
    /// `NAddQuote, NAddRef, NAddPrevPage, NAddNextPage, NAddStaticText,
    /// NAddImage` (0…5, з них 0, 1, 2, 3 і 5 підтверджено шаблонами),
    /// потім `NAddQuoteSecond, NAddRefSecond, NAddRefFirst` (6, 7, 8 — перші
    /// два підтверджено), потім чотири імені модуля (9…12) і останнім
    /// `NAddSongName`, чий номер 13 підтверджено шаблоном `SongDefault`.
    public enum ElementKind: Int, Sendable, Hashable, Codable, CaseIterable {
        case quote = 0                  // Цитата — основний текст
        case reference = 1              // об'єднана адреса
        case previousPage = 2           // стрілка «попередня сторінка»
        case nextPage = 3               // стрілка «наступна сторінка»
        case staticText = 4             // довільний напис
        case decoration = 5             // картинка: лінії, панелі, ноти, книга
        case secondQuote = 6            // другий переклад
        case secondReference = 7        // адреса другого перекладу
        case firstReference = 8         // адреса основного перекладу
        case moduleShortNameFirst = 9   // ім'я модуля 1 коротке
        case moduleShortNameSecond = 10 // ім'я модуля 2 коротке
        case moduleNameFirst = 11       // ім'я модуля 1 повне
        case moduleNameSecond = 12      // ім'я модуля 2 повне
        case songTitle = 13             // назва пісні

        public var title: String {
            switch self {
            case .quote:                 return OurWords.t("Цитата")
            case .reference:             return OurWords.t("Ссылка")
            case .previousPage:          return OurWords.t("Пред. страница")
            case .nextPage:              return OurWords.t("След. страница")
            case .staticText:            return OurWords.t("Статический текст")
            case .decoration:            return OurWords.t("Картинка")
            case .secondQuote:           return OurWords.t("Второй перевод")
            case .secondReference:       return OurWords.t("Ссылка второго перевода")
            case .firstReference:        return OurWords.t("Адрес основного перевода")
            case .moduleShortNameFirst:  return OurWords.t("Имя Модуля 1 короткое")
            case .moduleShortNameSecond: return OurWords.t("Имя Модуля 2 короткое")
            case .moduleNameFirst:       return OurWords.t("Имя Модуля 1 полное")
            case .moduleNameSecond:      return OurWords.t("Имя Модуля 2 полное")
            case .songTitle:             return OurWords.t("Название песни")
            }
        }
    }

    /// Слайд малюється у двох варіантах: один переклад і два.
    ///
    /// У файлі це пари атрибутів `Width` / `Width_2`, а в теці `thumbs` —
    /// `scene1.jpg` і `scene2.jpg`. Рамки у варіантах різні: при двох
    /// перекладах Цитата займає верхню половину слайда, а не весь.
    public enum Variant: Int, Sendable, Hashable, Codable, CaseIterable, Identifiable {
        case single = 0
        case dual = 1

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .single: return OurWords.t("Один перевод")
            case .dual:   return OurWords.t("Два перевода")
            }
        }
    }

    /// Виключка рядка всередині рамки — Delphi `TAlignment`.
    public enum TextAlignment: Int, Sendable, Hashable, Codable, CaseIterable {
        case left = 0, right = 1, center = 2
    }

    /// Як текст лежить у рамці по вертикалі — Delphi `TTextLayout`.
    public enum TextLayout: Int, Sendable, Hashable, Codable, CaseIterable {
        case top = 0, center = 1, bottom = 2
    }

    /// Від якого кута слайда відміряно відступи `IndentionX` / `IndentionY`.
    ///
    /// У файлі це одне число `Align`. Значення трапляються лише 0, 1, 2,
    /// 4, 5 і 6, і розкладаються на два поля: молодші два біти — горизонталь
    /// (0 — зліва, 1 — справа, 2 — по центру), наступний біт — вертикаль
    /// (0 — зверху, 1 — знизу). Звірено з мініатюрами: у `Default` книга
    /// (`Align="4"`) стоїть унизу зліва, посилання (`Align="5"`) — унизу справа,
    /// лінії (`Align="2"`) ідуть по центру і відміряні зверху, а в `SongDefault`
    /// посилання (`Align="1"`) висить угорі справа.
    public struct Anchor: Sendable, Hashable, Codable {

        public enum Horizontal: Int, Sendable, Hashable, Codable { case left = 0, right = 1, center = 2 }
        public enum Vertical: Int, Sendable, Hashable, Codable { case top = 0, bottom = 1 }

        public var horizontal: Horizontal
        public var vertical: Vertical
        /// Вихідне число — на випадок значень, яких ми ще не бачили.
        public var rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
            self.horizontal = Horizontal(rawValue: max(0, rawValue) & 0b11) ?? .center
            self.vertical = (max(0, rawValue) & 0b100) == 0 ? .top : .bottom
        }

        public init(horizontal: Horizontal, vertical: Vertical) {
            self.horizontal = horizontal
            self.vertical = vertical
            self.rawValue = horizontal.rawValue | (vertical.rawValue << 2)
        }
    }

    /// Прямокутник у частках слайда — 0…1 від лівого верхнього кута.
    public struct Box: Sendable, Hashable, Codable {
        public var x: Double, y: Double, width: Double, height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
        public var midX: Double { x + width / 2 }
        public var midY: Double { y + height / 2 }
    }

    /// Положення елемента в одному з двох варіантів слайда.
    ///
    /// Розміри і відступи оригінал тримає у відсотках від слайда, прозорість
    /// і тінь — у байтах 0…255 і у відсотках; тут уже частки і відсотки
    /// приведено до того вигляду, в якому ними зручно користуватися.
    public struct Placement: Sendable, Hashable, Codable {
        public var width: Double          // відсотки ширини слайда
        public var height: Double         // відсотки висоти слайда
        public var indentX: Double        // відсотки, відміряються від якоря
        public var indentY: Double
        public var anchor: Anchor
        public var opacity: Double        // 0…1
        public var isEnabled: Bool
        public var shadowOffset: Double   // відсотки (у тексту — від кегля)
        public var shadowBlur: Double
        public var shadowOpacity: Double  // 0…1
        public var shadowColor: SlideStyle.RGBA
        public var textAlignment: TextAlignment?  // лише в текстових елементів
        public var textLayout: TextLayout?

        public init(width: Double = 100,
                    height: Double = 100,
                    indentX: Double = 0,
                    indentY: Double = 0,
                    anchor: Anchor = Anchor(horizontal: .center, vertical: .top),
                    opacity: Double = 1,
                    isEnabled: Bool = true,
                    shadowOffset: Double = 0,
                    shadowBlur: Double = 0,
                    shadowOpacity: Double = 0,
                    shadowColor: SlideStyle.RGBA = .black,
                    textAlignment: TextAlignment? = nil,
                    textLayout: TextLayout? = nil) {
            self.width = width
            self.height = height
            self.indentX = indentX
            self.indentY = indentY
            self.anchor = anchor
            self.opacity = opacity
            self.isEnabled = isEnabled
            self.shadowOffset = shadowOffset
            self.shadowBlur = shadowBlur
            self.shadowOpacity = shadowOpacity
            self.shadowColor = shadowColor
            self.textAlignment = textAlignment
            self.textLayout = textLayout
        }

        /// Рамка в частках слайда.
        ///
        /// Відступ рахується зсувом від якоря, а не абсолютною координатою:
        /// у `Default` у Цитати `Align="2"` (по центру), ширина 94 % і
        /// `IndentionX="0"` — тобто поля по 3 % з кожного боку, а не
        /// притиснута до лівого краю рамка.
        public var box: Box {
            let w = width / 100, h = height / 100
            let dx = indentX / 100, dy = indentY / 100
            let x: Double
            switch anchor.horizontal {
            case .left:   x = dx
            case .right:  x = 1 - w - dx
            case .center: x = (1 - w) / 2 + dx
            }
            let y = anchor.vertical == .top ? dy : 1 - h - dy
            return Box(x: x, y: y, width: w, height: h)
        }
    }

    /// Поява елемента: один кадр анімації на кожен варіант слайда.
    ///
    /// `fx` — номер ефекту оригіналу, їх там три десятки на всі види
    /// «шторок». Розшифровки в нас немає, тому характер руху беремо не
    /// з номера, а з його параметрів: масштаб, зсув або просто проявлення.
    public struct Scene: Sendable, Hashable, Codable {
        public var fx: Int
        public var isAnimated: Bool
        public var fromOpacity: Double   // 0…1
        public var fromScale: Double     // 0…1, нуль — без зміни розміру
        public var moveFromX: Double     // відсотки слайда
        public var moveFromY: Double
        public var delay: Double         // секунди
        public var duration: Double      // секунди

        public init(fx: Int = 0,
                    isAnimated: Bool = false,
                    fromOpacity: Double = 1,
                    fromScale: Double = 0,
                    moveFromX: Double = 0,
                    moveFromY: Double = 0,
                    delay: Double = 0,
                    duration: Double = 0) {
            self.fx = fx
            self.isAnimated = isAnimated
            self.fromOpacity = fromOpacity
            self.fromScale = fromScale
            self.moveFromX = moveFromX
            self.moveFromY = moveFromY
            self.delay = delay
            self.duration = duration
        }

        public var movesHorizontally: Bool { abs(moveFromX) >= abs(moveFromY) }
        public var isMoving: Bool { abs(moveFromX) > 0.001 || abs(moveFromY) > 0.001 }
        public var isScaling: Bool { fromScale > 0.001 }
    }

    /// Набір анімацій елемента під один іменований пресет (`Fx1`, `Fx2`…).
    public struct FXPreset: Sendable, Hashable, Codable {
        public var name: String
        public var hasVariantParameters: Bool
        public var scenes: [Scene]

        public init(name: String = "", hasVariantParameters: Bool = false, scenes: [Scene] = []) {
            self.name = name
            self.hasVariantParameters = hasVariantParameters
            self.scenes = scenes
        }

        public func scene(_ variant: Variant) -> Scene? {
            if scenes.indices.contains(variant.rawValue) { return scenes[variant.rawValue] }
            return scenes.first
        }
    }

    /// Один `Object` шаблону.
    public struct Element: Sendable, Hashable, Codable {
        public var name: String
        public var rawType: Int
        public var kind: ElementKind?
        public var imageName: String?      // файл у теці шаблону
        public var imageMaskName: String?  // чорно-біла маска прозорості
        public var textColor: SlideStyle.RGBA?
        /// `EnableParamsVariant` — другий варіант налаштовано окремо, а не скопійовано.
        public var hasVariantParameters: Bool
        public var placements: [Placement]
        public var presets: [FXPreset]
        /// Усі атрибути як є — щоб незнайоме поле не пропадало.
        public var attributes: [String: String]

        public init(name: String,
                    rawType: Int,
                    imageName: String? = nil,
                    imageMaskName: String? = nil,
                    textColor: SlideStyle.RGBA? = nil,
                    hasVariantParameters: Bool = false,
                    placements: [Placement] = [],
                    presets: [FXPreset] = [],
                    attributes: [String: String] = [:]) {
            self.name = name
            self.rawType = rawType
            self.kind = ElementKind(rawValue: rawType)
            self.imageName = imageName
            self.imageMaskName = imageMaskName
            self.textColor = textColor
            self.hasVariantParameters = hasVariantParameters
            self.placements = placements
            self.presets = presets
            self.attributes = attributes
        }

        /// Положення у вибраному варіанті; якщо другого немає — береться перший.
        public func placement(_ variant: Variant = .single) -> Placement {
            if placements.indices.contains(variant.rawValue) { return placements[variant.rawValue] }
            return placements.first ?? Placement()
        }

        public func scene(_ variant: Variant = .single, preset: String? = nil) -> Scene? {
            let chosen = preset.flatMap { name in presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            return (chosen ?? presets.first)?.scene(variant)
        }
    }

    public var name: String
    /// Ім'я файлу фону всередині однойменної теки шаблону.
    public var backgroundImageName: String
    public var outlineEnabled: Bool
    public var outlineWidth: Double            // пікселі слайда, під який малювали
    public var outlineColor: SlideStyle.RGBA
    public var shadowEnabled: Bool
    public var shadowOffset: Double            // пікселі
    public var shadowBlur: Double              // пікселі
    public var shadowOpacity: Double           // 0…1
    public var shadowColor: SlideStyle.RGBA
    /// Імена пресетів анімації, оголошені у `FXPresetsList`.
    public var presetNames: [String]
    public var elements: [Element]
    public var attributes: [String: String]

    public init(name: String,
                backgroundImageName: String = "",
                outlineEnabled: Bool = false,
                outlineWidth: Double = 0,
                outlineColor: SlideStyle.RGBA = .black,
                shadowEnabled: Bool = false,
                shadowOffset: Double = 0,
                shadowBlur: Double = 0,
                shadowOpacity: Double = 0,
                shadowColor: SlideStyle.RGBA = .black,
                presetNames: [String] = [],
                elements: [Element] = [],
                attributes: [String: String] = [:]) {
        self.name = name
        self.backgroundImageName = backgroundImageName
        self.outlineEnabled = outlineEnabled
        self.outlineWidth = outlineWidth
        self.outlineColor = outlineColor
        self.shadowEnabled = shadowEnabled
        self.shadowOffset = shadowOffset
        self.shadowBlur = shadowBlur
        self.shadowOpacity = shadowOpacity
        self.shadowColor = shadowColor
        self.presetNames = presetNames
        self.elements = elements
        self.attributes = attributes
    }

    // MARK: - Пошук елементів

    public func element(_ kind: ElementKind) -> Element? {
        elements.first { $0.kind == kind }
    }

    public var quote: Element? { element(.quote) }
    public var secondQuote: Element? { element(.secondQuote) }
    public var reference: Element? { element(.reference) }
    public var songTitle: Element? { element(.songTitle) }
    public var decorations: [Element] { elements.filter { $0.kind == .decoration } }

    // MARK: - Переведення в стиль слайда

    /// Накладає шаблон на готовий стиль.
    ///
    /// Шрифти, кегль та інтерліньяж шаблон не задає — вони лишаються від `base`
    /// (зазвичай це стиль, зібраний із `VisioBible.ini`). Міняються кольори,
    /// обведення, тінь, поля, виключка і характер зміни слайда.
    ///
    /// Товщину обведення і розмиття тіні записано в пікселях того слайда, під
    /// який їх добирали: його висота лежить у `[OutScreen] height`. Ділимо
    /// на неї рівно так само, як `SlideStyle.init(config:section:dataRoot:)`,
    /// інакше один і той самий шаблон розійдеться з налаштуваннями з ini.
    public func slideStyle(base: SlideStyle = SlideStyle(),
                           designHeight: Double = 600,
                           variant: Variant = .single,
                           backgroundPath: String? = nil) -> SlideStyle {
        var style = base
        style.name = name

        let height = max(designHeight, 1)
        let outline = outlineEnabled ? outlineWidth / height : 0
        let shadow = shadowEnabled ? shadowBlur / height : 0

        let mainColor = quote?.textColor ?? base.main.color
        style.main.color = mainColor
        style.main.outlineColor = outlineColor
        style.main.outlineWidth = outline
        style.main.shadowRadius = shadow

        // Свого кольору в другого перекладу в шаблонах немає жодного — оригінал
        // малює його тим самим кольором, що й Цитату.
        style.secondary.color = secondQuote?.textColor ?? mainColor
        style.secondary.outlineColor = outlineColor
        style.secondary.outlineWidth = outline
        style.secondary.shadowRadius = shadow

        style.reference.color = reference?.textColor ?? base.reference.color
        style.reference.outlineColor = outlineColor
        style.reference.outlineWidth = outline
        style.reference.shadowRadius = shadow

        if let backgroundPath { style.backgroundImagePath = backgroundPath }

        if let placement = quote?.placement(variant) {
            let box = placement.box
            // Поля беремо по ближній стороні: рамка буває зміщена, а в нас
            // відступ один на обидві сторони — хай текст краще не вилізе.
            style.horizontalInset = min(max(min(box.x, 1 - box.maxX), 0), 0.45)
            style.verticalInset = min(max(min(box.y, 1 - box.maxY), 0), 0.45)
            style.verticalAlignment = Self.verticalAlignment(of: placement)
        }

        if let scene = quote?.scene(variant) {
            style.transition = Self.transition(for: scene)
            // Поріг той самий, що й у стилю з ini: у Delphi зміна йшла покадрово,
            // і 200 мс давали там кілька кадрів, а тут читаються ривком.
            if style.transition != .none { style.transitionDuration = max(0.25, scene.duration) }
        }

        return style
    }

    /// Куди притиснуто текст Цитати.
    ///
    /// Оригінал вирішує це двічі: положенням рамки і `Layout` усередині неї.
    /// Рамка майже завжди на весь слайд, тому у високої рамки слухаємо
    /// `Layout`, а у помітно зміщеної — її власну середину.
    static func verticalAlignment(of placement: Placement) -> SlideStyle.VerticalAlignment {
        let box = placement.box
        if box.height >= 0.8, let layout = placement.textLayout {
            switch layout {
            case .top:    return .top
            case .center: return .center
            case .bottom: return .bottom
            }
        }
        if abs(box.midY - 0.5) <= 0.08 { return .center }
        return box.midY < 0.5 ? .top : .bottom
    }

    /// Як шаблон уводить текст на слайд.
    ///
    /// Номери ефектів оригіналу не розшифровано, тому дивимося на
    /// параметри кадру: масштаб — наплив, зсув — зсув, решта —
    /// розчинення. У даних користувача це дає `zoom` у сезонних
    /// шаблонів (`FromScale="80"`), `slideLeft` у лінійки `Default`
    /// (`MoveFromX="9,9"`) і `fade` у пісенних.
    static func transition(for scene: Scene) -> SlideStyle.Transition {
        guard scene.isAnimated, scene.fx != 0 else { return .none }
        if scene.isScaling { return .zoom }
        if scene.isMoving { return scene.movesHorizontally ? .slideLeft : .slideUp }
        return .fade
    }
}
