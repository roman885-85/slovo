// =============================================================================
//  BibleNumbering.cs — база невідповідностей нумерації inconsistencies.sqlite3
//  (з Bible/BibleNumbering.swift)
// =============================================================================

using Microsoft.Data.Sqlite;

namespace Slovo.Core;

/// Невідповідності нумерації перекладів Біблії — база `inconsistencies.sqlite3`.
///
/// Різні переклади рахують розділи й вірші по-різному: у Псалтиря східного
/// рахунку розділи з 10-го по 145-й на одиницю менші, ніж у західного, а
/// надписання в одних перекладах займають перший вірш, в інших не займають.
/// Будова бази (знято з файла автора, 338 правил): `t_info` — стандарти
/// нумерації; `modules` — якому стандарту належить модуль; `bibletrans` —
/// правила переведення адреси. Номери книг — ті самі наскрізні номери MyBible.
public sealed record NumberingStandard(string Code, string Description)
{
    public string Id => Code;
}

/// Вид правила. Літери — як у колонці `type` бази автора.
public enum NumberingRuleKind
{
    /// `OC` — зсув номера розділу на сталу величину.
    OffsetChapter,
    /// `OV` — зсув номера вірша всередині розділу.
    OffsetVerse,
    /// `P` — частина розділу переїхала в інший розділ цілком, з новою нумерацією.
    Part,
    /// `D` — окремий вірш стоїть в іншому місці, іноді розбитий на кілька.
    Displaced,
}

public static class NumberingRuleKinds
{
    public static readonly IReadOnlyList<NumberingRuleKind> All =
        [NumberingRuleKind.OffsetChapter, NumberingRuleKind.OffsetVerse, NumberingRuleKind.Part, NumberingRuleKind.Displaced];

    public static string RawValue(this NumberingRuleKind kind) => kind switch
    {
        NumberingRuleKind.OffsetChapter => "OC",
        NumberingRuleKind.OffsetVerse => "OV",
        NumberingRuleKind.Part => "P",
        _ => "D",
    };

    public static NumberingRuleKind? FromRaw(string raw) => raw switch
    {
        "OC" => NumberingRuleKind.OffsetChapter,
        "OV" => NumberingRuleKind.OffsetVerse,
        "P" => NumberingRuleKind.Part,
        "D" => NumberingRuleKind.Displaced,
        _ => null,
    };

    public static string Id(this NumberingRuleKind kind) => kind.RawValue();

    public static string Title(this NumberingRuleKind kind) => kind switch
    {
        NumberingRuleKind.OffsetChapter => OurWords.T("Сдвиг глав"),
        NumberingRuleKind.OffsetVerse => OurWords.T("Сдвиг стихов"),
        NumberingRuleKind.Part => OurWords.T("Перенос части главы"),
        _ => OurWords.T("Перенесённый стих"),
    };
}

/// Одне правило переведення адреси. Порожні поля бази означають «не задано».
public sealed record NumberingRule
{
    public Guid Id { get; set; }
    public string From { get; set; }
    public string To { get; set; }
    public NumberingRuleKind Kind { get; set; }
    public int Book { get; set; }
    public int ChapterBegin { get; set; }
    public int? ChapterEnd { get; set; }
    public int? VerseBegin { get; set; }
    public int? VerseEnd { get; set; }
    /// В `OC` — зсув розділів, у `P` і `D` — номер розділу призначення,
    /// в `OV` — номер розділу призначення, якщо його задано.
    public int? ChapterTo { get; set; }
    public int? ChapterToEnd { get; set; }
    /// В `OV` — зсув віршів, у `P` і `D` — номер першого вірша призначення.
    public int? VerseTo { get; set; }
    public int? VerseToEnd { get; set; }

    public NumberingRule(string from, string to, NumberingRuleKind kind, int book, int chapterBegin,
                         int? chapterEnd = null, int? verseBegin = null, int? verseEnd = null,
                         int? chapterTo = null, int? chapterToEnd = null, int? verseTo = null, int? verseToEnd = null,
                         Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        From = from;
        To = to;
        Kind = kind;
        Book = book;
        ChapterBegin = chapterBegin;
        ChapterEnd = chapterEnd;
        VerseBegin = verseBegin;
        VerseEnd = verseEnd;
        ChapterTo = chapterTo;
        ChapterToEnd = chapterToEnd;
        VerseTo = verseTo;
        VerseToEnd = verseToEnd;
    }

