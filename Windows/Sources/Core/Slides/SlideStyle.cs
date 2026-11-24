// =============================================================================
//  SlideStyle.cs — вигляд слайда і вміст слайда (з Slides/SlideStyle.swift)
// =============================================================================
//  Перенесено разом із теками Settings/Text, бо на SlideStyle спираються
//  IniSettings (колір), ProgramOptions, SlideStyle+IniSettings і PlainTextDocument.
//  Решта тек Slides — окремим кроком.
// =============================================================================

using System.Text.Json;
using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Як виглядає слайд: шрифти, кольори, обведення, поля.
///
/// Окремо від самого вмісту — один і той самий вірш має вміти
/// намалюватися і у вікні передпоказу, і на проекторі, і (пізніше) у кадрі NDI.
public partial record struct SlideStyle
{
    /// Шар тексту (цитата, другий переклад, адреса).
    [JsonConverter(typeof(TextLayerConverter))]
    public record struct TextLayer
    {
        public string FontName;
        public double FontSize;        // у частках висоти слайда, не в пунктах
        public bool IsBold;
        public bool IsItalic;
        public RGBA Color;
        public RGBA OutlineColor;
        /// «Контур» (CBObjOutLineActive) — власний вимикач.
        ///
        /// У `.sch` це два різні атрибути: `QuoteOutLineEnable="true"` і
        /// `QuoteOutLineWidth="2,25"`. Поки вимикач обчислювався як
        /// «товщина більша за нуль», знята галочка стирала підібрану товщину.
        public bool IsOutlined;
        /// «Товщина контуру» (Label39) — у частках висоти слайда. Зберігається
        /// завжди, зокрема поки контур вимкнено.
        public double OutlineThickness;
        public double ShadowRadius;

        /// Товщина, з якою контур малюється: у вимкненого вона нуль.
        public double OutlineWidth
        {
            readonly get => IsOutlined ? OutlineThickness : 0;
            set
            {
                IsOutlined = value > 0;
                // Нуль означає «вимкнути», а не «забути підібране».
                if (value > 0) OutlineThickness = value;
            }
        }

        public TextLayer() : this("Helvetica Neue") { }

        public TextLayer(string fontName = "Helvetica Neue",
                         double fontSize = 0.085,
                         bool isBold = true,
                         bool isItalic = false,
                         RGBA? color = null,
                         RGBA? outlineColor = null,
                         double outlineWidth = 0.004,
                         double shadowRadius = 0.008)
        {
            FontName = fontName;
            FontSize = fontSize;
            IsBold = isBold;
            IsItalic = isItalic;
            Color = color ?? RGBA.White;
            OutlineColor = outlineColor ?? RGBA.Black;
            IsOutlined = outlineWidth > 0;
            OutlineThickness = outlineWidth > 0 ? outlineWidth : 0.004;
            ShadowRadius = shadowRadius;
        }
    }

    /// Колір 0…1 по каналах.
    [JsonConverter(typeof(RGBAConverter))]
    public record struct RGBA(double Red, double Green, double Blue, double Alpha = 1)
    {
        public static readonly RGBA White = new(1, 1, 1);
        public static readonly RGBA Black = new(0, 0, 0);
        public static readonly RGBA Gold = new(1, 0.85, 0.4);
    }

    [JsonConverter(typeof(SwiftStringEnumConverter<VerticalAlignment>))]
    public enum VerticalAlignment
    {
        [JsonStringEnumMemberName("top")] Top,
        [JsonStringEnumMemberName("center")] Center,
        [JsonStringEnumMemberName("bottom")] Bottom,
    }

