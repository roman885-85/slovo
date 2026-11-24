// =============================================================================
//  EBibleVPL.cs — переклади з eBible.org (VPL) → модуль MyBible
//  (з Resources/EBibleVPL.swift)
// =============================================================================
//  SQLite3 (C API) на Mac — тут Microsoft.Data.Sqlite; таблиці й рядки ті самі.
// =============================================================================

using Microsoft.Data.Sqlite;

namespace Slovo.Core;

/// Переклади з eBible.org — у модуль MyBible.
///
/// Власник: «добавить репозитории для скачивания других совместимых модулей
/// (в том числе английских и других переводов)». eBible.org віддає понад
/// півтори тисячі перекладів із вільною ліцензією, але у своїх форматах
/// (HTML, USFM, OSIS, Sword). Найпростіший із них — VPL, «вірш на рядок»:
/// `GEN 1:1 In the beginning…`. Його й перекладаємо в базу MyBible
/// (`info`, `books`, `verses`) — формат, який програма, планшет і пульт уже
/// читають. Назви книг — англійські: у VPL їх немає.
public static class EBibleVPL
{
    public sealed class Failure : Exception
    {
        public enum Kind { NoVerses, Database }

        public Kind FailureKind { get; }

        private Failure(Kind kind, string message) : base(message) => FailureKind = kind;

        public static Failure NoVerses(string name) => new(Kind.NoVerses, OurWords.T("%s: в файле нет ни одного стиха", name));
        public static Failure Database(string detail) => new(Kind.Database, OurWords.T("Не удалось записать модуль: %s", detail));

        public override string ToString() => Message;
    }

    /// Книга: коди VPL і USFM → номер MyBible (той самий канон, що в програмі).
    internal readonly record struct Book(int Number, string Short, string Long);

    /// Коди книг. У VPL eBible.org свої скорочення («JOH», «PHI», «SOL»), в
    /// USFM — інші («JHN», «PHP», «SNG»): приймаємо обидва.
    internal static readonly IReadOnlyDictionary<string, Book> Books = BuildBooks();

    private static Dictionary<string, Book> BuildBooks()
    {
        (string[] Codes, int Number, string Short, string Long)[] rows =
        [
            (["GEN"], 10, "Gen", "Genesis"), (["EXO"], 20, "Exo", "Exodus"), (["LEV"], 30, "Lev", "Leviticus"),
            (["NUM"], 40, "Num", "Numbers"), (["DEU"], 50, "Deu", "Deuteronomy"), (["JOS"], 60, "Josh", "Joshua"),
            (["JDG"], 70, "Judg", "Judges"), (["RUT"], 80, "Ruth", "Ruth"), (["1SA"], 90, "1Sam", "1 Samuel"),
            (["2SA"], 100, "2Sam", "2 Samuel"), (["1KI"], 110, "1Kgs", "1 Kings"), (["2KI"], 120, "2Kgs", "2 Kings"),
            (["1CH"], 130, "1Chr", "1 Chronicles"), (["2CH"], 140, "2Chr", "2 Chronicles"), (["EZR"], 150, "Ezra", "Ezra"),
            (["NEH"], 160, "Neh", "Nehemiah"), (["EST"], 190, "Esth", "Esther"), (["JOB"], 220, "Job", "Job"),
            (["PSA"], 230, "Ps", "Psalms"), (["PRO"], 240, "Prov", "Proverbs"), (["ECC"], 250, "Eccl", "Ecclesiastes"),
            (["SOL", "SNG"], 260, "Song", "Song of Songs"), (["ISA"], 290, "Isa", "Isaiah"), (["JER"], 300, "Jer", "Jeremiah"),
            (["LAM"], 310, "Lam", "Lamentations"), (["EZE", "EZK"], 330, "Ezek", "Ezekiel"), (["DAN"], 340, "Dan", "Daniel"),
            (["HOS"], 350, "Hos", "Hosea"), (["JOE", "JOL"], 360, "Joel", "Joel"), (["AMO"], 370, "Amos", "Amos"),
            (["OBA"], 380, "Obad", "Obadiah"), (["JON"], 390, "Jonah", "Jonah"), (["MIC"], 400, "Mic", "Micah"),
            (["NAH", "NAM"], 410, "Nah", "Nahum"), (["HAB"], 420, "Hab", "Habakkuk"), (["ZEP"], 430, "Zeph", "Zephaniah"),
            (["HAG"], 440, "Hag", "Haggai"), (["ZEC"], 450, "Zech", "Zechariah"), (["MAL"], 460, "Mal", "Malachi"),
            (["MAT"], 470, "Matt", "Matthew"), (["MAR", "MRK"], 480, "Mark", "Mark"), (["LUK"], 490, "Luke", "Luke"),
            (["JOH", "JHN"], 500, "John", "John"), (["ACT"], 510, "Acts", "Acts"), (["ROM"], 520, "Rom", "Romans"),
            (["1CO"], 530, "1Cor", "1 Corinthians"), (["2CO"], 540, "2Cor", "2 Corinthians"), (["GAL"], 550, "Gal", "Galatians"),
            (["EPH"], 560, "Eph", "Ephesians"), (["PHI", "PHP"], 570, "Phil", "Philippians"), (["COL"], 580, "Col", "Colossians"),
            (["1TH"], 590, "1Thess", "1 Thessalonians"), (["2TH"], 600, "2Thess", "2 Thessalonians"),
            (["1TI"], 610, "1Tim", "1 Timothy"), (["2TI"], 620, "2Tim", "2 Timothy"), (["TIT"], 630, "Titus", "Titus"),
            (["PHM"], 640, "Phlm", "Philemon"), (["HEB"], 650, "Heb", "Hebrews"), (["JAM", "JAS"], 660, "Jas", "James"),
            (["1PE"], 670, "1Pet", "1 Peter"), (["2PE"], 680, "2Pet", "2 Peter"), (["1JO", "1JN"], 690, "1John", "1 John"),
            (["2JO", "2JN"], 700, "2John", "2 John"), (["3JO", "3JN"], 710, "3John", "3 John"), (["JUD", "JDE"], 720, "Jude", "Jude"),
            (["REV"], 730, "Rev", "Revelation"),
            // Неканонічні — номери тієї самої схеми MyBible.
            (["TOB"], 170, "Tob", "Tobit"), (["JDT"], 180, "Jdt", "Judith"), (["WIS"], 270, "Wis", "Wisdom"),
            (["SIR"], 280, "Sir", "Sirach"), (["BAR"], 320, "Bar", "Baruch"), (["LJE"], 315, "EpJer", "Letter of Jeremiah"),
            (["1MA"], 462, "1Macc", "1 Maccabees"), (["2MA"], 464, "2Macc", "2 Maccabees"), (["3MA"], 466, "3Macc", "3 Maccabees"),
            (["1ES"], 165, "1Esd", "1 Esdras"), (["2ES"], 468, "2Esd", "2 Esdras"), (["MAN"], 790, "PrMan", "Prayer of Manasseh"),
        ];
        var map = new Dictionary<string, Book>(StringComparer.Ordinal);
        foreach (var (codes, number, shortName, longName) in rows)
            foreach (var code in codes) map[code] = new Book(number, shortName, longName);
        return map;
    }

