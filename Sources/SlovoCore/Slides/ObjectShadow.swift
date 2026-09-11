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

    public init(isEnabled: Bool = false,
                offsetPercent: Double = 2.7,
                blurPercent: Double = 7,
                opacity: Double = 1,
                color: SlideStyle.RGBA = .black) {
        self.isEnabled = isEnabled
        self.offsetPercent = offsetPercent
        self.blurPercent = blurPercent
        self.opacity = opacity
        self.color = color
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
        // Тінь падає вправо-вниз: так її малює й оригінал, окремого поля
        // «напрямок» у нього немає.
        return (CGSize(width: offset, height: offset), blur)
    }
}
