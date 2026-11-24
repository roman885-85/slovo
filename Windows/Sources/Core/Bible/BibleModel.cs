// =============================================================================
//  BibleModel.cs — книга, вірш, розділ, шапка модуля (з Bible/BibleModel.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Одна книга всередині модуля: опис із `bibleqt.ini` або з таблиці
/// `books` модуля MyBible — тексту тут немає.
public sealed record BookInfo
{
    public int Index { get; }                       // порядковий номер у модулі, з нуля
    public string FileName { get; }                 // PathName (у MyBible — номер книги рядком)
    public string FullName { get; }                 // FullName
    public IReadOnlyList<string> ShortNames { get; } // ShortName, розбитий за пробілами
    public int ChapterCount { get; }                // ChapterQty

    /// Наскрізний номер книги в каноні — див. `CanonicalBook`.
    ///
    /// Потрібен, щоб показати поруч два переклади: порядковий номер усередині
    /// модуля для цього не годиться, бо модулі з неканонічними книгами довші
    /// за звичайні і нумерація в них зсунута — «Буття» одного перекладу ставало
    /// навпроти «Товита» іншого.
    public int? CanonicalNumber { get; }

    public int Id => Index;

    /// Перше скорочення — те, що показуємо на кнопці в сітці книг.
    public string ButtonTitle => ShortNames.Count > 0 ? ShortNames[0] : FullName;

    public BookInfo(int index, string fileName, string fullName, IReadOnlyList<string> shortNames,
                    int chapterCount, int? canonicalNumber = null)
    {
        Index = index;
        FileName = fileName;
        FullName = fullName;
        ShortNames = shortNames.ToArray();
        ChapterCount = chapterCount;
        CanonicalNumber = canonicalNumber;
    }

    public BookInfo WithCanonicalNumber(int? number) =>
        new(Index, FileName, FullName, ShortNames, ChapterCount, number);

    public bool Equals(BookInfo? other) =>
        other is not null && Index == other.Index && FileName == other.FileName && FullName == other.FullName
        && ChapterCount == other.ChapterCount && CanonicalNumber == other.CanonicalNumber
        && ShortNames.SequenceEqual(other.ShortNames);

    public override int GetHashCode() => HashCode.Combine(Index, FileName, FullName, ChapterCount, CanonicalNumber);
}

/// Вірш у розібраному вигляді.
public readonly record struct Verse(int Number, string Text)
{
    public int Id => Number;
}

/// Розділ — просто список віршів плюс необов'язковий заголовок.
public sealed record Chapter
{
    public int Number { get; }
    public string? Heading { get; }
    public IReadOnlyList<Verse> Verses { get; }

    public Chapter(int number, string? heading, IReadOnlyList<Verse> verses)
    {
        Number = number;
        Heading = heading;
        Verses = verses;
    }

    public Verse? VerseNumbered(int n)
    {
        foreach (var verse in Verses)
            if (verse.Number == n) return verse;
        return null;
    }

    public bool Equals(Chapter? other) =>
        other is not null && Number == other.Number && Heading == other.Heading && Verses.SequenceEqual(other.Verses);

    public override int GetHashCode() => HashCode.Combine(Number, Heading, Verses.Count);
}

/// Шапка модуля — усе, що описує переклад цілком.
public sealed record ModuleInfo
{
    public string Name { get; set; } = "";              // BibleName
    public string ShortName { get; set; } = "";         // BibleShortName — ярлик вкладки
    public bool IsBible { get; set; } = true;           // Bible = Y/N
    public bool HasOldTestament { get; set; } = true;
    public bool HasNewTestament { get; set; } = true;
    public bool HasApocrypha { get; set; }
    public bool IsGreek { get; set; }
    public string? Language { get; set; }               // Language = ru_RU
    public string? Copyright { get; set; }
    public string? Alphabet { get; set; }
    public bool HasStrongNumbers { get; set; }
    public bool ChapterZero { get; set; }               // нумерація розділів з нуля
    public bool RightToLeft { get; set; }
    public bool ShowVerseNumbers { get; set; } = true;
    public string ChapterSign { get; set; } = "<h1>";   // маркер початку розділу в HTML
    public string VerseSign { get; set; } = "<sup>";    // маркер початку вірша
    public ValueList<string> HtmlFilter { get; set; } = new(); // теги, які модуль просить вирізати
    public Encoding? Encoding { get; set; }

    /// Глибока копія (у Swift — присвоєння значення).
    public ModuleInfo Copy() => this with { HtmlFilter = new ValueList<string>(HtmlFilter) };
}
