import Foundation

/// Преднастройка виводу: полотно, підкладка і розкладені по ньому об'єкти.
///
/// У кожного виводу — монітора, NDI, вебу, екрана служителя — своя
/// преднастройка. Це не примха: на проекторі потрібен фон і великий текст,
/// у NDI фон частіше заважає і його прибирають, а служителю корисні наступна
/// сторінка і нотатки, яких у залі бачити не повинні.
public struct SlidePreset: Codable, Hashable, Sendable, Identifiable {

    /// Як уписувати фонове зображення в полотно.
    public enum FillMode: String, Codable, CaseIterable, Sendable, Identifiable {
        case fill      // заповнити, обрізавши зайве
        case fit       // уписати цілком
        case stretch   // розтягнути, спотворюючи пропорції
        case center    // як є, по центру
        case tile      // замостити

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .fill:    return OurWords.t("Заполнить")
            case .fit:     return OurWords.t("Вписать")
            case .stretch: return OurWords.t("Растянуть")
            case .center:  return OurWords.t("По центру")
            case .tile:    return OurWords.t("Замостить")
            }
        }
    }

    public struct Background: Codable, Hashable, Sendable {
        public var color: SlideStyle.RGBA
        public var imagePath: String?
        public var fillMode: FillMode
        /// Затемнення поверх картинки. Більше не малюється ніде: власник
        /// побачив його як «накладено темний світлофільтр» і попросив прибрати
        /// зовсім. Поле лишилося лише для того, щоб читалися вже збережені
        /// шаблони, де воно записане.
        public var dim: Double
        /// Розмиття підкладки. В оригіналі його немає; тут воно вирішує часту
        /// біду: фотографія з деталями «шумить» під літерами і заважає читати.
        public var blurRadius: Double
        /// Повністю прозорий фон — режим для NDI, коли картинку
        /// підкладає відеомікшер.
        public var isTransparent: Bool

        public init(color: SlideStyle.RGBA = SlideStyle.RGBA(0.04, 0.07, 0.13),
                    imagePath: String? = nil,
                    fillMode: FillMode = .fill,
                    dim: Double = 0,
                    blurRadius: Double = 0,
                    isTransparent: Bool = false) {
            self.color = color
            self.imagePath = imagePath
            self.fillMode = fillMode
            self.dim = dim
            self.blurRadius = blurRadius
            self.isTransparent = isTransparent
        }
    }

    public var id: UUID
    public var name: String
    /// Розмір полотна, під який добирали розмітку. Самі об'єкти зберігаються
    /// в частках, а полотно потрібне, щоб рахувати кегль і пропорції передпоказу.
    public var canvasWidth: Int
    public var canvasHeight: Int
    public var background: Background
    public var objects: [SlideObject]
    public var transition: SlideStyle.Transition
    public var transitionDuration: Double
    public var transitionEasing: SlideStyle.Easing?

    public init(name: String,
                canvasWidth: Int = 1920,
                canvasHeight: Int = 1080,
                background: Background = Background(),
                objects: [SlideObject] = [],
                transition: SlideStyle.Transition = .fade,
                transitionDuration: Double = 0.35) {
        self.id = UUID()
        self.name = name
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.background = background
        self.objects = objects
        self.transition = transition
        self.transitionDuration = transitionDuration
    }

    public var aspectRatio: Double {
        canvasHeight > 0 ? Double(canvasWidth) / Double(canvasHeight) : 16.0 / 9.0
    }

    public func object(withID id: UUID) -> SlideObject? {
        objects.first { $0.id == id }
    }

    public mutating func replace(_ object: SlideObject) {
        guard let index = objects.firstIndex(where: { $0.id == object.id }) else { return }
        objects[index] = object
    }

    public mutating func move(from source: Int, to destination: Int) {
        guard objects.indices.contains(source),
              destination >= 0, destination <= objects.count else { return }
        let item = objects.remove(at: source)
        objects.insert(item, at: destination > source ? destination - 1 : destination)
    }
}

public extension SlidePreset {

    /// Преднастройка, що повторює звичну розкладку: текст по центру,
    /// під ним другий переклад, унизу адреса.
    static func standard(name: String, style: SlideStyle) -> SlidePreset {
        var quote = SlideObject(kind: .quote, text: style.main)
        quote.frame = ObjectFrame(x: 0, y: -0.06, width: 0.88, height: 0.46,
                                  anchorX: .center, anchorY: .middle)

        var second = SlideObject(kind: .secondaryQuote, text: style.secondary)
        second.frame = ObjectFrame(x: 0, y: 0.22, width: 0.88, height: 0.26,
                                   anchorX: .center, anchorY: .middle)

        var reference = SlideObject(kind: .reference, text: style.reference)
        reference.frame = ObjectFrame(x: 0, y: 0.06, width: 0.88, height: 0.1,
                                      anchorX: .center, anchorY: .bottom)

        var background = Background(color: style.backgroundColor,
                                    imagePath: style.backgroundImagePath,
                                    dim: style.dimBackground)
        background.blurRadius = 0

        return SlidePreset(name: name,
                           background: background,
                           objects: [quote, second, reference],
                           transition: style.transition,
                           transitionDuration: style.transitionDuration)
    }

    /// Розкладка для NDI: те саме, але без підкладки — картинку під текст
    /// підкладає відеомікшер.
    static func transparent(name: String, style: SlideStyle) -> SlidePreset {
        var preset = standard(name: name, style: style)
        preset.background.isTransparent = true
        preset.background.imagePath = nil
        preset.background.dim = 0
        return preset
    }

    /// Розкладка екрана служителя: великий поточний текст, зверху адреса,
    /// знизу наступна сторінка — щоб бачити, що буде далі.
    static func stage(name: String, style: SlideStyle) -> SlidePreset {
        var reference = SlideObject(kind: .reference, text: style.reference)
        reference.frame = ObjectFrame(x: 0, y: 0.04, width: 0.9, height: 0.09,
                                      anchorX: .center, anchorY: .top)

        var quote = SlideObject(kind: .quote, text: style.main)
        quote.frame = ObjectFrame(x: 0, y: -0.04, width: 0.92, height: 0.5,
                                  anchorX: .center, anchorY: .middle)

        var next = SlideObject(kind: .nextPage, text: style.secondary)
        next.name = "Следующая"
        next.opacity = 0.55
        next.frame = ObjectFrame(x: 0, y: 0.05, width: 0.92, height: 0.24,
                                 anchorX: .center, anchorY: .bottom)

        var background = Background(color: SlideStyle.RGBA(0, 0, 0), dim: 0)
        background.imagePath = nil

        return SlidePreset(name: name,
                           background: background,
                           objects: [reference, quote, next],
                           transition: .none,
                           transitionDuration: 0)
    }
}
