// =============================================================================
//  ImportKit.cs — дрібниці, з яких складено майстер імпорту (як NativeImportKit)
// =============================================================================
//  Тут немає нічого розумного: абзац, що переноситься по словах і знає свою
//  висоту за ширини; шлях в один рядок із трьома крапками посередині; стовпчик
//  згори донизу; рамка з підписом; рядок «підпис — значення»; ряд кнопок;
//  стовпчик у прокрутці; таблиця із заголовками колонок і смугастими рядками.
//  Усе це потрібне тому, що сторінки майстра — не форма налаштувань: на них
//  сусідять абзаци, списки й кнопки, і висота абзацу залежить від ширини вікна.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Slovo.Core;

namespace Slovo.App;

/// Те, що вміє сказати свою висоту за заданої ширини (ImportMeasurable).
public interface IHeightForWidth
{
    double HeightFor(double width);
}

/// Мірки кнопок AppKit, за якими рахує Mac-розкладка.
public static class MacButton
{
    /// Власна ширина кнопки зі звичайною рамкою (`intrinsicContentSize`, `sizeToFit`).
    /// Виміряно на знімку майстра 1.3.9: «Показати у Finder» 11 пт — рамка 119 точок
    /// при тексті 93,5, кадр кнопки 131 = власна ширина + 16; отже текст + 22.
    public static double Intrinsic(PushButton button) =>
        Math.Ceiling(UiFont.Width(button.Title, button.FontSize > 0 ? button.FontSize : 13)) + 22;
}

/// Підпис NSTextField малює текст за 2 точки від краю своєї рамки — рамки з Mac-розкладки
/// звужуються на стільки ж, щоб текст став там само.
public static class MacLabel
{
    public static Rect Inset(Rect frame) => new(frame.X + 2, frame.Y, Math.Max(0, frame.Width - 4), frame.Height);
}

/// Розмір файла словами (ByteCountFormatter, стиль .file — тисячні одиниці).
public static class ByteSize
{
    public static string Text(long bytes)
    {
        var cyrillic = OurWords.Language is "uk" or "ru";
        var culture = System.Globalization.CultureInfo.CurrentCulture;
        if (bytes < 1000) return bytes + (cyrillic ? " байт" : " bytes");
        if (bytes < 1_000_000) return Math.Round(bytes / 1000.0).ToString("0", culture) + (cyrillic ? " КБ" : " KB");
        if (bytes < 1_000_000_000) return (bytes / 1_000_000.0).ToString("0.0", culture) + (cyrillic ? " МБ" : " MB");
        return (bytes / 1_000_000_000.0).ToString("0.00", culture) + (cyrillic ? " ГБ" : " GB");
    }
}

/// Абзац із переносом по словах (ImportText): висоту рахує за справжньою шириною.
/// Як NSTextField-підпис: текст відступає на 2 точки від країв, а крок рядків —
/// округлені вгору висота над рядком і під ним (SF 11 пт — 14 точок, виміряно на
/// знімку майстра 1.3.9; у Inter без цього 13,3 — абзац виходив нижчим).
public sealed class WrapLabel : Control, IHeightForWidth
{
    const double Pad = 2;
    string _text;
    public double FontSize { get; }
    public FontWeight Weight { get; }
    public Func<Color> Tint { get; set; }
    (string Text, double Width, Color Colour, TextLayout Layout)? _cache;

    public WrapLabel(string text, double size = 12, FontWeight weight = FontWeight.Normal, bool secondary = false, Func<Color>? colour = null)
    {
        _text = text;
        FontSize = size;
        Weight = weight;
        Tint = colour ?? (secondary ? () => Palette.SecondaryLabel : () => Palette.Label);
        Palette.Changed += InvalidateVisual;
    }

    public string Text { get => _text; set { if (_text == value) return; _text = value; InvalidateVisual(); } }

    /// Крок рядків, як у AppKit: ⌈висота над рядком⌉ + ⌈під рядком⌉.
    public static double LineStep(double size) => Math.Ceiling(0.952 * size) + Math.Ceiling(0.242 * size);