    /// Останній розділ, на який поширюється правило.
    public int ChapterLast => ChapterEnd ?? ChapterBegin;

    /// Адреса-джерело рядком — для списку у вікні редактора.
    public string SourceText
    {
        get
        {
            // Проміжок з одного розділу пишемо одним числом: «13–13» читається як помилка.
            var text = ChapterEnd is { } end && end > ChapterBegin ? $"{ChapterBegin}–{end}" : $"{ChapterBegin}";
            if (VerseBegin is { } begin) text += ":" + (VerseEnd is { } verseEnd ? $"{begin}–{verseEnd}" : $"{begin}…");
            return text;
        }
    }

    /// Адреса-призначення рядком. У зсувів показуємо знак, у переносів — номер.
    public string TargetText
    {
        get
        {
            switch (Kind)
            {
                case NumberingRuleKind.OffsetChapter:
                    return Signed(ChapterTo ?? 0) + " к главе";
                case NumberingRuleKind.OffsetVerse:
                {
                    var text = Signed(VerseTo ?? 0) + " к стиху";
                    if (ChapterTo is { } chapter) text = OurWords.T($"гл. {chapter}, ") + text;
                    return text;
                }
                default:
                {
                    var text = ChapterTo is { } chapter ? $"{chapter}" : "та же глава";
                    if (VerseTo is { } verse) text += ":" + (VerseToEnd is { } end ? $"{verse}–{end}" : $"{verse}");
                    return text;
                }
            }
        }
    }

    private static string Signed(int value) => value > 0 ? $"+{value}" : $"{value}";
}

/// Уся база цілком, значенням: вікно редактора править копію і записує її
/// по «Ок», а по «Скасувати» просто викидає — як в оригіналі.
public sealed class NumberingBase
{
    public List<NumberingStandard> Standards { get; set; }
    /// Скорочення модуля → код стандарту. Ключі порівнюємо без урахування регістру.
    public Dictionary<string, string> Modules { get; set; }
    public List<NumberingRule> Rules { get; set; }

    public NumberingBase(List<NumberingStandard>? standards = null,
                         Dictionary<string, string>? modules = null,
                         List<NumberingRule>? rules = null)
    {
        Standards = standards ?? new List<NumberingStandard>();
        Modules = modules ?? new Dictionary<string, string>(StringComparer.Ordinal);
        Rules = rules ?? new List<NumberingRule>();
    }

    public bool IsEmpty => Standards.Count == 0 && Modules.Count == 0 && Rules.Count == 0;

    // ── Де лежить ───────────────────────────────────────────────────────────

    /// Своя копія бази. Файл автора належить користувачеві — писати в нього не
    /// можна, тому правки йдуть сюди.
    public static string UserUrl => Path.Combine(DataHome.Folder, "inconsistencies.sqlite3");

    /// Файл автора поруч із модулями — лише для читання.
    public static string OriginalUrl(string dataRoot) => Path.Combine(dataRoot, "inconsistencies.sqlite3");

    /// Читаємо свою копію, якщо вона є, інакше базу оригіналу.
    public static NumberingBase Load(string? dataRoot)
    {
        if (SwiftPath.Exists(UserUrl))
        {
            try { return LoadFrom(UserUrl); } catch { }
        }
        if (dataRoot != null)
        {
            var original = OriginalUrl(dataRoot);
            if (SwiftPath.Exists(original))
            {
                try { return LoadFrom(original); } catch { }
            }
        }
        return new NumberingBase();
    }

    // ── Читання ─────────────────────────────────────────────────────────────

    public sealed class NumberingError : Exception
    {
        public enum Kind { CannotOpen, CannotWrite }
        public Kind ErrorKind { get; }
        public NumberingError(Kind kind, string message) : base(message) => ErrorKind = kind;
    }

