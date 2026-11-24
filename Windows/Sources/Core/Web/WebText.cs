// =============================================================================
//  WebText.cs — пошук у рядку так, як його роблять Swift-джерела теки Web
// =============================================================================
//  `range(of:options:range:)` зі Swift — у відступах UTF-16: межі шукаються
//  щоразу заново за вже зміненим рядком (див. WebSlideParameters.Write), тож
//  тримати індекси через правку не доводиться ніде.
// =============================================================================

namespace Slovo.Core;

/// Відрізок рядка: від `Start` включно до `End` виключно (як `Range<String.Index>`).
public readonly record struct TextSpan(int Start, int End)
{
    public int Length => End - Start;
    public bool Contains(int index) => index >= Start && index < End;
}

internal static class WebText
{
    /// `range(of:options:range:)`: `ignoreCase` — `.caseInsensitive`, `backwards` — `.backwards`.
    public static TextSpan? Find(string text, string needle, int from = 0, int to = -1,
                                 bool ignoreCase = false, bool backwards = false)
    {
        if (to < 0) to = text.Length;
        from = Math.Max(0, from);
        to = Math.Min(text.Length, to);
        if (needle.Length == 0 || to - from < needle.Length) return null;
        var comparison = ignoreCase ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var at = backwards
            ? text.LastIndexOf(needle, to - 1, to - from, comparison)
            : text.IndexOf(needle, from, to - from, comparison);
        return at < 0 ? null : new TextSpan(at, at + needle.Length);
    }

    /// Рядки так, як їх ріже Swift `split(…, whereSeparator: \.isNewline)`: «\r\n» —
    /// один перенос (у Swift це один знак), а не два.
    public static List<string> Lines(string text, bool omitEmpty)
    {
        var lines = new List<string>();
        var start = 0;
        var index = 0;
        while (index <= text.Length)
        {
            if (index < text.Length && !SwiftText.IsNewline(text[index])) { index++; continue; }
            if (!omitEmpty || index > start) lines.Add(text[start..Math.Min(index, text.Length)]);
            if (index < text.Length && text[index] == '\r' && index + 1 < text.Length && text[index + 1] == '\n') index++;
            index++;
            start = index;
        }
        return lines;
    }

    /// Сам перенос рядка в цьому місці: «\r\n» — двома знаками, решта — одним; 0 — не перенос.
    public static int NewlineLength(string text, int index)
    {
        if (index >= text.Length || !SwiftText.IsNewline(text[index])) return 0;
        return text[index] == '\r' && index + 1 < text.Length && text[index + 1] == '\n' ? 2 : 1;
    }

    /// `String(format: "%g", value)` — шість значущих цифр без хвостових нулів.
    public static string G(double value)
    {
        if (double.IsNaN(value)) return "nan";
        if (double.IsInfinity(value)) return value > 0 ? "inf" : "-inf";
        var text = value.ToString("G6", System.Globalization.CultureInfo.InvariantCulture);
        var e = text.IndexOf('E');
        if (e < 0) return text;
        // .NET пише «1E-05», C — «1e-05»: показник щонайменше двома цифрами.
        var mantissa = text[..e];
        var exponent = int.Parse(text[(e + 1)..], System.Globalization.CultureInfo.InvariantCulture);
        return mantissa + "e" + (exponent < 0 ? "-" : "+") + Math.Abs(exponent).ToString("00");
    }

    /// `String(Double)` Swift — найкоротший запис, що читається назад тим самим числом.
    public static string Shortest(double value)
    {
        if (double.IsNaN(value)) return "nan";
        if (double.IsInfinity(value)) return value > 0 ? "inf" : "-inf";
        if (value == Math.Floor(value) && Math.Abs(value) < 1e16)
            return value.ToString("0", System.Globalization.CultureInfo.InvariantCulture) + ".0";
        return value.ToString("R", System.Globalization.CultureInfo.InvariantCulture).Replace("E", "e");
    }
}
