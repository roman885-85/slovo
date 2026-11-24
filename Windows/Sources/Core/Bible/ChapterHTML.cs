// =============================================================================
//  ChapterHTML.cs — книга модуля на розділи й вірші (з Bible/ChapterHTML.swift)
// =============================================================================

namespace Slovo.Core;

/// Розбір файла книги модуля на розділи й вірші.
///
/// У «Цитаті з Біблії» структуру книги задано не тегами, а двома рядками-
/// маркерами з ini: `ChapterSign` починає розділ, `VerseSign` — вірш.
/// Тому розбір тут — це пошук маркерів, а не обхід дерева.
public static class ChapterHTML
{
    private static readonly IReadOnlySet<string> StrongTags = new HashSet<string>(StringComparer.Ordinal) { "s" };
    private static readonly IReadOnlySet<string> NoTags = new HashSet<string>(StringComparer.Ordinal);

    /// <param name="expectedChapters">`ChapterQty` з ini. Служить арбітром,
    /// коли розмітка книги допускає два прочитання (див. `ChapterStarts`).</param>
    public static IReadOnlyList<Chapter> Parse(string html, ModuleInfo info, int expectedChapters = 0)
    {
        var dropStrong = info.HasStrongNumbers ? StrongTags : NoTags;
        var starts = ChapterStarts(html, info, expectedChapters);

        if (starts.Count == 0)
        {
            // Маркер розділу не трапився: книга з одного розділу (так буває
            // в небіблійних модулів — збірників проповідей, словників).
            var verses = ParseVerses(html, 0, html.Length, info, dropStrong);
            return verses.Count == 0
                ? Array.Empty<Chapter>()
                : new[] { new Chapter(FirstChapterNumber(info), null, verses) };
        }

        var chapters = new List<Chapter>(starts.Count);
        var number = FirstChapterNumber(info);
        for (var position = 0; position < starts.Count; position++)
        {
            var end = position + 1 < starts.Count ? starts[position + 1].MarkerStart : html.Length;
            var start = starts[position].BodyStart;
            chapters.Add(new Chapter(number,
                                     HeadingText(html, start, end, info, dropStrong),
                                     ParseVerses(html, start, end, info, dropStrong)));
            number += 1;
        }
        return chapters;
    }

    // ── Межі розділів ───────────────────────────────────────────────────────

    private readonly record struct ChapterStart(int MarkerStart, int BodyStart);

    /// Знаходить початки розділів, розбираючи неоднозначність розмітки на користь
    /// того, що модуль сам про себе оголосив.
    ///
    /// Просто рахувати входження `ChapterSign` не можна: в узбецькому модулі тим
    /// самим `<strong>` виділено два заголовки в шапці файла, і Приповісті
    /// розпадаються на 33 розділи замість 31. Але й відкидати входження без
    /// номера в заголовку не можна: 151-й псалом у Синодальному позначено
    /// `A NAME="glava-d"`, без цифр зовсім.
    ///
    /// Тому будуємо обидва прочитання і беремо те, що ближче до `ChapterQty`.
    /// За рівності виграє суворе: зайвий розділ ламає нумерацію всієї книги,
    /// відсутній — лише сам себе.
    private static List<ChapterStart> ChapterStarts(string text, ModuleInfo info, int expectedChapters)
    {
        var chapterMarks = Occurrences(info.ChapterSign, text, 0, text.Length);
        if (chapterMarks.Count == 0) return new List<ChapterStart>();

        var lenient = chapterMarks.Select(mark => new ChapterStart(mark.Start, mark.End)).ToList();

        var verseMarks = Occurrences(info.VerseSign, text, 0, text.Length);
        var allStarts = chapterMarks.Concat(verseMarks).Select(mark => mark.Start).OrderBy(start => start).ToList();

        var strict = new List<ChapterStart>();
        foreach (var mark in chapterMarks)
        {
            // Перший маркер (будь-який), що починається не раніше кінця цього.
            var at = allStarts.BinarySearch(mark.End);
            if (at < 0) at = ~at;
            else while (at > 0 && allStarts[at - 1] >= mark.End) at--;
            var headEnd = at < allStarts.Count ? allStarts[at] : text.Length;
            if (headEnd <= mark.End || !HasNumber(text, mark.End, headEnd)) continue;
            strict.Add(new ChapterStart(mark.Start, mark.End));
        }

        if (expectedChapters <= 0) return strict;
        return Math.Abs(lenient.Count - expectedChapters) < Math.Abs(strict.Count - expectedChapters) ? lenient : strict;
    }

