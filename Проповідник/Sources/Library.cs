// =============================================================================
//  Library.cs — своя бібліотека перекладів і пісенників
// =============================================================================
//  Перенесено з планшета (Library.java). Звідки б модуль не прийшов — зі
//  «Слова» по мережі, з GitHub чи з файла, — він лягає в одну базу однаковими
//  рядками: книга, розділ, вірш, текст. Екран плану тому не знає, якого
//  формату був модуль.
//
//  Разом із модулем з GitHub чи з файла зберігається й сам файл (Original):
//  якщо в програмі на служінні такого перекладу не виявиться, «Проповідник»
//  відвезе їй саме його, і програма поставить модуль собі.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Data.Sqlite;

namespace Propovidnyk;

public sealed record Module(string Id, string Kind, string Name, string ShortName, string Source, string Original);
public sealed record Book(int Index, int Canon, string Name, string ShortName, int Chapters);
public sealed record Verse(int Number, string Text);
public sealed record Song(int Index, string Title);
public sealed record Part(int Index, string Kind, string Text);

public sealed class Library : IDisposable
{
    public const string Bible = "bible";
    public const string Songs = "songs";

    readonly SqliteConnection _db;

    public Library(string? path = null)
    {
        _db = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path ?? Paths.Library,
            Mode = SqliteOpenMode.ReadWriteCreate,
        }.ToString());
        _db.Open();
        Exec("PRAGMA journal_mode=WAL");
        Exec("""
            CREATE TABLE IF NOT EXISTS modules (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL,
              short TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '',
              original TEXT NOT NULL DEFAULT '', added INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS books (module TEXT NOT NULL, idx INTEGER NOT NULL, canon INTEGER NOT NULL DEFAULT 0,
              name TEXT NOT NULL, short TEXT NOT NULL DEFAULT '', chapters INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (module, idx));
            CREATE TABLE IF NOT EXISTS verses (module TEXT NOT NULL, book INTEGER NOT NULL, chapter INTEGER NOT NULL,
              verse INTEGER NOT NULL, text TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS verses_at ON verses (module, book, chapter);
            CREATE TABLE IF NOT EXISTS songs (module TEXT NOT NULL, idx INTEGER NOT NULL, title TEXT NOT NULL,
              fold TEXT NOT NULL, PRIMARY KEY (module, idx));
            CREATE TABLE IF NOT EXISTS parts (module TEXT NOT NULL, song INTEGER NOT NULL, idx INTEGER NOT NULL,
              kind TEXT NOT NULL, text TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS parts_at ON parts (module, song);
            """);
    }

    public void Dispose() => _db.Dispose();

    void Exec(string sql)
    {
        using var command = _db.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    SqliteCommand Query(string sql, params object[] args)
    {
        var command = _db.CreateCommand();
        command.CommandText = sql;
        for (var i = 0; i < args.Length; i++) command.Parameters.AddWithValue("$" + (i + 1), args[i]);
        return command;
    }

    // MARK: Читання

    public List<Module> Modules(string kind)
    {
        var result = new List<Module>();
        using var command = Query("SELECT id, kind, name, short, source, original FROM modules WHERE kind = $1 ORDER BY name COLLATE NOCASE", kind);
        using var r = command.ExecuteReader();
        while (r.Read()) result.Add(new Module(r.GetString(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetString(4), r.GetString(5)));
        return result;
    }

    public Module? Find(string id)
    {
        using var command = Query("SELECT id, kind, name, short, source, original FROM modules WHERE id = $1", id);
        using var r = command.ExecuteReader();
        return r.Read() ? new Module(r.GetString(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetString(4), r.GetString(5)) : null;
    }

    public List<Book> Books(string module)
    {
        var result = new List<Book>();
        using var command = Query("SELECT idx, canon, name, short, chapters FROM books WHERE module = $1 ORDER BY idx", module);
        using var r = command.ExecuteReader();
        while (r.Read()) result.Add(new Book(r.GetInt32(0), r.GetInt32(1), r.GetString(2), r.GetString(3), r.GetInt32(4)));
        return result;
    }

    /// Номери розділів — ті, що справді є в базі: буває й нульовий розділ.
    public List<int> Chapters(string module, int book)
    {
        var result = new List<int>();
        using var command = Query("SELECT DISTINCT chapter FROM verses WHERE module = $1 AND book = $2 ORDER BY chapter", module, book);
        using var r = command.ExecuteReader();
        while (r.Read()) result.Add(r.GetInt32(0));
        return result;
    }

    public List<Verse> Verses(string module, int book, int chapter)
    {
        var result = new List<Verse>();
        using var command = Query("SELECT verse, text FROM verses WHERE module = $1 AND book = $2 AND chapter = $3 ORDER BY verse", module, book, chapter);
        using var r = command.ExecuteReader();
        while (r.Read()) result.Add(new Verse(r.GetInt32(0), r.GetString(1)));
        return result;
    }

    /// Пісні за номером або словами назви. Порожній фільтр — усі по порядку.
    public List<Song> SongsOf(string module, string filter, int limit = 500)
    {
        var result = new List<Song>();
        var wanted = Fold(filter);
        SqliteCommand command;
        if (wanted.Length == 0)
            command = Query($"SELECT idx, title FROM songs WHERE module = $1 ORDER BY idx LIMIT {limit}", module);
        else if (wanted.All(char.IsDigit) && int.TryParse(wanted, out var number))
            command = Query($"SELECT idx, title FROM songs WHERE module = $1 AND (idx = $2 OR fold LIKE $3) ORDER BY idx LIMIT {limit}",
                            module, number - 1, "%" + wanted + "%");
        else
            command = Query($"SELECT idx, title FROM songs WHERE module = $1 AND fold LIKE $2 ORDER BY idx LIMIT {limit}", module, "%" + wanted + "%");
        using (command)
        using (var r = command.ExecuteReader())
            while (r.Read()) result.Add(new Song(r.GetInt32(0), r.GetString(1)));
        return result;
    }

    public List<Part> Parts(string module, int song)
    {
        var result = new List<Part>();
        using var command = Query("SELECT idx, kind, text FROM parts WHERE module = $1 AND song = $2 ORDER BY idx", module, song);
        using var r = command.ExecuteReader();
        while (r.Read()) result.Add(new Part(r.GetInt32(0), r.GetString(1), r.GetString(2)));
        return result;
    }

    public int Count(string table, string module)
    {
        using var command = Query($"SELECT COUNT(*) FROM {table} WHERE module = $1", module);
        return Convert.ToInt32(command.ExecuteScalar());
    }

    /// Прибрати модуль — і рядки, і збережений файл.
    public void Delete(string id)
    {
        var known = Find(id);
        using (var transaction = _db.BeginTransaction())
        {
            DeleteRows(id, transaction);
            using var command = Query("DELETE FROM modules WHERE id = $1", id);
            command.Transaction = transaction;
            command.ExecuteNonQuery();
            transaction.Commit();
        }
        if (known != null && known.Original.Length > 0)
        {
            try { File.Delete(known.Original); } catch { /* файл уже прибрали */ }
        }
    }

    void DeleteRows(string id, SqliteTransaction transaction)
    {
        foreach (var table in new[] { "books", "verses", "songs", "parts" })
        {
            using var command = Query($"DELETE FROM {table} WHERE module = $1", id);
            command.Transaction = transaction;
            command.ExecuteNonQuery();
        }
    }

    /// Рядок для пошуку: малі літери, «ё» як «е», без розділових знаків.
    public static string Fold(string? text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var lower = text.ToLowerInvariant().Replace('ё', 'е');
        var output = new StringBuilder(lower.Length);
        var space = false;
        foreach (var ch in lower)
        {
            if (char.IsLetterOrDigit(ch))
            {
                output.Append(ch);
                space = false;
            }
            else if (!space && output.Length > 0)
            {
                output.Append(' ');
                space = true;
            }
        }
        return output.ToString().Trim();
    }

    // MARK: Запис

    /// Запис модуля — одна транзакція: або модуль ліг увесь, або його немає.
    public Writer Write(string id, string kind, string name, string shortName, string source, string original)
    {
        var transaction = _db.BeginTransaction();
        DeleteRows(id, transaction);
        using (var command = Query("INSERT OR REPLACE INTO modules (id, kind, name, short, source, original, added) VALUES ($1, $2, $3, $4, $5, $6, $7)",
                                   id, kind, string.IsNullOrEmpty(name) ? id : name, shortName ?? "", source, original ?? "",
                                   DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()))
        {
            command.Transaction = transaction;
            command.ExecuteNonQuery();
        }
        return new Writer(this, id, transaction);
    }

    public sealed class Writer
    {
        readonly Library _library;
        readonly string _id;
        readonly SqliteTransaction _transaction;
        readonly SqliteCommand _book, _verse, _song, _part;
        bool _finished;
        public int VerseCount { get; private set; }
        public int SongCount { get; private set; }

        internal Writer(Library library, string id, SqliteTransaction transaction)
        {
            _library = library;
            _id = id;
            _transaction = transaction;
            _book = Prepare("INSERT OR REPLACE INTO books (module, idx, canon, name, short, chapters) VALUES ($1, $2, $3, $4, $5, $6)", 6);
            _verse = Prepare("INSERT INTO verses (module, book, chapter, verse, text) VALUES ($1, $2, $3, $4, $5)", 5);
            _song = Prepare("INSERT OR REPLACE INTO songs (module, idx, title, fold) VALUES ($1, $2, $3, $4)", 4);
            _part = Prepare("INSERT INTO parts (module, song, idx, kind, text) VALUES ($1, $2, $3, $4, $5)", 5);
        }

        SqliteCommand Prepare(string sql, int count)
        {
            var command = _library._db.CreateCommand();
            command.CommandText = sql;
            command.Transaction = _transaction;
            for (var i = 1; i <= count; i++) command.Parameters.Add(new SqliteParameter("$" + i, null));
            command.Prepare();
            return command;
        }

        static void Run(SqliteCommand command, params object[] values)
        {
            for (var i = 0; i < values.Length; i++) command.Parameters[i].Value = values[i];
            command.ExecuteNonQuery();
        }

        public void Book(int index, int canon, string? name, string? shortName, int chapters) =>
            Run(_book, _id, index, canon, name ?? "", shortName ?? "", chapters);

        public void Verse(int book, int chapter, int number, string text)
        {
            Run(_verse, _id, book, chapter, number, text);
            VerseCount++;
        }

        public void Song(int index, string title)
        {
            Run(_song, _id, index, title, (index + 1) + " " + Fold(title));
            SongCount++;
        }

        public void Part(int song, int index, string? kind, string? text) =>
            Run(_part, _id, song, index, kind ?? "", text ?? "");

        public void Commit()
        {
            if (_finished) return;
            _finished = true;
            _transaction.Commit();
            Dispose();
        }

        public void Abort()
        {
            if (_finished) return;
            _finished = true;
            _transaction.Rollback();
            Dispose();
        }

        void Dispose()
        {
            _book.Dispose(); _verse.Dispose(); _song.Dispose(); _part.Dispose();
            _transaction.Dispose();
        }
    }
}
