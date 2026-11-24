// =============================================================================
//  References.cs — адреса місця Писання і швидкий вибір
// =============================================================================
//  Перенесено з ReferenceFormat.swift, ReferenceParser.swift і
//  ShortBookNames.swift: адреса на слайді («Буття 1:1-3,7»), розбір рядка
//  швидкого вводу («Ин 3:16», «Быт 1:1-5», «Мф.5:3,5,7», «Genesis 1 1») і
//  правило найкоротшого скорочення книги з посібника VisioBible (5.1.9).
// =============================================================================

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace Slovo;

/// Книга перекладу з її скороченнями — те, що лежить у бібліотеці.
public static class BookNames
{
    /// Скорочення книги — поле `short` бібліотеки, розбите за пробілами.
    public static string[] Shorts(Book book) =>
        book.ShortName.Split(' ', StringSplitOptions.RemoveEmptyEntries);

    /// Перше скорочення — те, що показуємо на кнопці в сітці книг.
    public static string ButtonTitle(Book book)
    {
        var shorts = Shorts(book);
        return shorts.Length > 0 ? shorts[0] : book.Name;
    }
}

/// Як збирається адреса місця Писання на слайді.
public static class ReferenceFormat
{
    /// Хвіст адреси: «1:1», «1:1-5» для віршів підряд, «1:1-3,7» для мішанини.
    public static string Position(int chapter, IEnumerable<int> verses)
    {
        var runs = Spans(verses);
        return runs.Count == 0 ? chapter.ToString(CultureInfo.InvariantCulture)
                               : chapter + ":" + string.Join(",", runs);
    }

    /// Номери віршів проміжками: [1,2,3,7,9,10] → ["1-3", "7", "9-10"].
    public static List<string> Spans(IEnumerable<int> verses)
    {
        var sorted = verses.Distinct().OrderBy(v => v).ToList();
        var runs = new List<string>();
        var index = 0;
        while (index < sorted.Count)
        {
            var first = sorted[index];
            var last = first;
            while (index + 1 < sorted.Count && sorted[index + 1] == last + 1) { index++; last = sorted[index]; }
            runs.Add(first == last ? first.ToString(CultureInfo.InvariantCulture) : first + "-" + last);
            index++;
        }
        return runs;
    }

    public static string Name(Book book, bool shortName) =>
        shortName ? BookNames.ButtonTitle(book) : book.Name;

    /// Об'єднана адреса для двох перекладів: «Буття(Gen.) 1:1».
    public static string Combined(Book main, Book? secondary, int chapter, IEnumerable<int> verses,
                                  bool mainShort, bool secondaryShort)
    {
        var tail = Position(chapter, verses);
        var head = Name(main, mainShort);
        if (secondary == null) return head + " " + tail;
        return head + "(" + Name(secondary, secondaryShort) + ") " + tail;
    }

    /// Окрема адреса для одного перекладу.
    public static string Separate(Book book, int chapter, IEnumerable<int> verses, bool shortName) =>
        Name(book, shortName) + " " + Position(chapter, verses);

    /// Вірші, що йдуть підряд, згортаються в діапазон: 1,2,3,7 → «1-3,7».
    public static string FormatVerses(IEnumerable<int> verses) => string.Join(",", Spans(verses.Where(v => v >= 0)));

    /// Зворотна операція: «1-3, 7» → [1,2,3,7].
    public static List<int> ParseVerses(string text)
    {
        var result = new List<int>();
        foreach (var chunk in text.Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = chunk.Split('-', 2);
            if (parts.Length == 1)
            {
                if (int.TryParse(parts[0].Trim(), out var single) && single >= 0) result.Add(single);
            }
            else if (int.TryParse(parts[0].Trim(), out var from) && int.TryParse(parts[1].Trim(), out var to)
                     && from >= 0 && to >= from)
            {
                var span = Math.Min(to - from, 1000);
                for (var v = from; v <= from + span; v++) result.Add(v);
            }
        }
        return result;
    }
}

/// Посилання, впізнане в рядку швидкого вводу.
public sealed record ParsedReference(Book Book, int Position, int? Chapter, List<int> Verses, int Match)
{
    public const int Exact = 0, Prefix = 1, Initials = 2, Inside = 3;

