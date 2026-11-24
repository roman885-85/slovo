// =============================================================================
//  Rows.cs — рядок списку, джерело рядків, міри й шрифти списку
// =============================================================================
//  Як на Mac (NativeRow / NativeListMetrics / NativeListStyle): рядок знає
//  лише те, що видно, і будується на вимогу — для видимих двох десятків рядків,
//  а не для всього збірника. Список питає джерело тільки «скільки» й «який
//  рядок за номером»: ні масивів, ні копій пісень. Саме ця форма прибрала
//  гальма на Mac (вибір пісні став у п'ятнадцять разів швидшим).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Slovo.App;

/// Вміст одного рядка — рівно те, що видно.
public struct Row
{
    /// Вузька колонка зліва: номер вірша, номер пісні, скорочення книги.
    public string Lead = "";
    /// Головний текст.
    public string Text = "";
    /// Приписка: підзаголовок пісні, число розділів.
    public string Detail = "";
    public Color? LeadColor;
    public Color? TextColor;
    /// Заливка невибраного рядка чи плитки.
    public Color? Fill;
    /// Риска під рядком — у автора червона під кожним десятим віршем.
    public Color? Rule;
    /// Текст в один рядок, зайве ріжуть три крапки.
    public bool SingleLine;
    public bool Bold;
    public string Tooltip = "";
    /// Позначка після тексту дрібним напівжирним на блідому тлі свого кольору
    /// («Немає», «Застар.» у майстрі імпорту — як бейдж у NativeImportListPage).
    public string Badge = "";
    public Color? BadgeColor;
    /// Значок у першій колонці замість тексту (ім'я з Icons — як `lead` «✎»/«🔒» у NativeTable).
    public string? LeadSymbol;

    public Row() { }
    public Row(string text, string lead = "", string detail = "") { Text = text; Lead = lead; Detail = detail; }
}

/// Звідки список бере дані: число рядків і рядок за номером.
public interface IRowSource
{
    int RowCount { get; }
    Row RowAt(int index);
    /// Меню правої кнопки — будується в мить клацання, не на кожен рядок.
    ContextMenu? MenuAt(int index) => null;
}

/// Відступи, ширини колонок і кольори списку — одні на весь список.
public sealed class ListMetrics
{
    /// Ширина колонки номера. 0 — номер упритул до тексту за своєю шириною.
    public double LeadWidth;
    /// Ширина колонки приписки праворуч. 0 — приписка другим рядком під текстом.
    public double DetailWidth;
    public Thickness Padding = new(10, 5, 10, 5);
    /// Просвіт між головним текстом і припискою знизу.
    public double LineGap = 1;
    public TextAlignment Align = TextAlignment.Left;
    public TextAlignment LeadAlign = TextAlignment.Right;
    public double LeadFontDelta = -2;
    public double TextFontDelta = 1;
    public double DetailFontDelta = -3;
    public Func<Color> LeadColor = () => Palette.SecondaryLabel;
    public Func<Color> TextColor = () => Palette.Label;
    public Func<Color> DetailColor = () => Palette.SecondaryLabel;
    public Func<Color> SelectionColor = () => Palette.Selection;
    public Func<Color> SelectedTextColor = () => Palette.SelectedText;
    public Func<Color> Background = () => Palette.TextBackground;

    public ListMetrics Copy() => (ListMetrics)MemberwiseClone();

    /// Списки вікна «Параметри»: одна колонка номера, одні поля, одна ширина приписки.
    public static ListMetrics Settings(double detailWidth = 200) =>
        new() { LeadWidth = 26, DetailWidth = detailWidth, Padding = new Thickness(8, 4, 8, 4) };

    public static ListMetrics Verses() =>
        new() { LeadWidth = 26, LeadColor = () => Palette.VerseNumber };

    public static ListMetrics Books() =>
        new()
        {
            LeadWidth = 46, LeadAlign = TextAlignment.Left, LeadFontDelta = 0,
            Padding = new Thickness(6, 3, 6, 3), TextFontDelta = 0,
        };

    public static ListMetrics Chapters() =>
        new() { Align = TextAlignment.Center, TextFontDelta = 0, Padding = new Thickness(2, 3, 2, 3) };

    public static ListMetrics Songs() =>
        new() { LeadWidth = 42, LeadFontDelta = -1, Padding = new Thickness(8, 4, 8, 4), TextFontDelta = 0 };
}

/// Готові кеглі й висоти рядків списку — живуть, доки не зміниться кегль.
public sealed class ListStyle
{
    public readonly double FontSize;
    public readonly ListMetrics M;
    public readonly double LeadSize, TextSize, DetailSize;
    public readonly double TextLineHeight, DetailLineHeight, LeadLineHeight, BoldLineHeight;

    public ListStyle(double fontSize, ListMetrics metrics)
    {
        FontSize = fontSize;
        M = metrics;
        LeadSize = Math.Max(7, fontSize + metrics.LeadFontDelta);
        TextSize = Math.Max(7, fontSize + metrics.TextFontDelta);
        DetailSize = Math.Max(7, fontSize + metrics.DetailFontDelta);
        TextLineHeight = UiFont.LineHeight(TextSize);
        BoldLineHeight = UiFont.LineHeight(TextSize, FontWeight.SemiBold);
        DetailLineHeight = UiFont.LineHeight(DetailSize);
        // Номери віршів і розділів у автора — напівжирні округлі цифри.
        LeadLineHeight = UiFont.LineHeight(LeadSize, FontWeight.SemiBold);
    }
}

/// Розмітка одного рядка: де номер, де текст, де приписка. Одна й та сама на
/// малювання і на розрахунок висоти — інакше текст обрізається.
public readonly struct RowLayout
{
    public readonly Rect Lead, Text, Detail;
    public readonly double Height;

    public RowLayout(Row row, double width, ListStyle style, bool measure)
    {
        var m = style.M;
        var left = m.Padding.Left;
        var right = m.Padding.Right;
        var textX = left;
        var lead = default(Rect);
        if (row.Lead.Length > 0 || row.LeadSymbol != null)
        {
            var leadWidth = m.LeadWidth > 0 ? m.LeadWidth
                : Math.Ceiling(UiFont.Width(row.Lead, style.LeadSize, FontWeight.SemiBold)) + 2;
            lead = new Rect(left, m.Padding.Top, leadWidth, style.LeadLineHeight);
            textX = left + leadWidth + 4;
        }
        var detailIsColumn = m.DetailWidth > 0 && row.Detail.Length > 0;
        var detailIsLine = m.DetailWidth == 0 && row.Detail.Length > 0;
        var textWidth = width - textX - right;
        if (detailIsColumn) textWidth -= m.DetailWidth + 4;
        textWidth = Math.Max(1, textWidth);

        double textHeight = row.SingleLine || !measure
            ? style.TextLineHeight
            : TextDraw.Height(row.Text, textWidth, style.TextSize, row.Bold ? FontWeight.SemiBold : FontWeight.Normal);

        Text = new Rect(textX, m.Padding.Top, textWidth, textHeight);
        if (detailIsColumn)
            Detail = new Rect(width - right - m.DetailWidth, m.Padding.Top, m.DetailWidth, style.DetailLineHeight);
        else if (detailIsLine)
            Detail = new Rect(textX, m.Padding.Top + textHeight + m.LineGap, textWidth, style.DetailLineHeight);
        else
            Detail = default;
        Lead = lead;
        var content = Math.Max(Math.Max(Text.Bottom, Detail.Bottom), lead.Bottom);
        Height = Math.Ceiling(content + m.Padding.Bottom);
    }
}
