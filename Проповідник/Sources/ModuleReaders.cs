// =============================================================================
//  ModuleReaders.cs — читання модулів різних форматів у свою бібліотеку
// =============================================================================
//  Перенесено з планшета (ModuleReaders.java), а там — із самого «Слова»
//  (SlovoCore: BibleQuoteIni, ChapterHTML, HTMLText, CanonicalBook, CodePage,
//  SongBook), щоб вірш у плані був тим самим текстом, що й на слайді в залі.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;

namespace Propovidnyk;

/// Файл не той, яким себе називає, або зіпсований — сказати людині словами.
public sealed class RefusedException : IOException
{
    public RefusedException(string reason) : base(reason) { }
}

public static class ModuleReaders
{
    static ModuleReaders() => Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

    // MARK: Переклад від «Слова»

    /// Рядки SLOVO-BIBLE, які віддає програма (/api/library/bible).
    public static string ReadSlovoBible(Library library, byte[] data)
    {
        using var reader = new StringReader(Encoding.UTF8.GetString(data));
        var header = reader.ReadLine();
        if (header == null || !header.StartsWith("SLOVO-BIBLE", StringComparison.Ordinal))
            throw new RefusedException(Lang.T("Це не переклад від «Слова»", "This is not a translation from Slovo"));
        var meta = (reader.ReadLine() ?? "").Split('\t');
        if (meta.Length < 4 || meta[0] != "M")
            throw new RefusedException(Lang.T("У відповіді немає опису перекладу", "The answer has no translation description"));
        var id = "slovo:" + meta[1];
        var writer = library.Write(id, Library.Bible, meta[2], meta[3], "slovo", "");
        try
        {
            var book = -1;
            string? line;
            while ((line = reader.ReadLine()) != null)
            {
                if (line.StartsWith("V\t", StringComparison.Ordinal))
                {
                    var v = line.Split('\t', 4);
                    if (v.Length == 4 && book >= 0) writer.Verse(book, Number(v[1]), Number(v[2]), v[3]);
                }
                else if (line.StartsWith("B\t", StringComparison.Ordinal))
                {
                    var b = line.Split('\t');
                    if (b.Length >= 6)
                    {
                        book = Number(b[1]);
                        writer.Book(book, b[2].Length == 0 ? 0 : Number(b[2]), b[3], b[4], Number(b[5]));
                    }
                }
            }
            if (writer.VerseCount == 0) throw new RefusedException(Lang.T("Переклад прийшов порожнім", "The translation arrived empty"));
            writer.Commit();
        }
        catch
        {
            writer.Abort();
            throw;
        }
        return id;
    }

    // MARK: «Цитата з Біблії» (BibleQuote)

    /// Модуль у zip-архіві — з GitHub чи з файла.
    public static string ImportBibleQuoteZip(Library library, string zip, string id, string source)
    {
        var folder = Path.Combine(Paths.Cache, "bq-" + Guid.NewGuid().ToString("N"));
        try
        {
            Unzip(zip, folder);
            var ini = FindIni(folder, 0) ?? throw new RefusedException(Lang.T(
                "В архіві немає bibleqt.ini — це не модуль «Цитати з Біблії»",
                "The archive has no bibleqt.ini — not a Bible Quote module"));
            return ImportBibleQuoteFolder(library, ini, id, source, zip);
        }
        finally
        {
            try { Directory.Delete(folder, true); } catch { /* тимчасова тека */ }
        }
    }

