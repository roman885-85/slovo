// =============================================================================
//  SlideObject.cs — об'єкти конструктора слайда (з Slides/SlideObject.swift)
// =============================================================================

using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Розмір у точках (у Swift — `CGSize`).
public readonly record struct SizeD(double Width, double Height);

/// Прямокутник у точках (у Swift — `CGRect`).
public readonly record struct RectD(double X, double Y, double Width, double Height);

/// Що за об'єкт лежить на слайді. Набір повторює «Конструктор слайда»
/// оригіналу: на слайд кладуть об'єкти, кожен зі своїм місцем і оформленням.
[JsonConverter(typeof(SwiftStringEnumConverter<SlideObjectKind>))]
public enum SlideObjectKind
{
    [JsonStringEnumMemberName("quote")] Quote,                                   // текст основного перекладу (або пісні)
    [JsonStringEnumMemberName("secondaryQuote")] SecondaryQuote,                 // другий переклад
    [JsonStringEnumMemberName("primaryReference")] PrimaryReference,             // адреса основного перекладу
    [JsonStringEnumMemberName("secondaryReference")] SecondaryReference,         // адреса другого перекладу
    [JsonStringEnumMemberName("reference")] Reference,                           // об'єднана адреса
    [JsonStringEnumMemberName("moduleShortNameFirst")] ModuleShortNameFirst,     // коротке ім'я модуля 1
    [JsonStringEnumMemberName("moduleNameFirst")] ModuleNameFirst,               // повне ім'я модуля 1
    [JsonStringEnumMemberName("moduleShortNameSecond")] ModuleShortNameSecond,   // коротке ім'я модуля 2
    [JsonStringEnumMemberName("moduleNameSecond")] ModuleNameSecond,             // повне ім'я модуля 2
    [JsonStringEnumMemberName("songTitle")] SongTitle,                           // назва пісні
    [JsonStringEnumMemberName("previousPage")] PreviousPage,                     // попередня сторінка тексту
    [JsonStringEnumMemberName("nextPage")] NextPage,                             // наступна сторінка тексту
    [JsonStringEnumMemberName("staticText")] StaticText,                         // довільний напис
    [JsonStringEnumMemberName("image")] Image,                                   // картинка: логотип, рамка, плашка
}

public static class SlideObjectKinds
{
    /// Порядок пунктів меню «Додати об'єкт» — рівно той, що в оригіналі.
    public static readonly IReadOnlyList<SlideObjectKind> MenuOrder =
    [
        SlideObjectKind.Quote, SlideObjectKind.SecondaryQuote,
        SlideObjectKind.PrimaryReference, SlideObjectKind.SecondaryReference, SlideObjectKind.Reference,
        SlideObjectKind.ModuleShortNameFirst, SlideObjectKind.ModuleNameFirst,
        SlideObjectKind.ModuleShortNameSecond, SlideObjectKind.ModuleNameSecond,
        SlideObjectKind.SongTitle, SlideObjectKind.PreviousPage, SlideObjectKind.NextPage,
        SlideObjectKind.StaticText, SlideObjectKind.Image,
    ];

    public static string RawValue(this SlideObjectKind kind) => kind switch
    {
        SlideObjectKind.Quote => "quote",
        SlideObjectKind.SecondaryQuote => "secondaryQuote",
        SlideObjectKind.PrimaryReference => "primaryReference",
        SlideObjectKind.SecondaryReference => "secondaryReference",
        SlideObjectKind.Reference => "reference",
        SlideObjectKind.ModuleShortNameFirst => "moduleShortNameFirst",
        SlideObjectKind.ModuleNameFirst => "moduleNameFirst",
        SlideObjectKind.ModuleShortNameSecond => "moduleShortNameSecond",
        SlideObjectKind.ModuleNameSecond => "moduleNameSecond",
        SlideObjectKind.SongTitle => "songTitle",
        SlideObjectKind.PreviousPage => "previousPage",
        SlideObjectKind.NextPage => "nextPage",
        SlideObjectKind.StaticText => "staticText",
        _ => "image",
    };

