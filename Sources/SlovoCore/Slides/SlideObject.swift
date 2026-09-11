import Foundation
import CoreGraphics

/// Що за об'єкт лежить на слайді.
///
/// Набір повторює «Конструктор слайда» оригіналу: там на слайд кладуть не
/// «текст і адресу», а саме об'єкти, кожен зі своїм місцем і оформленням.
/// Завдяки цьому один і той самий вірш можна по-різному розкласти для
/// проектора, для трансляції і для екрана служителя.
public enum SlideObjectKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case quote                   // біблійний текст основного перекладу (або текст пісні)
    case secondaryQuote          // другий переклад
    case primaryReference        // адреса основного перекладу (назва частини пісні)
    case secondaryReference      // адреса другого перекладу
    case reference               // об'єднана адреса (або назва частини пісні)
    case moduleShortNameFirst    // коротке ім'я модуля основного перекладу
    case moduleNameFirst         // повне ім'я модуля основного перекладу
    case moduleShortNameSecond   // коротке ім'я модуля другого перекладу
    case moduleNameSecond        // повне ім'я модуля другого перекладу
    case songTitle               // назва пісні
    case previousPage            // попередня сторінка тексту
    case nextPage                // наступна сторінка тексту
    case staticText              // довільний напис, що не залежить від вірша
    case image                   // картинка: логотип, рамка, плашка

    public var id: String { rawValue }

    /// Порядок пунктів меню «Додати об'єкт» — рівно той, що в оригіналі.
    /// `allCases` для цього не годиться: `staticText` і `image` в оригіналі
    /// стоять останніми, а оголошені в переліку раніше не будуть.
    public static let menuOrder: [SlideObjectKind] = [
        .quote, .secondaryQuote,
        .primaryReference, .secondaryReference, .reference,
        .moduleShortNameFirst, .moduleNameFirst,
        .moduleShortNameSecond, .moduleNameSecond,
        .songTitle, .previousPage, .nextPage,
        .staticText, .image,
    ]

    /// Ключ підпису в `[SlideConstructorForm]` файла перекладу: формулювання
    /// пункту меню беремо в автора, а не переписуємо своїми словами.
    public var languageKey: String {
        switch self {
        case .quote:                 return "NAddQuote"
        case .secondaryQuote:        return "NAddQuoteSecond"
        case .primaryReference:      return "NAddRefFirst"
        case .secondaryReference:    return "NAddRefSecond"
        case .reference:             return "NAddRef"
        case .moduleShortNameFirst:  return "NAddModuleShortNameFirst"
        case .moduleNameFirst:       return "NAddModuleNameFirst"
        case .moduleShortNameSecond: return "NAddModuleShortNameSecond"
        case .moduleNameSecond:      return "NAddModuleNameSecond"
        case .songTitle:             return "NAddSongName"
        case .previousPage:          return "NAddPrevPage"
        case .nextPage:              return "NAddNextPage"
        case .staticText:            return "NAddStaticText"
        case .image:                 return "NAddImage"
        }
    }

    /// Формулювання взято з пунктів меню конструктора в оригіналі.
    public var title: String {
        switch self {
        case .quote:                 return OurWords.t("Библейский текст основного перевода (текст песни)")
        case .secondaryQuote:        return OurWords.t("Библейский текст второго перевода")
        case .primaryReference:      return OurWords.t("Адрес основного перевода Библии (название части песни)")
        case .secondaryReference:    return OurWords.t("Адрес второго перевода Библии")
        case .reference:             return OurWords.t("Объединенный адрес для двух переводов (название части песни)")
        case .moduleShortNameFirst:  return OurWords.t("Имя Модуля 1 короткое")
        case .moduleNameFirst:       return OurWords.t("Имя Модуля 1 полное")
        case .moduleShortNameSecond: return OurWords.t("Имя Модуля 2 короткое")
        case .moduleNameSecond:      return OurWords.t("Имя Модуля 2 полное")
        case .songTitle:             return OurWords.t("Название песни")
        case .previousPage:          return OurWords.t("Пред. страница")
        case .nextPage:              return OurWords.t("След. страница")
        case .staticText:            return OurWords.t("Статический текст")
        case .image:                 return OurWords.t("Изображение")
        }
    }

    public var shortTitle: String {
        switch self {
        case .quote:                 return OurWords.t("Текст")
        case .secondaryQuote:        return OurWords.t("2-й перевод")
        case .primaryReference:      return OurWords.t("Адрес 1")
        case .secondaryReference:    return OurWords.t("Адрес 2")
        case .reference:             return OurWords.t("Адрес")
        case .moduleShortNameFirst:  return OurWords.t("Модуль 1 кор.")
        case .moduleNameFirst:       return OurWords.t("Модуль 1")
        case .moduleShortNameSecond: return OurWords.t("Модуль 2 кор.")
        case .moduleNameSecond:      return OurWords.t("Модуль 2")
        case .songTitle:             return OurWords.t("Название песни")
        case .previousPage:          return OurWords.t("Пред. стр.")
        case .nextPage:              return OurWords.t("След. стр.")
        case .staticText:            return OurWords.t("Надпись")
        case .image:                 return OurWords.t("Изображение")
        }
    }

    /// Об'єкти, яким потрібні шрифт і колір.
    public var isTextual: Bool { self != .image }
}