    /// Опис перекладу, що ляже в таблицю `info`.
    public readonly record struct Description(string Title, string Abbreviation, string Language, string Copyright, bool RightToLeft);

    /// Файл `…_vpl.txt` у розпакованому архіві eBible.org.
    public static string? FindText(string folder)
    {
        var all = EnumerateAll(folder);
        return all.FirstOrDefault(path => SwiftPath.LastComponent(path).ToLowerInvariant().EndsWith("_vpl.txt", StringComparison.Ordinal))
               ?? all.FirstOrDefault(path => SwiftPath.Extension(path).ToLowerInvariant() == "txt" && !SwiftPath.LastComponent(path).StartsWith('.'));
    }

    /// `FileManager.enumerator(at:)`: усе підряд, теки й файли, приховані теж —
    /// згори вниз, кожна тека одразу за своїм вмістом.
    internal static List<string> EnumerateAll(string folder)
    {
        var result = new List<string>();
        void Walk(string current)
        {
            string[] entries;
            try { entries = Directory.GetFileSystemEntries(current); }
            catch (Exception) { return; }
            foreach (var entry in entries.OrderBy(entry => entry, StringComparer.Ordinal))
            {
                result.Add(entry);
                if (Directory.Exists(entry)) Walk(entry);
            }
        }
        Walk(folder);
        return result;
    }