    /// Ключ підпису в `[SlideConstructorForm]` файла перекладу.
    public static string LanguageKey(this SlideObjectKind kind) => kind switch
    {
        SlideObjectKind.Quote => "NAddQuote",
        SlideObjectKind.SecondaryQuote => "NAddQuoteSecond",
        SlideObjectKind.PrimaryReference => "NAddRefFirst",
        SlideObjectKind.SecondaryReference => "NAddRefSecond",
        SlideObjectKind.Reference => "NAddRef",
        SlideObjectKind.ModuleShortNameFirst => "NAddModuleShortNameFirst",
        SlideObjectKind.ModuleNameFirst => "NAddModuleNameFirst",
        SlideObjectKind.ModuleShortNameSecond => "NAddModuleShortNameSecond",
        SlideObjectKind.ModuleNameSecond => "NAddModuleNameSecond",
        SlideObjectKind.SongTitle => "NAddSongName",
        SlideObjectKind.PreviousPage => "NAddPrevPage",
        SlideObjectKind.NextPage => "NAddNextPage",
        SlideObjectKind.StaticText => "NAddStaticText",
        _ => "NAddImage",
    };

    /// Формулювання взято з пунктів меню конструктора в оригіналі.
    public static string Title(this SlideObjectKind kind) => kind switch
    {
        SlideObjectKind.Quote => OurWords.T("Библейский текст основного перевода (текст песни)"),
        SlideObjectKind.SecondaryQuote => OurWords.T("Библейский текст второго перевода"),
        SlideObjectKind.PrimaryReference => OurWords.T("Адрес основного перевода Библии (название части песни)"),
        SlideObjectKind.SecondaryReference => OurWords.T("Адрес второго перевода Библии"),
        SlideObjectKind.Reference => OurWords.T("Объединенный адрес для двух переводов (название части песни)"),
        SlideObjectKind.ModuleShortNameFirst => OurWords.T("Имя Модуля 1 короткое"),
        SlideObjectKind.ModuleNameFirst => OurWords.T("Имя Модуля 1 полное"),
        SlideObjectKind.ModuleShortNameSecond => OurWords.T("Имя Модуля 2 короткое"),
        SlideObjectKind.ModuleNameSecond => OurWords.T("Имя Модуля 2 полное"),
        SlideObjectKind.SongTitle => OurWords.T("Название песни"),
        SlideObjectKind.PreviousPage => OurWords.T("Пред. страница"),
        SlideObjectKind.NextPage => OurWords.T("След. страница"),
        SlideObjectKind.StaticText => OurWords.T("Статический текст"),
        _ => OurWords.T("Изображение"),
    };

    public static string ShortTitle(this SlideObjectKind kind) => kind switch
    {
        SlideObjectKind.Quote => OurWords.T("Текст"),
        SlideObjectKind.SecondaryQuote => OurWords.T("2-й перевод"),
        SlideObjectKind.PrimaryReference => OurWords.T("Адрес 1"),
        SlideObjectKind.SecondaryReference => OurWords.T("Адрес 2"),
        SlideObjectKind.Reference => OurWords.T("Адрес"),
        SlideObjectKind.ModuleShortNameFirst => OurWords.T("Модуль 1 кор."),
        SlideObjectKind.ModuleNameFirst => OurWords.T("Модуль 1"),
        SlideObjectKind.ModuleShortNameSecond => OurWords.T("Модуль 2 кор."),
        SlideObjectKind.ModuleNameSecond => OurWords.T("Модуль 2"),
        SlideObjectKind.SongTitle => OurWords.T("Название песни"),
        SlideObjectKind.PreviousPage => OurWords.T("Пред. стр."),
        SlideObjectKind.NextPage => OurWords.T("След. стр."),
        SlideObjectKind.StaticText => OurWords.T("Надпись"),
        _ => OurWords.T("Изображение"),
    };

    /// Об'єкти, яким потрібні шрифт і колір.
    public static bool IsTextual(this SlideObjectKind kind) => kind != SlideObjectKind.Image;

    public static string Title(this HorizontalAnchor anchor) => anchor switch
    {
        HorizontalAnchor.Left => OurWords.T("Левая"),
        HorizontalAnchor.Center => OurWords.T("По центру"),
        _ => OurWords.T("Правая"),
    };

    public static string Title(this VerticalAnchor anchor) => anchor switch
    {
        VerticalAnchor.Top => OurWords.T("Верх"),
        VerticalAnchor.Middle => OurWords.T("Середина"),
        _ => "Низ",
    };

    public static string Title(this ParagraphAlignment alignment) => alignment switch
    {
        ParagraphAlignment.Leading => OurWords.T("Влево"),
        ParagraphAlignment.Center => OurWords.T("По центру"),
        _ => OurWords.T("Вправо"),
    };