    TextLayout Layout(double width, Color colour)
    {
        width = Math.Max(1, width - Pad * 2);
        if (_cache is { } c && c.Text == _text && Math.Abs(c.Width - width) < 0.25 && c.Colour == colour) return c.Layout;
        _cache?.Layout.Dispose();
        var layout = new TextLayout(_text, UiFont.Face(Weight), FontSize, Palette.Brush(colour), TextAlignment.Left, TextWrapping.Wrap,
                                    null, null, FlowDirection.LeftToRight, width, double.PositiveInfinity, LineStep(FontSize));
        _cache = (_text, width, colour, layout);
        return layout;
    }

    public double HeightFor(double width) =>
        _text.Length == 0 ? LineStep(FontSize) : Math.Ceiling(Layout(Math.Max(20, width), Tint()).Height);

    public override void Render(DrawingContext g)
    {
        if (_text.Length == 0 || Bounds.Width <= 0) return;
        using (g.PushClip(new Rect(Bounds.Size)))
            Layout(Bounds.Width, Tint()).Draw(g, new Point(Pad, 0));
    }
}

/// Рядок в одну лінію, зайве ріжеться трьома крапками посередині
/// (importPathLabel): шлях лишається впізнаваним з обох кінців. Шляхи —
/// моноширинним, як на Mac; повний текст — у підказці.
public sealed class PathLabel : Control
{
    static readonly FontFamily Mono = new("Cascadia Mono,Consolas,Menlo,monospace");
    readonly double _size;
    readonly bool _mono;
    string _text = "";
    (string Text, double Width, string Fitted)? _cache;
    public Func<Color> Tint { get; set; } = () => Palette.SecondaryLabel;

    public PathLabel(string text = "", double size = 11, bool monospace = true)
    {
        _size = size;
        _mono = monospace;
        Text = text;
        Palette.Changed += InvalidateVisual;
    }

    public string Text
    {
        get => _text;
        set
        {
            value ??= "";
            if (_text == value && _cache != null) return;
            _text = value;
            _cache = null;
            ToolTip.SetTip(this, value.Length > 0 ? value : null);
            InvalidateVisual();
        }
    }

    Typeface Face => _mono ? new Typeface(Mono) : UiFont.Regular;

    double Measure(string text)
    {
        using var layout = new TextLayout(text, Face, _size, null);
        return layout.WidthIncludingTrailingWhitespace;
    }

    string Cut(int keep) => _text[..((keep + 1) / 2)] + "…" + _text[(_text.Length - keep / 2)..];

    /// Скільки знаків лишити з обох кінців — двійковим пошуком.
    string Fitted(double width)
    {
        if (_cache is { } c && c.Text == _text && Math.Abs(c.Width - width) < 0.5) return c.Fitted;
        var result = _text;
        if (_text.Length > 0 && Measure(_text) > width)
        {
            int lo = 0, hi = _text.Length - 1;
            while (lo < hi)
            {
                var mid = (lo + hi + 1) / 2;
                if (Measure(Cut(mid)) <= width) lo = mid; else hi = mid - 1;
            }
            result = Cut(lo);
        }
        _cache = (_text, width, result);
        return result;
    }

    public override void Render(DrawingContext g)
    {
        // Як NSTextField-підпис: 2 точки від країв.
        var text = Fitted(Math.Max(0, Bounds.Width - 4));
        if (text.Length == 0) return;
        using var layout = new TextLayout(text, Face, _size, Palette.Brush(Tint()));
        using (g.PushClip(new Rect(Bounds.Size)))
            layout.Draw(g, new Point(2, Math.Round((Bounds.Height - layout.Height) / 2)));
    }
}

/// Шар, що малює під дітьми панелі (у Avalonia `Panel.Render` запечатано):
/// ставиться першою дитиною на весь прямокутник панелі.
public sealed class PaintLayer : Control
{
    readonly Action<DrawingContext, Rect> _paint;

    public PaintLayer(Action<DrawingContext, Rect> paint)
    {
        _paint = paint;
        IsHitTestVisible = false;
        Palette.Changed += InvalidateVisual;
    }

    public override void Render(DrawingContext g) => _paint(g, new Rect(Bounds.Size));
}

/// Розпірка: порожнє місце заданої висоти.
public sealed class ImportSpacer : Control
{
    public readonly double Wanted;
    public ImportSpacer(double height) { Wanted = height; }
}

