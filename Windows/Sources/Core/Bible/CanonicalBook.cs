// =============================================================================
//  CanonicalBook.cs — наскрізна нумерація книг (з Bible/CanonicalBook.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Наскрізна нумерація книг, спільна для всіх форматів модулів.
///
/// Без неї паралельні переклади роз'їжджаються: в одних модулях 66 книг, а в
/// інших 74–77 — з неканонічними, і «Буття» в одному перекладі стає навпроти
/// «Товита» в іншому. Числа взято з MyBible (Буття = 10, Вихід = 20, …
/// Об'явлення = 730): формат поширений, його нумерація вже стала спільним
/// знаменником.
public static class CanonicalBook
{
    /// Порядок канону і латинські скорочення, за якими впізнаємо книгу в
    /// модулях BibleQuote — там своєї нумерації немає, зате в `ShortName`
    /// майже завжди перелічено й латинські варіанти.
    private static readonly (int Number, string[] Aliases)[] Table =
    [
        (10,  ["ge", "gen", "gn", "genesis"]),
        (20,  ["ex", "exo", "exod", "exodus"]),
        (30,  ["le", "lev", "lv", "leviticus", "levit"]),
        (40,  ["nu", "num", "nm", "numb", "numbers"]),
        (50,  ["de", "deu", "deut", "dt", "deuteron", "deuteronomy"]),
        (60,  ["jos", "josh", "joshua"]),
        (70,  ["jdg", "judg", "judge", "judges"]),
        (80,  ["ru", "rut", "rth", "rt", "ruth"]),
        (90,  ["1sa", "1s", "1sam", "1sm", "1sml", "1samuel"]),
        (100, ["2sa", "2s", "2sam", "2sm", "2sml", "2samuel"]),
        (110, ["1ki", "1k", "1kn", "1kg", "1king", "1kng", "1kings"]),
        (120, ["2ki", "2k", "2kn", "2kg", "2king", "2kng", "2kings"]),
        (130, ["1ch", "1chr", "1chron", "1chronicles", "1par"]),
        (140, ["2ch", "2chr", "2chron", "2chronicles", "2par"]),
        (150, ["ezr", "ezra"]),
        (160, ["ne", "neh", "nehemiah"]),
        (190, ["es", "est", "esth", "esther"]),
        (220, ["job", "jb"]),
        (230, ["ps", "psa", "psalm", "psalms", "psm"]),
        (240, ["pr", "pro", "prov", "proverbs"]),
        (250, ["ec", "ecc", "eccl", "ecclesiastes"]),
        (260, ["so", "son", "song", "sos", "songofsongs", "canticles"]),
        (290, ["isa", "is", "isaiah"]),
        (300, ["jer", "je", "jeremiah"]),
        (310, ["la", "lam", "lamentations"]),
        (330, ["eze", "ezk", "ezek", "ezekiel"]),
        (340, ["da", "dan", "daniel"]),
        (350, ["ho", "hos", "hosea"]),
        (360, ["joe", "jol", "joel"]),
        (370, ["am", "amo", "amos"]),
        (380, ["ob", "oba", "obad", "obadiah"]),
        (390, ["jon", "jnh", "jonah"]),
        (400, ["mic", "mi", "micah"]),
        (410, ["na", "nah", "nahum"]),
        (420, ["hab", "hb", "habakkuk"]),
        (430, ["zep", "zph", "zephaniah"]),
        (440, ["hag", "hg", "haggai"]),
        (450, ["zec", "zch", "zechariah"]),
        (460, ["mal", "ml", "malachi"]),
        (470, ["mt", "mat", "matt", "matthew"]),
        (480, ["mr", "mk", "mar", "mark"]),
        (490, ["lu", "lk", "luk", "luke"]),
        (500, ["joh", "jn", "john"]),
        (510, ["ac", "act", "acts"]),
        (520, ["ro", "rom", "romans"]),
        (530, ["1co", "1cor", "1corinthians"]),
        (540, ["2co", "2cor", "2corinthians"]),
        (550, ["ga", "gal", "galatians"]),
        (560, ["eph", "ep", "ephesians"]),
        (570, ["php", "phil", "philippians"]),
        (580, ["col", "cl", "colossians"]),
        (590, ["1th", "1thes", "1thess", "1thessalonians"]),
        (600, ["2th", "2thes", "2thess", "2thessalonians"]),
        (610, ["1ti", "1tim", "1timothy"]),
        (620, ["2ti", "2tim", "2timothy"]),
        (630, ["tit", "tt", "titus"]),
        (640, ["phm", "phlm", "philemon"]),
        (650, ["heb", "hebrews"]),
        (660, ["jas", "jam", "jm", "james"]),
        (670, ["1pe", "1pet", "1pt", "1peter"]),
        (680, ["2pe", "2pet", "2pt", "2peter"]),
        (690, ["1jo", "1jn", "1john"]),
        (700, ["2jo", "2jn", "2john"]),
        (710, ["3jo", "3jn", "3john"]),
        (720, ["jud", "jde", "jude"]),
        (730, ["re", "rev", "rv", "revelation", "apocalypse"]),

        // Неканонічні книги. Номери взято з тієї самої схеми MyBible; для
        // зіставлення перекладів важливо лише те, що вони сталі й не
        // перетинаються з каноном.
        (165, ["2ezr", "2ездр", "2езд", "2ездра", "2ездры", "1esd", "1esdras"]),
        (468, ["3ezr", "3ездр", "3езд", "3ездра", "3ездры", "2esdras"]),
        (170, ["tob", "тов", "товит", "tobit", "tobias", "tobías"]),
        (180, ["jdt", "иудиф", "иудифь", "иудф", "judith", "judf", "judth", "judit"]),
        (270, ["wis", "прем", "премудр", "премудрсоломона", "премудрсоломон",
               "премсол", "wisdom", "sabiduria"]),
        (280, ["sir", "сир", "сирах", "ecclesiasticus", "eclesiastico"]),
        (315, ["послиер", "послиерем", "послиеремии", "epjer", "letjer"]),
        (320, ["bar", "вар", "варух", "baruch", "baruc"]),
        (462, ["1mac", "1макк", "1мак", "1маккав", "1maccabees", "1mach"]),
        (464, ["2mac", "2макк", "2мак", "2маккав", "2maccabees", "2mach"]),
        (466, ["3mac", "3макк", "3мак", "3маккав", "3maccabees", "3mach"]),
        (790, ["молман", "молитваманассии", "manasseh", "prman"]),

        // Національні скорочення канонічних книг, зустрінуті в модулях
        // користувача: польські, румунські, іспанські — кожне взято зі
        // справжнього `bibleqt.ini`.
        (60,  ["ios", "iosua", "joz", "jozue"]),
        (70,  ["sdz", "sedz", "sedziow", "sędz", "sędziów", "judecatori"]),
        (110, ["1im", "1imp", "1imparati", "1krl"]),
        (120, ["2im", "2imp", "2imparati", "2krl"]),
        (130, ["1cr", "1cron", "1cronici", "1krn"]),
        (140, ["2cr", "2cron", "2cronici", "2krn"]),
        (220, ["iov", "hi", "hiob"]),
        (260, ["cant", "cc", "cantarea", "pnp"]),
        (300, ["ie", "ier", "ieremia"]),
        (310, ["plang", "pl", "plangerile", "lm"]),
        (350, ["os", "osea", "oz"]),
        (360, ["ioel"]),
        (380, ["ab", "abd", "abdias", "abdia", "abdiasza"]),
        (390, ["iona", "jon"]),
        (430, ["tef", "tefania", "sofoniasza", "sofonia"]),
    ];