    /// Підписи рівно як в оригіналі (`FXDirectText0…9`).
    public static string Title(this ObjectAnimation.Direction direction) => direction switch
    {
        ObjectAnimation.Direction.None => "нет",
        ObjectAnimation.Direction.Left => OurWords.T("слева"),
        ObjectAnimation.Direction.TopLeft => OurWords.T("слева, сверху"),
        ObjectAnimation.Direction.Top => OurWords.T("сверху"),
        ObjectAnimation.Direction.TopRight => OurWords.T("сверху, справа"),
        ObjectAnimation.Direction.Right => OurWords.T("справа"),
        ObjectAnimation.Direction.BottomRight => OurWords.T("справа, снизу"),
        ObjectAnimation.Direction.Bottom => OurWords.T("снизу"),
        ObjectAnimation.Direction.BottomLeft => OurWords.T("снизу, слева"),
        _ => OurWords.T("из точки:"),
    };

    /// Зсув початкової позиції в частках полотна.
    public static (double X, double Y) Offset(this ObjectAnimation.Direction direction) => direction switch
    {
        ObjectAnimation.Direction.None => (0, 0),
        ObjectAnimation.Direction.Left => (-1, 0),
        ObjectAnimation.Direction.TopLeft => (-1, -1),
        ObjectAnimation.Direction.Top => (0, -1),
        ObjectAnimation.Direction.TopRight => (1, -1),
        ObjectAnimation.Direction.Right => (1, 0),
        ObjectAnimation.Direction.BottomRight => (1, 1),
        ObjectAnimation.Direction.Bottom => (0, 1),
        ObjectAnimation.Direction.BottomLeft => (-1, 1),
        _ => (0, 0),
    };
}

/// Прив'язка об'єкта до краю полотна. В оригіналі це «Прив'язка по X/Y»:
/// відступ відлічується від того краю, до якого об'єкт прив'язано.
[JsonConverter(typeof(SwiftStringEnumConverter<HorizontalAnchor>))]
public enum HorizontalAnchor
{
    [JsonStringEnumMemberName("left")] Left,
    [JsonStringEnumMemberName("center")] Center,
    [JsonStringEnumMemberName("right")] Right,
}

[JsonConverter(typeof(SwiftStringEnumConverter<VerticalAnchor>))]
public enum VerticalAnchor
{
    [JsonStringEnumMemberName("top")] Top,
    [JsonStringEnumMemberName("middle")] Middle,
    [JsonStringEnumMemberName("bottom")] Bottom,
}

[JsonConverter(typeof(SwiftStringEnumConverter<ParagraphAlignment>))]
public enum ParagraphAlignment
{
    [JsonStringEnumMemberName("leading")] Leading,
    [JsonStringEnumMemberName("center")] Center,
    [JsonStringEnumMemberName("trailing")] Trailing,
}

/// Місце і розмір об'єкта — в частках полотна, а не в пікселях: розмітка
/// переноситься між проектором, NDI і передпоказом без правок.
/// (У Swift — синтезований Codable: усі поля обов'язкові.)
public record struct ObjectFrame
{
    [JsonInclude, JsonRequired, JsonPropertyName("x")] public double X;               // відступ від краю прив'язки, частка ширини
    [JsonInclude, JsonRequired, JsonPropertyName("y")] public double Y;               // відступ від краю прив'язки, частка висоти
    [JsonInclude, JsonRequired, JsonPropertyName("width")] public double Width;       // частка ширини полотна
    [JsonInclude, JsonRequired, JsonPropertyName("height")] public double Height;     // частка висоти полотна
    [JsonInclude, JsonRequired, JsonPropertyName("anchorX")] public HorizontalAnchor AnchorX;
    [JsonInclude, JsonRequired, JsonPropertyName("anchorY")] public VerticalAnchor AnchorY;

    public ObjectFrame() : this(0.06) { }

    public ObjectFrame(double x = 0.06, double y = 0.06, double width = 0.88, double height = 0.6,
                       HorizontalAnchor anchorX = HorizontalAnchor.Center, VerticalAnchor anchorY = VerticalAnchor.Middle)
    {
        X = x;
        Y = y;
        Width = width;
        Height = height;
        AnchorX = anchorX;
        AnchorY = anchorY;
    }

    /// Перерахунок у точки всередині полотна заданого розміру.
    public readonly RectD Rect(SizeD size)
    {
        var w = Width * size.Width;
        var h = Height * size.Height;
        var dx = X * size.Width;
        var dy = Y * size.Height;

        var left = AnchorX switch
        {
            HorizontalAnchor.Left => dx,
            HorizontalAnchor.Center => (size.Width - w) / 2 + dx,
            _ => size.Width - w - dx,
        };
        var top = AnchorY switch
        {
            VerticalAnchor.Top => dy,
            VerticalAnchor.Middle => (size.Height - h) / 2 + dy,
            _ => size.Height - h - dy,
        };
        return new RectD(left, top, w, h);
    }
}

