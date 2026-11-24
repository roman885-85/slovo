// =============================================================================
//  ReferenceParser.cs — розбір рядка-посилання (з Search/ReferenceParser.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Посилання, впізнане в рядку швидкого вводу: книга модуля плюс те, що
/// вдалося вичитати з цифрового хвоста. Ввід буває неоднозначним («Иоан» — це
/// і Євангеліє, і три послання), тому розбір повертає список таких посилань.
public sealed record ParsedReference
{
    /// Наскільки впевнено впізнано книгу. Порядок значень — це і порядок
    /// підказок у списку: точне скорочення завжди вище за здогадку за підрядком.
    public enum Match
    {
        Exact = 0,      // «Ин» — рівно одне зі скорочень або повне ім'я
        Prefix = 1,     // «Иоа» — початок скорочення або повного імені
        Initials = 2,   // «иис нав» — початки слів підряд
        Inside = 3,     // «коринф» — шматок імені десь усередині
    }

    public BookInfo Book { get; }
    /// `null`, коли ввели лише книгу: «Ин» — відкрити її перший розділ.
    public int? Chapter { get; }
    /// Порожньо, коли вірш не названо: «Ин 3» — весь розділ.
    public IReadOnlyList<int> Verses { get; }
    public Match Kind { get; }

    public int Id => Book.Index;

    public ParsedReference(BookInfo book, int? chapter, IReadOnlyList<int> verses, Match match)
    {
        Book = book;
        Chapter = chapter;
        Verses = verses;
        Kind = match;
    }

    /// Чи є такий розділ у книзі. Число розділів відоме з `ChapterQty`.
    public bool IsChapterValid
    {
        get
        {
            if (Chapter is not { } chapter) return true;
            if (Book.ChapterCount <= 0) return chapter >= 0;
            return chapter >= 0 && chapter <= Book.ChapterCount;
        }
    }

    public string ShortName => Book.ShortNames.Count > 0 ? Book.ShortNames[0] : Book.FullName;

    /// Посилання у звичному вигляді: «Ин 3:16-18».
    public string DisplayText
    {
        get
        {
            if (Chapter is not { } chapter) return ShortName;
            if (Verses.Count == 0) return $"{ShortName} {chapter}";
            return $"{ShortName} {chapter}:{ReferenceParser.Format(Verses)}";
        }
    }

    public bool Equals(ParsedReference? other) =>
        other is not null && Book.Equals(other.Book) && Chapter == other.Chapter && Kind == other.Kind
        && Verses.SequenceEqual(other.Verses);

    public override int GetHashCode() => HashCode.Combine(Book, Chapter, Kind);
}

/// Розбір рядка-посилання: «Ин 3:16», «Быт 1:1-5», «Мф.5:3,5,7», «Genesis 1 1».
///
/// Синтаксис вводу в оригіналі ніде не описано — друкують як звикли, тому
/// розбір нічого не перевіряє, а витягує з рядка все, що в ньому є: спершу
/// відрізає цифровий хвіст, потім шукає книгу за залишком.
public static class ReferenceParser
{
    /// Скільки підказок показувати.
    public const int DefaultLimit = 12;

    /// Діапазон, довший за будь-який розділ Біблії (у Пс 118 — 176 віршів),
    /// означає описку, а не намір.
    public const int MaxVerseSpan = 200;

    // ── Розбір цілком ───────────────────────────────────────────────────────

    public static List<ParsedReference> Parse(string input, TextModule module, int limit = DefaultLimit) =>
        Parse(input, module.Books, limit);

    public static List<ParsedReference> Parse(string input, IReadOnlyList<BookInfo> books, int limit = DefaultLimit)
    {
        var parts = Split(input);
        var tail = Numbers(parts.Numbers);
        return Books(parts.Book, books, limit)
            .Select(found => new ParsedReference(found.Book, tail.Chapter, tail.Verses, found.Match)).ToList();
    }