/// Тонка лінія-розділювач (NSBox .separator).
public sealed class Rule : Control
{
    public Rule() { Palette.Changed += InvalidateVisual; }
    public override void Render(DrawingContext g) => g.FillRectangle(Palette.Brush(Palette.Separator), new Rect(Bounds.Size));
}

/// Стовпчик видів згори донизу (ImportStack). Висоту кожного питає за справжньою шириною.
public class ImportStack : LayoutPanel, IHeightForWidth
{
    readonly List<Control> _items = new();
    public double Spacing = 8;
    public Thickness Insets;

    public IReadOnlyList<Control> Items => _items;

    public void Set(IEnumerable<Control> views)
    {
        foreach (var view in _items) Children.Remove(view);
        _items.Clear();
        _items.AddRange(views);
        foreach (var view in _items) Children.Add(view);
        InvalidateMeasure();
    }

    /// Висота виду за цієї ширини.
    public static double HeightOf(Control view, double width) => view switch
    {
        IHeightForWidth measurable => measurable.HeightFor(width),
        ImportSpacer spacer => spacer.Wanted,
        // Підпис моноширинним 11 пт: у AppKit — 13 точок (знімок майстра).
        PathLabel => 13,
        _ => !double.IsNaN(view.Height) && view.Height > 0 ? view.Height : 22,
    };

    public double HeightFor(double width)
    {
        var inner = Math.Max(20, width - Insets.Left - Insets.Right);
        var total = Insets.Top + Insets.Bottom;
        for (var i = 0; i < _items.Count; i++)
        {
            if (!_items[i].IsVisible) continue;
            total += HeightOf(_items[i], inner);
            if (i < _items.Count - 1) total += Spacing;
        }
        return total;
    }

    protected override Size Desired(Size available)
    {
        var width = double.IsInfinity(available.Width) ? Bounds.Width : available.Width;
        return new Size(double.IsInfinity(available.Width) ? 0 : available.Width, HeightFor(width));
    }

    protected override void Arrangement(Size size)
    {
        var inner = Math.Max(20, size.Width - Insets.Left - Insets.Right);
        var top = Insets.Top;
        foreach (var view in _items)
        {
            if (!view.IsVisible) { Place(view, default); continue; }
            var height = HeightOf(view, inner);
            Place(view, new Rect(Insets.Left, top, inner, height));
            top += height + Spacing;
        }
    }
}

/// Рамка з підписом — `TGroupBox` оригіналу (ImportBox): обідок 1, кут 4,
/// підпис 11 пт напівжирний; усередині може стояти абзац.
public sealed class ImportBox : LayoutPanel, IHeightForWidth
{
    readonly PaintLayer _frame = new((g, b) =>
        g.DrawRectangle(null, new Pen(Palette.Brush(Palette.Separator), 1), b.Deflate(0.5), 4, 4));
    readonly BottomCaption _caption;
    readonly ImportStack _body = new() { Spacing = 4 };

    public ImportBox(string title, IEnumerable<Control> rows)
    {
        _caption = new BottomCaption(title) { FontSize = 11, Weight = FontWeight.SemiBold };
        Children.Add(_frame);
        Children.Add(_caption);
        Children.Add(_body);
        _body.Set(rows);
    }

    public double HeightFor(double width) => 22 + _body.HeightFor(width - 20) + 10;

    protected override Size Desired(Size available)
    {
        var width = double.IsInfinity(available.Width) ? Bounds.Width : available.Width;
        return new Size(double.IsInfinity(available.Width) ? 0 : available.Width, HeightFor(width));
    }

    protected override void Arrangement(Size size)
    {
        Place(_frame, new Rect(size));
        Place(_caption, MacLabel.Inset(new Rect(10, 4, Math.Max(0, size.Width - 20), 15)));
        var inner = Math.Max(20, size.Width - 20);
        Place(_body, new Rect(10, 22, inner, _body.HeightFor(inner)));
    }
}

/// Рядок «підпис — значення» для зведення (ImportPair): підпис 170, значення — шлях.
public sealed class ImportPair : LayoutPanel
{
    readonly BottomCaption _name;
    readonly PathLabel _value;

