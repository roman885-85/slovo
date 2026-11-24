// =============================================================================
//  SongBookJSON.cs — свій формат пісенника `.songbook` (з Songs/SongBookJSON.swift)
// =============================================================================

using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Свій формат пісенника «Слова» — `.songbook`: JSON в UTF-8.
///
/// Власник: «формат vbi та vbm — це формат старої програми; для нас потрібен свій,
/// але так, щоб не поламати імпорт пісенників чи перекладів з старої програми та
/// інших сумісних форматів». Тому:
///  • програма пише лише `.songbook` — читається будь-яким редактором, лягає
///    в git, без zlib і UTF-16;
///  • `.vbm` лишається форматом ІМПОРТУ (майстер, бібліотека відкриває його
///    як і раніше) та ЕКСПОРТУ (планшет розбирає лише `.vbm`, стара програма на
///    Windows — теж): `SongBookWriter` збирає його з тієї самої структури;
///  • поля заголовка старої програми (`formatVersion`, `flags`, `charset`) їдуть
///    у файлі в гілці `vbm`, щоб експорт віддавав файл, який відкриє оригінал.
public static class SongBookJSON
{
    public const string PathExtension = "songbook";
    public const string Format = "slovo-songbook";
    public const int Version = 1;

    internal sealed class FileRecord
    {
        [JsonRequired, JsonPropertyName("format")] public string Format { get; set; } = "";
        [JsonRequired, JsonPropertyName("version")] public int Version { get; set; }
        [JsonRequired, JsonPropertyName("title")] public string Title { get; set; } = "";
        [JsonRequired, JsonPropertyName("shortName")] public string ShortName { get; set; } = "";
        [JsonRequired, JsonPropertyName("publisher")] public string Publisher { get; set; } = "";
        [JsonRequired, JsonPropertyName("revisionDate")] public string RevisionDate { get; set; } = "";
        [JsonRequired, JsonPropertyName("comment")] public string Comment { get; set; } = "";
        [JsonRequired, JsonPropertyName("groups")] public List<GroupRecord> Groups { get; set; } = new();
        [JsonRequired, JsonPropertyName("songs")] public List<SongRecord> Songs { get; set; } = new();
        [JsonPropertyName("vbm")] public HeaderRecord? Vbm { get; set; }
    }

    internal sealed class HeaderRecord
    {
        [JsonRequired, JsonPropertyName("formatVersion")] public uint FormatVersion { get; set; }
        [JsonRequired, JsonPropertyName("flags")] public uint Flags { get; set; }
        [JsonRequired, JsonPropertyName("charset")] public uint Charset { get; set; }
    }

    internal sealed class GroupRecord
    {
        [JsonRequired, JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonRequired, JsonPropertyName("songs")] public List<int> Songs { get; set; } = new();
    }

    internal sealed class SongRecord
    {
        [JsonRequired, JsonPropertyName("index")] public int Index { get; set; }
        [JsonRequired, JsonPropertyName("title")] public string Title { get; set; } = "";
        [JsonPropertyName("alternateTitle")] public string? AlternateTitle { get; set; }
        [JsonPropertyName("author")] public string? Author { get; set; }
        [JsonPropertyName("composer")] public string? Composer { get; set; }
        [JsonPropertyName("note")] public string? Note { get; set; }
        [JsonPropertyName("properties")] public string? Properties { get; set; }
        [JsonRequired, JsonPropertyName("parts")] public List<PartRecord> Parts { get; set; } = new();
    }

    internal sealed class PartRecord
    {
        [JsonRequired, JsonPropertyName("index")] public int Index { get; set; }
        [JsonRequired, JsonPropertyName("kind")] public string Kind { get; set; } = "";
        [JsonRequired, JsonPropertyName("text")] public string Text { get; set; } = "";
        [JsonPropertyName("align")] public string? Align { get; set; }
    }

    public static bool IsSongBookFile(string path) => SwiftPath.Extension(path).ToLowerInvariant() == PathExtension;