    public static NumberingBase LoadFrom(string path)
    {
        using var handle = SqliteAccess.OpenReadOnly(path)
                           ?? throw new NumberingError(NumberingError.Kind.CannotOpen, SwiftPath.LastComponent(path));
        var result = new NumberingBase();

        SqliteAccess.Each(handle, "SELECT lng, description FROM t_info", row =>
        {
            if (SqliteAccess.Text(row, 0) is not { Length: > 0 } code) return;
            result.Standards.Add(new NumberingStandard(code, SqliteAccess.Text(row, 1) ?? code));
        });
        result.Standards = result.Standards.OrderBy(standard => standard.Code, StringComparer.Ordinal).ToList();

        SqliteAccess.Each(handle, "SELECT name, lng FROM modules", row =>
        {
            if (SqliteAccess.Text(row, 0) is not { } name || SqliteAccess.Text(row, 1) is not { } code) return;
            result.Modules[name.ToLowerInvariant()] = code;
        });

        const string columns = "SELECT lng_from, lng_to, type, book_from, chapter_from_begin, chapter_from_end, " +
                               "verse_from_begin, verse_from_end, chapter_to_begin, chapter_to_end, " +
                               "verse_to_begin, verse_to_end FROM bibletrans";
        SqliteAccess.Each(handle, columns, row =>
        {
            if (SqliteAccess.Text(row, 0) is not { } from || SqliteAccess.Text(row, 1) is not { } to
                || SqliteAccess.Text(row, 2) is not { } type || NumberingRuleKinds.FromRaw(type) is not { } kind
                || Number(row, 3) is not { } book || Number(row, 4) is not { } chapter) return;
            result.Rules.Add(new NumberingRule(from, to, kind, book, chapter,
                                               chapterEnd: Number(row, 5),
                                               verseBegin: Number(row, 6),
                                               verseEnd: Number(row, 7),
                                               chapterTo: Number(row, 8),
                                               chapterToEnd: Number(row, 9),
                                               verseTo: Number(row, 10),
                                               verseToEnd: Number(row, 11)));
        });
        return result;
    }

    /// Порожній рядок у базі автора означає «не задано», і відрізняти його від нуля
    /// обов'язково: зсув 0 — це правило, яке нічого не міняє.
    private static int? Number(SqliteDataReader row, int index)
    {
        if (row.IsDBNull(index)) return null;
        if (SqliteAccess.Text(row, index) is { } raw)
        {
            var value = raw.TrimWhitespaces();
            if (value.Length == 0) return null;
            return SwiftText.ParseInt(value);
        }
        return unchecked((int)SqliteAccess.Int64(row, index));
    }

    // ── Запис ───────────────────────────────────────────────────────────────

    /// Пишемо свою копію цілком і тією самою схемою, що в автора: щоб файл
    /// відкривався і оригіналом, якщо власник вирішить перенести правки назад.
    public void Save(string? path = null)
    {
        path ??= UserUrl;
        var folder = SwiftPath.Parent(path);
        Directory.CreateDirectory(folder);
        var temporary = Path.Combine(folder, $"inconsistencies-{Guid.NewGuid().ToString().ToUpperInvariant()}.sqlite3");

        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = temporary,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false,
        };
        var handle = new SqliteConnection(builder.ToString());
        try
        {
            handle.Open();
        }
        catch
        {
            handle.Dispose();
            throw new NumberingError(NumberingError.Kind.CannotWrite, SwiftPath.LastComponent(path));
        }

        void Run(string sql)
        {
            try
            {
                using var command = handle.CreateCommand();
                command.CommandText = sql;
                command.ExecuteNonQuery();
            }
            catch (SqliteException error)
            {
                throw new NumberingError(NumberingError.Kind.CannotWrite, error.Message);
            }
        }