    public ImportPair(string title, string text)
    {
        _name = new BottomCaption(title) { FontSize = 11, Color = () => Palette.Label };
        _value = new PathLabel(text);
        Children.Add(_name);
        Children.Add(_value);
        Height = 16;
    }

    protected override void Arrangement(Size size)
    {
        Place(_name, MacLabel.Inset(new Rect(0, 0, 170, 16)));
        Place(_value, new Rect(178, 0, Math.Max(0, size.Width - 178), 16));
    }
}

/// Ряд кнопок, притиснутих праворуч (ImportRight) чи зліва (ImportLeft).
public sealed class ButtonRow : LayoutPanel
{
    readonly IReadOnlyList<PushButton> _buttons;
    readonly bool _right;

    public ButtonRow(bool right, params PushButton[] buttons)
    {
        _right = right;
        _buttons = buttons;
        foreach (var button in buttons) Children.Add(button);
        Height = 24;
    }

    protected override void Arrangement(Size size)
    {
        if (_right)
        {
            var right = size.Width;
            foreach (var button in _buttons.Reverse())
            {
                var width = Math.Max(60, MacButton.Intrinsic(button) + 16);
                Place(button, new Rect(right - width, 0, width, 22));
                right -= width + 8;
            }
        }
        else
        {
            double left = 0;
            foreach (var button in _buttons)
            {
                var width = Math.Max(80, MacButton.Intrinsic(button) + 16);
                Place(button, new Rect(left, 0, width, 22));
                left += width + 8;
            }
        }
    }
}

/// Стовпчик у прокрутці (ImportScroll): і опис на сотню рядків, і зведення
/// після перенесення бувають вищими за вікно.
public sealed class ImportScroll : LayoutPanel
{
    public readonly ImportStack Body = new() { Insets = new Thickness(0, 0, 0, 8) };
    readonly ScrollViewer _scroll;

    public ImportScroll()
    {
        _scroll = new ScrollViewer
        {
            Content = Body,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            AllowAutoHide = true,
        };
        Children.Add(_scroll);
    }

    protected override void Arrangement(Size size) => Place(_scroll, new Rect(size));

    /// Перерахувати висоту вмісту — після кожної зміни рядків.
    public void RefreshHeight()
    {
        Body.InvalidateMeasure();
        _scroll.Offset = default;
        InvalidateMeasure();
    }
}

/// Таблиця майстра (NSTableView у прокрутці з рамкою .bezelBorder): рядок
/// заголовків колонок 27 + лінія, рядки по 22 точки через один сірі
/// (usesAlternatingRowBackgroundColors — і в порожньому місці під рядками).
/// Колонки — як у стилі .inset: перша з відступом 9, між колонками 17;
/// остання забирає решту ширини (lastColumnOnlyAutoresizingStyle).
/// Галочка, якщо є, — у вузькій першій колонці.
public sealed class ImportTable : LayoutPanel
{
    public const double HeaderHeight = 28, RowHeight = 22;
    const double Inset = 9, Gap = 17;
    public readonly RowList List;
    readonly ListMetrics _metrics;
    readonly Header _header;
    readonly PaintLayer _backdrop;
    readonly double _markWidth, _firstWidth;
    readonly string _firstTitle, _lastTitle;

    /// Сірий рядок через один (alternatingContentBackgroundColors).
    public static Color Alternate => Palette.IsDark ? Color.FromArgb(13, 255, 255, 255) : Color.FromRgb(0xF4, 0xF5, 0xF5);
    /// Обідок прокрутки й лінія під заголовками (знімок редактора нумерації 1.3.9).
    public static Color Border => Palette.IsDark ? Color.FromRgb(0x35, 0x35, 0x35) : Color.FromRgb(0xE5, 0xE5, 0xE5);

    /// Заливка рядка за номером — сірий через один.
    public static Color? Stripe(int index) => index % 2 == 1 ? Alternate : Palette.TextBackground;

