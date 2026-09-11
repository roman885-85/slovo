import Foundation
import CoreGraphics

/// Тень объекта слайда — «Тень» из панели «Параметры» конструктора (6.3.7).
///
/// В шаблонах оригинала это четыре атрибута у каждого `Object`, и у каждого
/// есть двойник с хвостом `_2`:
/// `ShadowOffsetPerc`, `ShadowBlurPerc`, `ShadowOpacity`, `ShadowColor`.
/// Значит, тень — параметр не объекта целиком, а его набора для сцены: при
/// двух переводах она может быть другой. Поэтому тень лежит в `ObjectVariant`
/// рядом с рамкой, а не в оформлении текста.
///
/// Числа хранятся так же, как в файле: смещение и размытие — проценты,
/// прозрачность приведена к долям 0…1 (в файле это байт 0…255).
public struct ObjectShadow: Codable, Hashable, Sendable {

    /// «Тень» (CBObjShadowActive) — выключатель всей группы.
    public var isEnabled: Bool
    /// «Смещение (%)» (Label33, `ShadowOffsetPerc`).
    public var offsetPercent: Double
    /// «Сглаживание(%)» (Label34, `ShadowBlurPerc`) — радиус размытия.
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

    /// Тень выключена целиком — ничего не рисуем.
    public var isVisible: Bool {
        isEnabled && opacity > 0 && (offsetPercent != 0 || blurPercent > 0)
    }

    /// Проценты в точки.
    ///
    /// От чего считать процент, оригинал не поясняет, но по числам видно:
    /// у надписей `ShadowOffsetPerc="2,7"` и `ShadowBlurPerc="7"` одинаковы во
    /// всех шаблонах и совпадают с общими для слайда `QuoteShadowOffset` и
    /// `QuoteShadowBlur`, то есть привязаны к кеглю. А у картинки книги в
    /// SpringFade стоит 10 и 9,6 — от кегля это была бы тень в один пиксель,
    /// от высоты самой картинки получается заметная подложка, как на
    /// миниатюре `scene1.jpg`. Отсюда правило: у текста процент от кегля,
    /// у картинки — от её высоты.
    public func metrics(fontSize: CGFloat, objectHeight: CGFloat) -> (offset: CGSize, blur: CGFloat) {
        let base = fontSize > 0 ? fontSize : objectHeight
        let offset = base * offsetPercent / 100
        let blur = base * blurPercent / 100
        // Тень падает вправо-вниз: так её рисует и оригинал, отдельного поля
        // «направление» у него нет.
        return (CGSize(width: offset, height: offset), blur)
    }
}
