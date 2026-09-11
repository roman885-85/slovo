import Foundation

/// Як виглядає слайд: шрифти, кольори, обведення, поля.
///
/// Окремо від самого вмісту — один і той самий вірш має вміти
/// намалюватися і у вікні передпоказу, і на проекторі, і (пізніше) у кадрі NDI.
public struct SlideStyle: Sendable, Codable, Hashable {

    public struct TextLayer: Sendable, Codable, Hashable {
        public var fontName: String
        public var fontSize: Double        // у частках висоти слайда, не в пунктах
        public var isBold: Bool
        public var isItalic: Bool
        public var color: RGBA
        public var outlineColor: RGBA
        /// «Контур» (CBObjOutLineActive) — власний вимикач.
        ///
        /// У `.sch` це два різні атрибути: `QuoteOutLineEnable="true"` і
        /// `QuoteOutLineWidth="2,25"`. Поки вимикач обчислювався як
        /// «товщина більша за нуль», знята галочка стирала підібрану товщину,
        /// а повернення галочки підставляло чужі 0,4 %.
        public var isOutlined: Bool
        /// «Товщина контуру» (Label39) — у частках висоти слайда. Зберігається
        /// завжди, зокрема поки контур вимкнено.
        public var outlineThickness: Double
        public var shadowRadius: Double

        /// Товщина, з якою контур малюється: у вимкненого вона нуль.
        ///
        /// Лишена окремою властивістю, бо нею користуються і
        /// малювання (`OutlinedText`), і розбір `VisioBible.ini`, і шаблони —
        /// вимикач їм знати нема чого.
        public var outlineWidth: Double {
            get { isOutlined ? outlineThickness : 0 }
            set {
                isOutlined = newValue > 0
                // Нуль означає «вимкнути», а не «забути підібране».
                if newValue > 0 { outlineThickness = newValue }
            }
        }

        public init(fontName: String = "Helvetica Neue",
                    fontSize: Double = 0.085,
                    isBold: Bool = true,
                    isItalic: Bool = false,
                    color: RGBA = .white,
                    outlineColor: RGBA = .black,
                    outlineWidth: Double = 0.004,
                    shadowRadius: Double = 0.008) {
            self.fontName = fontName
            self.fontSize = fontSize
            self.isBold = isBold
            self.isItalic = isItalic
            self.color = color
            self.outlineColor = outlineColor
            self.isOutlined = outlineWidth > 0
            self.outlineThickness = outlineWidth > 0 ? outlineWidth : 0.004
            self.shadowRadius = shadowRadius
        }

        private enum CodingKeys: String, CodingKey {
            case fontName, fontSize, isBold, isItalic, color, outlineColor
            case outlineWidth, isOutlined, shadowRadius
        }

        /// Розбір терпить відсутні поля: преднастройки лежать читабельним JSON
        /// і правляться руками, а файли, записані до появи вимикача,
        /// знають лише товщину.
        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            fontName = try box.decodeIfPresent(String.self, forKey: .fontName) ?? "Helvetica Neue"
            fontSize = try box.decodeIfPresent(Double.self, forKey: .fontSize) ?? 0.085
            isBold = try box.decodeIfPresent(Bool.self, forKey: .isBold) ?? true
            isItalic = try box.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
            color = try box.decodeIfPresent(RGBA.self, forKey: .color) ?? .white
            outlineColor = try box.decodeIfPresent(RGBA.self, forKey: .outlineColor) ?? .black
            let width = try box.decodeIfPresent(Double.self, forKey: .outlineWidth) ?? 0.004
            outlineThickness = width > 0 ? width : 0.004
            // У файлах, записаних раніше, вимикача немає — його роль грав нуль.
            isOutlined = try box.decodeIfPresent(Bool.self, forKey: .isOutlined) ?? (width > 0)
            shadowRadius = try box.decodeIfPresent(Double.self, forKey: .shadowRadius) ?? 0.008
        }