    private static readonly Dictionary<string, int> ByAlias = BuildAliases();

    private static Dictionary<string, int> BuildAliases()
    {
        var map = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var (number, aliases) in Table)
            foreach (var alias in aliases) map.TryAdd(alias, number);
        return map;
    }

    /// Порядок 66 канонічних книг — початок таблиці: там канон іде підряд.
    public static readonly IReadOnlyList<int> CanonicalOrder = Table.Take(66).Select(entry => entry.Number).ToArray();

    /// Упізнає книгу за будь-яким з її скорочень. Крапки, пробіли і регістр
    /// відкидаємо: у модулях трапляється і «1Кор.», і «1 Cor», і «1CO».
    public static int? NumberForAlias(string raw)
    {
        var lower = raw.ToLowerInvariant();
        var key = new StringBuilder(lower.Length);
        foreach (var c in lower)
            if (SwiftText.IsLetter(c) || SwiftText.IsNumber(c)) key.Append(c);
        if (key.Length == 0) return null;
        // Рядки Swift рівні з точністю до складання знаків («ę» одним знаком і двома).
        var text = key.ToString().Normalize(NormalizationForm.FormC);
        return ByAlias.TryGetValue(text, out var number) ? number : null;
    }

    /// Проставляє наскрізні номери списку книг модуля.
    ///
    /// Спершу впізнаємо книги за скороченнями. Потім, якщо книг рівно 66, —
    /// добудовуємо решту за порядком канону. Добудовуємо лише за згоди з уже
    /// впізнаним: дивимося на більшість — якщо майже всі впізнані книги стоять
    /// на канонічних місцях, порядок звичайний, а розбіжність — омонім
    /// («Jud» — Юда англійською і Судді румунською).
    public static IReadOnlyList<BookInfo> AssignNumbers(IReadOnlyList<BookInfo> books)
    {
        var recognised = books.Select(book =>
            book.ShortNames.Select(NumberForAlias).FirstOrDefault(number => number != null)
            ?? NumberForAlias(book.FullName)).ToList();

        if (books.Count != CanonicalOrder.Count)
            return books.Select((book, index) => book.WithCanonicalNumber(recognised[index])).ToList();

        var agreed = 0;
        var disagreed = 0;
        for (var index = 0; index < books.Count; index++)
        {
            if (recognised[index] is not { } found) continue;
            if (found == CanonicalOrder[index]) agreed += 1;
            else disagreed += 1;
        }
        if (agreed < 40 || disagreed * 10 > agreed)
            return books.Select((book, index) => book.WithCanonicalNumber(recognised[index])).ToList();
        return books.Select((book, index) => book.WithCanonicalNumber(CanonicalOrder[index])).ToList();
    }
}