    static string ImportBibleQuoteFolder(Library library, string iniFile, string id, string source, string original)
    {
        var ini = ParseIni(File.ReadAllBytes(iniFile));
        if (ini.Books.Count == 0) throw new RefusedException(Lang.T("У bibleqt.ini немає жодної книги", "bibleqt.ini lists no books"));
        if (!ini.IsBible) throw new RefusedException(Lang.T(
            "Це не Біблія (коментар, словник чи книга) — у план її не взяти",
            "Not a Bible (a commentary, dictionary or book) — it cannot go into a plan"));
        var canon = CanonicalBook.Assign(ini.Books);
        var writer = library.Write(id, Library.Bible, ini.Name, ini.ShortName, source, original);
        try
        {
            var folder = Path.GetDirectoryName(iniFile)!;
            var drop = ini.Strong ? new HashSet<string> { "s" } : new HashSet<string>();
            for (var index = 0; index < ini.Books.Count; index++)
            {
                var book = ini.Books[index];
                writer.Book(index, canon[index], book.Full.Length == 0 ? book.Path : book.Full, string.Join(' ', book.Shorts), book.Chapters);
                var file = Resolve(folder, book.Path);
                if (file == null) continue;
                var html = Decode(File.ReadAllBytes(file), ini.Charset);
                ParseBook(html, ini, book.Chapters, index, drop, writer);
            }
            if (writer.VerseCount == 0) throw new RefusedException(Lang.T("У модулі не знайшлося жодного вірша", "No verses were found in the module"));
            writer.Commit();
        }
        catch
        {
            writer.Abort();
            throw;
        }
        return id;
    }

    public sealed class IniBook
    {
        public string Path = "";
        public string Full = "";
        public List<string> Shorts = new();
        public int Chapters;
    }

    public sealed class Ini
    {
        public string Name = "";
        public string ShortName = "";
        public string ChapterSign = "";
        public string VerseSign = "";
        public bool IsBible = true;
        public bool Strong;
        public bool ChapterZero;
        public Encoding? Charset;
        public readonly List<IniBook> Books = new();
    }

