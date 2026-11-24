// =============================================================================
//  SongBook.cs — пісенник старої програми `.vbm` і свій `.songbook`
//  (з Songs/SongBook.swift)
// =============================================================================
//  У Swift пісня, частина і пісенник — значення (struct): копія ніколи не
//  тягне за собою оригінал. Тут:
//    SongPart  — record struct (копіюється сам);
//    Song, SongGroup, SongBook — класи з глибокою копією `Copy()` і
//    порівнянням за вмістом. Хто бере пісню, щоб змінити, бере копію —
//    так робить і SongBookEditor.
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Частина пісні: куплет, приспів, місток… Назва частини задає і її колір
/// у списку — відповідність лежить у `[SongChunksColors]` налаштувань старої програми.
public record struct SongPart
{
    public int Index;
    public string Kind;
    public string Text;
    /// Вирівнювання тексту частини (кнопки 9–12 панелі «Текст», розділ 5.3.9.2).
    public SongPartAlign Align;

    public SongPart(int index, string kind, string text, SongPartAlign align = SongPartAlign.Default)
    {
        Index = index;
        Kind = kind;
        Text = text;
        Align = align;
    }

    public readonly int Id => Index;

    /// Текст, розбитий на рядки так, як його набирали, — перенос рядка
    /// в пісні значущий, його не можна схлопувати як у біблійному вірші.
    public readonly string[] Lines => Text.Replace("\r\n", "\n").Split('\n');
}

public sealed partial class Song : IEquatable<Song>
{
    public int Index;
    public string Title;
    public string AlternateTitle;
    public string Author;
    public string Composer;
    public string Note;
    public string Properties;
    public List<SongPart> Parts;

    public Song(int index, string title, string alternateTitle = "", string author = "",
                string composer = "", string note = "", string properties = "",
                IEnumerable<SongPart>? parts = null)
    {
        Index = index;
        Title = title;
        AlternateTitle = alternateTitle;
        Author = author;
        Composer = composer;
        Note = note;
        Properties = properties;
        Parts = parts?.ToList() ?? new List<SongPart>();
    }

    public int Id => Index;

    public string? Subtitle
    {
        get
        {
            var credits = new[] { Author, Composer }.Where(credit => credit.Length > 0).ToList();
            if (credits.Count == 0) return null;
            // Автор слів і музики часто збігаються — дублювати ім'я нема чого.
            return credits.Count == 1 || SwiftText.Same(credits[0], credits[1])
                ? credits[0]
                : string.Join(" / ", credits);
        }
    }

    /// Глибока копія: у Swift пісня — значення.
    public Song Copy() => new(Index, Title, AlternateTitle, Author, Composer, Note, Properties, Parts);

    public bool Equals(Song? other) =>
        other is not null && Index == other.Index && Title == other.Title && AlternateTitle == other.AlternateTitle
        && Author == other.Author && Composer == other.Composer && Note == other.Note
        && Properties == other.Properties && Parts.SequenceEqual(other.Parts);

    public override bool Equals(object? obj) => obj is Song other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(Index, Title, Parts.Count);
}

/// Пісенник у форматі старої програми (`.vbm`).
///
/// Файл — це короткий заголовок і один zlib-потік слідом. Усередині потоку все
/// одноманітно: рядок це UInt16 з числом символів і самі символи в UTF-16LE.
///
/// Зсув потоку не фіксований: у заголовку лежать назва і коротке ім'я
/// збірника, а вони різної довжини. Зате на зсуві 20 записано розмір стиснутих
/// даних, і потік завжди впирається в останні чотири байти файла — звідси
/// і рахуємо початок.
///
/// Розкладка заголовка (перевірена на всіх 22 пісенниках користувача):
///     0   «VisioBibleModule»
///     16  UInt32 версія формату (0x0102)
///     20  UInt32 розмір стиснутих даних
///     24  UInt32 розмір розпакованих даних
///     28  UInt32 ознака (скрізь 1)
///     32  UInt32 кодування Пісенника (0x200 — UNICODE; 1 трапляється в
///         одному старому збірнику, про такі й каже розділ 5.3.9.3)
///     36  36 нульових байтів
///     72  коротке ім'я і назва (дублі того, що лежить у потоці)
///         UInt32 0, потім сам zlib-потік і UInt32 0 у хвості файла
public sealed class SongBook
{
    public string Title;
    public string ShortName;
    public string Publisher;
    public string RevisionDate;
    public string Comment;
    public List<Song> Songs;
    /// Користувацькі групи пісень (список «Група», розділ 5.3.1).
    public List<SongGroup> Groups;