/// Прив'язка об'єкта до краю полотна. В оригіналі це «Прив'язка по X/Y»:
/// відступ відлічується від того краю, до якого об'єкт прив'язано, — тоді
/// розмітка не роз'їжджається при зміні роздільності проектора.
public enum HorizontalAnchor: String, Codable, CaseIterable, Sendable, Identifiable {
    case left, center, right
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .left:   return OurWords.t("Левая")
        case .center: return OurWords.t("По центру")
        case .right:  return OurWords.t("Правая")
        }
    }
}

public enum VerticalAnchor: String, Codable, CaseIterable, Sendable, Identifiable {
    case top, middle, bottom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .top:    return OurWords.t("Верх")
        case .middle: return OurWords.t("Середина")
        case .bottom: return "Низ"
        }
    }
}

public enum ParagraphAlignment: String, Codable, CaseIterable, Sendable, Identifiable {
    case leading, center, trailing
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .leading:  return OurWords.t("Влево")
        case .center:   return OurWords.t("По центру")
        case .trailing: return OurWords.t("Вправо")
        }
    }
}

/// Місце і розмір об'єкта — в частках полотна, а не в пікселях.
///
/// Пікселі довелося б перераховувати під кожен вивід: проектор 1920×1080,
/// кадр NDI може бути іншим, вікно передпоказу взагалі довільне.
/// У частках розмітка переноситься між ними без правок.
public struct ObjectFrame: Codable, Hashable, Sendable {
    public var x: Double        // відступ від краю прив'язки, частка ширини
    public var y: Double        // відступ від краю прив'язки, частка висоти
    public var width: Double    // частка ширини полотна
    public var height: Double   // частка висоти полотна
    public var anchorX: HorizontalAnchor
    public var anchorY: VerticalAnchor

    public init(x: Double = 0.06, y: Double = 0.06,
                width: Double = 0.88, height: Double = 0.6,
                anchorX: HorizontalAnchor = .center, anchorY: VerticalAnchor = .middle) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.anchorX = anchorX
        self.anchorY = anchorY
    }

    /// Перерахунок у точки всередині полотна заданого розміру.
    public func rect(in size: CGSize) -> CGRect {
        let w = width * size.width
        let h = height * size.height
        let dx = x * size.width
        let dy = y * size.height

        let left: Double
        switch anchorX {
        case .left:   left = dx
        case .center: left = (size.width - w) / 2 + dx
        case .right:  left = size.width - w - dx
        }

        let top: Double
        switch anchorY {
        case .top:    top = dy
        case .middle: top = (size.height - h) / 2 + dy
        case .bottom: top = size.height - h - dy
        }

        return CGRect(x: left, y: top, width: w, height: h)
    }
}

