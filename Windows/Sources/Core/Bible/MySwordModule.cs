// =============================================================================
//  MySwordModule.cs — модуль MySword (з Bible/MySwordModule.swift)
// =============================================================================

using Microsoft.Data.Sqlite;

namespace Slovo.Core;

/// Модуль MySword — теж база SQLite, але влаштована інакше, ніж MyBible.
///
/// Увесь опис перекладу лежить в єдиному рядку таблиці `Details`, а вірші —
/// в таблиці `Bible` з полями `Book`, `Chapter`, `Verse`, `Scripture`.
/// Таблиці книг тут немає зовсім: `Book` — наскрізний номер канону 1…66, а
/// назви ми беремо з `MySwordBookNames`. Тип модуля стоїть в імені файлу перед
/// розширенням: вірші є лише в `*.bbl.mybible`.
public sealed class MySwordModule : TextModule, IDisposable
{
    public string Identifier { get; }
    public ModuleInfo Info { get; }
    public IReadOnlyList<BookInfo> Books { get; }
    public TextModuleFormat Format => TextModuleFormat.MySword;

    private readonly SqliteConnection database;
    private readonly Dictionary<int, IReadOnlyList<Chapter>> chapterCache = new();
    private readonly object cacheLock = new();
    private readonly object databaseLock = new();

    public MySwordModule(string path)
    {
        var fileName = SwiftPath.LastComponent(path);
        // Відмова за ім'ям — до відкриття файла: нема чого чіпати чужу базу,
        // якщо вже за типом видно, що віршів у ній немає.
        if (!IsBibleModuleName(fileName)) throw MySwordError.NotBibleModule(fileName);
        // Ідентифікатор — ім'я без обох розширень: інакше замість «Proba» осіло б «Proba.bbl».
        Identifier = SwiftPath.LastComponent(SwiftPath.DeletingExtension(SwiftPath.DeletingExtension(path)));

        var handle = SqliteAccess.OpenReadOnly(path) ?? throw MySwordError.CannotOpen(fileName);
        try
        {
            var contents = Read(handle, fileName, Identifier);
            Info = contents.Info;
            Books = contents.Books;
            database = handle;
        }
        catch
        {
            // Об'єкт ще не зібрано цілком — базу закриваємо тут самі.
            handle.Dispose();
            throw;
        }
    }

    public void Dispose() => database.Dispose();

    /// Чи модуль це з віршами. Дивимося на два розширення одразу: одне
    /// `.mybible` носять і нотатки, і закладки, і налаштування самої MySword.
    public static bool IsBibleModuleName(string name) =>
        name.ToLowerInvariant().EndsWith(".bbl.mybible", StringComparison.Ordinal);

    // ── Тексти ──────────────────────────────────────────────────────────────

    public IReadOnlyList<Chapter> Chapters(BookInfo book)
    {
        lock (cacheLock)
        {
            if (chapterCache.TryGetValue(book.Index, out var cached)) return cached;
        }
        // Ключ у базі — номер MySword, він же лежить у `FileName`. Брати
        // `CanonicalNumber` не можна: там уже перераховані 10…730.
        if (SwiftText.ParseInt(book.FileName) is not { } number) return Array.Empty<Chapter>();

        var chapters = new List<Chapter>();
        lock (databaseLock)
        {
            // Команда живе стільки ж, скільки читач: її закриття закриває і його.
            using var command = database.CreateCommand();
            command.CommandText = "SELECT Chapter, Verse, Scripture FROM Bible WHERE Book = $book ORDER BY Chapter, Verse";
            command.Parameters.AddWithValue("$book", number);
            SqliteDataReader reader;
            try
            {
                reader = command.ExecuteReader();
            }
            catch (SqliteException)
            {
                throw MySwordError.QueryFailed(Identifier);
            }
            using (reader)
            {
                var currentNumber = int.MinValue;
                var verses = new List<Verse>();
                while (SqliteAccess.Step(reader))
                {
                    var chapter = SqliteAccess.Int(reader, 0);
                    var verse = SqliteAccess.Int(reader, 1);
                    var raw = SqliteAccess.Text(reader, 2) ?? "";
                    if (chapter != currentNumber)
                    {
                        if (currentNumber != int.MinValue) chapters.Add(new Chapter(currentNumber, null, verses));
                        currentNumber = chapter;
                        verses = new List<Verse>();
                    }
                    var text = MySwordText.Plain(raw);
                    if (text.Length > 0) verses.Add(new Verse(verse, text));
                }
                if (currentNumber != int.MinValue) chapters.Add(new Chapter(currentNumber, null, verses));
            }
        }

        lock (cacheLock) chapterCache[book.Index] = chapters;
        return chapters;
    }

    public IReadOnlyList<Chapter>? CachedChapters(BookInfo book)
    {
        lock (cacheLock) return chapterCache.TryGetValue(book.Index, out var cached) ? cached : null;
    }

    public void ReleaseCache()
    {
        lock (cacheLock) chapterCache.Clear();
    }

    // ── Розбір бази ─────────────────────────────────────────────────────────