    public string ShortName => BookNames.ButtonTitle(Book);

    /// Посилання у звичному вигляді: «Ин 3:16-18».
    public string DisplayText
    {
        get
        {
            if (Chapter == null) return ShortName;
            if (Verses.Count == 0) return ShortName + " " + Chapter;
            return ShortName + " " + Chapter + ":" + ReferenceFormat.FormatVerses(Verses);
        }
    }
}

/// Розбір рядка-посилання: спершу відрізає цифровий хвіст, потім шукає книгу.
public static class ReferenceParser
{
    public const int DefaultLimit = 12;
    public const int MaxVerseSpan = 200;

    public static List<ParsedReference> Parse(string input, IReadOnlyList<Book> books, int limit = DefaultLimit)
    {
        var (bookText, numbersText) = Split(input);
        var (chapter, verses) = Numbers(numbersText);
        return BooksMatching(bookText, books, limit)
            .Select(found => new ParsedReference(found.Book, found.Position, chapter, verses, found.Match))
            .ToList();
    }

    /// Однозначна відповідь або нічого — для Enter у полі швидкого вводу.
    public static ParsedReference? Resolve(string input, IReadOnlyList<Book> books)
    {
        var found = Parse(input, books, 2);
        if (found.Count == 0) return null;
        if (found.Count > 1 && found[1].Match == found[0].Match) return null;
        return found[0];
    }

    /// Ділить ввід на ім'я книги і цифровий хвіст. Хвіст шукаємо з кінця,
    /// інакше цифра на початку імені («1Кор», «2Ин») поїде в номер розділу.
    public static (string Book, string Numbers) Split(string input)
    {
        var chars = input.ToCharArray();
        if (chars.Length == 0) return ("", "");
        var cursor = chars.Length - 1;
        while (cursor >= 0 && (char.IsDigit(chars[cursor]) || IsSeparator(chars[cursor]))) cursor--;
        var start = cursor + 1;
        while (start < chars.Length && !char.IsDigit(chars[start])) start++;
        return (new string(chars, 0, start).Trim(), new string(chars, start, chars.Length - start));
    }

    /// Цифровий хвіст: «3:16-18» → (3, [16, 17, 18]).
    public static (int? Chapter, List<int> Verses) Numbers(string text)
    {
        var first = -1;
        for (var i = 0; i < text.Length; i++) if (char.IsDigit(text[i])) { first = i; break; }
        if (first < 0) return (null, new List<int>());
        var end = first;
        while (end < text.Length && char.IsDigit(text[end])) end++;
        int? chapter = int.TryParse(text[first..end], out var number) ? number : null;
        return (chapter, VerseList(text[end..]));
    }

    /// Список віршів з розкритими діапазонами: «3,5,7-9» → [3, 5, 7, 8, 9].
    public static List<int> VerseList(string text)
    {
        var result = new List<int>();
        var digits = new StringBuilder();
        var afterDash = false;

        void Flush()
        {
            if (digits.Length > 0 && int.TryParse(digits.ToString(), out var number))
            {
                if (afterDash && result.Count > 0 && number > result[^1])
                {
                    var from = result[^1];
                    var span = Math.Min(number - from, MaxVerseSpan);
                    for (var v = from + 1; v <= from + span; v++) result.Add(v);
                }
                else result.Add(number);
            }
            digits.Clear();
            afterDash = false;
        }

        foreach (var ch in text)
        {
            if (char.IsDigit(ch)) { digits.Append(ch); continue; }
            if (digits.Length > 0) Flush();
            if (IsDash(ch)) afterDash = true;
        }
        if (digits.Length > 0) Flush();
        return result.Distinct().OrderBy(v => v).ToList();
    }

    public sealed record BookMatch(Book Book, int Position, int Match);