        public func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encode(fontName, forKey: .fontName)
            try box.encode(fontSize, forKey: .fontSize)
            try box.encode(isBold, forKey: .isBold)
            try box.encode(isItalic, forKey: .isItalic)
            try box.encode(color, forKey: .color)
            try box.encode(outlineColor, forKey: .outlineColor)
            try box.encode(outlineThickness, forKey: .outlineWidth)
            try box.encode(isOutlined, forKey: .isOutlined)
            try box.encode(shadowRadius, forKey: .shadowRadius)
        }
    }

    public struct RGBA: Sendable, Codable, Hashable {
        public var red: Double, green: Double, blue: Double, alpha: Double

        public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }

        public static let white = RGBA(1, 1, 1)
        public static let black = RGBA(0, 0, 0)
        public static let gold  = RGBA(1, 0.85, 0.4)
    }

    public enum VerticalAlignment: String, Sendable, Codable, CaseIterable {
        case top, center, bottom
    }

    /// Зміна слайдів. Різка підміна тексту на великому екрані читається як
    /// ривок, тому за умовчанням — розчинення, як в оригіналі.
    public enum Transition: String, Sendable, Codable, CaseIterable, Identifiable {
        // Колишні п'ять — своїми іменами: вони записані в шаблонах і налаштуваннях.
        case none, fade, slideLeft, slideUp, zoom
        // Власник: «20 шаблонов эффектов переходов с их настройками».
        case fadeBlack, slideRight, slideDown
        case coverLeft, coverRight, coverUp, coverDown
        case wipeLeft, wipeRight, wipeUp, wipeDown
        case zoomOut, spin, flip, blur, bounce

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .none:       return OurWords.t("Без перехода")
            case .fade:       return OurWords.t("Растворение")
            case .fadeBlack:  return OurWords.t("Через чёрное")
            case .slideLeft:  return OurWords.t("Сдвиг влево")
            case .slideRight: return OurWords.t("Сдвиг вправо")
            case .slideUp:    return OurWords.t("Сдвиг вверх")
            case .slideDown:  return OurWords.t("Сдвиг вниз")
            case .coverLeft:  return OurWords.t("Накрытие влево")
            case .coverRight: return OurWords.t("Накрытие вправо")
            case .coverUp:    return OurWords.t("Накрытие вверх")
            case .coverDown:  return OurWords.t("Накрытие вниз")
            case .wipeLeft:   return OurWords.t("Шторка влево")
            case .wipeRight:  return OurWords.t("Шторка вправо")
            case .wipeUp:     return OurWords.t("Шторка вверх")
            case .wipeDown:   return OurWords.t("Шторка вниз")
            case .zoom:       return OurWords.t("Наплыв")
            case .zoomOut:    return OurWords.t("Отдаление")
            case .spin:       return OurWords.t("Поворот")
            case .flip:       return OurWords.t("Переворот")
            case .blur:       return OurWords.t("Размытие")
            case .bounce:     return OurWords.t("Падение с отскоком")
            }
        }
    }

    /// Крива часу переходу.
    public enum Easing: String, Sendable, Codable, CaseIterable, Identifiable {
        case linear, easeInOut, easeOut, spring
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .linear:    return OurWords.t("Равномерно")
            case .easeInOut: return OurWords.t("Плавно")
            case .easeOut:   return OurWords.t("С замедлением")
            case .spring:    return OurWords.t("Пружиной")
            }
        }
        /// Частка шляху за часткою часу — для трансляції, де кадри рахуємо самі.
        public func apply(_ t: Double) -> Double {
            let x = min(1, max(0, t))
            switch self {
            case .linear:    return x
            case .easeInOut: return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
            case .easeOut:   return 1 - (1 - x) * (1 - x)
            case .spring:
                let s = 1.70158
                let y = x - 1
                return 1 + y * y * ((s + 1) * y + s)
            }
        }
    }

    /// Шаблон переходу: ефект зі своєю тривалістю і кривою — те, що
    /// вибирають у «Параметрах» одним пунктом.
    public struct TransitionPreset: Sendable, Hashable, Identifiable {
        public let kind: Transition
        public let duration: Double
        public let easing: Easing
        public var id: String { kind.rawValue }
        public var title: String { kind.title }

        public static let all: [TransitionPreset] = [
            .init(kind: .none, duration: 0, easing: .linear),
            .init(kind: .fade, duration: 0.35, easing: .easeInOut),
            .init(kind: .fadeBlack, duration: 0.7, easing: .easeInOut),
            .init(kind: .slideLeft, duration: 0.4, easing: .easeOut),
            .init(kind: .slideRight, duration: 0.4, easing: .easeOut),
            .init(kind: .slideUp, duration: 0.4, easing: .easeOut),
            .init(kind: .slideDown, duration: 0.4, easing: .easeOut),
            .init(kind: .coverLeft, duration: 0.45, easing: .easeOut),
            .init(kind: .coverRight, duration: 0.45, easing: .easeOut),
            .init(kind: .coverUp, duration: 0.45, easing: .easeOut),
            .init(kind: .coverDown, duration: 0.45, easing: .easeOut),
            .init(kind: .wipeLeft, duration: 0.5, easing: .linear),
            .init(kind: .wipeRight, duration: 0.5, easing: .linear),
            .init(kind: .wipeUp, duration: 0.5, easing: .linear),
            .init(kind: .wipeDown, duration: 0.5, easing: .linear),
            .init(kind: .zoom, duration: 0.45, easing: .easeInOut),
            .init(kind: .zoomOut, duration: 0.45, easing: .easeInOut),
            .init(kind: .spin, duration: 0.6, easing: .easeInOut),
            .init(kind: .flip, duration: 0.6, easing: .easeInOut),
            .init(kind: .blur, duration: 0.5, easing: .easeInOut),
            .init(kind: .bounce, duration: 0.7, easing: .spring),
        ]

        public static func preset(for kind: Transition) -> TransitionPreset {
            all.first { $0.kind == kind } ?? all[0]
        }
    }

    public var name: String
    public var main: TextLayer
    public var secondary: TextLayer
    public var reference: TextLayer
    public var verticalAlignment: VerticalAlignment
    public var horizontalInset: Double     // поля в частках ширини
    public var verticalInset: Double
    public var lineSpacing: Double
    public var backgroundImagePath: String?
    public var backgroundColor: RGBA
    /// Затемнення підкладки, 0…1.
    ///
    /// За умовчанням НУЛЬ. В автора такого налаштування немає зовсім — жодного
    /// ключа у `VisioBible.ini`, — і фон він показує як є. Наші 0,25
    /// клали поверх кожної картинки чорну плівку на чверть, і власник
    /// побачив це одразу: «изображение неестественно тусклое, как будто
    /// наложен тёмный фильтр». Затемнювати фон має право лише шаблон або
    /// конструктор, якщо людина сама про це попросила.
    public var dimBackground: Double
    public var transition: Transition
    public var transitionDuration: Double  // секунди
    /// Крива переходу; порожньо — «плавно». Необов'язкове поле: старі
    /// записи стилю його не знають.
    public var transitionEasing: Easing?
    public var effectiveEasing: Easing { transitionEasing ?? .easeInOut }

    public init(name: String = "По умолчанию") {
        self.name = name
        self.main = TextLayer()
        self.secondary = TextLayer(fontSize: 0.062, isBold: false, isItalic: true,
                                   color: RGBA(0.92, 0.95, 1.0))
        self.reference = TextLayer(fontSize: 0.045, isBold: false, isItalic: true,
                                   color: .gold, shadowRadius: 0.006)
        self.verticalAlignment = .center
        self.horizontalInset = 0.06
        self.verticalInset = 0.06
        self.lineSpacing = 0.18
        self.backgroundImagePath = nil
        self.backgroundColor = RGBA(0.04, 0.07, 0.13)
        self.dimBackground = 0
        self.transition = .fade
        self.transitionDuration = 0.35
    }
}

/// Вміст одного слайда — те, що реально виводиться на екран.
public struct Slide: Sendable, Hashable {
    public var mainText: String
    public var secondaryTexts: [String]
    public var reference: String
    public var isBlank: Bool

    public init(mainText: String = "", secondaryTexts: [String] = [], reference: String = "", isBlank: Bool = false) {
        self.mainText = mainText
        self.secondaryTexts = secondaryTexts
        self.reference = reference
        self.isBlank = isBlank
    }

    public static let blank = Slide(isBlank: true)
}