    /// Зміна слайдів. Різка підміна тексту на великому екрані читається як
    /// ривок, тому за умовчанням — розчинення, як в оригіналі.
    [JsonConverter(typeof(SwiftStringEnumConverter<Transition>))]
    public enum Transition
    {
        // Колишні п'ять — своїми іменами: вони записані в шаблонах і налаштуваннях.
        [JsonStringEnumMemberName("none")] None,
        [JsonStringEnumMemberName("fade")] Fade,
        [JsonStringEnumMemberName("slideLeft")] SlideLeft,
        [JsonStringEnumMemberName("slideUp")] SlideUp,
        [JsonStringEnumMemberName("zoom")] Zoom,
        // Власник: «20 шаблонов эффектов переходов с их настройками».
        [JsonStringEnumMemberName("fadeBlack")] FadeBlack,
        [JsonStringEnumMemberName("slideRight")] SlideRight,
        [JsonStringEnumMemberName("slideDown")] SlideDown,
        [JsonStringEnumMemberName("coverLeft")] CoverLeft,
        [JsonStringEnumMemberName("coverRight")] CoverRight,
        [JsonStringEnumMemberName("coverUp")] CoverUp,
        [JsonStringEnumMemberName("coverDown")] CoverDown,
        [JsonStringEnumMemberName("wipeLeft")] WipeLeft,
        [JsonStringEnumMemberName("wipeRight")] WipeRight,
        [JsonStringEnumMemberName("wipeUp")] WipeUp,
        [JsonStringEnumMemberName("wipeDown")] WipeDown,
        [JsonStringEnumMemberName("zoomOut")] ZoomOut,
        [JsonStringEnumMemberName("spin")] Spin,
        [JsonStringEnumMemberName("flip")] Flip,
        [JsonStringEnumMemberName("blur")] Blur,
        [JsonStringEnumMemberName("bounce")] Bounce,
    }

    /// Крива часу переходу.
    [JsonConverter(typeof(SwiftStringEnumConverter<Easing>))]
    public enum Easing
    {
        [JsonStringEnumMemberName("linear")] Linear,
        [JsonStringEnumMemberName("easeInOut")] EaseInOut,
        [JsonStringEnumMemberName("easeOut")] EaseOut,
        [JsonStringEnumMemberName("spring")] Spring,
    }

    /// Шаблон переходу: ефект зі своєю тривалістю і кривою — те, що
    /// вибирають у «Параметрах» одним пунктом.
    public readonly record struct TransitionPreset(Transition Kind, double Duration, Easing Easing)
    {
        public string Id => Kind.RawValue();
        public string Title => Kind.Title();

        public static readonly IReadOnlyList<TransitionPreset> All =
        [
            new(Transition.None, 0, Easing.Linear),
            new(Transition.Fade, 0.35, Easing.EaseInOut),
            new(Transition.FadeBlack, 0.7, Easing.EaseInOut),
            new(Transition.SlideLeft, 0.4, Easing.EaseOut),
            new(Transition.SlideRight, 0.4, Easing.EaseOut),
            new(Transition.SlideUp, 0.4, Easing.EaseOut),
            new(Transition.SlideDown, 0.4, Easing.EaseOut),
            new(Transition.CoverLeft, 0.45, Easing.EaseOut),
            new(Transition.CoverRight, 0.45, Easing.EaseOut),
            new(Transition.CoverUp, 0.45, Easing.EaseOut),
            new(Transition.CoverDown, 0.45, Easing.EaseOut),
            new(Transition.WipeLeft, 0.5, Easing.Linear),
            new(Transition.WipeRight, 0.5, Easing.Linear),
            new(Transition.WipeUp, 0.5, Easing.Linear),
            new(Transition.WipeDown, 0.5, Easing.Linear),
            new(Transition.Zoom, 0.45, Easing.EaseInOut),
            new(Transition.ZoomOut, 0.45, Easing.EaseInOut),
            new(Transition.Spin, 0.6, Easing.EaseInOut),
            new(Transition.Flip, 0.6, Easing.EaseInOut),
            new(Transition.Blur, 0.5, Easing.EaseInOut),
            new(Transition.Bounce, 0.7, Easing.Spring),
        ];

        public static TransitionPreset Preset(Transition kind) =>
            All.FirstOrDefault(preset => preset.Kind == kind, All[0]);
    }

