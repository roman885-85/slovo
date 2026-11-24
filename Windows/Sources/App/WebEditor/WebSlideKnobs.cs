// =============================================================================
//  WebSlideKnobs.cs — ручки оформлення, спільна мова панелі (з Views/WebEditor/WebSlideKnobs.swift)
// =============================================================================
//  Сторінки веб-слайдів тримають оформлення двома способами: наші заготовки — у
//  власному блоці «Налаштування сторінки», будь-яка інша сторінка — у блоках
//  `Слово: налаштування` і `Слово: прив'язка` (WebSlideParameters). Панель про
//  різницю знати не повинна: обидва каталоги зведено тут до `WebSlideKnob`, а
//  різниця схована в `WebSlideSheet`.
// =============================================================================

using System.Globalization;
using Avalonia;
using Slovo.Core;

namespace Slovo.App;

/// Розділ панелі оформлення — п'ять, однакові для сторінок обох устроїв.
public enum WebSlideSection { Content, Text, Layout, Background, Behaviour }

public static class WebSlideSections
{
    public static readonly IReadOnlyList<WebSlideSection> All =
        [WebSlideSection.Content, WebSlideSection.Text, WebSlideSection.Layout, WebSlideSection.Background, WebSlideSection.Behaviour];

    public static string Title(this WebSlideSection section) => section switch
    {
        WebSlideSection.Content => OurWords.T("Что показывать"),
        WebSlideSection.Text => OurWords.T("Текст"),
        WebSlideSection.Layout => OurWords.T("Расположение"),
        WebSlideSection.Background => OurWords.T("Фон и прозрачность"),
        _ => OurWords.T("Поведение"),
    };

    public static string Icon(this WebSlideSection section) => section switch
    {
        WebSlideSection.Content => "list.bullet.rectangle",
        WebSlideSection.Text => "textformat",
        WebSlideSection.Layout => "square.grid.3x3",
        WebSlideSection.Background => "photo",
        _ => "wand.and.rays",
    };

    /// У який розділ лягає група каталогу. Незнайома група — пустота навмисно:
    /// кожна група обох каталогів має бути розкладена явно.
    public static WebSlideSection? Of(string group) => group switch
    {
        "Содержимое" or "Адрес" or "Второй перевод" or "Следующий стих" or "Номера стихов" => WebSlideSection.Content,
        "Шрифт" or "Текст" or "Обводка и тень" => WebSlideSection.Text,
        "Расположение" => WebSlideSection.Layout,
        "Фон" or "Фон страницы" or "Подложка под текстом" => WebSlideSection.Background,
        "Поведение" or "Появление слайда" => WebSlideSection.Behaviour,
        _ => null,
    };
}

/// Ручка оформлення в тому вигляді, в якому її показує панель.
public sealed record WebSlideKnob
{
    public sealed record Choice(string Value, string Title);

    public enum KindTag { Number, Color, ColorRGB, Choice, Toggle, Text }

    public sealed record KnobKind
    {
        public KindTag Tag { get; init; }
        /// Повзунок: одиниця дописується до числа при записі (у заготовок порожня).
        public double Min { get; init; }
        public double Max { get; init; }
        public double Step { get; init; }
        public string Unit { get; init; } = "";
        public IReadOnlyList<Choice> Choices { get; init; } = Array.Empty<Choice>();
        public string On { get; init; } = "";
        public string Off { get; init; } = "";
        public string OnTitle { get; init; } = "";
        public string OffTitle { get; init; } = "";
    }

    public string Name { get; init; } = "";
    public string Title { get; init; } = "";
    /// Підзаголовок усередині розділу — назва групи у вихідному каталозі.
    public string Group { get; init; } = "";
    public WebSlideSection Section { get; init; }
    public string Hint { get; init; } = "";
    public KnobKind Kind { get; init; } = new();

    public string Id => Name;

    // ── Значення туди і назад ─────────────────────────────────────────────────

    /// Чи розуміє ручка це значення. Незрозуміле — не біда: людина могла вписати в
    /// блок своє; панель таку ручку гасить і показує сирий рядок, але з файла не тре.
    public bool Understands(string raw)
    {
        var value = raw.TrimWhitespaces();
        if (!WebSlideParameters.IsWritable(value)) return false;
        return Kind.Tag switch
        {
            KindTag.Number => Number(value) != null,
            KindTag.Color => IsHexColor(value),
            KindTag.ColorRGB => IsColorTriple(value),
            KindTag.Choice => Kind.Choices.Any(choice => choice.Value == value),
            KindTag.Toggle => value == Kind.On || value == Kind.Off,
            _ => true,
        };
    }

