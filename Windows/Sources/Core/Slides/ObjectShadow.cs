// =============================================================================
//  ObjectShadow.cs — тінь об'єкта слайда (з Slides/ObjectShadow.swift)
// =============================================================================

using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Тінь об'єкта слайда — «Тень» із панелі «Параметры» конструктора (6.3.7).
///
/// У шаблонах оригіналу це чотири атрибути в кожного `Object`, і в кожного
/// є двійник із хвостом `_2`: `ShadowOffsetPerc`, `ShadowBlurPerc`,
/// `ShadowOpacity`, `ShadowColor`. Отже, тінь — параметр набору для сцени,
/// тому вона лежить в `ObjectVariant` поруч із рамкою. Зсув і розмиття —
/// відсотки, прозорість — частки 0…1 (у файлі це байт 0…255).
///
/// Розбір JSON терпить відсутні поля (у Swift — `decodeIfPresent` з умовчанням):
/// шаблони, збережені до появи напрямку, читаються як були.
public record struct ObjectShadow
{
    /// «Тень» (CBObjShadowActive) — вимикач усієї групи.
    [JsonInclude, JsonPropertyName("isEnabled")] public bool IsEnabled = false;
    /// «Смещение (%)» (Label33, `ShadowOffsetPerc`).
    [JsonInclude, JsonPropertyName("offsetPercent")] public double OffsetPercent = 2.7;
    /// «Сглаживание(%)» (Label34, `ShadowBlurPerc`) — радіус розмиття.
    [JsonInclude, JsonPropertyName("blurPercent")] public double BlurPercent = 7;
    /// «Прозрачность» (Label35, `ShadowOpacity`), 0…1.
    [JsonInclude, JsonPropertyName("opacity")] public double Opacity = 1;
    /// «Цвет тени» (SBObjShadowColor, `ShadowColor`).
    [JsonInclude, JsonPropertyName("color")] public SlideStyle.RGBA Color = SlideStyle.RGBA.Black;
    /// Куди падає тінь, у градусах: 0° — управо, 45° — управо-вниз (як в
    /// оригіналі), 90° — просто вниз. Свого поля для напрямку в автора немає;
    /// власник просив «м'якше й різноманітніше» — ось і напрямок.
    [JsonInclude, JsonPropertyName("angleDegrees")] public double AngleDegrees = 45;

    public ObjectShadow() { }

    public ObjectShadow(bool isEnabled = false, double offsetPercent = 2.7, double blurPercent = 7,
                        double opacity = 1, SlideStyle.RGBA? color = null, double angleDegrees = 45)
    {
        IsEnabled = isEnabled;
        OffsetPercent = offsetPercent;
        BlurPercent = blurPercent;
        Opacity = opacity;
        Color = color ?? SlideStyle.RGBA.Black;
        AngleDegrees = angleDegrees;
    }

    /// Тінь вимкнено цілком — нічого не малюємо.
    [JsonIgnore]
    public readonly bool IsVisible => IsEnabled && Opacity > 0 && (OffsetPercent != 0 || BlurPercent > 0);

    /// Відсотки в точки.
    ///
    /// У тексту відсоток від кегля (`ShadowOffsetPerc="2,7"` однакові в усіх
    /// шаблонах і збігаються з `QuoteShadowOffset`), у картинки — від її висоти.
    public readonly (SizeD Offset, double Blur) Metrics(double fontSize, double objectHeight)
    {
        var size = fontSize > 0 ? fontSize : objectHeight;
        var offset = size * OffsetPercent / 100;
        var blur = size * BlurPercent / 100;
        // Зсув по діагоналі: за кута 45° обидві осі дістають рівно «Зсув», як
        // було завжди, — авторські шаблони від появи напрямку не змінилися.
        var radians = AngleDegrees * Math.PI / 180;
        var distance = offset * Math.Sqrt(2.0);
        return (new SizeD(distance * Math.Cos(radians), distance * Math.Sin(radians)), blur);
    }
}