    /// Однозначна відповідь або нічого: Enter у полі швидкого вводу, посилання
    /// з плану служіння, зовнішня команда.
    public static ParsedReference? Resolve(string input, IReadOnlyList<BookInfo> books)
    {
        var found = Parse(input, books, 2);
        if (found.Count == 0) return null;
        // Дві однаково добрі книги — це не відповідь, а питання до оператора.
        if (found.Count > 1 && found[1].Kind == found[0].Kind) return null;
        return found[0];
    }

    public static ParsedReference? Resolve(string input, TextModule module) => Resolve(input, module.Books);

    // ── Межа між книгою і цифрами ───────────────────────────────────────────

    /// Ділить ввід на ім'я книги і цифровий хвіст. Хвіст шукаємо з кінця,
    /// інакше цифра на початку імені («1Кор», «2Ин») поїде в номер розділу.
    public static (string Book, string Numbers) Split(string input)
    {
        var chars = SwiftText.Characters(input);
        if (chars.Length == 0) return ("", "");

        var cursor = chars.Length - 1;
        while (cursor >= 0 && (SwiftText.IsNumber(chars[cursor]) || IsSeparator(chars[cursor]))) cursor -= 1;

        var start = cursor + 1;
        while (start < chars.Length && !SwiftText.IsNumber(chars[start])) start += 1;

        var book = string.Concat(chars.Take(start)).TrimWhitespaces();
        return (book, string.Concat(chars.Skip(start)));
    }

    /// Цифровий хвіст: «3:16-18» → (3, [16, 17, 18]). Перше число — завжди розділ.
    public static (int? Chapter, List<int> Verses) Numbers(string text)
    {
        var chars = SwiftText.Characters(text);
        var firstDigit = Array.FindIndex(chars, SwiftText.IsNumber);
        if (firstDigit < 0) return (null, new List<int>());
        var end = firstDigit;
        while (end < chars.Length && SwiftText.IsNumber(chars[end])) end++;
        return (SwiftText.ParseInt(string.Concat(chars.Skip(firstDigit).Take(end - firstDigit))),
                VerseList(string.Concat(chars.Skip(end))));
    }

    /// Список віршів з розкритими діапазонами: «3,5,7-9» → [3, 5, 7, 8, 9].
    /// Окрема точка входу потрібна F9: там книгу і розділ уже вибрано.
    public static List<int> VerseList(string text)
    {
        // Як у Swift, числа 64-розрядні: «1-9223372036854775807» не помилка
        // розбору, а діапазон, обрізаний до `MaxVerseSpan`.
        var result = new List<long>();
        var digits = new StringBuilder();
        var afterDash = false;

        void Flush()
        {
            var raw = digits.ToString();
            digits.Clear();
            var dash = afterDash;
            afterDash = false;
            if (!long.TryParse(raw, System.Globalization.NumberStyles.AllowLeadingSign,
                               System.Globalization.CultureInfo.InvariantCulture, out var number)) return;
            if (dash && result.Count > 0 && number > result[^1])
            {
                var from = result[^1];
                var span = Math.Min(number - from, MaxVerseSpan);
                for (var verse = from + 1; verse <= from + span; verse++) result.Add(verse);
            }
            else
            {
                result.Add(number);
            }
        }

        foreach (var character in SwiftText.Characters(text))
        {
            if (SwiftText.IsNumber(character))
            {
                digits.Append(character);
                continue;
            }
            if (digits.Length > 0) Flush();
            if (IsDash(character)) afterDash = true;
        }
        if (digits.Length > 0) Flush();

        // Порядок вводу («7,3») нічого не значить, а виділення віршів — значить.
        return result.Distinct().Where(value => value is >= int.MinValue and <= int.MaxValue)
            .Select(value => (int)value).OrderBy(value => value).ToList();
    }