    // ── Запис ───────────────────────────────────────────────────────────────

    public static byte[] Data(SongBook book)
    {
        static string? Blank(string text) => text.Length == 0 ? null : text;
        var file = new FileRecord
        {
            Format = Format,
            Version = Version,
            Title = book.Title,
            ShortName = book.ShortName,
            Publisher = book.Publisher,
            RevisionDate = book.RevisionDate,
            Comment = book.Comment,
            Groups = book.Groups.Select(group => new GroupRecord { Name = group.Name, Songs = group.SongIndices.ToList() }).ToList(),
            Songs = book.Songs.Select(song => new SongRecord
            {
                Index = song.Index,
                Title = song.Title,
                AlternateTitle = Blank(song.AlternateTitle),
                Author = Blank(song.Author),
                Composer = Blank(song.Composer),
                Note = Blank(song.Note),
                Properties = Blank(song.Properties),
                Parts = song.Parts.Select(part => new PartRecord
                {
                    Index = part.Index,
                    Kind = part.Kind,
                    Text = part.Text,
                    Align = part.Align == SongPartAlign.Default ? null : Name(part.Align),
                }).ToList(),
            }).ToList(),
            Vbm = new HeaderRecord { FormatVersion = book.FormatVersion, Flags = book.Flags, Charset = book.Charset },
        };
        // Ключі за абеткою й відступи: файл однаковий за однакового вмісту —
        // зручно порівнювати й тримати в git.
        return SwiftJson.EncodeBytes(file, pretty: true, sortedKeys: true, escapeSlashes: false);
    }

    public static void Write(SongBook book, string path) => SwiftPath.WriteAtomically(path, Data(book));

    /// Зберегти у своєму форматі ПОРУЧ із тим файлом, на який показали: для
    /// `pv3055.vbm` це `pv3055.songbook` (сам `.vbm` не чіпаємо — він для
    /// старої програми). Повертає, куди лягло.
    public static string Save(SongBook book, string path)
    {
        var target = IsSongBookFile(path) ? path : SwiftPath.DeletingExtension(path) + "." + PathExtension;
        Write(book, target);
        return target;
    }

    // ── Читання ─────────────────────────────────────────────────────────────

    public static SongBook Book(byte[] data, string name)
    {
        FileRecord file;
        try
        {
            file = SwiftJson.Decode<FileRecord>(data);
        }
        catch (Exception)
        {
            throw SongBookError.Damaged(name);
        }
        // Порожній елемент масиву Swift теж не прочитав би.
        if (file.Groups.Any(group => group == null) || file.Songs.Any(song => song == null || song.Parts.Any(part => part == null)))
            throw SongBookError.Damaged(name);
        if (file.Format != Format) throw SongBookError.NotASongBook(name);
        var book = new SongBook(
            file.Title, file.ShortName, file.Publisher, file.RevisionDate, file.Comment,
            file.Songs.Select(record => new Song(
                record.Index, record.Title, record.AlternateTitle ?? "", record.Author ?? "",
                record.Composer ?? "", record.Note ?? "", record.Properties ?? "",
                record.Parts.Select(part => new SongPart(part.Index, part.Kind, part.Text, Align(part.Align))))),
            file.Groups.Select(group => new SongGroup(group.Name, group.Songs)));
        if (file.Vbm is { } header)
        {
            book.FormatVersion = header.FormatVersion;
            book.Flags = header.Flags;
            book.Charset = header.Charset;
        }
        return book;
    }

    // ── Вирівнювання ────────────────────────────────────────────────────────

    internal static string Name(SongPartAlign align) => align switch
    {
        SongPartAlign.Left => "left",
        SongPartAlign.Right => "right",
        SongPartAlign.Center => "center",
        _ => "default",
    };

    internal static SongPartAlign Align(string? name) => name switch
    {
        "left" => SongPartAlign.Left,
        "right" => SongPartAlign.Right,
        "center" => SongPartAlign.Center,
        _ => SongPartAlign.Default,
    };
}