    private static bool HasNumber(string text, int start, int end)
    {
        for (var index = start; index < end; index++)
            if (SwiftText.IsNumber(text[index])) return true;
        return false;
    }

    /// Усі входження маркера без урахування регістру, без перекриттів.
    private static List<(int Start, int End)> Occurrences(string marker, string text, int start, int end)
    {
        var found = new List<(int, int)>();
        if (marker.Length == 0) return found;
        var searchFrom = start;
        while (searchFrom < end)
        {
            var at = text.IndexOf(marker, searchFrom, end - searchFrom, StringComparison.OrdinalIgnoreCase);
            if (at < 0) break;
            found.Add((at, at + marker.Length));
            searchFrom = at + marker.Length;
        }
        return found;
    }

    // ── Вірші ───────────────────────────────────────────────────────────────

    private static int FirstChapterNumber(ModuleInfo info) => info.ChapterZero ? 0 : 1;

    private static List<Verse> ParseVerses(string source, int start, int end, ModuleInfo info, IReadOnlySet<string> dropContentOf)
    {
        var verses = new List<Verse>();
        var fallbackNumber = 1;

        var marks = Occurrences(info.VerseSign, source, start, end);
        if (marks.Count == 0) return verses;

        for (var position = 0; position < marks.Count; position++)
        {
            var bodyEnd = position + 1 < marks.Count ? marks[position + 1].Start : end;
            var bodyStart = marks[position].End;

            var leading = LeadingNumber(source, bodyStart, bodyEnd);
            int number;
            if (leading is { } found)
            {
                number = found.Number;
                bodyStart = found.After;
            }
            else
            {
                number = fallbackNumber;
            }
            fallbackNumber = number + 1;

            var text = HTMLText.Plain(source, bodyStart, bodyEnd, dropContentOf);
            if (text.Length == 0) continue;
            verses.Add(new Verse(number, text));
        }
        return verses;
    }

    /// Зчитує номер вірша одразу за маркером і з'їдає закривальний тег,
    /// якщо номер було обгорнуто в нього (`<sup>12</sup>текст`).
    private static (int Number, int After)? LeadingNumber(string body, int start, int end)
    {
        var cursor = start;
        while (cursor < end && (char.IsWhiteSpace(body[cursor]) || body[cursor] == (char)0x200B)) cursor++;

        var digitsStart = cursor;
        while (cursor < end && SwiftText.IsNumber(body[cursor])) cursor++;
        if (SwiftText.ParseInt(body[digitsStart..cursor]) is not { } number) return null;

        var lookahead = cursor;
        while (lookahead < end && char.IsWhiteSpace(body[lookahead])) lookahead++;
        if (lookahead < end && body[lookahead] == '<' && lookahead + 1 < end && body[lookahead + 1] == '/')
        {
            var close = body.IndexOf('>', lookahead, end - lookahead);
            if (close >= 0) cursor = close + 1;
        }
        return (number, cursor);
    }

    private static string? HeadingText(string html, int start, int end, ModuleInfo info, IReadOnlySet<string> dropContentOf)
    {
        if (info.VerseSign.Length == 0) return null;
        var firstVerse = html.IndexOf(info.VerseSign, start, end - start, StringComparison.OrdinalIgnoreCase);
        if (firstVerse < 0) return null;
        var head = HTMLText.Plain(html, start, firstVerse, dropContentOf);
        // У шапці розділу зазвичай лежить лише його номер — як заголовок він марний.
        var meaningful = head.Any(c => !SwiftText.IsNumber(c) && !char.IsWhiteSpace(c) && c != '=' && c != '"');
        return meaningful ? head : null;
    }
}