/// Поява об'єкта на слайді. Напрямки і поля повторюють вкладку
/// «Анімація» конструктора оригіналу, включно з вильотом «з точки».
public struct ObjectAnimation: Codable, Hashable, Sendable {

    public enum Direction: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, left, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, point

        public var id: String { rawValue }

        /// Підписи рівно як в оригіналі (`FXDirectText0…9`).
        public var title: String {
            switch self {
            case .none:        return "нет"
            case .left:        return OurWords.t("слева")
            case .topLeft:     return OurWords.t("слева, сверху")
            case .top:         return OurWords.t("сверху")
            case .topRight:    return OurWords.t("сверху, справа")
            case .right:       return OurWords.t("справа")
            case .bottomRight: return OurWords.t("справа, снизу")
            case .bottom:      return OurWords.t("снизу")
            case .bottomLeft:  return OurWords.t("снизу, слева")
            case .point:       return OurWords.t("из точки:")
            }
        }

        /// Зсув початкової позиції в частках полотна.
        public var offset: (x: Double, y: Double) {
            switch self {
            case .none:        return (0, 0)
            case .left:        return (-1, 0)
            case .topLeft:     return (-1, -1)
            case .top:         return (0, -1)
            case .topRight:    return (1, -1)
            case .right:       return (1, 0)
            case .bottomRight: return (1, 1)
            case .bottom:      return (0, 1)
            case .bottomLeft:  return (-1, 1)
            case .point:       return (0, 0)
            }
        }
    }

    public var direction: Direction
    public var pointX: Double        // для «з точки», частка ширини
    public var pointY: Double
    public var startScale: Double    // «Початковий», частка від кінцевого розміру
    /// «Початкова» прозорість (Label8, у шаблоні `FromOpacity`) — з якої
    /// видимості об'єкт починає проявлятися. Нуль — зовсім невидимий.
    public var startOpacity: Double
    public var duration: Double      // мс
    public var delay: Double         // мс
    public var animatesScale: Bool
    public var animatesOpacity: Bool

    public init(direction: Direction = .none,
                pointX: Double = 0.5, pointY: Double = 0.5,
                startScale: Double = 0.9,
                startOpacity: Double = 0,
                duration: Double = 350, delay: Double = 0,
                animatesScale: Bool = false, animatesOpacity: Bool = true) {
        self.direction = direction
        self.pointX = pointX
        self.pointY = pointY
        self.startScale = startScale
        self.startOpacity = startOpacity
        self.duration = duration
        self.delay = delay
        self.animatesScale = animatesScale
        self.animatesOpacity = animatesOpacity
    }

    /// Розбір, терпимий до відсутніх полів, — як у `ObjectVariant`.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        direction = try box.decodeIfPresent(Direction.self, forKey: .direction) ?? .none
        pointX = try box.decodeIfPresent(Double.self, forKey: .pointX) ?? 0.5
        pointY = try box.decodeIfPresent(Double.self, forKey: .pointY) ?? 0.5
        startScale = try box.decodeIfPresent(Double.self, forKey: .startScale) ?? 0.9
        startOpacity = try box.decodeIfPresent(Double.self, forKey: .startOpacity) ?? 0
        duration = try box.decodeIfPresent(Double.self, forKey: .duration) ?? 350
        delay = try box.decodeIfPresent(Double.self, forKey: .delay) ?? 0
        animatesScale = try box.decodeIfPresent(Bool.self, forKey: .animatesScale) ?? false
        animatesOpacity = try box.decodeIfPresent(Bool.self, forKey: .animatesOpacity) ?? true
    }

    public static let instant = ObjectAnimation(direction: .none, duration: 0,
                                                animatesScale: false, animatesOpacity: false)

    public var isAnimated: Bool {
        duration > 0 && (direction != .none || animatesScale || animatesOpacity)
    }
}

