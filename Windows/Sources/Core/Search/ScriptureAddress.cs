// =============================================================================
//  ScriptureAddress.cs — адреса з поля швидкого вибору (з Search/ScriptureAddress.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Адреса місця Писання з поля швидкого вибору (9) — розділ 5.1.9 посібника.
///
/// Формат оригіналу: `[Номер] Книга Розділ НомерПершогоВірша НомерОстанньогоВірша`.
/// Особливі випадки: замість номера вірша стоїть «-» — узяти розділ цілком
/// («иак 4 -»); останнім віршем указано число свідомо більше, ніж є в розділі
/// («333»), — узяти до кінця розділу. Перелік «3,5,7» теж підтримано.
public sealed record ScriptureAddress
{
    public BookInfo Book { get; }
    /// `null`, якщо названо лише книгу: «иак» — відкрити її перший розділ.
    public int? Chapter { get; }
    /// Перший вірш уривка. `null` — вірш не названо.
    public int? FirstVerse { get; }
    /// Останній вірш уривка. `null` — уривок з одного вірша.
    public int? LastVerse { get; }
    /// У рядку стояв «-» замість вірша: потрібен весь розділ.
    public bool WantsWholeChapter { get; }
    /// Явний перелік віршів («3,5,7») — тоді межі не рахуються.
    public IReadOnlyList<int> ListedVerses { get; }

    public ScriptureAddress(BookInfo book, int? chapter, int? firstVerse = null, int? lastVerse = null,
                            bool wantsWholeChapter = false, IReadOnlyList<int>? listedVerses = null)
    {
        Book = book;
        Chapter = chapter;
        FirstVerse = firstVerse;
        LastVerse = lastVerse;
        WantsWholeChapter = wantsWholeChapter;
        ListedVerses = listedVerses ?? Array.Empty<int>();
    }

    // ── Розбір ──────────────────────────────────────────────────────────────

    /// Розбирає рядок в адресу. `null` — книгу впізнати не вдалося.
    public static ScriptureAddress? Parse(string input, IReadOnlyList<BookInfo> books)
    {
        var trimmed = input.TrimWhitespacesAndNewlines();
        if (trimmed.Length == 0) return null;

        // Межу між ім'ям книги і числами шукаємо з кінця — інакше цифра на
        // початку імені («1 кор») поїде в номер розділу.
        var parts = ReferenceParser.Split(trimmed);
        if (ShortBookNames.Book(parts.Book, books) is not { } book) return null;

        var tail = parts.Numbers;
        var numbers = Integers(tail);
        int? chapter = numbers.Count > 0 ? numbers[0] : null;

        // Перелік через кому — це список, а не межі уривка.
        if (tail.Contains(',') || tail.Contains(';'))
        {
            var listed = ReferenceParser.VerseList(DropFirstNumber(tail));
            return new ScriptureAddress(book, chapter, listedVerses: listed);
        }

        var verses = numbers.Skip(1).ToList();
        // «-» без другого числа означає «весь розділ». Між двома числами той
        // самий знак — звичайний діапазон.
        var whole = SwiftText.Characters(tail).Any(IsDash) && verses.Count == 0;

        return new ScriptureAddress(book, chapter,
                                    firstVerse: verses.Count > 0 ? verses[0] : null,
                                    lastVerse: verses.Count > 1 ? verses[1] : null,
                                    wantsWholeChapter: whole);
    }

    // ── Що виділяти ─────────────────────────────────────────────────────────

    /// Номери віршів, які треба виділити, з тих, що є в розділі. Верхня межа
    /// не перевіряється, а просто обрізається по кінцю розділу («333»).
    public List<int> VerseNumbers(IReadOnlyList<int> available)
    {
        if (available.Count == 0) return new List<int>();
        if (WantsWholeChapter) return available.ToList();
        if (ListedVerses.Count > 0) return ListedVerses.Where(available.Contains).ToList();

        if (FirstVerse is not { } first) return new List<int>();
        if (LastVerse is not { } last) return available.Contains(first) ? new List<int> { first } : new List<int>();
        var lower = Math.Min(first, last);
        var upper = Math.Max(first, last);
        return available.Where(verse => verse >= lower && verse <= upper).ToList();
    }

    /// Посилання у звичному вигляді — те, що можна показати підказкою.
    public string DisplayText(IReadOnlyList<int> verses)
    {
        var name = Book.ShortNames.Count > 0 ? Book.ShortNames[0] : Book.FullName;
        if (Chapter is not { } chapter) return name;
        var numbers = ReferenceParser.Format(verses);
        return numbers.Length == 0 ? $"{name} {chapter}" : $"{name} {chapter}:{numbers}";
    }

    // ── ─────────────────────────────────────────────────────────────────────

    private static List<int> Integers(string text)
    {
        var result = new List<int>();
        var digits = new StringBuilder();
        foreach (var character in SwiftText.Characters(text))
        {
            if (SwiftText.IsNumber(character))
            {
                digits.Append(character);
                continue;
            }
            if (SwiftText.ParseInt(digits.ToString()) is { } number) result.Add(number);
            digits.Clear();
        }
        if (SwiftText.ParseInt(digits.ToString()) is { } last) result.Add(last);
        return result;
    }

    /// Хвіст без першого числа: перше — це розділ, далі йдуть вірші.
    private static string DropFirstNumber(string text)
    {
        var characters = SwiftText.Characters(text);
        var start = Array.FindIndex(characters, SwiftText.IsNumber);
        if (start < 0) return text;
        var end = start;
        while (end < characters.Length && SwiftText.IsNumber(characters[end])) end++;
        return string.Concat(characters.Skip(end));
    }

    private static bool IsDash(string character) => character is "-" or "–" or "—";

    public bool Equals(ScriptureAddress? other) =>
        other is not null && Book.Equals(other.Book) && Chapter == other.Chapter && FirstVerse == other.FirstVerse
        && LastVerse == other.LastVerse && WantsWholeChapter == other.WantsWholeChapter
        && ListedVerses.SequenceEqual(other.ListedVerses);

    public override int GetHashCode() => HashCode.Combine(Book, Chapter, FirstVerse, LastVerse, WantsWholeChapter);
}
