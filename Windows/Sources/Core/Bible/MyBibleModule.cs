// =============================================================================
//  MyBibleModule.cs — модуль MyBible: уся книга в одній базі SQLite
//  (з Bible/MyBibleModule.swift)
// =============================================================================

using Microsoft.Data.Sqlite;

namespace Slovo.Core;

/// Модуль MyBible — уся книга в одній базі SQLite.
///
/// Будова бази: таблиця `info` — пари ім'я/значення з описом модуля,
/// `books` — книги з їхніми наскрізними номерами (Буття = 10, … Об'явлення = 730),
/// `verses` — самі вірші з полями `book_number`, `chapter`, `verse`, `text`.
public sealed class MyBibleModule : TextModule, IDisposable
{
    public string Identifier { get; }
    public ModuleInfo Info { get; }
    public IReadOnlyList<BookInfo> Books { get; }
    public TextModuleFormat Format => TextModuleFormat.MyBible;

    private readonly SqliteConnection database;
    private readonly Dictionary<int, IReadOnlyList<Chapter>> chapterCache = new();
    private readonly object cacheLock = new();
    private readonly object databaseLock = new();

    public MyBibleModule(string path)
    {
        var fileName = SwiftPath.LastComponent(path);
        // Лише читання: модуль користувача не наш, псувати його не можна навіть
        // випадковим службовим записом на кшталт журналу.
        database = SqliteAccess.OpenReadOnly(path) ?? throw MyBibleError.CannotOpen(fileName);
        Identifier = SwiftPath.LastComponent(SwiftPath.DeletingExtension(path));

        var values = ReadInfo(database);
        if (!HasTable("verses", database) || !HasTable("books", database))
        {
            database.Dispose();
            throw MyBibleError.NotAModule(fileName);
        }

        var info = new ModuleInfo();
        info.Name = values.GetValueOrDefault("description") ?? Identifier;
        // Свого скорочення в `info` у модулів MyBible зазвичай немає, і брати
        // замість нього `chapter_string` не можна — там лежить слово «Глава».
        // Ім'я файлу якраз і є звичне скорочення: RST+, TUB, VIN-ru+.
        info.ShortName = values.TryGetValue("abbreviation", out var abbreviation) && abbreviation.Length > 0
            ? abbreviation
            : Identifier;
        info.Language = values.GetValueOrDefault("language");
        info.Copyright = values.GetValueOrDefault("detailed_info") ?? values.GetValueOrDefault("origin");
        // Ключ називався по-різному в різних поколіннях формату.
        info.HasStrongNumbers = Flag(values.GetValueOrDefault("strong_numbers") ?? values.GetValueOrDefault("is_strong"));
        info.RightToLeft = Flag(values.GetValueOrDefault("right_to_left"));
        info.IsBible = true;
        info.Encoding = CodePage.Utf8;
        Info = info;

        Books = ReadBooks(database);
        if (Books.Count == 0)
        {
            database.Dispose();
            throw MyBibleError.NoBooks(fileName);
        }
    }

    public void Dispose() => database.Dispose();

    // ── Тексти ──────────────────────────────────────────────────────────────

    /// Викидаємо номери Стронга `<S>`, розбір слова `<m>` і виноски `<f>`:
    /// на слайді їм не місце. А от `<n>` лишаємо — у звичайних модулях це
    /// рідкісна примітка, зате в підрядниках саме там лежить переклад, і без
    /// нього від тексту лишається сама грецька.
    private static readonly IReadOnlySet<string> Dropped = new HashSet<string>(StringComparer.Ordinal) { "s", "m", "f" };