/// Другий набір параметрів об'єкта — розкладка на випадок, коли на слайді
/// показують два переклади.
///
/// Так влаштовано й оригінал: у його шаблонах кожен об'єкт описано двічі, другий
/// набір позначено суфіксом `_2`, а поруч лежать дві намальовані мініатюри —
/// `scene1.jpg` з одним перекладом і `scene2.jpg` з двома. Без цього ввімкнення
/// другого перекладу просто налазило б на перший: у шаблоні «SongDefault»
/// цитата займає 94% висоти наодинці і 48% у парі.
public struct ObjectVariant: Codable, Hashable, Sendable {
    public var frame: ObjectFrame
    public var opacity: Double
    public var isVisible: Bool
    /// «Вирівн. по X» (Label36) — виключка рядків усередині рамки.
    public var alignment: ParagraphAlignment
    /// «Вирівн. по Y» (Label37) — куди текст притиснуто по вертикалі.
    /// У шаблоні це `Layout` і `Layout_2`, отже налаштування посценне.
    public var verticalAlignment: SlideStyle.VerticalAlignment
    /// «Тінь» (6.3.7) — у шаблоні `Shadow…Perc` і `Shadow…Perc_2`.
    public var shadow: ObjectShadow
    public var animation: ObjectAnimation

    public init(frame: ObjectFrame,
                opacity: Double = 1,
                isVisible: Bool = true,
                alignment: ParagraphAlignment = .center,
                verticalAlignment: SlideStyle.VerticalAlignment = .center,
                shadow: ObjectShadow = ObjectShadow(),
                animation: ObjectAnimation = ObjectAnimation()) {
        self.frame = frame
        self.opacity = opacity
        self.isVisible = isVisible
        self.alignment = alignment
        self.verticalAlignment = verticalAlignment
        self.shadow = shadow
        self.animation = animation
    }

    /// Розбір терпить відсутні поля.
    ///
    /// Преднастройки лежать звичайним JSON і правляться руками — так задумано.
    /// Синтезований розбір падав би на файлі, записаному до появи
    /// чергового поля, і людина втрачала б весь шаблон через один рядок.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        frame = try box.decodeIfPresent(ObjectFrame.self, forKey: .frame) ?? ObjectFrame()
        opacity = try box.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        isVisible = try box.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        alignment = try box.decodeIfPresent(ParagraphAlignment.self, forKey: .alignment) ?? .center
        verticalAlignment = try box.decodeIfPresent(SlideStyle.VerticalAlignment.self,
                                                    forKey: .verticalAlignment) ?? .center
        shadow = try box.decodeIfPresent(ObjectShadow.self, forKey: .shadow) ?? ObjectShadow()
        animation = try box.decodeIfPresent(ObjectAnimation.self, forKey: .animation) ?? ObjectAnimation()
    }
}

