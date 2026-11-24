// =============================================================================
//  ReferenceFormat.cs — як збирається адреса на слайді (з Settings/ReferenceFormat.swift)
// =============================================================================

namespace Slovo.Core;

/// Як збирається адреса місця Писання на слайді.
///
/// В оригіналі це вкладка «Слайд» вікна параметрів. Адреса буває двох видів:
/// об'єднана, коли на слайді два переклади й обидві назви зливаються в
/// один рядок виду «Буття(Gen.) 1:1», і окрема, коли в кожного перекладу
/// свій рядок — «Буття 1:1» і «Genesis 1:1». Для кожного з чотирьох випадків
/// окремо задається, брати повну назву книги чи скорочення.
public record struct ReferenceFormat
{
    public enum NameLength
    {
        Long = 0,     // «Буття»
        Short = 1,    // «Бут.»
    }

    /// Об'єднана адреса: основний переклад і другий у дужках.
    public NameLength CombinedMain { get; set; }
    public NameLength CombinedSecondary { get; set; }
    /// Окремі адреси, коли кожен переклад підписано сам по собі.
    public NameLength SeparateMain { get; set; }
    public NameLength SeparateSecondary { get; set; }

    public ReferenceFormat() : this(NameLength.Long) { }

    public ReferenceFormat(NameLength combinedMain = NameLength.Long,
                           NameLength combinedSecondary = NameLength.Short,
                           NameLength separateMain = NameLength.Long,
                           NameLength separateSecondary = NameLength.Long)
    {
        CombinedMain = combinedMain;
        CombinedSecondary = combinedSecondary;
        SeparateMain = separateMain;
        SeparateSecondary = separateSecondary;
    }

    public ReferenceFormat(IniSettings config)
    {
        NameLength Length(string key, NameLength fallback) =>
            config.Int(key, "settings") is { } raw && Enum.IsDefined((NameLength)raw) ? (NameLength)raw : fallback;
        CombinedMain = Length("RefAllMainType", NameLength.Long);
        CombinedSecondary = Length("RefAllSecType", NameLength.Short);
        SeparateMain = Length("RefMainType", NameLength.Long);
        SeparateSecondary = Length("RefSecType", NameLength.Long);
    }

    // ── Збирання ────────────────────────────────────────────────────────────

    public readonly string Name(BookInfo book, NameLength length) => length switch
    {
        NameLength.Long => book.FullName,
        _ => book.ShortNames.Count > 0 ? book.ShortNames[0] : book.FullName,
    };

    /// Хвіст адреси: «1:1», «1:1-5» для віршів підряд, «1:1,3,5» для
    /// розрізнених і «1:1-3,7» для мішанини.
    ///
    /// Власник 19.09.2026: додали до віршів підряд вірш не по порядку — і всі
    /// вірші йшли через кому. Тепер набір ріжеться на проміжки, і кожен
    /// пишеться по-своєму.
    public static string Position(int chapter, IReadOnlyList<int> verses)
    {
        var runs = Spans(verses);
        if (runs.Count == 0) return $"{chapter}";
        return $"{chapter}:" + string.Join(",", runs);
    }

    /// Номери віршів проміжками: [1,2,3,7,9,10] → ["1-3", "7", "9-10"].
    /// Повтори прибираються, порядок — за зростанням.
    public static List<string> Spans(IReadOnlyList<int> verses)
    {
        var sorted = verses.Distinct().OrderBy(verse => verse).ToList();
        var runs = new List<string>();
        var index = 0;
        while (index < sorted.Count)
        {
            var first = sorted[index];
            var last = first;
            while (index + 1 < sorted.Count && sorted[index + 1] == last + 1)
            {
                index += 1;
                last = sorted[index];
            }
            runs.Add(first == last ? $"{first}" : $"{first}-{last}");
            index += 1;
        }
        return runs;
    }

    /// Об'єднана адреса для двох перекладів: «Буття(Gen.) 1:1».
    public readonly string Combined(BookInfo main, BookInfo? secondary, int chapter, IReadOnlyList<int> verses)
    {
        var tail = Position(chapter, verses);
        var head = Name(main, CombinedMain);
        if (secondary == null) return $"{head} {tail}";
        return $"{head}({Name(secondary, CombinedSecondary)}) {tail}";
    }

    /// Окрема адреса для одного перекладу.
    public readonly string Separate(BookInfo book, int chapter, IReadOnlyList<int> verses, bool isSecondary)
    {
        var length = isSecondary ? SeparateSecondary : SeparateMain;
        return $"{Name(book, length)} {Position(chapter, verses)}";
    }
}

public static class ReferenceFormatNameLength
{
    public static int Id(this ReferenceFormat.NameLength length) => (int)length;
    public static string Title(this ReferenceFormat.NameLength length) =>
        length == ReferenceFormat.NameLength.Long ? "Длинный" : "Короткий";
}
