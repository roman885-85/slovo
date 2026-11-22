// =============================================================================
//  Library.cs — своя бібліотека перекладів і пісенників
// =============================================================================
//  Перенесено з «Проповідника Слова» (а туди — з планшета). Звідки б модуль
//  не прийшов — з ресурсів «Слова», з GitHub, з файла чи з теки VisioBible, —
//  він лягає в одну базу SQLite однаковими рядками: книга, розділ, вірш,
//  текст; пісня, частина. Разом із модулем зберігається й сам файл
//  (Original), щоб віддати його планшету чи «Проповіднику».
//
//  Відмінності від «Проповідника»: у пісень є всі поля старої програми
//  (друга назва, автор, композитор, примітка, властивості, вирівнювання
//  частини) — щоб редагувати пісні й писати пісенники назад; у модуля є
//  опис (видавець, дата редакції, коментар, заголовок .vbm); є пошук за
//  словами по всьому перекладу.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace Slovo;

public sealed record Module(string Id, string Kind, string Name, string ShortName, string Source, string Original);
public sealed record Book(int Index, int Canon, string Name, string ShortName, int Chapters);
public sealed record Verse(int Number, string Text);
public sealed record Song(int Index, string Title);
public sealed record Part(int Index, string Kind, string Text);
/// Вірш для пошуку — з адресою.
public sealed record VerseAt(int Book, int Chapter, int Number, string Text);

public sealed class Library : IDisposable
{
    public const string Bible = "bible";
    public const string Songs = "songs";

