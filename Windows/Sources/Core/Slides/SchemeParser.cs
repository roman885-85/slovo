// =============================================================================
//  SchemeParser.cs — читання шаблону слайда .sch (з Slides/SchemeParser.swift)
// =============================================================================
//  На Mac розбір іде через XMLParser (події «початок/кінець вузла»); тут —
//  System.Xml.XmlReader тими самими подіями: порожній вузол `<Object …/>` дає
//  і початок, і кінець, як у XMLParser.
// =============================================================================

using System.Xml;

namespace Slovo.Core;

/// Читання шаблону слайда `.sch`.
///
/// Формат — XML без оголошення кодування: `VisioBibleScheme` → `Scheme` →
/// список `Object`, у кожного свої `FXPresets` з парою `Scene`. Розбір
/// навмисно нестрогий: невідомі атрибути й цілі незнайомі вузли не заважають —
/// усе, що не розібрано в поля, лишається в `Attributes`, а чого немає зовсім,
/// підставляється значенням за умовчанням.
public static class SchemeParser
{
    public sealed class Failure : Exception
    {
        public enum Kind { Unreadable, Malformed, NoScheme }

        public Kind FailureKind { get; }

        private Failure(Kind kind, string message) : base(message) => FailureKind = kind;

        public static Failure Unreadable(string path) =>
            new(Kind.Unreadable, $"Не удалось прочитать шаблон {SwiftPath.LastComponent(path)}");

        public static Failure Malformed(string text) =>
            new(Kind.Malformed, OurWords.T("Шаблон разобрать не удалось: %s", text));

        public static Failure NoScheme() => new(Kind.NoScheme, OurWords.T("В файле нет узла Scheme"));

        public override string ToString() => Message;
    }

    public static SlideScheme Scheme(string path)
    {
        byte[] data;
        try { data = File.ReadAllBytes(path); }
        catch { throw Failure.Unreadable(path); }
        return Scheme(data, SwiftPath.LastComponent(SwiftPath.DeletingExtension(path)));
    }

