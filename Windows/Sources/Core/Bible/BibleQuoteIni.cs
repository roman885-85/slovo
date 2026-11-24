// =============================================================================
//  BibleQuoteIni.cs — розбір bibleqt.ini (з Bible/BibleQuoteIni.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Розбір `bibleqt.ini` — опису модуля у форматі «Цитата з Біблії».
///
/// Формат плоский: `Ключ = значення`, коментарі починаються з `//` або `;`.
/// Книги не виділено секціями — вони йдуть повторюваними блоками
/// `PathName` / `FullName` / `ShortName` / `ChapterQty`, і новий `PathName`
/// означає початок наступної книги.
public static class BibleQuoteIni
{
    public sealed record Result(ModuleInfo Info, IReadOnlyList<BookInfo> Books);

    public static Result Parse(string path) => Parse(File.ReadAllBytes(path));

    public static Result Parse(byte[] data)
    {
        // Кодування ini ми дізнаємося з нього ж, тому читаємо двічі: спершу
        // «як вийде», щоб витягти DefaultEncoding/DesiredFontCharset,
        // потім уже правильно. Ключі латинські, вони переживуть будь-який прогін.
        var probe = CodePage.Decode(data, null);
        var hints = EncodingHints(probe);
        // DefaultEncoding — пряма вказівка автора модуля, вона головніша за все.
        // Далі довіряємо самим байтам: те, що строго читається як UTF-8,
        // майже напевно UTF-8, навіть якщо DesiredFontCharset каже «204».
        var declared = hints.Declared ?? (CodePage.IsValidUtf8(data) ? CodePage.Utf8 : hints.FontCharset);
        var text = CodePage.Decode(data, declared);

        var info = new ModuleInfo { Encoding = declared };

        var books = new List<BookInfo>();
        (string Path, string Full, string[] Short, int Chapters)? pending = null;

        void Flush()
        {
            if (pending is not { } p || p.Path.Length == 0) return;
            books.Add(new BookInfo(books.Count, p.Path, p.Full.Length == 0 ? p.Path : p.Full, p.Short, p.Chapters));
            pending = null;
        }

        foreach (var rawLine in text.SplitLines())
        {
            var line = rawLine.TrimWhitespaces();
            if (line.Length == 0 || line.StartsWith("//", StringComparison.Ordinal) || line.StartsWith(';')) continue;
            var eq = line.IndexOf('=');
            if (eq < 0) continue;

            var key = line[..eq].TrimWhitespaces().ToLowerInvariant();
            var value = line[(eq + 1)..].TrimWhitespaces();

            switch (key)
            {
                case "biblename": info.Name = value; break;
                case "bibleshortname": info.ShortName = value; break;
                case "bible": info.IsBible = IsYes(value); break;
                case "oldtestament": info.HasOldTestament = IsYes(value); break;
                case "newtestament": info.HasNewTestament = IsYes(value); break;
                case "apocrypha": info.HasApocrypha = IsYes(value); break;
                case "greek": info.IsGreek = IsYes(value); break;
                case "language": info.Language = value; break;
                case "copyright": info.Copyright = value; break;
                case "alphabet": info.Alphabet = value; break;
                case "strongnumbers": info.HasStrongNumbers = IsYes(value); break;
                case "chapterzero": info.ChapterZero = IsYes(value); break;
                case "showversenumbers": info.ShowVerseNumbers = IsYes(value); break;
                case "lefttoright": info.RightToLeft = !IsYes(value); break;
                case "chaptersign": info.ChapterSign = value.ToLowerInvariant(); break;
                case "versesign": info.VerseSign = value.ToLowerInvariant(); break;
                case "htmlfilter":
                    info.HtmlFilter = new ValueList<string>(value.Split(' ', StringSplitOptions.RemoveEmptyEntries)
                        .Select(tag => tag.ToLowerInvariant()));
                    break;

                case "pathname":
                    Flush();
                    pending = (value, "", Array.Empty<string>(), 0);
                    break;
                case "fullname":
                    if (pending is { } withFull) pending = withFull with { Full = value };
                    break;
                case "shortname":
                    if (pending is { } withShort)
                        pending = withShort with { Short = value.Split(' ', StringSplitOptions.RemoveEmptyEntries) };
                    break;
                case "chapterqty":
                    if (pending is { } withCount) pending = withCount with { Chapters = SwiftText.ParseInt(value) ?? 0 };
                    break;
            }
        }
        Flush();

        if (info.ShortName.Length == 0)
            info.ShortName = info.Name.Length == 0 ? "?" : SwiftText.PrefixCharacters(info.Name, 8);
        return new Result(info, books);
    }

    private static bool IsYes(string value)
    {
        var v = value.ToLowerInvariant();
        return v.StartsWith('y') || v == "1" || v == "true";
    }

    /// Збирає обидві підказки про кодування, не змішуючи їх: у них різна вага.
    private static (Encoding? Declared, Encoding? FontCharset) EncodingHints(string text)
    {
        Encoding? declared = null;
        Encoding? fontCharset = null;

        foreach (var rawLine in text.SplitLines())
        {
            var line = rawLine.TrimWhitespaces();
            var eq = line.IndexOf('=');
            if (eq < 0) continue;
            var key = line[..eq].TrimWhitespaces().ToLowerInvariant();
            var value = line[(eq + 1)..].TrimWhitespaces();

            if (key == "defaultencoding" && declared == null) declared = CodePage.EncodingForName(value);
            if (key == "desiredfontcharset" && fontCharset == null && SwiftText.ParseInt(value) is { } n)
                fontCharset = CodePage.EncodingForCharset(n);
        }
        return (declared, fontCharset);
    }
}