    [JsonInclude, JsonRequired, JsonPropertyName("name")] public string Name;
    [JsonInclude, JsonRequired, JsonPropertyName("main")] public TextLayer Main;
    [JsonInclude, JsonRequired, JsonPropertyName("secondary")] public TextLayer Secondary;
    [JsonInclude, JsonRequired, JsonPropertyName("reference")] public TextLayer Reference;
    [JsonInclude, JsonRequired, JsonPropertyName("verticalAlignment")] public VerticalAlignment VerticalAlign;
    [JsonInclude, JsonRequired, JsonPropertyName("horizontalInset")] public double HorizontalInset;  // поля в частках ширини
    [JsonInclude, JsonRequired, JsonPropertyName("verticalInset")] public double VerticalInset;
    [JsonInclude, JsonRequired, JsonPropertyName("lineSpacing")] public double LineSpacing;
    [JsonInclude, JsonPropertyName("backgroundImagePath")] public string? BackgroundImagePath;
    [JsonInclude, JsonRequired, JsonPropertyName("backgroundColor")] public RGBA BackgroundColor;
    /// Затемнення підкладки, 0…1.
    ///
    /// За умовчанням НУЛЬ. В автора такого налаштування немає зовсім, і фон він
    /// показує як є. Наші 0,25 клали поверх кожної картинки чорну плівку на
    /// чверть — власник: «изображение неестественно тусклое». Затемнювати фон
    /// має право лише шаблон або конструктор, якщо людина сама попросила.
    [JsonInclude, JsonRequired, JsonPropertyName("dimBackground")] public double DimBackground;
    [JsonInclude, JsonRequired, JsonPropertyName("transition")] public Transition TransitionKind;
    [JsonInclude, JsonRequired, JsonPropertyName("transitionDuration")] public double TransitionDuration;  // секунди
    /// Крива переходу; порожньо — «плавно». Необов'язкове поле: старі
    /// записи стилю його не знають.
    [JsonInclude, JsonPropertyName("transitionEasing")] public Easing? TransitionEasing;

    [JsonIgnore] public readonly Easing EffectiveEasing => TransitionEasing ?? Easing.EaseInOut;

    public SlideStyle() : this("По умолчанию") { }

    public SlideStyle(string name)
    {
        Name = name;
        Main = new TextLayer();
        Secondary = new TextLayer(fontSize: 0.062, isBold: false, isItalic: true, color: new RGBA(0.92, 0.95, 1.0));
        Reference = new TextLayer(fontSize: 0.045, isBold: false, isItalic: true, color: RGBA.Gold, shadowRadius: 0.006);
        VerticalAlign = VerticalAlignment.Center;
        HorizontalInset = 0.06;
        VerticalInset = 0.06;
        LineSpacing = 0.18;
        BackgroundImagePath = null;
        BackgroundColor = new RGBA(0.04, 0.07, 0.13);
        DimBackground = 0;
        TransitionKind = Transition.Fade;
        TransitionDuration = 0.35;
        TransitionEasing = null;
    }
}

/// Підписи й сирі значення перелічень SlideStyle (у Swift — властивості самих enum).
public static class SlideStyleEnums
{
    public static string RawValue(this SlideStyle.Transition transition) => transition switch
    {
        SlideStyle.Transition.None => "none",
        SlideStyle.Transition.Fade => "fade",
        SlideStyle.Transition.SlideLeft => "slideLeft",
        SlideStyle.Transition.SlideUp => "slideUp",
        SlideStyle.Transition.Zoom => "zoom",
        SlideStyle.Transition.FadeBlack => "fadeBlack",
        SlideStyle.Transition.SlideRight => "slideRight",
        SlideStyle.Transition.SlideDown => "slideDown",
        SlideStyle.Transition.CoverLeft => "coverLeft",
        SlideStyle.Transition.CoverRight => "coverRight",
        SlideStyle.Transition.CoverUp => "coverUp",
        SlideStyle.Transition.CoverDown => "coverDown",
        SlideStyle.Transition.WipeLeft => "wipeLeft",
        SlideStyle.Transition.WipeRight => "wipeRight",
        SlideStyle.Transition.WipeUp => "wipeUp",
        SlideStyle.Transition.WipeDown => "wipeDown",
        SlideStyle.Transition.ZoomOut => "zoomOut",
        SlideStyle.Transition.Spin => "spin",
        SlideStyle.Transition.Flip => "flip",
        SlideStyle.Transition.Blur => "blur",
        _ => "bounce",
    };

    /// `Transition(rawValue:)`.
    public static SlideStyle.Transition? TransitionFromRaw(string raw) =>
        Enum.GetValues<SlideStyle.Transition>().Cast<SlideStyle.Transition?>()
            .FirstOrDefault(value => value!.Value.RawValue() == raw);