    /// Перекласти VPL у базу MyBible. Пише в тимчасовий файл і лише потім
    /// ставить на місце: обірвана робота не лишає напівмодуля.
    /// Повертає, скільки віршів лягло.
    public static int Convert(string textPath, string destination, Description description)
    {
        var raw = File.ReadAllBytes(textPath);
        var text = CodePage.TryDecode(raw, CodePage.Utf8) ?? System.Text.Encoding.UTF8.GetString(raw);
        var verses = new List<(int Book, int Chapter, int Verse, string Text)>();
        var seen = new HashSet<int>();
        var order = new List<int>();
        foreach (var line in text.SplitLines())
        {
            var rest = line;
            if (rest.StartsWith('\uFEFF')) rest = rest[1..];
            // «GEN 1:1 текст», буває й «PSA 119:1-2 текст».
            var space = rest.IndexOf(' ');
            if (space < 0) continue;
            var code = rest[..space].ToUpperInvariant();
            if (!Books.TryGetValue(code, out var book)) continue;
            rest = rest[(space + 1)..];
            var second = rest.IndexOf(' ');
            if (second < 0) continue;
            var reference = rest[..second];
            var words = rest[(second + 1)..].TrimWhitespaces();
            var pieces = reference.Split(':', StringSplitOptions.RemoveEmptyEntries);
            if (pieces.Length != 2 || SwiftText.ParseInt(pieces[0]) is not { } chapter) continue;
            var verseText = pieces[1].Split('-', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
            if (SwiftText.ParseInt(verseText) is not { } verse || words.Length == 0) continue;
            verses.Add((book.Number, chapter, verse, words));
            if (seen.Add(book.Number)) order.Add(book.Number);
        }
        if (verses.Count == 0) throw Failure.NoVerses(SwiftPath.LastComponent(textPath));

        var folder = SwiftPath.Parent(destination);
        var temporary = Path.Combine(folder, ".slovo-vpl-" + Guid.NewGuid().ToString().ToUpperInvariant() + ".SQLite3");
        try { Directory.CreateDirectory(folder); } catch { }
        try
        {
            var builder = new SqliteConnectionStringBuilder { DataSource = temporary, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = false };
            using (var db = new SqliteConnection(builder.ToString()))
            {
                try { db.Open(); }
                catch (SqliteException) { throw Failure.Database(OurWords.T("база не открылась")); }

                void Exec(string sql)
                {
                    try
                    {
                        using var command = db.CreateCommand();
                        command.CommandText = sql;
                        command.ExecuteNonQuery();
                    }
                    catch (SqliteException error)
                    {
                        throw Failure.Database(error.Message);
                    }
                }

                Exec("CREATE TABLE info (name TEXT, value TEXT);\n"
                     + "CREATE TABLE books (book_color TEXT, book_number NUMERIC, short_name TEXT, long_name TEXT);\n"
                     + "CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT);\n"
                     + "BEGIN;");
                (string, string)[] pairs =
                [
                    ("description", description.Title), ("abbreviation", description.Abbreviation),
                    ("language", description.Language), ("detailed_info", description.Copyright),
                    ("origin", "eBible.org"), ("right_to_left", description.RightToLeft ? "true" : "false"),
                    ("strong_numbers", "false"), ("chapter_string", "Chapter"),
                ];
                try
                {
                    using (var info = db.CreateCommand())
                    {
                        info.CommandText = "INSERT INTO info (name, value) VALUES ($name, $value)";
                        var name = info.Parameters.Add("$name", SqliteType.Text);
                        var value = info.Parameters.Add("$value", SqliteType.Text);
                        foreach (var (key, text2) in pairs)
                        {
                            name.Value = key;
                            value.Value = text2;
                            info.ExecuteNonQuery();
                        }
                    }

                    var names = new Dictionary<int, Book>();
                    foreach (var entry in Books.Values) names.TryAdd(entry.Number, entry);
                    using (var bookRow = db.CreateCommand())
                    {
                        bookRow.CommandText = "INSERT INTO books (book_color, book_number, short_name, long_name) VALUES ('#ffcccccc', $number, $short, $long)";
                        var number = bookRow.Parameters.Add("$number", SqliteType.Integer);
                        var shortName = bookRow.Parameters.Add("$short", SqliteType.Text);
                        var longName = bookRow.Parameters.Add("$long", SqliteType.Text);
                        foreach (var bookNumber in order.OrderBy(value2 => value2))
                        {
                            if (!names.TryGetValue(bookNumber, out var book)) continue;
                            number.Value = bookNumber;
                            shortName.Value = book.Short;
                            longName.Value = book.Long;
                            bookRow.ExecuteNonQuery();
                        }
                    }

                    using (var verseRow = db.CreateCommand())
                    {
                        verseRow.CommandText = "INSERT INTO verses (book_number, chapter, verse, text) VALUES ($book, $chapter, $verse, $text)";
                        var book = verseRow.Parameters.Add("$book", SqliteType.Integer);
                        var chapter = verseRow.Parameters.Add("$chapter", SqliteType.Integer);
                        var verse = verseRow.Parameters.Add("$verse", SqliteType.Integer);
                        var body = verseRow.Parameters.Add("$text", SqliteType.Text);
                        foreach (var item in verses)
                        {
                            book.Value = item.Book;
                            chapter.Value = item.Chapter;
                            verse.Value = item.Verse;
                            body.Value = item.Text;
                            verseRow.ExecuteNonQuery();
                        }
                    }
                }
                catch (SqliteException error)
                {
                    throw Failure.Database(error.Message);
                }
                Exec("COMMIT; CREATE INDEX verses_index ON verses (book_number, chapter, verse);");
            }

            if (SwiftPath.Exists(destination))
            {
                if (Directory.Exists(destination)) Directory.Delete(destination, recursive: true);
                else File.Delete(destination);
            }
            File.Move(temporary, destination);
            return verses.Count;
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
        }
    }
}
