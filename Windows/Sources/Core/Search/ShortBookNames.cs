// =============================================================================
//  ShortBookNames.cs — найкоротші скорочення назв книг (з Search/ShortBookNames.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Найкоротші скорочення назв книг — розділ 5.1.9 посібника.
///
/// Правило розбору: 1) спершу **точний** збіг з одним зі скорочень книги
/// (`ShortName` у `bibleqt.ini`); 2) якщо точного немає — перше скорочення, яке
/// **починається** з уведеного; 3) книги перебираються в тому порядку, в якому
/// лежать у модулі. Порядок «точне поперед префікса» — необхідність: у King
/// James «ez» — це Ezekiel, хоча за самим префіксом першим трапився б Ezra.
///
/// Повне ім'я книги в порівнянні не бере участі — інакше «от» давало б
/// «От Матфея», а посібник обіцяє Об'явлення. Воно лишається запасним
/// варіантом, коли за скороченнями не знайшлося нічого.
public static class ShortBookNames
{
    /// Рядок таблиці: як книгу названо в посібнику і найкоротше скорочення.
    public sealed record Entry(string Name, string Abbreviation)
    {
        public string Id => Abbreviation;
    }

    /// «Русская Синодальная Библия» — сторінка 14 посібника, слово в слово.
    public static readonly IReadOnlyList<Entry> RussianSynodal =
    [
        new("Бытие", "б"), new("Исход", "и"), new("Левит", "л"), new("Числа", "ч"),
        new("Второзаконие", "в"), new("Иисус Навин", "ии"), new("Судьи", "с"), new("Руфь", "р"),
        new("1 Царств", "1ц"), new("2 Царств", "2ц"), new("3 Царств", "3ц"), new("4 Царств", "4ц"),
        new("1 Паралипоменон", "1п"), new("2 Паралипоменон", "2п"), new("Ездра", "е"), new("Неемия", "не"),
        new("Есфирь", "ес"), new("Иов", "ио"), new("Псалтирь", "пс"), new("Притчи", "пр"),
        new("Екклесиаст", "ек"), new("Песня Песней", "пе"),

        new("Исаия", "иса"), new("Иеремия", "ие"), new("Плач Иеремии", "пл"), new("Иезекииль", "иез"),
        new("Даниил", "д"), new("Осия", "о"), new("Иоиль", "иои"), new("Амос", "а"), new("Авдий", "ав"),
        new("Иона", "ион"), new("Михей", "м"), new("Наум", "нау"), new("Аввакум", "авв"), new("Софония", "со"),
        new("Аггей", "аг"), new("Захария", "з"), new("Малахия", "ма"), new("От Матфея", "мт"),
        new("От Марка", "мр"), new("От Луки", "лу"), new("От Иоанна", "ин"), new("Деяния", "де"),

        new("Иакова", "иа"), new("1 Петра", "1пе"), new("2 Петра", "2пе"), new("1 Иоанна", "1и"),
        new("2 Иоанна", "2и"), new("3 Иоанна", "3и"), new("Иуды", "иу"), new("Римлянам", "ри"),
        new("1 Коринфянам", "1к"), new("2 Коринфянам", "2к"), new("Галатам", "г"), new("Ефесянам", "еф"),
        new("Филиппийцам", "ф"), new("Колоссянам", "к"), new("1 Фессалоникийцам", "1ф"),
        // У посібнику в цьому рядку описка: «1 Фессалоникийцам» надруковано двічі,
        // хоча скорочення стоїть «2ф». Назву виправлено, скорочення — як в оригіналі.
        new("2 Фессалоникийцам", "2ф"),
        new("1 Тимофею", "1т"), new("2 Тимофею", "2т"), new("Титу", "т"), new("Филимону", "флм"),
        new("Евреям", "ев"), new("Откровение", "от"),
    ];