    /// Кодування ini дізнаємося з нього ж, тому читаємо двічі.
    public static Ini ParseIni(byte[] data)
    {
        var probe = Decode(data, null);
        Encoding? declared = null, font = null;
        foreach (var raw in SplitLines(probe))
        {
            var eq = raw.IndexOf('=');
            if (eq < 0) continue;
            var key = raw[..eq].Trim().ToLowerInvariant();
            var value = raw[(eq + 1)..].Trim();
            if (key == "defaultencoding" && declared == null) declared = CharsetForName(value);
            if (key == "desiredfontcharset" && font == null && int.TryParse(value, out var code)) font = CharsetForFont(code);
        }
        var chosen = declared ?? (IsStrictUtf8(data) ? new UTF8Encoding(false) : font);
        var text = Decode(data, chosen);

        var ini = new Ini { Charset = chosen };
        IniBook? pending = null;
        foreach (var raw in SplitLines(text))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("//") || line.StartsWith(';')) continue;
            var eq = line.IndexOf('=');
            if (eq < 0) continue;
            var key = line[..eq].Trim().ToLowerInvariant();
            var value = line[(eq + 1)..].Trim();
            switch (key)
            {
                case "biblename": ini.Name = value; break;
                case "bibleshortname": ini.ShortName = value; break;
                case "bible": ini.IsBible = IsYes(value); break;
                case "strongnumbers": ini.Strong = IsYes(value); break;
                case "chapterzero": ini.ChapterZero = IsYes(value); break;
                case "chaptersign": ini.ChapterSign = value.ToLowerInvariant(); break;
                case "versesign": ini.VerseSign = value.ToLowerInvariant(); break;
                case "pathname":
                    if (pending != null && pending.Path.Length > 0) ini.Books.Add(pending);
                    pending = new IniBook { Path = value };
                    break;
                case "fullname":
                    if (pending != null) pending.Full = value;
                    break;
                case "shortname":
                    if (pending != null) pending.Shorts = value.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
                    break;
                case "chapterqty":
                    if (pending != null) pending.Chapters = Number(value);
                    break;
            }
        }
        if (pending != null && pending.Path.Length > 0) ini.Books.Add(pending);
        if (ini.ShortName.Length == 0) ini.ShortName = ini.Name.Length == 0 ? "?" : ini.Name[..Math.Min(8, ini.Name.Length)];
        return ini;
    }

    static IEnumerable<string> SplitLines(string text) => text.Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.None);

    static bool IsYes(string value)
    {
        var v = value.ToLowerInvariant();
        return v.StartsWith('y') || v == "1" || v == "true";
    }

    // MARK: Розділи й вірші

    /// Файл книги — на розділи й вірші за маркерами ChapterSign і VerseSign.
    /// Будуємо обидва прочитання (з номером і без) і беремо ближче до ChapterQty.
    public static void ParseBook(string html, Ini ini, int expected, int bookIndex, HashSet<string> drop, Library.Writer writer)
    {
        var first = ini.ChapterZero ? 0 : 1;
        var starts = ChapterStarts(html, ini, expected);
        if (starts.Count == 0)
        {
            ParseVerses(html, ini.VerseSign, bookIndex, first, drop, writer);
            return;
        }
        var number = first;
        for (var i = 0; i < starts.Count; i++)
        {
            var end = i + 1 < starts.Count ? starts[i + 1].Start : html.Length;
            ParseVerses(html[starts[i].End..end], ini.VerseSign, bookIndex, number, drop, writer);
            number++;
        }
    }

    readonly record struct Mark(int Start, int End);

    static List<Mark> ChapterStarts(string text, Ini ini, int expected)
    {
        var chapterMarks = Occurrences(ini.ChapterSign, text);
        if (chapterMarks.Count == 0) return chapterMarks;
        var verseMarks = Occurrences(ini.VerseSign, text);
        var all = chapterMarks.Concat(verseMarks).OrderBy(m => m.Start).ToList();
        var strict = new List<Mark>();
        foreach (var mark in chapterMarks)
        {
            var headEnd = text.Length;
            foreach (var other in all)
            {
                if (other.Start >= mark.End) { headEnd = other.Start; break; }
            }
            if (headEnd <= mark.End) continue;
            var digit = false;
            for (var i = mark.End; i < headEnd; i++)
            {
                if (char.IsDigit(text[i])) { digit = true; break; }
            }
            if (digit) strict.Add(mark);
        }
        if (expected <= 0) return strict;
        return Math.Abs(chapterMarks.Count - expected) < Math.Abs(strict.Count - expected) ? chapterMarks : strict;
    }

    static void ParseVerses(string slice, string verseSign, int bookIndex, int chapter, HashSet<string> drop, Library.Writer writer)
    {
        var marks = Occurrences(verseSign, slice);
        var fallback = 1;
        for (var i = 0; i < marks.Count; i++)
        {
            var end = i + 1 < marks.Count ? marks[i + 1].Start : slice.Length;
            var cursor = marks[i].End;
            while (cursor < end && (char.IsWhiteSpace(slice[cursor]) || slice[cursor] == '​')) cursor++;
            var digitsStart = cursor;
            while (cursor < end && char.IsDigit(slice[cursor])) cursor++;
            var number = fallback;
            if (cursor > digitsStart)
            {
                number = Number(slice[digitsStart..cursor]);
                // Номер, обгорнутий у тег (<sup>12</sup>текст), — з'їдаємо закривальний тег.
                var look = cursor;
                while (look < end && char.IsWhiteSpace(slice[look])) look++;
                if (look + 1 < end && slice[look] == '<' && slice[look + 1] == '/')
                {
                    var close = slice.IndexOf('>', look);
                    if (close >= 0 && close < end) cursor = close + 1;
                }
            }
            fallback = number + 1;
            var text = Plain(slice[cursor..end], drop);
            if (text.Length > 0) writer.Verse(bookIndex, chapter, number, text);
        }
    }

    static List<Mark> Occurrences(string marker, string text)
    {
        var found = new List<Mark>();
        if (string.IsNullOrEmpty(marker)) return found;
        var from = 0;
        while (from + marker.Length <= text.Length)
        {
            var at = text.IndexOf(marker, from, StringComparison.OrdinalIgnoreCase);
            if (at < 0) break;
            found.Add(new Mark(at, at + marker.Length));
            from = at + marker.Length;
        }
        return found;
    }

    // MARK: HTML — у чистий текст

    static readonly Dictionary<string, string> Entities = new()
    {
        ["nbsp"] = " ", ["amp"] = "&", ["lt"] = "<", ["gt"] = ">", ["quot"] = "\"", ["apos"] = "'",
        ["mdash"] = "—", ["ndash"] = "–", ["hellip"] = "…", ["laquo"] = "«", ["raquo"] = "»",
    };

    /// drop — теги, у яких викидається й уміст (номери Стронга <s>7225</s>).
    public static string Plain(string html, HashSet<string> drop)
    {
        var output = new StringBuilder(html.Length);
        var i = 0;
        string? skipping = null;
        while (i < html.Length)
        {
            var ch = html[i];
            if (ch != '<')
            {
                if (skipping == null) output.Append(ch);
                i++;
                continue;
            }
            var close = html.IndexOf('>', i);
            if (close < 0)
            {
                if (skipping == null) output.Append(html, i, html.Length - i);
                break;
            }
            var body = html[(i + 1)..close];
            var name = TagName(body);
            if (skipping != null)
            {
                if (body.StartsWith('/') && name == skipping) skipping = null;
            }
            else if (!body.StartsWith('/') && !body.EndsWith('/') && drop.Contains(name))
            {
                skipping = name;
            }
            else if (name is "br" or "p" or "div" or "pb" or "td" or "tr")
            {
                output.Append(' ');
            }
            i = close + 1;
        }
        return Condense(DecodeEntities(output.ToString()).Replace("​", ""));
    }

    static string TagName(string body)
    {
        var rest = body.StartsWith('/') ? body[1..] : body;
        var end = rest.IndexOfAny(new[] { ' ', '\t', '/', '\n' });
        return (end < 0 ? rest : rest[..end]).ToLowerInvariant();
    }

    static string DecodeEntities(string text)
    {
        if (!text.Contains('&')) return text;
        var output = new StringBuilder(text.Length);
        var i = 0;
        while (i < text.Length)
        {
            var ch = text[i];
            var semi = ch == '&' ? text.IndexOf(';', i) : -1;
            if (semi > i && semi - i <= 12)
            {
                var body = text[(i + 1)..semi];
                string? replacement = null;
                if (body.StartsWith('#'))
                {
                    var hex = body.StartsWith("#x", StringComparison.OrdinalIgnoreCase);
                    if (int.TryParse(hex ? body[2..] : body[1..], hex ? NumberStyles.HexNumber : NumberStyles.Integer,
                                     CultureInfo.InvariantCulture, out var code) && code is >= 0 and <= 0x10FFFF and not (>= 0xD800 and <= 0xDFFF))
                        replacement = char.ConvertFromUtf32(code);
                }
                else if (Entities.TryGetValue(body.ToLowerInvariant(), out var known))
                {
                    replacement = known;
                }
                if (replacement != null)
                {
                    output.Append(replacement);
                    i = semi + 1;
                    continue;
                }
            }
            output.Append(ch);
            i++;
        }
        return output.ToString();
    }

    static string Condense(string text)
    {
        var output = new StringBuilder(text.Length);
        var space = false;
        foreach (var ch in text)
        {
            if (char.IsWhiteSpace(ch) || ch == ' ')
            {
                if (!space && output.Length > 0) output.Append(' ');
                space = true;
            }
            else
            {
                output.Append(ch);
                space = false;
            }
        }
        return output.ToString().TrimEnd(' ');
    }

    // MARK: MyBible

    /// Модуль MyBible (.SQLite3): таблиці info, books, verses. Номери книг у
    /// ньому — ті самі наскрізні номери канону, що й у програмі.
    public static string ImportMyBible(Library library, string file, string id, string source)
    {
        SqliteConnection db;
        try
        {
            db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = file, Mode = SqliteOpenMode.ReadOnly }.ToString());
            db.Open();
        }
        catch
        {
            throw new RefusedException(Lang.T("Файл не відкривається як модуль MyBible", "The file does not open as a MyBible module"));
        }
        using (db)
        {
            var name = Info(db, "description");
            var baseName = System.IO.Path.GetFileName(file);
            if (baseName.EndsWith(".sqlite3", StringComparison.OrdinalIgnoreCase)) baseName = baseName[..^8];
            var writer = library.Write(id, Library.Bible, name.Length == 0 ? baseName : name, baseName, source, file);
            try
            {
                var drop = new HashSet<string> { "s", "m", "f" };
                var position = new Dictionary<int, int>();
                using (var command = db.CreateCommand())
                {
                    command.CommandText = "SELECT b.book_number, b.short_name, b.long_name, MAX(v.chapter) FROM books AS b " +
                                          "JOIN verses AS v ON v.book_number = b.book_number " +
                                          "GROUP BY b.book_number, b.short_name, b.long_name ORDER BY b.book_number";
                    using var r = command.ExecuteReader();
                    var index = 0;
                    while (r.Read())
                    {
                        var number = r.GetInt32(0);
                        position[number] = index;
                        writer.Book(index, number, r.IsDBNull(2) ? "" : r.GetString(2), r.IsDBNull(1) ? "" : r.GetString(1), r.IsDBNull(3) ? 0 : r.GetInt32(3));
                        index++;
                    }
                }
                using (var command = db.CreateCommand())
                {
                    command.CommandText = "SELECT book_number, chapter, verse, text FROM verses ORDER BY book_number, chapter, verse";
                    using var r = command.ExecuteReader();
                    while (r.Read())
                    {
                        if (!position.TryGetValue(r.GetInt32(0), out var book)) continue;
                        var text = Plain(r.IsDBNull(3) ? "" : r.GetString(3), drop);
                        if (text.Length > 0) writer.Verse(book, r.GetInt32(1), r.GetInt32(2), text);
                    }
                }
                if (writer.VerseCount == 0) throw new RefusedException(Lang.T("У модулі не знайшлося жодного вірша", "No verses were found in the module"));
                writer.Commit();
            }
            catch (RefusedException)
            {
                writer.Abort();
                throw;
            }
            catch (Exception error)
            {
                writer.Abort();
                throw new RefusedException(Lang.T("Модуль MyBible не прочитався: ", "The MyBible module could not be read: ") + error.Message);
            }
        }
        return id;
    }

    static string Info(SqliteConnection db, string key)
    {
        try
        {
            using var command = db.CreateCommand();
            command.CommandText = "SELECT value FROM info WHERE name = $key";
            command.Parameters.AddWithValue("$key", key);
            return (command.ExecuteScalar() as string)?.Trim() ?? "";
        }
        catch
        {
            return "";
        }
    }

    // MARK: Пісенник VisioBible (.vbm)

    /// Короткий заголовок і один zlib-потік; рядки всередині — UInt16 з числом
    /// символів і самі символи в UTF-16LE (див. SongBook.swift у програмі).
    public static string ImportVbm(Library library, byte[] data, string fileName, string source, string original)
    {
        var magic = Encoding.ASCII.GetBytes("VisioBibleModule");
        var damaged = "«" + fileName + Lang.T("»: файл пошкоджено", "»: the file is damaged");
        if (data.Length <= 24 || !data.AsSpan(0, magic.Length).SequenceEqual(magic))
            throw new RefusedException("«" + fileName + Lang.T("»: це не пісенник .vbm", "»: not a .vbm songbook"));
        long compressed = BitConverter.ToUInt32(data, 20);
        var start = data.Length - 4 - compressed;
        if (start <= 16 || start >= data.Length) throw new RefusedException(damaged);
        byte[] body;
        try
        {
            using var input = new ZLibStream(new MemoryStream(data, (int)start, data.Length - (int)start), CompressionMode.Decompress);
            using var output = new MemoryStream(data.Length * 4);
            input.CopyTo(output);
            body = output.ToArray();
        }
        catch
        {
            throw new RefusedException(damaged);
        }
        var reader = new BinaryText(body);
        var title = reader.Text();
        var shortName = reader.Text();
        reader.Text(); reader.Text(); reader.Text(); // видавець, дата редакції, коментар
        var count = reader.U32();
        if (count > 100_000) throw new RefusedException(damaged);

        // Ім'я файла — з регістром: під ним пісенник лежить і в програмі.
        var id = "songs:" + fileName;
        var writer = library.Write(id, Library.Songs, title.Length == 0 ? fileName : title, shortName, source, original);
        try
        {
            for (var index = 0; index < count; index++)
            {
                var songTitle = reader.Text();
                for (var skip = 0; skip < 5; skip++) reader.Text(); // друга назва, автор, композитор, примітка, властивості
                var parts = reader.U32();
                if (parts > 1000) throw new RefusedException(damaged);
                writer.Song(index, songTitle);
                for (var part = 0; part < parts; part++)
                {
                    var kind = reader.Text();
                    var text = reader.Text();
                    reader.U32(); // вирівнювання
                    writer.Part(index, part, kind, text);
                }
            }
            writer.Commit();
        }
        catch (RefusedException)
        {
            writer.Abort();
            throw;
        }
        catch
        {
            writer.Abort();
            throw new RefusedException(damaged);
        }
        return id;
    }

    sealed class BinaryText
    {
        readonly byte[] _data;
        int _at;
        public BinaryText(byte[] data) => _data = data;

        public uint U32()
        {
            if (_at + 4 > _data.Length) throw new EndOfStreamException();
            var value = BitConverter.ToUInt32(_data, _at);
            _at += 4;
            return value;
        }

        public string Text()
        {
            if (_at + 2 > _data.Length) throw new EndOfStreamException();
            int length = BitConverter.ToUInt16(_data, _at);
            _at += 2;
            if (_at + length * 2 > _data.Length) throw new EndOfStreamException();
            var text = Encoding.Unicode.GetString(_data, _at, length * 2);
            _at += length * 2;
            return text;
        }
    }

    // MARK: Свій пісенник «Слова» (.songbook)

    /// JSON у UTF-8 (SongBookJSON.swift). Програма везе на планшет .vbm, але
    /// з GitHub ресурсів «Слова» й з диска приходить саме .songbook.
    public static string ImportSongbookJson(Library library, byte[] data, string fileName, string source, string original)
    {
        JsonObject? json;
        try { json = JsonNode.Parse(Encoding.UTF8.GetString(data)) as JsonObject; }
        catch { json = null; }
        if (json == null || (string?)json["format"] != "slovo-songbook")
            throw new RefusedException("«" + fileName + Lang.T("»: це не пісенник .songbook", "»: not a .songbook songbook"));
        var id = "songs:" + fileName;
        var title = (string?)json["title"] ?? "";
        var writer = library.Write(id, Library.Songs, title.Length == 0 ? fileName : title, (string?)json["shortName"] ?? "", source, original);
        try
        {
            var songs = json["songs"] as JsonArray ?? new JsonArray();
            for (var index = 0; index < songs.Count; index++)
            {
                var song = songs[index] as JsonObject;
                writer.Song(index, (string?)song?["title"] ?? "");
                var parts = song?["parts"] as JsonArray ?? new JsonArray();
                for (var part = 0; part < parts.Count; part++)
                    writer.Part(index, part, (string?)parts[part]?["kind"], (string?)parts[part]?["text"]);
            }
            writer.Commit();
        }
        catch
        {
            writer.Abort();
            throw;
        }
        return id;
    }

    // MARK: Кодування

    /// Оголошене кодування, потім суворий UTF-8, потім CP1251 і CP1252.
    public static string Decode(byte[] data, Encoding? declared)
    {
        var candidates = new List<Encoding>();
        if (declared != null) candidates.Add(declared);
        candidates.Add(new UTF8Encoding(false));
        candidates.Add(Encoding.GetEncoding(1251));
        candidates.Add(Encoding.GetEncoding(1252));
        foreach (var encoding in candidates)
        {
            var text = Strict(data, encoding);
            if (!string.IsNullOrEmpty(text)) return text.TrimStart('﻿');
        }
        return Encoding.UTF8.GetString(data).TrimStart('﻿');
    }

    static string? Strict(byte[] data, Encoding encoding)
    {
        try
        {
            var strict = Encoding.GetEncoding(encoding.CodePage, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback);
            return strict.GetString(data);
        }
        catch
        {
            return null;
        }
    }

    static bool IsStrictUtf8(byte[] data) => Strict(data, Encoding.UTF8) != null;

    static Encoding? CharsetForName(string raw)
    {
        var name = raw.Trim().ToLowerInvariant();
        try
        {
            if (name is "utf-8" or "utf8") return new UTF8Encoding(false);
            if (name is "utf-16" or "utf16") return Encoding.Unicode;
            if (name.StartsWith("cp125") && name.Length == 6) return Encoding.GetEncoding(int.Parse(name[2..], CultureInfo.InvariantCulture));
            if (name.StartsWith("windows-125")) return Encoding.GetEncoding(name);
        }
        catch
        {
            // Невідоме ім'я кодування.
        }
        return null;
    }

    static Encoding? CharsetForFont(int code) => code switch
    {
        0 => Encoding.GetEncoding(1252),
        161 => Encoding.GetEncoding(1253),
        162 => Encoding.GetEncoding(1254),
        163 => Encoding.GetEncoding(1258),
        177 => Encoding.GetEncoding(1255),
        178 => Encoding.GetEncoding(1256),
        186 => Encoding.GetEncoding(1257),
        204 => Encoding.GetEncoding(1251),
        238 => Encoding.GetEncoding(1250),
        _ => null,
    };

    // MARK: Файли

    /// Розпакувати архів у теку. Шляхи, що виходять за теку, пропускаємо.
    static void Unzip(string zip, string folder)
    {
        Directory.CreateDirectory(folder);
        var root = System.IO.Path.GetFullPath(folder) + System.IO.Path.DirectorySeparatorChar;
        try
        {
            using var archive = ZipFile.OpenRead(zip);
            foreach (var entry in archive.Entries)
            {
                var target = System.IO.Path.GetFullPath(System.IO.Path.Combine(folder, entry.FullName));
                if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;
                if (entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\'))
                {
                    Directory.CreateDirectory(target);
                    continue;
                }
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(target)!);
                entry.ExtractToFile(target, true);
            }
        }
        catch (InvalidDataException)
        {
            throw new RefusedException(Lang.T("Архів пошкоджено або це не zip", "The archive is damaged or not a zip"));
        }
    }

    static string? FindIni(string folder, int depth)
    {
        foreach (var file in Directory.GetFiles(folder))
            if (System.IO.Path.GetFileName(file).Equals("bibleqt.ini", StringComparison.OrdinalIgnoreCase)) return file;
        if (depth >= 3) return null;
        foreach (var sub in Directory.GetDirectories(folder))
        {
            var found = FindIni(sub, depth + 1);
            if (found != null) return found;
        }
        return null;
    }

    /// Регістр імен в ini і на диску збігається не завжди.
    static string? Resolve(string folder, string name)
    {
        var direct = System.IO.Path.Combine(folder, name.Replace('\\', System.IO.Path.DirectorySeparatorChar));
        if (File.Exists(direct)) return direct;
        return Directory.GetFiles(folder).FirstOrDefault(f => System.IO.Path.GetFileName(f).Equals(name, StringComparison.OrdinalIgnoreCase));
    }

    static int Number(string text) => int.TryParse(text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : 0;
}