    public ImportTable(IRowSource source, double markWidth, double firstWidth, string firstTitle, string lastTitle)
    {
        _markWidth = markWidth;
        _firstWidth = firstWidth;
        _firstTitle = firstTitle;
        _lastTitle = lastTitle;
        // Галочка — у своїй колонці, текст назви — за проміжком між колонками: колонка
        // галочки в списку займає все від краю до назви, квадратик — посередині неї.
        _metrics = new ListMetrics
        {
            LeadWidth = markWidth > 0 ? Inset + markWidth + Gap - 4 : 0,
            DetailWidth = 100,
            Padding = new Thickness(markWidth > 0 ? 0 : Inset, 3, Inset, 3),
            TextFontDelta = 0,
            DetailFontDelta = -1,
            Background = () => Colors.Transparent,
        };
        List = new RowList(_metrics, 12) { ContentInset = new Thickness(0) };
        List.SetUniformHeight(RowHeight);
        List.Source = source;
        _header = new Header(this);
        _backdrop = new PaintLayer(Paint);
        Children.Add(_backdrop);
        Children.Add(_header);
        Children.Add(List);
        // Смуги під рядками стоять там, де кінчився список, — він прокрутився, їх треба перемалювати.
        List.AddHandler(ScrollViewer.ScrollChangedEvent, (_, _) => _backdrop.InvalidateVisual());
    }

    double FirstX => Inset + (_markWidth > 0 ? _markWidth + Gap : 0);

    /// Перечитати рядки (і смуги під ними).
    public void Reload()
    {
        List.Reload();
        _backdrop.InvalidateVisual();
    }
    double LastX => FirstX + _firstWidth + Gap;

    protected override void Arrangement(Size size)
    {
        Place(_backdrop, new Rect(size));
        Place(_header, new Rect(1, 1, Math.Max(0, size.Width - 2), HeaderHeight));
        Place(List, new Rect(1, 1 + HeaderHeight, Math.Max(0, size.Width - 2), Math.Max(0, size.Height - 2 - HeaderHeight)));
        // Остання колонка — від свого початку до правого відступу.
        var detail = Math.Max(60, size.Width - 2 - LastX - Inset);
        if (Math.Abs(detail - _metrics.DetailWidth) > 0.5)
        {
            _metrics.DetailWidth = detail;
            List.Reload();
        }
    }

    void Paint(DrawingContext g, Rect b)
    {
        g.FillRectangle(Palette.Brush(Palette.TextBackground), b);
        // Смуги в порожньому місці під рядками: рядки малює список, тут — те, що нижче.
        var count = List.ItemCount;
        var top = 1 + HeaderHeight + count * RowHeight - List.ScrollOffset;
        for (var i = count; top < b.Height - 1; i++, top += RowHeight)
            if (i % 2 == 1) g.FillRectangle(Palette.Brush(Alternate), new Rect(1, top, Math.Max(0, b.Width - 2), Math.Min(RowHeight, b.Height - 1 - top)));
        g.DrawRectangle(null, new Pen(Palette.Brush(Border), 1), b.Deflate(0.5));
    }

    /// Заголовки колонок: 11 пт, проміжки — тонкими рисками.
    sealed class Header : Control
    {
        readonly ImportTable _table;
        public Header(ImportTable table) { _table = table; Palette.Changed += InvalidateVisual; }

        public override void Render(DrawingContext g)
        {
            var b = new Rect(Bounds.Size);
            g.FillRectangle(Palette.Brush(Palette.TextBackground), b);
            g.FillRectangle(Palette.Brush(Border), new Rect(0, b.Height - 1, b.Width, 1));
            var lh = UiFont.LineHeight(11);
            var y = Math.Round((b.Height - 1 - lh) / 2);
            var first = _table.FirstX;
            var last = _table.LastX;
            TextDraw.Draw(g, _table._firstTitle, new Rect(first, y, Math.Max(1, last - Gap - first), lh), 11, Palette.Label, wrap: false, trim: true);
            TextDraw.Draw(g, _table._lastTitle, new Rect(last, y, Math.Max(1, b.Width - Inset - last), lh), 11, Palette.Label, wrap: false, trim: true);
            var pen = Palette.Brush(Border);
            if (_table._markWidth > 0) g.FillRectangle(pen, new Rect(first - Gap / 2, 5, 1, b.Height - 11));
            g.FillRectangle(pen, new Rect(last - Gap / 2, 5, 1, b.Height - 11));
        }
    }
}