    /// Поля заголовка файла. Їх нема чого показувати, але при збереженні треба
    /// повернути рівно ті самі значення — інакше оригінал не відкриє файл.
    public uint FormatVersion;
    public uint Flags;
    public uint Charset;

    public const uint CurrentFormatVersion = 0x0102;
    /// Значення поля «Кодування», яке стоїть у всіх збірниках, крім
    /// одного старого. Посібник (5.3.9.3) вимагає для нових Пісенників
    /// саме «UNICODE».
    public const uint UnicodeCharset = 0x200;

    public SongBook(string title, string shortName, string publisher = "", string revisionDate = "",
                    string comment = "", IEnumerable<Song>? songs = null, IEnumerable<SongGroup>? groups = null,
                    uint formatVersion = CurrentFormatVersion, uint flags = 1, uint charset = UnicodeCharset)
    {
        Title = title;
        ShortName = shortName;
        Publisher = publisher;
        RevisionDate = revisionDate;
        Comment = comment;
        Songs = songs?.ToList() ?? new List<Song>();
        Groups = groups?.ToList() ?? new List<SongGroup>();
        FormatVersion = formatVersion;
        Flags = flags;
        Charset = charset;
    }

    /// Глибока копія: у Swift пісенник — значення.
    public SongBook Copy() =>
        new(Title, ShortName, Publisher, RevisionDate, Comment,
            Songs.Select(song => song.Copy()), Groups.Select(group => group.Copy()),
            FormatVersion, Flags, Charset);

    /// `SongBook(fileAt:)`.
    public static SongBook FromFile(string path)
    {
        var data = File.ReadAllBytes(path);
        var name = SwiftPath.LastComponent(SwiftPath.DeletingExtension(path));
        // Свій формат `.songbook` (JSON) — за розширенням або за першим
        // знаком; `.vbm` старої програми — далі, як і раніше.
        if (SongBookJSON.IsSongBookFile(path) || (data.Length > 0 && data[0] == (byte)'{'))
            return SongBookJSON.Book(data, name);
        return FromData(data, name);
    }

