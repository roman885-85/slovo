import Foundation
import CoreGraphics

/// Тінь об'єкта слайда — «Тень» із панелі «Параметры» конструктора (6.3.7).
///
/// У шаблонах оригіналу це чотири атрибути в кожного `Object`, і в кожного
/// є двійник із хвостом `_2`:
/// `ShadowOffsetPerc`, `ShadowBlurPerc`, `ShadowOpacity`, `ShadowColor`.
/// Отже, тінь — параметр не об'єкта загалом, а його набору для сцени: за
/// двох перекладів вона може бути іншою. Тому тінь лежить в `ObjectVariant`
/// поруч із рамкою, а не в оформленні тексту.
///
/// Числа зберігаються так само, як у файлі: зсув і розмиття — відсотки,
/// прозорість зведено до часток 0…1 (у файлі це байт 0…255).
public struct ObjectShadow: Codable, Hashable, Sendable {

    /// «Тень» (CBObjShadowActive) — вимикач усієї групи.
    public var isEnabled: Bool
    /// «Смещение (%)» (Label33, `ShadowOffsetPerc`).
    public var offsetPercent: Double
    /// «Сглаживание(%)» (Label34, `ShadowBlurPerc`) — радіус розмиття.
    public var blurPercent: Double
    /// «Прозрачность» (Label35, `ShadowOpacity`), 0…1.
    public var opacity: Double
    /// «Цвет тени» (SBObjShadowColor, `ShadowColor`).
    public var color: SlideStyle.RGBA
    /// Куди падає тінь, у градусах: 0° — управо, 45° — управо-вниз (як в
    /// оригіналі), 90° — просто вниз, 225° — уліво-вгору. Свого поля для
    /// напрямку в автора немає, тінь у нього завжди діагональна; власник
    /// просив «м'якше й різноманітніше» — ось і напрямок.
    public var angleDegrees: Double

    public init(isEnabled: Bool = false,
                offsetPercent: Double = 2.7,
                blurPercent: Double = 7,
                opacity: Double = 1,
                color: SlideStyle.RGBA = .black,
                angleDegrees: Double = 45) {
        self.isEnabled = isEnabled
        self.offsetPercent = offsetPercent
        self.blurPercent = blurPercent
        self.opacity = opacity
        self.color = color
        self.angleDegrees = angleDegrees
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, offsetPercent, blurPercent, opacity, color, angleDegrees
    }

    /// Шаблони, збережені до появи напрямку, читаються як були: кута в них
    /// немає, і тінь у них падає вправо-вниз.
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try box.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        offsetPercent = try box.decodeIfPresent(Double.self, forKey: .offsetPercent) ?? 2.7
        blurPercent = try box.decodeIfPresent(Double.self, forKey: .blurPercent) ?? 7
        opacity = try box.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        color = try box.decodeIfPresent(SlideStyle.RGBA.self, forKey: .color) ?? .black
        angleDegrees = try box.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 45
    }

    /// Тінь вимкнено цілком — нічого не малюємо.
    public var isVisible: Bool {
        isEnabled && opacity > 0 && (offsetPercent != 0 || blurPercent > 0)
    }

    /// Відсотки в точки.
    ///
    /// Від чого рахувати відсоток, оригінал не пояснює, але з чисел видно:
    /// у написів `ShadowOffsetPerc="2,7"` і `ShadowBlurPerc="7"` однакові в
    /// усіх шаблонах і збігаються зі спільними для слайда `QuoteShadowOffset` і
    /// `QuoteShadowBlur`, тобто прив'язані до кегля. А в картинки книги в
    /// SpringFade стоїть 10 і 9,6 — від кегля це була б тінь в один піксель,
    /// від висоти самої картинки виходить помітна підкладка, як на
    /// мініатюрі `scene1.jpg`. Звідси правило: у тексту відсоток від кегля,
    /// у картинки — від її висоти.
    public func metrics(fontSize: CGFloat, objectHeight: CGFloat) -> (offset: CGSize, blur: CGFloat) {
        let base = fontSize > 0 ? fontSize : objectHeight
        let offset = base * offsetPercent / 100
        let blur = base * blurPercent / 100
        // Зсув рахуємо по діагоналі: за кута 45° обидві осі дістають рівно
        // «Зсув», як було завжди, — авторські шаблони від появи напрямку не
        // змінилися ні на піксель.
        let radians = angleDegrees * Double.pi / 180
        let distance = Double(offset) * 2.0.squareRoot()
        return (CGSize(width: distance * Foundation.cos(radians),
                       height: distance * Foundation.sin(radians)), blur)
    }
}