// MARK: Наскрізна нумерація книг

public static class CanonicalBook
{
    static readonly (int Number, string Aliases)[] Table =
    {
        (10, "ge gen gn genesis"), (20, "ex exo exod exodus"), (30, "le lev lv leviticus levit"),
        (40, "nu num nm numb numbers"), (50, "de deu deut dt deuteron deuteronomy"),
        (60, "jos josh joshua"), (70, "jdg judg judge judges"), (80, "ru rut rth rt ruth"),
        (90, "1sa 1s 1sam 1sm 1sml 1samuel"), (100, "2sa 2s 2sam 2sm 2sml 2samuel"),
        (110, "1ki 1k 1kn 1kg 1king 1kng 1kings"), (120, "2ki 2k 2kn 2kg 2king 2kng 2kings"),
        (130, "1ch 1chr 1chron 1chronicles 1par"), (140, "2ch 2chr 2chron 2chronicles 2par"),
        (150, "ezr ezra"), (160, "ne neh nehemiah"), (190, "es est esth esther"),
        (220, "job jb"), (230, "ps psa psalm psalms psm"), (240, "pr pro prov proverbs"),
        (250, "ec ecc eccl ecclesiastes"), (260, "so son song sos songofsongs canticles"),
        (290, "isa is isaiah"), (300, "jer je jeremiah"), (310, "la lam lamentations"),
        (330, "eze ezk ezek ezekiel"), (340, "da dan daniel"), (350, "ho hos hosea"),
        (360, "joe jol joel"), (370, "am amo amos"), (380, "ob oba obad obadiah"),
        (390, "jon jnh jonah"), (400, "mic mi micah"), (410, "na nah nahum"),
        (420, "hab hb habakkuk"), (430, "zep zph zephaniah"), (440, "hag hg haggai"),
        (450, "zec zch zechariah"), (460, "mal ml malachi"), (470, "mt mat matt matthew"),
        (480, "mr mk mar mark"), (490, "lu lk luk luke"), (500, "joh jn john"),
        (510, "ac act acts"), (520, "ro rom romans"), (530, "1co 1cor 1corinthians"),
        (540, "2co 2cor 2corinthians"), (550, "ga gal galatians"), (560, "eph ep ephesians"),
        (570, "php phil philippians"), (580, "col cl colossians"),
        (590, "1th 1thes 1thess 1thessalonians"), (600, "2th 2thes 2thess 2thessalonians"),
        (610, "1ti 1tim 1timothy"), (620, "2ti 2tim 2timothy"), (630, "tit tt titus"),
        (640, "phm phlm philemon"), (650, "heb hebrews"), (660, "jas jam jm james"),
        (670, "1pe 1pet 1pt 1peter"), (680, "2pe 2pet 2pt 2peter"), (690, "1jo 1jn 1john"),
        (700, "2jo 2jn 2john"), (710, "3jo 3jn 3john"), (720, "jud jde jude"),
        (730, "re rev rv revelation apocalypse"),
        (165, "2ezr 2ездр 2езд 2ездра 2ездры 1esd 1esdras"), (468, "3ezr 3ездр 3езд 3ездра 3ездры 2esdras"),
        (170, "tob тов товит tobit tobias tobías"), (180, "jdt иудиф иудифь иудф judith judf judth judit"),
        (270, "wis прем премудр премудрсоломона премудрсоломон премсол wisdom sabiduria"),
        (280, "sir сир сирах ecclesiasticus eclesiastico"), (315, "послиер послиерем послиеремии epjer letjer"),
        (320, "bar вар варух baruch baruc"), (462, "1mac 1макк 1мак 1маккав 1maccabees 1mach"),
        (464, "2mac 2макк 2мак 2маккав 2maccabees 2mach"), (466, "3mac 3макк 3мак 3маккав 3maccabees 3mach"),
        (790, "молман молитваманассии manasseh prman"),
        (60, "ios iosua joz jozue"), (70, "sdz sedz sedziow sędz sędziów judecatori"),
        (110, "1im 1imp 1imparati 1krl"), (120, "2im 2imp 2imparati 2krl"),
        (130, "1cr 1cron 1cronici 1krn"), (140, "2cr 2cron 2cronici 2krn"), (220, "iov hi hiob"),
        (260, "cant cc cantarea pnp"), (300, "ie ier ieremia"), (310, "plang pl plangerile lm"),
        (350, "os osea oz"), (360, "ioel"), (380, "ab abd abdias abdia abdiasza"),
        (390, "iona jon"), (430, "tef tefania sofoniasza sofonia"),
    };