    public IReadOnlyList<Chapter> Chapters(BookInfo book)
    {
        lock (cacheLock)
        {
            if (chapterCache.TryGetValue(book.Index, out var cached)) return cached;
        }
        if (book.CanonicalNumber is not { } number) return Array.Empty<Chapter>();

        var chapters = new List<Chapter>();
        lock (databaseLock)
        {
            // Команда живе стільки ж, скільки читач: її закриття закриває і його.
            using var command = database.CreateCommand();
            command.CommandText = "SELECT chapter, verse, text FROM verses WHERE book_number = $book ORDER BY chapter, verse";
            command.Parameters.AddWithValue("$book", number);
            SqliteDataReader reader;
            try
            {
                reader = command.ExecuteReader();
            }
            catch (SqliteException)
            {
                throw MyBibleError.QueryFailed(Identifier);
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
                    // Розмітка в MyBible та сама за духом, що в «Цитаті»: інлайнові
                    // теги плюс номери Стронга і виноски, які на слайді не потрібні.
                    var text = HTMLText.Plain(raw, Dropped);
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

    // ── Читання службових таблиць ───────────────────────────────────────────

    /// В `info` трапляються і «true»/«false», і «1»/«0» — розбираємо обидва.
    private static bool Flag(string? raw)
    {
        if (raw == null) return false;
        var value = raw.TrimWhitespaces().ToLowerInvariant();
        return value is "true" or "yes" or "1";
    }

    private static Dictionary<string, string> ReadInfo(SqliteConnection handle)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        if (!HasTable("info", handle)) return values;
        SqliteAccess.Each(handle, "SELECT name, value FROM info", reader =>
        {
            if (SqliteAccess.Text(reader, 0) is not { } key) return;
            values[key.ToLowerInvariant()] = SqliteAccess.Text(reader, 1) ?? "";
        });
        return values;
    }

    private static IReadOnlyList<BookInfo> ReadBooks(SqliteConnection handle)
    {
        // Число розділів рахуємо просто в запиті: окремий прохід по віршах заради
        // цього читав би всю базу, а модулі бувають на десятки мегабайтів.
        const string sql = """
            SELECT b.book_number, b.short_name, b.long_name, MAX(v.chapter)
            FROM books AS b
            JOIN verses AS v ON v.book_number = b.book_number
            GROUP BY b.book_number, b.short_name, b.long_name
            ORDER BY b.book_number
            """;
        var books = new List<BookInfo>();
        SqliteAccess.Each(handle, sql, reader =>
        {
            var number = SqliteAccess.Int(reader, 0);
            var shortName = SqliteAccess.Text(reader, 1) ?? "";
            var longName = SqliteAccess.Text(reader, 2) ?? "";
            var chapters = SqliteAccess.Int(reader, 3);

            var shortNames = shortName.Length == 0 ? new[] { longName } : new[] { shortName };
            books.Add(new BookInfo(books.Count, $"{number}", longName.Length == 0 ? shortName : longName,
                                   shortNames, chapters, number));
        });
        return books;
    }

    private static bool HasTable(string name, SqliteConnection handle)
    {
        var found = false;
        SqliteAccess.Each(handle,
            $"SELECT 1 FROM sqlite_master WHERE type='table' AND lower(name)=lower('{name}') LIMIT 1",
            _ => found = true);
        return found;
    }
}

public sealed class MyBibleError : Exception
{
    public enum Kind { CannotOpen, NotAModule, NoBooks, QueryFailed }

    public Kind ErrorKind { get; }

    private MyBibleError(Kind kind, string message) : base(message) => ErrorKind = kind;

    public static MyBibleError CannotOpen(string name) => new(Kind.CannotOpen, OurWords.T("%s: не удалось открыть базу модуля", name));
    public static MyBibleError NotAModule(string name) => new(Kind.NotAModule, OurWords.T("%s: это не модуль MyBible — нет таблиц books и verses", name));
    public static MyBibleError NoBooks(string name) => new(Kind.NoBooks, OurWords.T("%s: в модуле нет ни одной книги", name));
    public static MyBibleError QueryFailed(string name) => new(Kind.QueryFailed, OurWords.T("%s: ошибка запроса к базе модуля", name));

    public override string ToString() => Message;
}

/// Доступ до SQLite з тими самими правилами, що `sqlite3_column_*` у Swift:
/// NULL у цілому стовпці — нуль, текст обривається на першому NUL
/// (`String(cString:)`), помилка запиту — «нічого не знайшлося».
internal static class SqliteAccess
{
    /// `sqlite3_open_v2(…, SQLITE_OPEN_READONLY)`; без пулу — файл не тримається
    /// відкритим після `Dispose` (на Windows інакше його не замінити).
    public static SqliteConnection? OpenReadOnly(string path)
    {
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        };
        var connection = new SqliteConnection(builder.ToString());
        try
        {
            connection.Open();
            return connection;
        }
        catch (Exception)
        {
            connection.Dispose();
            return null;
        }
    }

    /// Прогнати запит; помилка підготовки чи кроку — просто кінець рядків.
    public static void Each(SqliteConnection handle, string sql, Action<SqliteDataReader> body)
    {
        try
        {
            using var command = handle.CreateCommand();
            command.CommandText = sql;
            using var reader = command.ExecuteReader();
            while (Step(reader)) body(reader);
        }
        catch (SqliteException)
        {
        }
    }

    /// `sqlite3_step(…) == SQLITE_ROW`.
    public static bool Step(SqliteDataReader reader)
    {
        try { return reader.Read(); }
        catch (SqliteException) { return false; }
    }

    public static string? Text(SqliteDataReader reader, int column)
    {
        if (reader.IsDBNull(column)) return null;
        var text = reader.GetString(column);
        var nul = text.IndexOf('\0');
        return nul < 0 ? text : text[..nul];
    }

    public static int Int(SqliteDataReader reader, int column) =>
        reader.IsDBNull(column) ? 0 : unchecked((int)reader.GetInt64(column));

    public static long Int64(SqliteDataReader reader, int column) =>
        reader.IsDBNull(column) ? 0 : reader.GetInt64(column);
}