    /// `SongBook(data:name:)` — розбір `.vbm`.
    public static SongBook FromData(byte[] data, string name)
    {
        if (data.Length <= 24 || !data.AsSpan(0, 16).SequenceEqual("VisioBibleModule"u8))
            throw SongBookError.NotASongBook(name);
        uint Header(int offset) => data.Length >= offset + 4 ? BitConverter.ToUInt32(data, offset) : 0;
        var formatVersion = Header(16);
        var flags = Header(28);
        var charset = Header(32);

        var compressedSize = (int)Header(20);
        var start = data.Length - 4 - compressedSize;
        if (start <= 16 || start >= data.Length) throw SongBookError.Damaged(name);

        var body = Inflate.Zlib(data[start..]);
        var reader = new SongBinaryReader(body);

        var title = reader.String();
        var shortName = reader.String();
        var publisher = reader.String();
        var revisionDate = reader.String();
        var comment = reader.String();

        var count = (int)reader.UInt32();
        if (count < 0 || count >= 100_000) throw SongBookError.Damaged(name);

        var songs = new List<Song>(count);
        for (var index = 0; index < count; index++)
        {
            var songTitle = reader.String();
            var alternate = reader.String();
            var author = reader.String();
            var composer = reader.String();
            var note = reader.String();
            var properties = reader.String();

            var partCount = (int)reader.UInt32();
            if (partCount < 0 || partCount >= 1000) throw SongBookError.Damaged(name);

            var parts = new List<SongPart>(partCount);
            for (var part = 0; part < partCount; part++)
            {
                var kind = reader.String();
                var text = reader.String();
                // Службове поле частини — вирівнювання її тексту. Значення
                // розібрано за кодом оригіналу: 1 → Left, 2 → Right, 3 → Center.
                var align = SongPartAligns.FromRawValue(reader.UInt32()) ?? SongPartAlign.Default;
                parts.Add(new SongPart(part, kind, text, align));
            }
            songs.Add(new Song(index, songTitle, alternate, author, composer, note, properties, parts));
        }

        // Групи пісень лежать у самому кінці потоку: їхня кількість, потім на
        // кожну групу назва і номери пісень, що входять до неї. Збірники без
        // груп закінчуються нулем — його теж треба прочитати, інакше при
        // збереженні хвіст загубиться.
        var groups = new List<SongGroup>();
        var groupCount = (int)reader.UInt32();
        if (groupCount > 0 && groupCount < 10_000)
        {
            for (var group = 0; group < groupCount; group++)
            {
                var groupName = reader.String();
                var memberCount = (int)reader.UInt32();
                if (memberCount < 0 || memberCount > count) break;
                var members = new List<int>(memberCount);
                for (var member = 0; member < memberCount; member++) members.Add((int)reader.UInt32());
                groups.Add(new SongGroup(groupName, members));
            }
        }
        return new SongBook(title, shortName, publisher, revisionDate, comment, songs, groups,
                            formatVersion, flags, charset);
    }
}

public sealed class SongBookError : Exception
{
    public enum Kind { NotASongBook, Damaged, InflateFailed }

    public Kind ErrorKind { get; }
    public string Name { get; }

    private SongBookError(Kind kind, string name, string message) : base(message)
    {
        ErrorKind = kind;
        Name = name;
    }

    public static SongBookError NotASongBook(string name) =>
        new(Kind.NotASongBook, name, OurWords.T("%s: это не песенник .vbm", name));

    public static SongBookError Damaged(string name) =>
        new(Kind.Damaged, name, OurWords.T("%s: файл повреждён или формат новее", name));

    public static SongBookError InflateFailed() =>
        new(Kind.InflateFailed, "", OurWords.T("не удалось распаковать данные песенника"));

    public override string ToString() => Message;
}

/// Послідовне читання простих значень з розпакованого блоку
/// (`BinaryReader` у Swift; тут ім'я зайняте System.IO).
internal sealed class SongBinaryReader
{
    private readonly byte[] data;
    private int offset;

    public SongBinaryReader(byte[] data) => this.data = data;

    public void Skip(int count) => offset = Math.Min(offset + count, data.Length);

    public ushort UInt16()
    {
        if (offset + 2 > data.Length)
        {
            offset = data.Length;
            return 0;
        }
        var value = (ushort)(data[offset] | data[offset + 1] << 8);
        offset += 2;
        return value;
    }

    public uint UInt32()
    {
        if (offset + 4 > data.Length)
        {
            offset = data.Length;
            return 0;
        }
        var value = (uint)(data[offset] | data[offset + 1] << 8 | data[offset + 2] << 16 | data[offset + 3] << 24);
        offset += 4;
        return value;
    }

    /// Рядок: число символів в UInt16, потім самі символи в UTF-16LE.
    public string String()
    {
        var characters = (int)UInt16();
        var length = characters * 2;
        if (characters <= 0 || offset + length > data.Length)
        {
            offset = Math.Min(offset + Math.Max(0, length), data.Length);
            return "";
        }
        // `String(decoding:as: UTF16.self)`: одинокий сурогат стає U+FFFD.
        var text = Encoding.Unicode.GetString(data, offset, length);
        offset += length;
        return text;
    }
}