/// Поява об'єкта на слайді. Напрямки і поля повторюють вкладку «Анімація»
/// конструктора оригіналу. Розбір терпить відсутні поля.
public record struct ObjectAnimation
{
    [JsonConverter(typeof(SwiftStringEnumConverter<Direction>))]
    public enum Direction
    {
        [JsonStringEnumMemberName("none")] None,
        [JsonStringEnumMemberName("left")] Left,
        [JsonStringEnumMemberName("topLeft")] TopLeft,
        [JsonStringEnumMemberName("top")] Top,
        [JsonStringEnumMemberName("topRight")] TopRight,
        [JsonStringEnumMemberName("right")] Right,
        [JsonStringEnumMemberName("bottomRight")] BottomRight,
        [JsonStringEnumMemberName("bottom")] Bottom,
        [JsonStringEnumMemberName("bottomLeft")] BottomLeft,
        [JsonStringEnumMemberName("point")] Point,
    }

    [JsonInclude, JsonPropertyName("direction")] public Direction Move = Direction.None;
    [JsonInclude, JsonPropertyName("pointX")] public double PointX = 0.5;        // для «з точки», частка ширини
    [JsonInclude, JsonPropertyName("pointY")] public double PointY = 0.5;
    [JsonInclude, JsonPropertyName("startScale")] public double StartScale = 0.9; // «Початковий», частка від кінцевого розміру
    /// «Початкова» прозорість (Label8, у шаблоні `FromOpacity`). Нуль — зовсім невидимий.
    [JsonInclude, JsonPropertyName("startOpacity")] public double StartOpacity = 0;
    [JsonInclude, JsonPropertyName("duration")] public double Duration = 350;     // мс
    [JsonInclude, JsonPropertyName("delay")] public double Delay = 0;             // мс
    [JsonInclude, JsonPropertyName("animatesScale")] public bool AnimatesScale = false;
    [JsonInclude, JsonPropertyName("animatesOpacity")] public bool AnimatesOpacity = true;

    public ObjectAnimation() { }

    public ObjectAnimation(Direction direction = Direction.None, double pointX = 0.5, double pointY = 0.5,
                           double startScale = 0.9, double startOpacity = 0, double duration = 350, double delay = 0,
                           bool animatesScale = false, bool animatesOpacity = true)
    {
        Move = direction;
        PointX = pointX;
        PointY = pointY;
        StartScale = startScale;
        StartOpacity = startOpacity;
        Duration = duration;
        Delay = delay;
        AnimatesScale = animatesScale;
        AnimatesOpacity = animatesOpacity;
    }

    public static readonly ObjectAnimation Instant =
        new(direction: Direction.None, duration: 0, animatesScale: false, animatesOpacity: false);

    [JsonIgnore]
    public readonly bool IsAnimated => Duration > 0 && (Move != Direction.None || AnimatesScale || AnimatesOpacity);
}

/// Другий набір параметрів об'єкта — розкладка на випадок, коли на слайді
/// показують два переклади (у шаблонах оригіналу — атрибути з хвостом `_2`).
/// Розбір терпить відсутні поля: преднастройки правляться руками.
public record struct ObjectVariant
{
    [JsonInclude, JsonPropertyName("frame")] public ObjectFrame Frame = new();
    [JsonInclude, JsonPropertyName("opacity")] public double Opacity = 1;
    [JsonInclude, JsonPropertyName("isVisible")] public bool IsVisible = true;
    /// «Вирівн. по X» (Label36) — виключка рядків усередині рамки.
    [JsonInclude, JsonPropertyName("alignment")] public ParagraphAlignment Alignment = ParagraphAlignment.Center;
    /// «Вирівн. по Y» (Label37) — у шаблоні це `Layout` і `Layout_2`.
    [JsonInclude, JsonPropertyName("verticalAlignment")] public SlideStyle.VerticalAlignment VerticalAlignment = SlideStyle.VerticalAlignment.Center;
    /// «Тінь» (6.3.7) — у шаблоні `Shadow…Perc` і `Shadow…Perc_2`.
    [JsonInclude, JsonPropertyName("shadow")] public ObjectShadow Shadow = new();
    [JsonInclude, JsonPropertyName("animation")] public ObjectAnimation Animation = new();

    public ObjectVariant() { }