    /// Усе, що може відмовити, зібрано тут і робиться до збирання об'єкта.
    private static (ModuleInfo Info, IReadOnlyList<BookInfo> Books) Read(SqliteConnection handle, string fileName, string identifier)
    {
        // Успішне відкриття про формат не каже нічого: перша правда приходить
        // лише на запиті.
        var tables = TableNames(handle, fileName);
        if (!tables.Contains("bible")) throw MySwordError.NotAModule(fileName);

        var details = ReadDetails(handle);
        var rows = ReadBookRows(handle);
        if (rows.Count == 0) throw MySwordError.NoVerses(fileName);
        // Фірмові модулі (ABP, HiSB) шифрують текст віршів, і спосіб ніде
        // не описано. Показати замість Писання кашу гірше, ніж чесно відмовити.
        if (IsEncrypted(details)) throw MySwordError.Encrypted(fileName);

        var books = new List<BookInfo>();
        foreach (var (bookNumber, chapters) in rows)
        {
            // Неканонічних книг формат не знає; номери поза 1…66 недійсні.
            if (MySwordBookNames.Book(bookNumber) is not { } names) continue;
            books.Add(new BookInfo(books.Count, $"{bookNumber}", names.FullName, names.ShortNames, chapters,
                                   MySwordBookNames.CanonicalNumber(bookNumber)));
        }
        if (books.Count == 0) throw MySwordError.StrangeNumbering(fileName);

        var info = new ModuleInfo
        {
            // `Title` — спадок e-Sword 11: частина модулів пише назву саме туди.
            Name = FirstNonEmpty(details, "description", "title") ?? identifier,
            // Скорочення в MySword без пробілів — годиться на ярлик вкладки як є.
            ShortName = FirstNonEmpty(details, "abbreviation") ?? identifier,
            // Мова тут трилітерна («rus», «ukr») — поле показне.
            Language = FirstNonEmpty(details, "language"),
            Copyright = FirstNonEmpty(details, "comments"),
            HasStrongNumbers = Flag(details.GetValueOrDefault("strong")),
            RightToLeft = Flag(details.GetValueOrDefault("righttoleft")),
            // Полям `OT` і `NT` вірити не можна: рахуємо за справжніми номерами книг.
            HasOldTestament = rows.Any(row => row.Book <= 39),
            HasNewTestament = rows.Any(row => row.Book >= 40),
            HasApocrypha = false,
            IsBible = true,
            Encoding = CodePage.Utf8,
        };
        return (info, books);
    }

    /// Імена таблиць і представлень у нижньому регістрі.
    private static HashSet<string> TableNames(SqliteConnection handle, string fileName)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            using var command = handle.CreateCommand();
            command.CommandText = "SELECT name FROM sqlite_master WHERE type IN ('table','view')";
            using var reader = command.ExecuteReader();
            while (SqliteAccess.Step(reader))
                if (SqliteAccess.Text(reader, 0) is { } name) names.Add(name.ToLowerInvariant());
        }
        catch (SqliteException)
        {
            throw MySwordError.NotADatabase(fileName);
        }
        return names;
    }

    /// Єдиний рядок `Details`, розібраний за іменами колонок.
    private static Dictionary<string, string> ReadDetails(SqliteConnection handle)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            using var command = handle.CreateCommand();
            command.CommandText = "SELECT * FROM Details LIMIT 1";
            using var reader = command.ExecuteReader();
            if (!SqliteAccess.Step(reader)) return values;
            for (var column = 0; column < reader.FieldCount; column++)
                values[reader.GetName(column).ToLowerInvariant()] = SqliteAccess.Text(reader, column) ?? "";
        }
        catch (SqliteException)
        {
        }
        return values;
    }

    /// Книги і число розділів у них — одним запитом.
    private static List<(int Book, int Chapters)> ReadBookRows(SqliteConnection handle)
    {
        var rows = new List<(int, int)>();
        SqliteAccess.Each(handle, "SELECT Book, MAX(Chapter) FROM Bible GROUP BY Book ORDER BY Book",
            reader => rows.Add((SqliteAccess.Int(reader, 0), SqliteAccess.Int(reader, 1))));
        return rows;
    }

    private static bool IsEncrypted(Dictionary<string, string> details)
    {
        if (!details.TryGetValue("encryption", out var raw)) return false;
        var value = raw.TrimWhitespaces();
        return value.Length > 0 && value != "0";
    }

    private static string? FirstNonEmpty(Dictionary<string, string> details, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (details.TryGetValue(key, out var raw))
            {
                var value = raw.TrimWhitespacesAndNewlines();
                if (value.Length > 0) return value;
            }
        }
        return null;
    }

    private static bool Flag(string? raw)
    {
        if (raw == null) return false;
        var value = raw.TrimWhitespaces().ToLowerInvariant();
        return value is "true" or "yes" or "1";
    }
}

public sealed class MySwordError : Exception
{
    public enum Kind { NotBibleModule, CannotOpen, NotADatabase, NotAModule, NoVerses, Encrypted, StrangeNumbering, QueryFailed }

    public Kind ErrorKind { get; }

    private MySwordError(Kind kind, string message) : base(message) => ErrorKind = kind;

    public static MySwordError NotBibleModule(string name) => new(Kind.NotBibleModule, OurWords.T("%s: это не модуль со стихами — у MySword они лежат в файлах «.bbl.mybible»", name));
    public static MySwordError CannotOpen(string name) => new(Kind.CannotOpen, OurWords.T("%s: не удалось открыть файл модуля", name));
    public static MySwordError NotADatabase(string name) => new(Kind.NotADatabase, OurWords.T("%s: это не база данных", name));
    public static MySwordError NotAModule(string name) => new(Kind.NotAModule, OurWords.T("%s: это не модуль MySword — нет таблицы Bible", name));
    public static MySwordError NoVerses(string name) => new(Kind.NoVerses, OurWords.T("%s: в модуле нет ни одного стиха", name));
    public static MySwordError Encrypted(string name) => new(Kind.Encrypted, OurWords.T("%s: модуль зашифрован, читать нечем", name));
    public static MySwordError StrangeNumbering(string name) => new(Kind.StrangeNumbering, OurWords.T("%s: непонятная нумерация книг — ни одного номера в пределах 1…66", name));
    public static MySwordError QueryFailed(string name) => new(Kind.QueryFailed, $"{name}: ошибка запроса к базе модуля");

    public override string ToString() => Message;
}
