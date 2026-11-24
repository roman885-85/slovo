// =============================================================================
//  UiFont.cs — шрифт інтерфейсу: Inter (найближчий до SF Pro на Mac)
// =============================================================================
//  Кеглі — як на Mac у пунктах (1 пункт = 1 точка Avalonia при 100 %).
//  Розміри текстових рядків рахує сам шрифт: висота рядка — з TextLayout.
// =============================================================================

using Avalonia.Media;
using Avalonia.Media.TextFormatting;

namespace Slovo.App;

public static class UiFont
{
    public static readonly FontFamily Family = new("fonts:Inter#Inter");

    static readonly Dictionary<FontWeight, Typeface> Faces = new();

    public static Typeface Face(FontWeight weight = FontWeight.Normal)
    {
        if (!Faces.TryGetValue(weight, out var face))
            Faces[weight] = face = new Typeface(Family, FontStyle.Normal, weight);
        return face;
    }

    public static Typeface Regular => Face(FontWeight.Normal);
    public static Typeface Medium => Face(FontWeight.Medium);
    public static Typeface Semibold => Face(FontWeight.SemiBold);
    public static Typeface Bold => Face(FontWeight.Bold);

    static readonly Dictionary<(FontWeight, double), double> LineHeights = new();

    /// Висота рядка тексту (верх літер — низ «хвостів» + інтервал), як
    /// `ascender − descender + leading` у Mac-версії.
    public static double LineHeight(double size, FontWeight weight = FontWeight.Normal)
    {
        var key = (weight, size);
        if (!LineHeights.TryGetValue(key, out var height))
        {
            using var layout = new TextLayout("Ag", Face(weight), size, null);
            LineHeights[key] = height = Math.Ceiling(layout.Height);
        }
        return height;
    }

    /// Ширина рядка одним рядком.
    public static double Width(string text, double size, FontWeight weight = FontWeight.Normal)
    {
        if (string.IsNullOrEmpty(text)) return 0;
        using var layout = new TextLayout(text, Face(weight), size, null);
        return layout.WidthIncludingTrailingWhitespace;
    }
}