    public static string Title(this SlideStyle.Transition transition) => transition switch
    {
        SlideStyle.Transition.None => OurWords.T("Без перехода"),
        SlideStyle.Transition.Fade => OurWords.T("Растворение"),
        SlideStyle.Transition.FadeBlack => OurWords.T("Через чёрное"),
        SlideStyle.Transition.SlideLeft => OurWords.T("Сдвиг влево"),
        SlideStyle.Transition.SlideRight => OurWords.T("Сдвиг вправо"),
        SlideStyle.Transition.SlideUp => OurWords.T("Сдвиг вверх"),
        SlideStyle.Transition.SlideDown => OurWords.T("Сдвиг вниз"),
        SlideStyle.Transition.CoverLeft => OurWords.T("Накрытие влево"),
        SlideStyle.Transition.CoverRight => OurWords.T("Накрытие вправо"),
        SlideStyle.Transition.CoverUp => OurWords.T("Накрытие вверх"),
        SlideStyle.Transition.CoverDown => OurWords.T("Накрытие вниз"),
        SlideStyle.Transition.WipeLeft => OurWords.T("Шторка влево"),
        SlideStyle.Transition.WipeRight => OurWords.T("Шторка вправо"),
        SlideStyle.Transition.WipeUp => OurWords.T("Шторка вверх"),
        SlideStyle.Transition.WipeDown => OurWords.T("Шторка вниз"),
        SlideStyle.Transition.Zoom => OurWords.T("Наплыв"),
        SlideStyle.Transition.ZoomOut => OurWords.T("Отдаление"),
        SlideStyle.Transition.Spin => OurWords.T("Поворот"),
        SlideStyle.Transition.Flip => OurWords.T("Переворот"),
        SlideStyle.Transition.Blur => OurWords.T("Размытие"),
        _ => OurWords.T("Падение с отскоком"),
    };

    public static string RawValue(this SlideStyle.Easing easing) => easing switch
    {
        SlideStyle.Easing.Linear => "linear",
        SlideStyle.Easing.EaseInOut => "easeInOut",
        SlideStyle.Easing.EaseOut => "easeOut",
        _ => "spring",
    };

    /// `Easing(rawValue:)`.
    public static SlideStyle.Easing? EasingFromRaw(string raw) =>
        Enum.GetValues<SlideStyle.Easing>().Cast<SlideStyle.Easing?>()
            .FirstOrDefault(value => value!.Value.RawValue() == raw);

    public static string Title(this SlideStyle.Easing easing) => easing switch
    {
        SlideStyle.Easing.Linear => OurWords.T("Равномерно"),
        SlideStyle.Easing.EaseInOut => OurWords.T("Плавно"),
        SlideStyle.Easing.EaseOut => OurWords.T("С замедлением"),
        _ => OurWords.T("Пружиной"),
    };

    /// Частка шляху за часткою часу — для трансляції, де кадри рахуємо самі.
    public static double Apply(this SlideStyle.Easing easing, double t)
    {
        var x = Math.Min(1, Math.Max(0, t));
        switch (easing)
        {
            case SlideStyle.Easing.Linear: return x;
            case SlideStyle.Easing.EaseInOut: return x < 0.5 ? 2 * x * x : 1 - Math.Pow(-2 * x + 2, 2) / 2;
            case SlideStyle.Easing.EaseOut: return 1 - (1 - x) * (1 - x);
            default:
                const double s = 1.70158;
                var y = x - 1;
                return 1 + y * y * ((s + 1) * y + s);
        }
    }

    public static string RawValue(this SlideStyle.VerticalAlignment alignment) => alignment switch
    {
        SlideStyle.VerticalAlignment.Top => "top",
        SlideStyle.VerticalAlignment.Center => "center",
        _ => "bottom",
    };
}