    public double? Number(string raw)
    {
        if (Kind.Tag != KindTag.Number) return null;
        var value = raw.TrimWhitespaces();
        if (Kind.Unit.Length == 0) return SwiftText.ParseDouble(value);
        if (!value.EndsWith(Kind.Unit, StringComparison.Ordinal)) return SwiftText.ParseDouble(value);
        return SwiftText.ParseDouble(value[..^Kind.Unit.Length]);
    }

    public string Text(double value) => Kind.Tag == KindTag.Number ? Digits(Clamped(value)) + Kind.Unit : "";

    public double Clamped(double value) => Kind.Tag == KindTag.Number ? Math.Min(Math.Max(value, Kind.Min), Kind.Max) : value;

    /// Повзунок без значення у файлі мусить на чомусь стояти.
    public double FallbackNumber => Kind.Tag != KindTag.Number ? 0 : Kind.Min <= 0 && Kind.Max >= 0 ? 0 : Kind.Min;

    // ── Розбір рядків ─────────────────────────────────────────────────────────

    /// Число в текст без хвостових нулів: «6.0» людина прочитає як «програма насмітила».
    public static string Digits(double value)
    {
        if (value == Math.Round(value, MidpointRounding.AwayFromZero) && Math.Abs(value) < 1e9)
            return ((long)Math.Round(value, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);
        return WebText.G(value);
    }

    public static bool IsHexColor(string value)
    {
        if (!value.StartsWith('#')) return false;
        var digits = value[1..];
        return digits.Length is 3 or 4 or 6 or 8 && digits.All(Uri.IsHexDigit);
    }

    public static bool IsColorTriple(string value)
    {
        var parts = value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length == 3 && parts.All(part => SwiftText.ParseDouble(part) is { } number && number >= 0 && number <= 255);
    }

    // ── Переклад каталогів ────────────────────────────────────────────────────

    /// Ручка заготовки.
    public static WebSlideKnob From(WebSlideTemplates.Parameter parameter)
    {
        var source = parameter.ValueKind;
        var kind = source.Tag switch
        {
            WebSlideTemplates.Parameter.KindTag.Number => new KnobKind { Tag = KindTag.Number, Min = source.Min, Max = source.Max, Step = source.Step },
            WebSlideTemplates.Parameter.KindTag.Color => new KnobKind { Tag = KindTag.Color },
            WebSlideTemplates.Parameter.KindTag.ColorRGB => new KnobKind { Tag = KindTag.ColorRGB },
            WebSlideTemplates.Parameter.KindTag.Choice => new KnobKind { Tag = KindTag.Choice, Choices = source.Options.Select(option => new Choice(option.Value, option.Label)).ToList() },
            // У заготовок підписи вимикача не задано: вони всюди означають «показувати» чи ні.
            WebSlideTemplates.Parameter.KindTag.Toggle => new KnobKind { Tag = KindTag.Toggle, On = source.On, Off = source.Off, OnTitle = OurWords.T("Да"), OffTitle = OurWords.T("Нет") },
            _ => new KnobKind { Tag = KindTag.Text },
        };
        return new WebSlideKnob
        {
            Name = parameter.Id, Title = parameter.Label, Group = parameter.Group,
            Section = WebSlideSections.Of(parameter.Group) ?? WebSlideSection.Behaviour,
            Hint = parameter.Hint, Kind = kind,
        };
    }

    /// Ручка спільного каталогу.
    public static WebSlideKnob From(WebSlideParameter parameter)
    {
        var source = parameter.ValueKind;
        var kind = source.Tag switch
        {
            WebSlideParameter.KindTag.Number => new KnobKind { Tag = KindTag.Number, Min = source.Min, Max = source.Max, Step = source.Step, Unit = source.Unit },
            WebSlideParameter.KindTag.Fraction => new KnobKind { Tag = KindTag.Number, Min = source.Min, Max = source.Max, Step = 0.05 },
            WebSlideParameter.KindTag.Color => new KnobKind { Tag = KindTag.Color },
            WebSlideParameter.KindTag.ColorRGB => new KnobKind { Tag = KindTag.ColorRGB },
            WebSlideParameter.KindTag.Choice => new KnobKind { Tag = KindTag.Choice, Choices = source.Options.Select(option => new Choice(option.Value, option.Title)).ToList() },
            WebSlideParameter.KindTag.Toggle => new KnobKind { Tag = KindTag.Toggle, On = source.On, Off = source.Off, OnTitle = source.OnTitle, OffTitle = source.OffTitle },
            _ => new KnobKind { Tag = KindTag.Text },
        };
        return new WebSlideKnob
        {
            Name = parameter.Name, Title = parameter.Title, Group = parameter.Section.Title(),
            Section = WebSlideSections.Of(parameter.Section.Key()) ?? WebSlideSection.Behaviour,
            Hint = parameter.Hint, Kind = kind,
        };
    }
}

/// Чим у цій сторінці рухається блок тексту: панель питає «чи можна тягнути» і
/// віддає частку ширини й висоти кадру.
public readonly record struct WebSlidePlacement(string? Horizontal = null, string? Vertical = null, string? Anchor = null,
                                                string? OffsetX = null, string? OffsetY = null)
{
    public bool CanDrag => Anchor != null || (Horizontal != null && Vertical != null);

    public static readonly WebSlidePlacement None = new();

    /// Дев'ять точок: частка ширини й висоти кадру.
    public static Point Fraction(int column, int row) =>
        new(new[] { 0.0, 0.5, 1.0 }[Math.Clamp(column, 0, 2)], new[] { 0.0, 0.5, 1.0 }[Math.Clamp(row, 0, 2)]);

    /// Куди стане блок, якщо відпустити мишу в цій точці кадру: найближча точка
    /// прив'язки, а залишок — у тонкий зсув (малий залишок гаситься).
    public static (int Column, int Row, double OffsetX, double OffsetY) Drop(Point point)
    {
        var column = Nearest(point.X);
        var row = Nearest(point.Y);
        var basis = Fraction(column, row);
        return (column, row, Snap((point.X - basis.X) * 100), Snap((point.Y - basis.Y) * 100));
    }

    static int Nearest(double value) => value < 0.25 ? 0 : value < 0.75 ? 1 : 2;

    /// Залишок меншим за дві з половиною сотих кадру вважаємо влучанням.
    static double Snap(double value)
    {
        var limited = Math.Min(Math.Max(value, -40), 40);
        return Math.Abs(limited) < 2.5 ? 0 : Math.Round(limited * 2, MidpointRounding.AwayFromZero) / 2;
    }

    /// Кадр 16:9, вписаний у відведене місце.
    public static Size Frame(Size size)
    {
        const double ratio = 16.0 / 9.0;
        var width = Math.Min(size.Width, size.Height * ratio);
        var height = width / ratio;
        return new Size(Math.Max(width, 1), Math.Max(height, 1));
    }

    /// Точка миші в частках кадру; за краї — на пів кадру, щоб не губити останній сантиметр руху.
    public static Point Fraction(Point location, Size side) =>
        new(Math.Min(Math.Max(location.X / Math.Max(side.Width, 1), -0.5), 1.5),
            Math.Min(Math.Max(location.Y / Math.Max(side.Height, 1), -0.5), 1.5));

    /// Значення притиску для заготовки.
    public static readonly IReadOnlyList<string> FlexValues = ["flex-start", "center", "flex-end"];

    /// Значення точки прив'язки спільного каталогу: спершу вертикаль, потім горизонталь.
    public static string AnchorValue(int column, int row) =>
        new[] { "top", "center", "bottom" }[Math.Clamp(row, 0, 2)] + "-" + new[] { "left", "center", "right" }[Math.Clamp(column, 0, 2)];

    public static int Column(string flex) => FlexValues.ToList().IndexOf(flex) is var i and >= 0 ? i : 1;

    public static (int Column, int Row) Place(string anchor)
    {
        var parts = anchor.Split('-', 2);
        var rows = new Dictionary<string, int> { ["top"] = 0, ["center"] = 1, ["bottom"] = 2 };
        var columns = new Dictionary<string, int> { ["left"] = 0, ["center"] = 1, ["right"] = 2 };
        var row = parts.Length > 0 && rows.TryGetValue(parts[0], out var r) ? r : 1;
        var column = parts.Length > 1 && columns.TryGetValue(parts[1], out var c) ? c : 1;
        return (column, row);
    }
}