    /// Згортає номери, що йдуть підряд, назад у діапазон — для підпису.
    public static string Format(IReadOnlyList<int> verses)
    {
        var sorted = verses.Distinct().OrderBy(verse => verse).ToList();
        if (sorted.Count == 0) return "";
        var first = sorted[0];
        var last = sorted[^1];
        if (sorted.Count > 1 && last - first == sorted.Count - 1) return $"{first}-{last}";
        return string.Join(",", sorted);
    }

    // ── Пошук книги ─────────────────────────────────────────────────────────

    public sealed record BookMatch(BookInfo Book, ParsedReference.Match Match);

    /// Кандидати на книгу, від найточнішого до найвільнішого. Крім початку
    /// рядка перевіряємо початки слів і входження всередину імені: повні імена
    /// починаються зі службових слів — «От Иоанна», «К Римлянам», «1-е Петра».
    public static List<BookMatch> Books(string token, IReadOnlyList<BookInfo> books, int limit = DefaultLimit)
    {
        var needle = Key(token);
        if (needle.Length == 0) return new List<BookMatch>();
        var needleWords = Words(token);
        var needleCount = SwiftText.CharacterCount(needle);

        var found = new List<BookMatch>();
        foreach (var book in books)
        {
            ParsedReference.Match? best = null;
            foreach (var candidate in book.ShortNames.Append(book.FullName))
            {
                var candidateKey = Key(candidate);
                if (candidateKey.Length == 0) continue;

                ParsedReference.Match? match;
                if (candidateKey == needle) match = ParsedReference.Match.Exact;
                else if (candidateKey.StartsWith(needle, StringComparison.Ordinal)) match = ParsedReference.Match.Prefix;
                else if (MatchesWordwise(needleWords, Words(candidate))) match = ParsedReference.Match.Initials;
                // Шматок закоротший упізнає що завгодно: «ин» сидить і всередині
                // «Коринфянам», і всередині «Филиппийцам».
                else if (needleCount >= 3 && candidateKey.Contains(needle, StringComparison.Ordinal)) match = ParsedReference.Match.Inside;
                else match = null;

                if (match is { } value && (best == null || value < best)) best = value;
                if (best == ParsedReference.Match.Exact) break;
            }
            if (best is { } result) found.Add(new BookMatch(book, result));
        }

        return found.OrderBy(item => item.Match).ThenBy(item => item.Book.Index).Take(limit).ToList();
    }

    // ── ─────────────────────────────────────────────────────────────────────

    /// Ключ для порівняння: регістр, діакритика, крапки, дефіси і пробіли у
    /// вводі значення не мають — «мф.», «Мф» і «МФ .» це одне й те саме.
    private static string Key(string text)
    {
        var result = new StringBuilder(text.Length);
        foreach (var character in SwiftText.Characters(SwiftText.Fold(text)))
        {
            if (SwiftText.IsWhitespace(character) || character == "." || character == "-") continue;
            result.Append(character);
        }
        return result.ToString();
    }

    private static List<string> Words(string text)
    {
        var words = new List<string>();
        var current = new StringBuilder();
        foreach (var character in SwiftText.Characters(SwiftText.Fold(text)))
        {
            if (SwiftText.IsWhitespace(character) || character == "." || character == "-")
            {
                if (current.Length > 0) words.Add(current.ToString());
                current.Clear();
                continue;
            }
            current.Append(character);
        }
        if (current.Length > 0) words.Add(current.ToString());
        return words;
    }

    /// «иис нав» → «Иисус Навин»: кожне слово вводу починає своє слово імені.
    private static bool MatchesWordwise(List<string> needle, List<string> candidate)
    {
        if (needle.Count <= 1 || needle.Count > candidate.Count) return false;
        for (var index = 0; index < needle.Count; index++)
            if (!candidate[index].StartsWith(needle[index], StringComparison.Ordinal)) return false;
        return true;
    }

    private static bool IsSeparator(string character) =>
        SwiftText.IsWhitespace(character) || character is ":" or "," or ";" or "." || IsDash(character);

    private static bool IsDash(string character) => character is "-" or "–" or "—";
}