/// Розбір шару тексту терпить відсутні поля: преднастройки лежать
/// читабельним JSON і правляться руками, а файли, записані до появи
/// вимикача, знають лише товщину.
public sealed class TextLayerConverter : JsonConverter<SlideStyle.TextLayer>
{
    public override SlideStyle.TextLayer Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartObject) throw new JsonException("TextLayer: очікувався об'єкт");
        string? fontName = null;
        double? fontSize = null, width = null, shadow = null;
        bool? bold = null, italic = null, outlined = null;
        SlideStyle.RGBA? color = null, outline = null;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
        {
            var key = reader.GetString();
            reader.Read();
            if (reader.TokenType == JsonTokenType.Null) continue;
            switch (key)
            {
                case "fontName": fontName = reader.TokenType == JsonTokenType.String ? reader.GetString() : throw new JsonException(key); break;
                case "fontSize": fontSize = reader.GetDouble(); break;
                case "isBold": bold = reader.GetBoolean(); break;
                case "isItalic": italic = reader.GetBoolean(); break;
                case "color": color = JsonSerializer.Deserialize<SlideStyle.RGBA>(ref reader, options); break;
                case "outlineColor": outline = JsonSerializer.Deserialize<SlideStyle.RGBA>(ref reader, options); break;
                case "outlineWidth": width = reader.GetDouble(); break;
                case "isOutlined": outlined = reader.GetBoolean(); break;
                case "shadowRadius": shadow = reader.GetDouble(); break;
                default: reader.Skip(); break;
            }
        }
        var layer = new SlideStyle.TextLayer();
        layer.FontName = fontName ?? "Helvetica Neue";
        layer.FontSize = fontSize ?? 0.085;
        layer.IsBold = bold ?? true;
        layer.IsItalic = italic ?? false;
        layer.Color = color ?? SlideStyle.RGBA.White;
        layer.OutlineColor = outline ?? SlideStyle.RGBA.Black;
        var thickness = width ?? 0.004;
        layer.OutlineThickness = thickness > 0 ? thickness : 0.004;
        // У файлах, записаних раніше, вимикача немає — його роль грав нуль.
        layer.IsOutlined = outlined ?? (thickness > 0);
        layer.ShadowRadius = shadow ?? 0.008;
        return layer;
    }

    public override void Write(Utf8JsonWriter writer, SlideStyle.TextLayer value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("fontName", value.FontName);
        writer.WriteNumber("fontSize", value.FontSize);
        writer.WriteBoolean("isBold", value.IsBold);
        writer.WriteBoolean("isItalic", value.IsItalic);
        writer.WritePropertyName("color");
        JsonSerializer.Serialize(writer, value.Color, options);
        writer.WritePropertyName("outlineColor");
        JsonSerializer.Serialize(writer, value.OutlineColor, options);
        writer.WriteNumber("outlineWidth", value.OutlineThickness);
        writer.WriteBoolean("isOutlined", value.IsOutlined);
        writer.WriteNumber("shadowRadius", value.ShadowRadius);
        writer.WriteEndObject();
    }
}

/// Колір у JSON — чотири обов'язкові поля, як у синтезованого Codable Swift.
public sealed class RGBAConverter : JsonConverter<SlideStyle.RGBA>
{
    public override SlideStyle.RGBA Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.StartObject) throw new JsonException("RGBA: очікувався об'єкт");
        double? red = null, green = null, blue = null, alpha = null;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
        {
            var key = reader.GetString();
            reader.Read();
            switch (key)
            {
                case "red": red = reader.GetDouble(); break;
                case "green": green = reader.GetDouble(); break;
                case "blue": blue = reader.GetDouble(); break;
                case "alpha": alpha = reader.GetDouble(); break;
                default: reader.Skip(); break;
            }
        }
        if (red is null || green is null || blue is null || alpha is null)
            throw new JsonException("RGBA: бракує каналу");
        return new SlideStyle.RGBA(red.Value, green.Value, blue.Value, alpha.Value);
    }

    public override void Write(Utf8JsonWriter writer, SlideStyle.RGBA value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteNumber("red", value.Red);
        writer.WriteNumber("green", value.Green);
        writer.WriteNumber("blue", value.Blue);
        writer.WriteNumber("alpha", value.Alpha);
        writer.WriteEndObject();
    }
}

/// Вміст одного слайда — те, що реально виводиться на екран.
public record struct Slide
{
    public string MainText;
    public IReadOnlyList<string> SecondaryTexts;
    public string Reference;
    public bool IsBlank;

    public Slide() : this("") { }

    public Slide(string mainText = "", IReadOnlyList<string>? secondaryTexts = null, string reference = "", bool isBlank = false)
    {
        MainText = mainText;
        SecondaryTexts = secondaryTexts ?? Array.Empty<string>();
        Reference = reference;
        IsBlank = isBlank;
    }

    public static readonly Slide Blank = new(isBlank: true);

    public readonly bool Equals(Slide other) =>
        MainText == other.MainText && Reference == other.Reference && IsBlank == other.IsBlank
        && (SecondaryTexts ?? Array.Empty<string>()).SequenceEqual(other.SecondaryTexts ?? Array.Empty<string>());

    public readonly override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(MainText);
        hash.Add(Reference);
        hash.Add(IsBlank);
        foreach (var text in SecondaryTexts ?? Array.Empty<string>()) hash.Add(text);
        return hash.ToHashCode();
    }
}