    static readonly Dictionary<string, int> ByAlias = new();
    static readonly int[] Order = new int[66];

    static CanonicalBook()
    {
        for (var i = 0; i < Table.Length; i++)
        {
            if (i < 66) Order[i] = Table[i].Number;
            foreach (var alias in Table[i].Aliases.Split(' ')) ByAlias.TryAdd(alias, Table[i].Number);
        }
    }

    public static int Number(string raw)
    {
        var key = new string(raw.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
        return ByAlias.TryGetValue(key, out var found) ? found : 0;
    }

    /// Спершу за скороченнями, а для повної Біблії з 66 книг у звичайному
    /// порядку — за місцем у списку.
    public static int[] Assign(List<ModuleReaders.IniBook> books)
    {
        var recognised = new int[books.Count];
        for (var i = 0; i < books.Count; i++)
        {
            var found = 0;
            foreach (var alias in books[i].Shorts)
            {
                found = Number(alias);
                if (found != 0) break;
            }
            if (found == 0) found = Number(books[i].Full);
            recognised[i] = found;
        }
        if (books.Count != Order.Length) return recognised;
        int agreed = 0, disagreed = 0;
        for (var i = 0; i < Order.Length; i++)
        {
            if (recognised[i] == 0) continue;
            if (recognised[i] == Order[i]) agreed++; else disagreed++;
        }
        if (agreed < 40 || disagreed * 10 > agreed) return recognised;
        return (int[])Order.Clone();
    }
}