    /// «King James Bible» — та сама сторінка посібника.
    public static readonly IReadOnlyList<Entry> KingJames =
    [
        new("Genesis", "ge"), new("Exodus", "ex"), new("Leviticus", "le"), new("Numbers", "nu"),
        new("Deuteronomy", "de"), new("Joshua", "jos"), new("Judges", "judg"), new("Ruth", "ru"),
        new("1 Samuel", "1s"), new("2 Samuel", "2s"), new("1 Kings", "1k"), new("2 Kings", "2k"),
        new("1 Chronicles", "1ch"), new("2 Chronicles", "2ch"), new("Ezra", "ezr"), new("Nehemiah", "ne"),
        new("Esther", "est"), new("Job", "job"), new("Psalms", "ps"), new("Proverbs", "pr"),
        new("Ecclesiastes", "ec"), new("Song of Solomon", "ss"),

        new("Isaiah", "is"), new("Jeremiah", "je"), new("Lamentations", "la"), new("Ezekiel", "ez"),
        new("Daniel", "da"), new("Hosea", "ho"), new("Joel", "joe"), new("Amos", "am"), new("Obadiah", "ob"),
        new("Jonah", "jon"), new("Micah", "mi"), new("Nahum", "na"), new("Habakkuk", "hab"),
        new("Zephaniah", "zep"), new("Haggai", "hag"), new("Zechariah", "ze"), new("Malachi", "mal"),
        new("Matthew", "ma"), new("Mark", "mar"), new("Luke", "lu"), new("John", "jn"), new("Acts", "ac"),

        new("Romans", "ro"), new("1 Corinthians", "1co"), new("2 Corinthians", "2co"), new("Galatians", "ga"),
        new("Ephesians", "ep"), new("Philippians", "ph"), new("Colossians", "col"), new("1 Thessalonians", "1th"),
        new("2 Thessalonians", "2th"), new("1 Timothy", "1ti"), new("2 Timothy", "2ti"), new("Titus", "ti"),
        new("Philemon", "phile"), new("Hebrews", "he"), new("James", "ja"), new("1 Peter", "1pe"),
        new("2 Peter", "2pe"), new("1 John", "1jo"), new("2 John", "2jo"), new("3 John", "3jo"),
        new("Jude", "jud"), new("Revelation", "re"),
    ];

    // ── Розв'язання введеного скорочення ────────────────────────────────────

    /// Книга, яку викликає набраний шматок назви.
    public static BookInfo? Book(string token, IReadOnlyList<BookInfo> books) =>
        IndexMatching(token, books) is { } position ? books[position] : null;

    /// Те саме, але повертається позиція в переданому списку: список буває
    /// відфільтрований «Класом» (1), і позиція там своя.
    public static int? IndexMatching(string token, IReadOnlyList<BookInfo> books)
    {
        var needle = Key(token);
        if (needle.Length == 0) return null;

        // 1. Точне скорочення.
        for (var position = 0; position < books.Count; position++)
            if (books[position].ShortNames.Any(name => Key(name) == needle)) return position;
        // 2. Початок скорочення.
        for (var position = 0; position < books.Count; position++)
            if (books[position].ShortNames.Any(name => Key(name).StartsWith(needle, StringComparison.Ordinal))) return position;
        // 3. Запасний варіант — повне ім'я: сюди доходить лише те, що за
        //    скороченнями не знайшлося.
        for (var position = 0; position < books.Count; position++)
            if (Key(books[position].FullName) == needle) return position;
        for (var position = 0; position < books.Count; position++)
            if (Key(books[position].FullName).StartsWith(needle, StringComparison.Ordinal)) return position;
        return null;
    }

    /// Найкоротше скорочення для кожної книги списку — та сама таблиця, що
    /// надрукована в посібнику, але порахована для поточного модуля.
    public static List<Entry> Shortest(IReadOnlyList<BookInfo> books)
    {
        // Ключі рахуємо один раз: їх близько тисячі, а перебір проганяє по них
        // кожен пробний префікс.
        var keys = books.Select(book => book.ShortNames.Select(Key).Where(key => key.Length > 0).ToList()).ToList();

        int? Resolves(string needle)
        {
            for (var position = 0; position < keys.Count; position++)
                if (keys[position].Contains(needle)) return position;
            for (var position = 0; position < keys.Count; position++)
                if (keys[position].Any(key => key.StartsWith(needle, StringComparison.Ordinal))) return position;
            return null;
        }

        var result = new List<Entry>(books.Count);
        for (var position = 0; position < books.Count; position++)
        {
            string? best = null;
            foreach (var candidate in keys[position])
            {
                var characters = SwiftText.Characters(candidate);
                for (var length = 1; length <= characters.Length; length++)
                {
                    var probe = string.Concat(characters.Take(length));
                    if (Resolves(probe) != position) continue;
                    if (best == null || SwiftText.CharacterCount(probe) < SwiftText.CharacterCount(best)) best = probe;
                    break;
                }
            }
            var book = books[position];
            result.Add(new Entry(book.FullName, best ?? (book.ShortNames.Count > 0 ? book.ShortNames[0] : book.FullName)));
        }
        return result;
    }

    // ── Ключ ────────────────────────────────────────────────────────────────

    /// Ключ порівняння: регістр, діакритика, крапки, пробіли і дефіси значення
    /// не мають — «1Кор.», «1 кор» і «1КОР» це одне й те саме скорочення.
    internal static string Key(string text)
    {
        var folded = SwiftText.Fold(text);
        var result = new StringBuilder(folded.Length);
        foreach (var character in SwiftText.Characters(folded))
            if (SwiftText.IsLetter(character) || SwiftText.IsNumber(character)) result.Append(character);
        return result.ToString();
    }
}