        try
        {
            Run("CREATE TABLE bibletrans (lng_from TEXT, lng_to TEXT, type TEXT, book_from INTEGER, " +
                "chapter_from_begin INTEGER, chapter_from_end INTEGER, verse_from_begin INTEGER, " +
                "verse_from_end INTEGER, chapter_to_begin INTEGER, chapter_to_end INTEGER, " +
                "verse_to_begin INTEGER, verse_to_end INTEGER);\n" +
                "CREATE UNIQUE INDEX idx1 ON bibletrans (lng_from, lng_to, type, book_from, " +
                "chapter_from_begin, verse_from_begin, verse_from_end, chapter_from_end);\n" +
                "CREATE TABLE modules (name TEXT UNIQUE NOT NULL, lng TEXT NOT NULL);\n" +
                "CREATE INDEX Index0 ON modules (name, lng);\n" +
                "CREATE TABLE t_info (lng TEXT PRIMARY KEY UNIQUE NOT NULL, description TEXT);");
            Run("BEGIN");
            foreach (var standard in Standards)
                Run("INSERT OR REPLACE INTO t_info (lng, description) VALUES (" + Quote(standard.Code) + ", "
                    + Quote(standard.Description) + ")");
            foreach (var (name, code) in Modules.OrderBy(pair => pair.Key, StringComparer.Ordinal))
                Run("INSERT OR REPLACE INTO modules (name, lng) VALUES (" + Quote(name) + ", " + Quote(code) + ")");
            foreach (var rule in Rules)
            {
                var values = new[]
                {
                    Quote(rule.From), Quote(rule.To), Quote(rule.Kind.RawValue()),
                    $"{rule.Book}", $"{rule.ChapterBegin}",
                    Cell(rule.ChapterEnd), Cell(rule.VerseBegin), Cell(rule.VerseEnd),
                    Cell(rule.ChapterTo), Cell(rule.ChapterToEnd),
                    Cell(rule.VerseTo), Cell(rule.VerseToEnd),
                };
                Run("INSERT OR REPLACE INTO bibletrans VALUES (" + string.Join(", ", values) + ")");
            }
            Run("COMMIT");
        }
        catch
        {
            handle.Dispose();
            try { File.Delete(temporary); } catch { }
            throw;
        }
        handle.Dispose();

        File.Move(temporary, path, overwrite: true);
    }

    /// В автора «не задано» записано порожнім рядком, а не NULL, — повторюємо.
    private static string Cell(int? value) => value is { } number ? $"{number}" : "''";

    private static string Quote(string value) => "'" + value.Replace("'", "''") + "'";

    // ── Стандарт модуля ─────────────────────────────────────────────────────

    /// Стандарт нумерації модуля шукаємо за його скороченням та ім'ям файлу:
    /// у базі автора записано скорочення (`BW`, `UBT2020`, `МСЦ'22`).
    public string? StandardCode(IReadOnlyList<string> moduleNames)
    {
        foreach (var name in moduleNames)
            if (Modules.TryGetValue(name.ToLowerInvariant(), out var code)) return code;
        foreach (var name in moduleNames)
        {
            if (ModuleNameMatch.Nearest(name, Modules.Keys.ToList()) is { } near && Modules.TryGetValue(near, out var code))
                return code;
        }
        return null;
    }
}

/// Зіставлення імені модуля з рядком чужої таблиці, коли в імені описка.
///
/// У базі нумерації у власника рядок названо `ua_ogienka`, а тека перекладу
/// — `UA_Ogienko`: одна літера. Правило навмисно вузьке: пов'язуємо лише тоді,
/// коли розходяться літери, а не цифри (`ubt2020` і `ubt2022` — різні переклади),
/// довжина збігається, ім'я не коротше за п'ять знаків і підхожий рядок рівно один.
public static class ModuleNameMatch
{
    public static string? Nearest(string name, IReadOnlyList<string> keys)
    {
        var key = name.ToLowerInvariant();
        if (SwiftText.CharacterCount(key) < 5) return null;
        var near = keys.Where(candidate => DiffersByOneLetter(candidate, key)).ToList();
        return near.Count == 1 ? near[0] : null;
    }

    /// Та сама довжина і рівно одне розходження, причому обидві розбіжні літери — не цифри.
    internal static bool DiffersByOneLetter(string one, string two)
    {
        var a = SwiftText.Characters(one);
        var b = SwiftText.Characters(two);
        if (a.Length != b.Length) return false;
        (string Left, string Right)? difference = null;
        for (var index = 0; index < a.Length; index++)
        {
            if (SwiftText.Same(a[index], b[index])) continue;
            if (difference != null) return false;
            difference = (a[index], b[index]);
        }
        if (difference is not { } found) return false;
        return !SwiftText.IsNumber(found.Left) && !SwiftText.IsNumber(found.Right);
    }
}
