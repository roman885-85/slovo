import Foundation
import CoreGraphics

/// Розкладка слайда для браузера: те саме, що малює проектор, але числами,
/// які розуміє сторінка.
///
/// Навіщо вона. Веб-вивід досі віддавав сторінці ГОЛИЙ ТЕКСТ, а як його
/// розкласти — вирішувала сама сторінка своїм CSS. Отже шаблон, зібраний у
/// «Конструкторі слайда», в зал мережею не потрапляв зовсім: ні розташування
/// об'єктів, ні шрифт, ні фон, ні логотип. Оператор ставив шаблон, дивився на
/// проектор — і бачив на екрані в притворі зовсім інше.
///
/// Тут той самий шаблон перекладено в частки полотна: сторінка ставить об'єкти за
/// відсотками і сама тягнеться під будь-який екран, від телефона до панелі в притворі.
/// Перерахунок робиться один раз на слайд, а не на кадр: об'єкти міняються лише
/// зі зміною шаблону.
///
/// Картинки мережею йдуть не шляхами з диска, а короткими іменами: сторінка
/// просить `/slide-image/<ім'я>`, і сервер віддає рівно те, що в шаблоні є.
/// Віддавати браузеру шляхи до файлів не можна — за ними він попросить що завгодно.
public struct WebSlideLayout: Sendable, Hashable {

    public struct Background: Sendable, Hashable {
        public var color: SlideStyle.RGBA
        public var imageID: String?
        /// `cover`, `contain`, `100% 100%`, `auto`, `repeat` — як у CSS.
        public var fillMode: String

        public init(color: SlideStyle.RGBA, imageID: String?, fillMode: String) {
            self.color = color
            self.imageID = imageID
            self.fillMode = fillMode
        }
    }

    public struct Object: Sendable, Hashable {
        public var kind: String
        /// Частки полотна, 0…1. Лівий верхній кут і розмір.
        public var x, y, width, height: Double
        public var text: String
        public var imageID: String?
        public var fontFamily: String
        /// Частка висоти полотна — сторінка переведе в пікселі за своєю висотою.
        public var fontSize: Double
        public var isBold, isItalic, isUnderlined: Bool
        public var color: SlideStyle.RGBA
        public var alignment: String
        public var verticalAlignment: String
        public var lineSpacing: Double
        public var minimumScale: Double
        public var opacity: Double
        public var backgroundColor: SlideStyle.RGBA
        /// Частка висоти полотна.
        public var cornerRadius: Double
        public var blurRadius: Double
        public var outlineColor: SlideStyle.RGBA
        public var outlineWidth: Double
        public var shadowColor: SlideStyle.RGBA
        public var shadowOffset: Double
        public var shadowBlur: Double
        /// Куди падає тінь, у градусах (45° — управо-вниз, як було завжди).
        public var shadowAngle: Double
    }

    public var canvasWidth: Double
    public var canvasHeight: Double
    public var background: Background
    public var objects: [Object]
    /// Шрифти шаблону: ім'я родини → коротке ім'я файлу на сервері.
    ///
    /// Проектор бере їх із теки `Fonts` поруч із модулями, а в браузера їх
    /// немає: `Jikharev_VB` у чужій системі не встановлено, і сторінка мовчки
    /// підставляла б системний. Віддаємо файл — тоді літери ті самі.
    public var fonts: [String: String]

    public init(canvasWidth: Double = 1920, canvasHeight: Double = 1080,
                background: Background = Background(color: .black, imageID: nil, fillMode: "cover"),
                objects: [Object] = [],
                fonts: [String: String] = [:]) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.background = background
        self.objects = objects
        self.fonts = fonts
    }

    public var isEmpty: Bool { objects.isEmpty && background.imageID == nil }

    // MARK: - У JSON

    static func rgba(_ color: SlideStyle.RGBA) -> String {
        let r = Int((color.red * 255).rounded())
        let g = Int((color.green * 255).rounded())
        let b = Int((color.blue * 255).rounded())
        return String(format: "rgba(%d,%d,%d,%.3f)", r, g, b, color.alpha)
    }

    func json() -> [String: Any] {
        var background: [String: Any] = [
            "Color": Self.rgba(self.background.color),
            "FillMode": self.background.fillMode,
        ]
        if let id = self.background.imageID { background["Image"] = id }

        return [
            "Width": canvasWidth,
            "Height": canvasHeight,
            "Background": background,
            "Fonts": fonts,
            "Objects": objects.map { object -> [String: Any] in
                var item: [String: Any] = [
                    "Kind": object.kind,
                    "X": object.x, "Y": object.y,
                    "Width": object.width, "Height": object.height,
                    "Text": object.text,
                    "FontFamily": object.fontFamily,
                    "FontSize": object.fontSize,
                    "Bold": object.isBold,
                    "Italic": object.isItalic,
                    "Underline": object.isUnderlined,
                    "Color": Self.rgba(object.color),
                    "Align": object.alignment,
                    "VerticalAlign": object.verticalAlignment,
                    "LineSpacing": object.lineSpacing,
                    "MinimumScale": object.minimumScale,
                    "Opacity": object.opacity,
                    "Background": Self.rgba(object.backgroundColor),
                    "CornerRadius": object.cornerRadius,
                    "Blur": object.blurRadius,
                    "OutlineColor": Self.rgba(object.outlineColor),
                    "OutlineWidth": object.outlineWidth,
                    "ShadowColor": Self.rgba(object.shadowColor),
                    "ShadowOffset": object.shadowOffset,
                    "ShadowBlur": object.shadowBlur,
                    "ShadowAngle": object.shadowAngle,
                ]
                if let id = object.imageID { item["Image"] = id }
                return item
            },
        ]
    }
}