    readonly SqliteConnection _db;
    readonly object _lock = new();

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
        // Поля, яких у «Проповіднику» не було, — додаються до наявної бази.
        EnsureColumn("modules", "meta", "TEXT NOT NULL DEFAULT ''");
        EnsureColumn("songs", "alt", "TEXT NOT NULL DEFAULT ''");
        EnsureColumn("songs", "author", "TEXT NOT NULL DEFAULT ''");
        EnsureColumn("songs", "composer", "TEXT NOT NULL DEFAULT ''");
        EnsureColumn("songs", "note", "TEXT NOT NULL DEFAULT ''");
        EnsureColumn("songs", "props", "TEXT NOT NULL DEFAULT ''");
        EnsureColumn("parts", "align", "INTEGER NOT NULL DEFAULT 0");
    }

    public void Dispose() => _db.Dispose();

    void EnsureColumn(string table, string column, string ddl)
    {
        lock (_lock)
        {
            using var info = Query($"PRAGMA table_info({table})");
            using (var r = info.ExecuteReader())
                while (r.Read()) if (r.GetString(1).Equals(column, StringComparison.OrdinalIgnoreCase)) return;
            using var alter = _db.CreateCommand();
            alter.CommandText = $"ALTER TABLE {table} ADD COLUMN {column} {ddl}";
            alter.ExecuteNonQuery();
        }
    }

    void Exec(string sql)
    {
        lock (_lock)
        {
            using var command = _db.CreateCommand();
            command.CommandText = sql;
            command.ExecuteNonQuery();
        }
    }

    SqliteCommand Query(string sql, params object[] args)
    {
        var command = _db.CreateCommand();
        command.CommandText = sql;
        for (var i = 0; i < args.Length; i++) command.Parameters.AddWithValue("$" + (i + 1), args[i] ?? DBNull.Value);
        return command;
    }

    // MARK: Читання

    public List<Module> Modules(string kind)
    {
        lock (_lock)
        {
            var result = new List<Module>();
            using var command = Query("SELECT id, kind, name, short, source, original FROM modules WHERE kind = $1 ORDER BY name COLLATE NOCASE", kind);
            using var r = command.ExecuteReader();
            while (r.Read()) result.Add(new Module(r.GetString(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetString(4), r.GetString(5)));
            return result;
        }
    }

    public Module? Find(string id)
    {
        lock (_lock)
        {
            using var command = Query("SELECT id, kind, name, short, source, original FROM modules WHERE id = $1", id);
            using var r = command.ExecuteReader();
            return r.Read() ? new Module(r.GetString(0), r.GetString(1), r.GetString(2), r.GetString(3), r.GetString(4), r.GetString(5)) : null;
        }
    }

    /// Опис модуля (JSON): publisher, revision, comment, заголовок .vbm, групи.
    public JsonObject Meta(string id)
    {
        lock (_lock)
        {
            using var command = Query("SELECT meta FROM modules WHERE id = $1", id);
            var text = command.ExecuteScalar() as string ?? "";
            if (text.Length == 0) return new JsonObject();
            try { return JsonNode.Parse(text) as JsonObject ?? new JsonObject(); } catch { return new JsonObject(); }
        }
    }

    public void SetMeta(string id, JsonObject meta)
    {
        lock (_lock)
        {
            using var command = Query("UPDATE modules SET meta = $2 WHERE id = $1", id, meta.ToJsonString());
            command.ExecuteNonQuery();
        }
    }

    public void Rename(string id, string name, string shortName)
    {
        lock (_lock)
        {
            using var command = Query("UPDATE modules SET name = $2, short = $3 WHERE id = $1", id, name, shortName);
            command.ExecuteNonQuery();
        }
    }

    public List<Book> Books(string module)
    {
        lock (_lock)
        {
            var result = new List<Book>();
            using var command = Query("SELECT idx, canon, name, short, chapters FROM books WHERE module = $1 ORDER BY idx", module);
            using var r = command.ExecuteReader();
            while (r.Read()) result.Add(new Book(r.GetInt32(0), r.GetInt32(1), r.GetString(2), r.GetString(3), r.GetInt32(4)));
            return result;
        }
    }

    /// Номери розділів — ті, що справді є в базі: буває й нульовий розділ.
    public List<int> Chapters(string module, int book)
    {
        lock (_lock)
        {
            var result = new List<int>();
            using var command = Query("SELECT DISTINCT chapter FROM verses WHERE module = $1 AND book = $2 ORDER BY chapter", module, book);
            using var r = command.ExecuteReader();
            while (r.Read()) result.Add(r.GetInt32(0));
            return result;
        }
    }

    public List<Verse> Verses(string module, int book, int chapter)
    {
        lock (_lock)
        {
            var result = new List<Verse>();
            using var command = Query("SELECT verse, text FROM verses WHERE module = $1 AND book = $2 AND chapter = $3 ORDER BY verse", module, book, chapter);
            using var r = command.ExecuteReader();
            while (r.Read()) result.Add(new Verse(r.GetInt32(0), r.GetString(1)));
            return result;
        }
    }

    /// Усі вірші перекладу підряд — для пошуку за словами (31 тисяча рядків).
    public List<VerseAt> AllVerses(string module)
    {
        lock (_lock)
        {
            var result = new List<VerseAt>(32_000);
            using var command = Query("SELECT book, chapter, verse, text FROM verses WHERE module = $1 ORDER BY book, chapter, verse", module);
            using var r = command.ExecuteReader();
            while (r.Read()) result.Add(new VerseAt(r.GetInt32(0), r.GetInt32(1), r.GetInt32(2), r.GetString(3)));
            return result;
        }
    }

    /// Пісні за номером або словами назви. Порожній фільтр — усі по порядку.
    public List<Song> SongsOf(string module, string filter, int limit = 5000)
    {
        lock (_lock)
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
    }

    /// Пісні, у тексті яких є всі слова запиту, — пошук на вкладці «Пісні».
    public List<Song> SongsWithWords(string module, string query, int limit = 200)
    {
        var words = Fold(query).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return new List<Song>();
        lock (_lock)
        {
            var result = new List<Song>();
            var sql = new StringBuilder("SELECT s.idx, s.title FROM songs s WHERE s.module = $1");
            var args = new List<object> { module };
            foreach (var word in words)
            {
                args.Add("%" + word + "%");
                sql.Append($" AND (s.fold LIKE ${args.Count} OR EXISTS (SELECT 1 FROM parts p WHERE p.module = s.module AND p.song = s.idx AND lower(p.text) LIKE ${args.Count}))");
            }
            sql.Append($" ORDER BY s.idx LIMIT {limit}");
            using var command = Query(sql.ToString(), args.ToArray());
            using var r = command.ExecuteReader();
            while (r.Read()) result.Add(new Song(r.GetInt32(0), r.GetString(1)));
            return result;
        }
    }

    public Song? SongAt(string module, int index)
    {
        lock (_lock)
        {
            using var command = Query("SELECT idx, title FROM songs WHERE module = $1 AND idx = $2", module, index);
            using var r = command.ExecuteReader();
            return r.Read() ? new Song(r.GetInt32(0), r.GetString(1)) : null;
        }
    }

    public List<Part> Parts(string module, int song)
    {
        lock (_lock)
        {
            var result = new List<Part>();
            using var command = Query("SELECT idx, kind, text FROM parts WHERE module = $1 AND song = $2 ORDER BY idx", module, song);
            using var r = command.ExecuteReader();
            while (r.Read()) result.Add(new Part(r.GetInt32(0), r.GetString(1), r.GetString(2)));
            return result;
        }
    }

    public int Count(string table, string module)
    {
        lock (_lock)
        {
            using var command = Query($"SELECT COUNT(*) FROM {table} WHERE module = $1", module);
            return Convert.ToInt32(command.ExecuteScalar());
        }
    }

    /// Прибрати модуль — і рядки, і збережений файл.
    public void Delete(string id)
    {
        var known = Find(id);
        lock (_lock)
        {
            using (var transaction = _db.BeginTransaction())
            {
                DeleteRows(id, transaction);
                using var command = Query("DELETE FROM modules WHERE id = $1", id);
                command.Transaction = transaction;
                command.ExecuteNonQuery();
                transaction.Commit();
            }
        }
        if (known != null && known.Original.Length > 0 && known.Original.StartsWith(Paths.Home, StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                if (Directory.Exists(known.Original)) Directory.Delete(known.Original, true);
                else File.Delete(known.Original);
            }
            catch { /* файл уже прибрали */ }
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
            if (char.IsLetterOrDigit(ch)) { output.Append(ch); space = false; }
            else if (!space && output.Length > 0) { output.Append(' '); space = true; }
        }
        return output.ToString().Trim();
    }

    // MARK: Пісенник цілком — для редактора й експорту

    public SongBookData SongBook(string module)
    {
        var known = Find(module) ?? throw new RefusedException(Lang.T("Такого пісенника немає", "No such songbook"));
        var meta = Meta(module);
        var book = new SongBookData
        {
            Title = known.Name, ShortName = known.ShortName,
            Publisher = (string?)meta["publisher"] ?? "", RevisionDate = (string?)meta["revision"] ?? "", Comment = (string?)meta["comment"] ?? "",
        };
        if (meta["vbm"] is JsonObject header)
        {
            book.FormatVersion = (uint?)header["formatVersion"] ?? book.FormatVersion;
            book.Flags = (uint?)header["flags"] ?? book.Flags;
            book.Charset = (uint?)header["charset"] ?? book.Charset;
        }
        lock (_lock)
        {
            using (var command = Query("SELECT idx, title, alt, author, composer, note, props FROM songs WHERE module = $1 ORDER BY idx", module))
            using (var r = command.ExecuteReader())
                while (r.Read())
                    book.Songs.Add(new SongData
                    {
                        Index = r.GetInt32(0), Title = r.GetString(1), AlternateTitle = r.GetString(2), Author = r.GetString(3),
                        Composer = r.GetString(4), Note = r.GetString(5), Properties = r.GetString(6),
                    });
            var bySong = book.Songs.ToDictionary(s => s.Index);
            using (var command = Query("SELECT song, idx, kind, text, align FROM parts WHERE module = $1 ORDER BY song, idx", module))
            using (var r = command.ExecuteReader())
                while (r.Read())
                    if (bySong.TryGetValue(r.GetInt32(0), out var song))
                        song.Parts.Add(new PartData { Index = r.GetInt32(1), Kind = r.GetString(2), Text = r.GetString(3), Align = r.GetInt32(4) });
        }
        foreach (var node in meta["groups"] as JsonArray ?? new JsonArray())
            if (node is JsonObject group)
                book.Groups.Add(((string?)group["name"] ?? "", (group["songs"] as JsonArray ?? new JsonArray()).Select(n => (int?)n ?? 0).ToList()));
        return book;
    }

    /// Записати пісенник цілком — одна транзакція (редактор зберігає все).
    public void SaveSongBook(string id, SongBookData book, string source, string original)
    {
        var writer = Write(id, Songs, book.Title, book.ShortName, source, original);
        try
        {
            foreach (var song in book.Songs)
            {
                writer.Song(song.Index, song.Title, song.AlternateTitle, song.Author, song.Composer, song.Note, song.Properties);
                foreach (var part in song.Parts) writer.Part(song.Index, part.Index, part.Kind, part.Text, part.Align);
            }
            writer.Commit();
        }
        catch
        {
            writer.Abort();
            throw;
        }
        var meta = new JsonObject
        {
            ["publisher"] = book.Publisher, ["revision"] = book.RevisionDate, ["comment"] = book.Comment,
            ["vbm"] = new JsonObject { ["formatVersion"] = book.FormatVersion, ["flags"] = book.Flags, ["charset"] = book.Charset },
            ["groups"] = new JsonArray(book.Groups.Select(g => (JsonNode)new JsonObject
            {
                ["name"] = g.Name, ["songs"] = new JsonArray(g.Songs.Select(s => (JsonNode)s).ToArray()),
            }).ToArray()),
        };
        SetMeta(id, meta);
    }

    // MARK: Запис

    /// Запис модуля — одна транзакція: або модуль ліг увесь, або його немає.
    public Writer Write(string id, string kind, string name, string shortName, string source, string original)
    {
        System.Threading.Monitor.Enter(_lock);
        try
        {
            var transaction = _db.BeginTransaction();
            DeleteRows(id, transaction);
            using (var command = Query("INSERT OR REPLACE INTO modules (id, kind, name, short, source, original, added, meta) VALUES ($1, $2, $3, $4, $5, $6, $7, '')",
                                       id, kind, string.IsNullOrEmpty(name) ? id : name, shortName ?? "", source, original ?? "",
                                       DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()))
            {
                command.Transaction = transaction;
                command.ExecuteNonQuery();
            }
            return new Writer(this, id, transaction);
        }
        catch
        {
            System.Threading.Monitor.Exit(_lock);
            throw;
        }
    }

    /// Запис тримає замок бібліотеки до Commit/Abort: один модуль за раз.
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
            _song = Prepare("INSERT OR REPLACE INTO songs (module, idx, title, fold, alt, author, composer, note, props) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)", 9);
            _part = Prepare("INSERT INTO parts (module, song, idx, kind, text, align) VALUES ($1, $2, $3, $4, $5, $6)", 6);
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

        public void Song(int index, string title) => Song(index, title, "", "", "", "", "");

        public void Song(int index, string title, string alt, string author, string composer, string note, string props)
        {
            Run(_song, _id, index, title, (index + 1) + " " + Fold(title), alt ?? "", author ?? "", composer ?? "", note ?? "", props ?? "");
            SongCount++;
        }

        public void Part(int song, int index, string? kind, string? text) => Part(song, index, kind, text, 0);

        public void Part(int song, int index, string? kind, string? text, int align) =>
            Run(_part, _id, song, index, kind ?? "", text ?? "", align);

        public void Commit()
        {
            if (_finished) return;
            _finished = true;
            try { _transaction.Commit(); }
            finally { Dispose(); }
        }

        public void Abort()
        {
            if (_finished) return;
            _finished = true;
            try { _transaction.Rollback(); }
            catch { /* уже відкочено */ }
            finally { Dispose(); }
        }

        void Dispose()
        {
            _book.Dispose(); _verse.Dispose(); _song.Dispose(); _part.Dispose();
            _transaction.Dispose();
            System.Threading.Monitor.Exit(_library._lock);
        }
    }
}