    /// Кандидати на книгу, від найточнішого до найвільнішого.
    public static List<BookMatch> BooksMatching(string token, IReadOnlyList<Book> books, int limit = DefaultLimit)
    {
        var needle = Key(token);
        var found = new List<BookMatch>();
        if (needle.Length == 0) return found;
        var needleWords = Words(token);

        for (var position = 0; position < books.Count; position++)
        {
            var book = books[position];
            int? best = null;
            foreach (var candidate in BookNames.Shorts(book).Append(book.Name))
            {
                var key = Key(candidate);
                if (key.Length == 0) continue;
                int? match = null;
                if (key == needle) match = ParsedReference.Exact;
                else if (key.StartsWith(needle, StringComparison.Ordinal)) match = ParsedReference.Prefix;
                else if (MatchesWordwise(needleWords, Words(candidate))) match = ParsedReference.Initials;
                else if (needle.Length >= 3 && key.Contains(needle, StringComparison.Ordinal)) match = ParsedReference.Inside;
                if (match != null && (best == null || match < best)) best = match;
                if (best == ParsedReference.Exact) break;
            }
            if (best != null) found.Add(new BookMatch(book, position, best.Value));
        }
        return found.OrderBy(f => f.Match).ThenBy(f => f.Position).Take(limit).ToList();
    }

    /// Ключ для порівняння: регістр, діакритика, крапки, дефіси і пробіли
    /// значення не мають — «мф.», «Мф» і «МФ .» це одне й те саме.
    public static string Key(string text)
    {
        var result = new StringBuilder(text.Length);
        foreach (var ch in Fold(text))
        {
            if (char.IsWhiteSpace(ch) || ch == '.' || ch == '-') continue;
            result.Append(ch);
        }
        return result.ToString();
    }

    static string[] Words(string text) =>
        Fold(text).Split(new[] { ' ', '.', '-', '\t' }, StringSplitOptions.RemoveEmptyEntries);

    /// «иис нав» → «Иисус Навин»: кожне слово вводу починає своє слово імені.
    static bool MatchesWordwise(string[] needle, string[] candidate)
    {
        if (needle.Length <= 1 || needle.Length > candidate.Length) return false;
        for (var i = 0; i < needle.Length; i++)
            if (!candidate[i].StartsWith(needle[i], StringComparison.Ordinal)) return false;
        return true;
    }

    /// Малі літери без діакритики («ё» → «е», «ї» лишається своєю літерою).
    public static string Fold(string text)
    {
        var lower = text.ToLowerInvariant().Normalize(NormalizationForm.FormD);
        var result = new StringBuilder(lower.Length);
        foreach (var ch in lower)
        {
            var category = CharUnicodeInfo.GetUnicodeCategory(ch);
            if (category == UnicodeCategory.NonSpacingMark) continue;
            result.Append(ch);
        }
        return result.ToString().Normalize(NormalizationForm.FormC).Replace('ё', 'е');
    }

    static bool IsSeparator(char c) => char.IsWhiteSpace(c) || c is ':' or ',' or ';' or '.' || IsDash(c);
    static bool IsDash(char c) => c is '-' or '–' or '—';
}

/// Найкоротші скорочення назв книг — розділ 5.1.9 посібника: спершу точний
/// збіг зі скороченням, потім перше скорочення, що починається з уведеного,
/// потім повне ім'я.
public static class ShortBookNames
{
    public static int? Index(string token, IReadOnlyList<Book> books)
    {
        var needle = Key(token);
        if (needle.Length == 0) return null;
        for (var i = 0; i < books.Count; i++)
            if (BookNames.Shorts(books[i]).Any(s => Key(s) == needle)) return i;
        for (var i = 0; i < books.Count; i++)
            if (BookNames.Shorts(books[i]).Any(s => Key(s).StartsWith(needle, StringComparison.Ordinal))) return i;
        for (var i = 0; i < books.Count; i++)
            if (Key(books[i].Name) == needle) return i;
        for (var i = 0; i < books.Count; i++)
            if (Key(books[i].Name).StartsWith(needle, StringComparison.Ordinal)) return i;
        return null;
    }

    static string Key(string text)
    {
        var result = new StringBuilder(text.Length);
        foreach (var ch in ReferenceParser.Fold(text))
            if (char.IsLetterOrDigit(ch)) result.Append(ch);
        return result.ToString();
    }
}