// MARK: - Збирання розкладки з шаблону

public extension WebSlideLayout {

    /// Перекласти шаблон у розкладку для сторінки.
    ///
    /// `text` віддає готовий рядок об'єкта — той самий, що йде на проектор:
    /// збирати його тут удруге означало б завести друге джерело правди
    /// про те, що написано на слайді.
    ///
    /// `imageID` реєструє картинку і повертає її коротке ім'я; `nil`
    /// означає «такої картинки немає» — тоді об'єкт просто не малюється.
    static func make(preset: SlidePreset,
                     withSecondTranslation: Bool,
                     canvas: CGSize = CGSize(width: 1920, height: 1080),
                     text: (SlideObject) -> String,
                     imageID: (String) -> String?,
                     fontID: (String) -> String? = { _ in nil }) -> WebSlideLayout {
        var objects: [Object] = []
        for object in preset.objects where object.isVisible {
            let variant = object.variant(withSecondTranslation: withSecondTranslation)
            guard variant.isVisible else { continue }
            let rect = variant.frame.rect(in: canvas)
            // Об'єкт за краєм полотна в браузері розтягнув би сторінку; на
            // проекторі він просто обрізаний, і тут має бути обрізаний теж.
            guard rect.width > 0, rect.height > 0 else { continue }

            var picture: String?
            if object.kind == .image {
                guard let path = object.imagePath, let id = imageID(path) else { continue }
                picture = id
            }
            let body = object.kind == .image ? "" : text(object)
            // Порожній текст малювати нічим: порожня рамка на екрані — це
            // прямокутник підкладки без жодної літери, і в залі він зайвий.
            if object.kind != .image, body.isEmpty, object.backgroundColor.alpha <= 0 { continue }

            objects.append(Object(
                kind: object.kind.rawValue,
                x: rect.minX / canvas.width,
                y: rect.minY / canvas.height,
                width: rect.width / canvas.width,
                height: rect.height / canvas.height,
                text: body,
                imageID: picture,
                fontFamily: object.text.fontName,
                fontSize: object.text.fontSize,
                isBold: object.text.isBold,
                isItalic: object.text.isItalic,
                isUnderlined: object.isUnderlined,
                color: object.text.color,
                alignment: cssAlign(variant.alignment),
                verticalAlignment: cssVertical(variant.verticalAlignment),
                lineSpacing: object.lineSpacing,
                minimumScale: object.minimumScale,
                opacity: variant.opacity,
                backgroundColor: object.backgroundColor,
                cornerRadius: object.cornerRadius,
                blurRadius: object.blurRadius,
                outlineColor: object.text.outlineColor,
                outlineWidth: object.text.outlineWidth,
                shadowColor: variant.shadow.isEnabled ? variant.shadow.color : SlideStyle.RGBA(0, 0, 0, 0),
                shadowOffset: variant.shadow.isEnabled ? variant.shadow.offsetPercent / 100 : 0,
                shadowBlur: variant.shadow.isEnabled ? variant.shadow.blurPercent / 100 : 0,
                shadowAngle: variant.shadow.angleDegrees))
        }

        var fonts: [String: String] = [:]
        for object in objects where !object.fontFamily.isEmpty {
            guard fonts[object.fontFamily] == nil, let id = fontID(object.fontFamily) else { continue }
            fonts[object.fontFamily] = id
        }

        return WebSlideLayout(
            canvasWidth: canvas.width,
            canvasHeight: canvas.height,
            background: Background(color: preset.background.color,
                                   imageID: preset.background.imagePath.flatMap(imageID),
                                   fillMode: cssFill(preset.background.fillMode)),
            objects: objects,
            fonts: fonts)
    }

    private static func cssAlign(_ value: ParagraphAlignment) -> String {
        switch value {
        case .leading:  return "left"
        case .center:   return "center"
        case .trailing: return "right"
        }
    }

    private static func cssVertical(_ value: SlideStyle.VerticalAlignment) -> String {
        switch value {
        case .top:    return "flex-start"
        case .center: return "center"
        case .bottom: return "flex-end"
        }
    }

    private static func cssFill(_ value: SlidePreset.FillMode) -> String {
        switch value {
        case .fill:    return "cover"
        case .fit:     return "contain"
        case .stretch: return "100% 100%"
        case .center:  return "auto"
        case .tile:    return "repeat"
        }
    }
}

// MARK: - Картинки шаблону

/// Картинки, які сторінка має право попросити в сервера.
///
/// Список закритий і живе рівно один слайд: сторінка просить `/slide-image/<ім'я>`,
/// і сервер віддає файл, лише якщо він названий у нинішньому шаблоні. Шляхів з
/// диска браузеру не показуємо зовсім — за таким шляхом він попросить що завгодно,
/// а сервер стоїть у мережі залу.
public final class WebSlideImages: @unchecked Sendable {

    private let lock = NSLock()
    private var byID: [String: URL] = [:]
    private var byPath: [String: String] = [:]

    public init() {}

    /// Записати картинку й отримати її коротке ім'я.
    @discardableResult
    public func register(path: String, url: URL) -> String {
        lock.lock(); defer { lock.unlock() }
        if let known = byPath[path] { return known }
        // Ім'я коротке і без літер шляху: розширення лишаємо, щоб браузер
        // сам зрозумів тип, усе інше — лічильник.
        let extensionName = url.pathExtension.lowercased()
        let id = "i\(byID.count + 1)" + (extensionName.isEmpty ? "" : ".\(extensionName)")
        byID[id] = url
        byPath[path] = id
        return id
    }

    public func url(forID id: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return byID[id]
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        byID.removeAll()
        byPath.removeAll()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return byID.count
    }
}