    /// `fallbackName` іде в хід, якщо у файлі немає атрибута `Name`.
    public static SlideScheme Scheme(byte[] data, string fallbackName = "")
    {
        // Кодування не оголошено: свіжі файли UTF-8, старі могли бути в CP1251.
        var declared = CodePage.IsValidUtf8(data) ? CodePage.Utf8 : null;
        var text = CodePage.Decode(data, declared);

        var collector = new Collector(fallbackName);
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Ignore,
            XmlResolver = null,
            IgnoreComments = true,
            IgnoreProcessingInstructions = true,
        };
        try
        {
            using var reader = XmlReader.Create(new StringReader(text), settings);
            while (reader.Read())
            {
                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                    {
                        var name = reader.Name;
                        var empty = reader.IsEmptyElement;
                        var attributes = new List<KeyValuePair<string, string>>();
                        if (reader.MoveToFirstAttribute())
                        {
                            do attributes.Add(new KeyValuePair<string, string>(reader.Name, reader.Value));
                            while (reader.MoveToNextAttribute());
                            reader.MoveToElement();
                        }
                        collector.Start(name, new Attributes(attributes));
                        if (empty) collector.End(name);
                        break;
                    }
                    case XmlNodeType.EndElement:
                        collector.End(reader.Name);
                        break;
                }
            }
        }
        catch (XmlException error)
        {
            throw Failure.Malformed(error.Message);
        }
        return collector.Finish() ?? throw Failure.NoScheme();
    }

    // ── Розбір значень ──────────────────────────────────────────────────────

    /// Delphi пише дробові з комою й іноді в науковому записі (`-3,66568565368652E-6`).
    internal static double? Number(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return null;
        return SwiftText.ParseDouble(raw.Replace(",", "."));
    }

    internal static bool? Flag(string? raw)
    {
        if (raw == null) return null;
        return raw.TrimWhitespaces().ToLowerInvariant() switch
        {
            "true" or "1" or "yes" => true,
            "false" or "0" or "no" => false,
            _ => null,
        };
    }

    /// `TColor` — `0x00BBGGRR`. Від'ємні значення в Delphi — системні кольори
    /// на зразок `clWindowText`; їх брати нізвідки, віддаємо null.
    internal static SlideStyle.RGBA? Color(string? raw)
    {
        if (raw == null || SwiftText.ParseInt(raw.TrimWhitespaces()) is not { } value || value < 0) return null;
        return new SlideStyle.RGBA((value & 0xFF) / 255.0, ((value >> 8) & 0xFF) / 255.0, ((value >> 16) & 0xFF) / 255.0);
    }

    /// Атрибути вузла з пошуком без урахування регістру.
    internal sealed class Attributes
    {
        public readonly Dictionary<string, string> Raw = new(StringComparer.Ordinal);
        private readonly Dictionary<string, string> index = new(StringComparer.Ordinal);

        public Attributes(IEnumerable<KeyValuePair<string, string>> raw)
        {
            foreach (var (key, value) in raw)
            {
                Raw[key] = value;
                index[key.ToLowerInvariant()] = value;
            }
        }

        public string? String(string key) => index.TryGetValue(key.ToLowerInvariant(), out var value) ? value : null;
        public double? Number(string key) => SchemeParser.Number(String(key));
        public bool? Flag(string key) => SchemeParser.Flag(String(key));
        public SlideStyle.RGBA? Color(string key) => SchemeParser.Color(String(key));
    }

    // ── Обхід дерева ────────────────────────────────────────────────────────

    private sealed class Collector
    {
        private readonly string fallbackName;

        private Attributes? schemeAttributes;
        private readonly List<string> presetNames = new();
        private readonly List<SlideScheme.Element> elements = new();

        // `FXPreset` трапляється і в списку пресетів схеми, і всередині об'єкта —
        // розрізняємо за тим, чи почато об'єкт.
        private bool inPresetList;
        private Attributes? elementAttributes;
        private List<SlideScheme.FXPreset> elementPresets = new();
        private SlideScheme.FXPreset? openPreset;

        public Collector(string fallbackName) => this.fallbackName = fallbackName;

        public SlideScheme? Finish()
        {
            if (schemeAttributes is not { } attributes) return null;
            return new SlideScheme(name: attributes.String("Name") ?? fallbackName,
                                   backgroundImageName: attributes.String("BackImg") ?? "",
                                   outlineEnabled: attributes.Flag("QuoteOutLineEnable") ?? false,
                                   outlineWidth: attributes.Number("QuoteOutLineWidth") ?? 0,
                                   outlineColor: attributes.Color("QuoteOutLineColor") ?? SlideStyle.RGBA.Black,
                                   shadowEnabled: attributes.Flag("QuoteShadowEnabled") ?? false,
                                   shadowOffset: attributes.Number("QuoteShadowOffset") ?? 0,
                                   shadowBlur: attributes.Number("QuoteShadowBlur") ?? 0,
                                   shadowOpacity: (attributes.Number("QuoteShadowOpacity") ?? 0) / 255,
                                   shadowColor: attributes.Color("QuoteShadowColor") ?? SlideStyle.RGBA.Black,
                                   presetNames: new List<string>(presetNames),
                                   elements: new List<SlideScheme.Element>(elements),
                                   attributes: new Dictionary<string, string>(attributes.Raw));
        }

        public void Start(string elementName, Attributes attributes)
        {
            switch (elementName.ToLowerInvariant())
            {
                case "scheme":
                    schemeAttributes = attributes;
                    break;
                case "fxpresetslist":
                    inPresetList = true;
                    break;
                case "fxpreset":
                    if (inPresetList)
                    {
                        presetNames.Add(attributes.String("Name") ?? $"Fx{presetNames.Count + 1}");
                    }
                    else if (elementAttributes != null)
                    {
                        var name = elementPresets.Count < presetNames.Count
                            ? presetNames[elementPresets.Count]
                            : $"Fx{elementPresets.Count + 1}";
                        openPreset = new SlideScheme.FXPreset(name, attributes.Flag("EnableFxParamsVariant") ?? false);
                    }
                    break;
                case "object":
                    elementAttributes = attributes;
                    elementPresets = new List<SlideScheme.FXPreset>();
                    openPreset = null;
                    break;
                case "scene":
                    openPreset?.Scenes.Add(SceneFrom(attributes));
                    break;
            }
        }

        public void End(string elementName)
        {
            switch (elementName.ToLowerInvariant())
            {
                case "fxpresetslist":
                    inPresetList = false;
                    break;
                case "fxpreset":
                    if (openPreset != null)
                    {
                        elementPresets.Add(openPreset);
                        openPreset = null;
                    }
                    break;
                case "object":
                    if (elementAttributes != null) elements.Add(ElementFrom(elementAttributes, elementPresets));
                    elementAttributes = null;
                    elementPresets = new List<SlideScheme.FXPreset>();
                    break;
            }
        }

        // ── Складання моделей ───────────────────────────────────────────────

        private static SlideScheme.Element ElementFrom(Attributes attributes, List<SlideScheme.FXPreset> presets)
        {
            var image = attributes.String("Image") is { Length: > 0 } imageName ? imageName : null;
            var mask = attributes.String("ImageMask") is { Length: > 0 } maskName ? maskName : null;
            var rawType = attributes.String("Type") is { } type && SwiftText.ParseInt(type) is { } number ? number : -1;

            // Другий варіант може бути зовсім не описаний — тоді він повторює
            // перший, а не схлопується в порожню рамку за умовчанням.
            var primary = PlacementFrom(attributes, "");
            var dual = attributes.String("Width_2") == null ? primary : PlacementFrom(attributes, "_2");

            return new SlideScheme.Element(name: attributes.String("Name") ?? "",
                                           rawType: rawType,
                                           imageName: image,
                                           imageMaskName: mask,
                                           textColor: attributes.Color("TextColor"),
                                           hasVariantParameters: attributes.Flag("EnableParamsVariant") ?? false,
                                           placements: new List<SlideScheme.Placement> { primary, dual },
                                           presets: new List<SlideScheme.FXPreset>(presets),
                                           attributes: new Dictionary<string, string>(attributes.Raw));
        }

        /// Другий варіант слайда записано тими самими ключами з хвостом `_2`.
        private static SlideScheme.Placement PlacementFrom(Attributes attributes, string suffix)
        {
            double? Value(string key) => attributes.Number(key + suffix);

            return new SlideScheme.Placement(
                width: Value("Width") ?? 100,
                height: Value("Height") ?? 100,
                indentX: Value("IndentionX") ?? 0,
                indentY: Value("IndentionY") ?? 0,
                anchor: new SlideScheme.Anchor(Truncate(Value("Align") ?? 0)),
                opacity: (Value("Opacity") ?? 255) / 255,
                isEnabled: attributes.Flag("Enabled" + suffix) ?? true,
                shadowOffset: Value("ShadowOffsetPerc") ?? 0,
                shadowBlur: Value("ShadowBlurPerc") ?? 0,
                shadowOpacity: (Value("ShadowOpacity") ?? 0) / 255,
                shadowColor: attributes.Color("ShadowColor" + suffix) ?? SlideStyle.RGBA.Black,
                textAlignment: Value("Alignment") is { } alignment && Enum.IsDefined((SlideScheme.TextAlignment)Truncate(alignment))
                    ? (SlideScheme.TextAlignment)Truncate(alignment) : null,
                textLayout: Value("Layout") is { } layout && Enum.IsDefined((SlideScheme.TextLayout)Truncate(layout))
                    ? (SlideScheme.TextLayout)Truncate(layout) : null);
        }

        /// `Int(double)` Swift: відкидання дробу (на NaN і нескінченності Swift
        /// падає; тут — нуль, щоб битий шаблон не ронив програму).
        private static int Truncate(double value) =>
            double.IsFinite(value) && Math.Abs(value) < int.MaxValue ? (int)value : 0;

        private static SlideScheme.Scene SceneFrom(Attributes attributes) =>
            new(fx: attributes.String("FX") is { } fx && SwiftText.ParseInt(fx) is { } number ? number : 0,
                isAnimated: attributes.Flag("Animation") ?? false,
                fromOpacity: (attributes.Number("FromOpacity") ?? 255) / 255,
                fromScale: (attributes.Number("FromScale") ?? 0) / 100,
                moveFromX: attributes.Number("MoveFromX") ?? 0,
                moveFromY: attributes.Number("MoveFromY") ?? 0,
                delay: (attributes.Number("Delay") ?? 0) / 1000,
                duration: (attributes.Number("TimeLength") ?? 0) / 1000);
    }
}