    public ObjectVariant(ObjectFrame frame, double opacity = 1, bool isVisible = true,
                         ParagraphAlignment alignment = ParagraphAlignment.Center,
                         SlideStyle.VerticalAlignment verticalAlignment = SlideStyle.VerticalAlignment.Center,
                         ObjectShadow? shadow = null, ObjectAnimation? animation = null)
    {
        Frame = frame;
        Opacity = opacity;
        IsVisible = isVisible;
        Alignment = alignment;
        VerticalAlignment = verticalAlignment;
        Shadow = shadow ?? new ObjectShadow();
        Animation = animation ?? new ObjectAnimation();
    }
}

/// Об'єкт слайда цілком. Розбір із JSON терпить відсутні поля — файл
/// преднастройки правиться руками, і один незаповнений ключ не має забирати
/// весь об'єкт.
public record struct SlideObject : IJsonOnDeserialized
{
    [JsonInclude, JsonPropertyName("id")] public Guid Id = Guid.NewGuid();
    /// Без імені у файлі — коротка назва виду (у Swift — `kind.shortTitle`).
    [JsonInclude, JsonPropertyName("name")] public string Name = null!;
    [JsonInclude, JsonPropertyName("kind")] public SlideObjectKind Kind = SlideObjectKind.Quote;
    [JsonInclude, JsonPropertyName("isVisible")] public bool IsVisible = true;

    [JsonInclude, JsonPropertyName("frame")] public ObjectFrame Frame = new();
    [JsonInclude, JsonPropertyName("opacity")] public double Opacity = 1;

    // Оформлення тексту
    [JsonInclude, JsonPropertyName("text")] public SlideStyle.TextLayer Text = new();
    [JsonInclude, JsonPropertyName("isUnderlined")] public bool IsUnderlined = false;
    [JsonInclude, JsonPropertyName("alignment")] public ParagraphAlignment Alignment = ParagraphAlignment.Center;
    /// «Вирівн. по Y» для сцени 1. Другій сцені відповідає `SecondVariant`.
    [JsonInclude, JsonPropertyName("verticalAlignment")] public SlideStyle.VerticalAlignment VerticalAlignment = SlideStyle.VerticalAlignment.Center;
    /// «Тінь» для сцени 1.
    [JsonInclude, JsonPropertyName("shadow")] public ObjectShadow Shadow = new();
    [JsonInclude, JsonPropertyName("lineSpacing")] public double LineSpacing = 0.18;
    /// Мінімальний масштаб автодобору: довгий вірш стискається, але не в кашу.
    [JsonInclude, JsonPropertyName("minimumScale")] public double MinimumScale = 0.35;

    // Вміст, що не залежить від вірша
    [JsonInclude, JsonPropertyName("staticText")] public string StaticText = "";
    [JsonInclude, JsonPropertyName("imagePath")] public string? ImagePath = null;
    /// Маска прозорості — в оригіналі окремий файл поруч із зображенням.
    [JsonInclude, JsonPropertyName("maskPath")] public string? MaskPath = null;

    // Понад оригінал: підкладка під об'єктом і розмиття
    [JsonInclude, JsonPropertyName("backgroundColor")] public SlideStyle.RGBA BackgroundColor = new(0, 0, 0, 0);
    [JsonInclude, JsonPropertyName("cornerRadius")] public double CornerRadius = 0;
    [JsonInclude, JsonPropertyName("blurRadius")] public double BlurRadius = 0;

    [JsonInclude, JsonPropertyName("animation")] public ObjectAnimation Animation = new();

    /// Розкладка для слайда з двома перекладами. `null` — об'єкт стоїть на місці
    /// незалежно від того, один переклад показано чи два.
    [JsonInclude, JsonPropertyName("secondVariant")] public ObjectVariant? SecondVariant = null;

    public SlideObject() { }

    public SlideObject(SlideObjectKind kind, string? name = null, ObjectFrame? frame = null, SlideStyle.TextLayer? text = null)
    {
        Kind = kind;
        Name = name ?? kind.ShortTitle();
        Frame = frame ?? new ObjectFrame();
        Text = text ?? new SlideStyle.TextLayer();
    }

    void IJsonOnDeserialized.OnDeserialized() => Name ??= Kind.ShortTitle();

    /// Параметри під поточний склад слайда.
    public readonly ObjectVariant Variant(bool withSecondTranslation)
    {
        if (withSecondTranslation && SecondVariant is { } second) return second;
        return new ObjectVariant(Frame, Opacity, IsVisible, Alignment, VerticalAlignment, Shadow, Animation);
    }
}