/// Об'єкт слайда цілком.
public struct SlideObject: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: SlideObjectKind
    public var isVisible: Bool

    public var frame: ObjectFrame
    public var opacity: Double

    // Оформлення тексту
    public var text: SlideStyle.TextLayer
    public var isUnderlined: Bool
    public var alignment: ParagraphAlignment
    /// «Вирівн. по Y» для сцени 1. Другій сцені відповідає `secondVariant`.
    public var verticalAlignment: SlideStyle.VerticalAlignment
    /// «Тінь» для сцени 1.
    public var shadow: ObjectShadow
    public var lineSpacing: Double
    /// Мінімальний масштаб автодобору: довгий вірш стискається, але не в кашу.
    public var minimumScale: Double

    // Вміст, що не залежить від вірша
    public var staticText: String
    public var imagePath: String?
    /// Маска прозорості — в оригіналі окремий файл поруч із зображенням.
    public var maskPath: String?

    // Понад оригінал: підкладка під об'єктом і розмиття
    public var backgroundColor: SlideStyle.RGBA
    public var cornerRadius: Double
    public var blurRadius: Double

    public var animation: ObjectAnimation

    /// Розкладка для слайда з двома перекладами. `nil` — об'єкт стоїть на місці
    /// незалежно від того, один переклад показано чи два.
    public var secondVariant: ObjectVariant?

    /// Параметри під поточний склад слайда.
    public func variant(withSecondTranslation: Bool) -> ObjectVariant {
        if withSecondTranslation, let secondVariant { return secondVariant }
        return ObjectVariant(frame: frame, opacity: opacity, isVisible: isVisible,
                             alignment: alignment, verticalAlignment: verticalAlignment,
                             shadow: shadow, animation: animation)
    }

    public init(kind: SlideObjectKind,
                name: String? = nil,
                frame: ObjectFrame = ObjectFrame(),
                text: SlideStyle.TextLayer = SlideStyle.TextLayer()) {
        self.id = UUID()
        self.kind = kind
        self.name = name ?? kind.shortTitle
        self.isVisible = true
        self.frame = frame
        self.opacity = 1
        self.text = text
        self.isUnderlined = false
        self.alignment = .center
        self.verticalAlignment = .center
        self.shadow = ObjectShadow()
        self.lineSpacing = 0.18
        self.minimumScale = 0.35
        self.staticText = ""
        self.imagePath = nil
        self.maskPath = nil
        self.backgroundColor = SlideStyle.RGBA(0, 0, 0, 0)
        self.cornerRadius = 0
        self.blurRadius = 0
        self.animation = ObjectAnimation()
        self.secondVariant = nil
    }

    /// Розбір із JSON, терпимий до відсутніх полів, — з тієї самої причини,
    /// що й у `ObjectVariant`: файл преднастройки правиться руками, і один
    /// незаповнений ключ не має забирати весь об'єкт.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try box.decodeIfPresent(SlideObjectKind.self, forKey: .kind) ?? .quote
        name = try box.decodeIfPresent(String.self, forKey: .name) ?? kind.shortTitle
        isVisible = try box.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        frame = try box.decodeIfPresent(ObjectFrame.self, forKey: .frame) ?? ObjectFrame()
        opacity = try box.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        text = try box.decodeIfPresent(SlideStyle.TextLayer.self, forKey: .text) ?? SlideStyle.TextLayer()
        isUnderlined = try box.decodeIfPresent(Bool.self, forKey: .isUnderlined) ?? false
        alignment = try box.decodeIfPresent(ParagraphAlignment.self, forKey: .alignment) ?? .center
        verticalAlignment = try box.decodeIfPresent(SlideStyle.VerticalAlignment.self,
                                                    forKey: .verticalAlignment) ?? .center
        shadow = try box.decodeIfPresent(ObjectShadow.self, forKey: .shadow) ?? ObjectShadow()
        lineSpacing = try box.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 0.18
        minimumScale = try box.decodeIfPresent(Double.self, forKey: .minimumScale) ?? 0.35
        staticText = try box.decodeIfPresent(String.self, forKey: .staticText) ?? ""
        imagePath = try box.decodeIfPresent(String.self, forKey: .imagePath)
        maskPath = try box.decodeIfPresent(String.self, forKey: .maskPath)
        backgroundColor = try box.decodeIfPresent(SlideStyle.RGBA.self, forKey: .backgroundColor)
            ?? SlideStyle.RGBA(0, 0, 0, 0)
        cornerRadius = try box.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        blurRadius = try box.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 0
        animation = try box.decodeIfPresent(ObjectAnimation.self, forKey: .animation) ?? ObjectAnimation()
        secondVariant = try box.decodeIfPresent(ObjectVariant.self, forKey: .secondVariant)
    }
}
