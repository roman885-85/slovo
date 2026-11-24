// =============================================================================
//  SongBookImport.cs — імпорт Пісенника з чужих форматів, посібник 5.3.8.3
//  (з Songs/SongBookImport.swift)
// =============================================================================
//  На Mac — SQLite3 (C API) і XMLParser (libxml2). Тут — Microsoft.Data.Sqlite
//  і XmlReader: ті самі події, той самий розбір. Різниця лише в тексті
//  помилки самого XML-розбору (його пише бібліотека).
// =============================================================================

using System.Globalization;
using System.Text;
using System.Xml;
using Microsoft.Data.Sqlite;

namespace Slovo.Core;

/// Імпорт Пісенника з чужих форматів — посібник, 5.3.8.3.
/// «Импорт возможен из 2-х источников: BibleQuote модуль, SoftProjector модуль».
public static class SongBookImporter
{
    public sealed class Failure : Exception
    {
        public enum Kind { CannotOpen, NotASongSource, Empty, UnexpectedStructure, UnsupportedVersion }

        public Kind FailureKind { get; }
        public string Name { get; }
        /// Для `UnexpectedStructure` — готове пояснення: що знайшли і чого забракло.
        /// Мовчазна відмова операторові не допомагає — він має бачити, на чому
        /// саме спіткнулися.
        public string Detail { get; }
        /// Для `UnsupportedVersion` — версія пісенника (`PRAGMA user_version`).
        public int Version { get; }

        private Failure(Kind kind, string name, string detail, int version, string message) : base(message)
        {
            FailureKind = kind;
            Name = name;
            Detail = detail;
            Version = version;
        }

        public static Failure CannotOpen(string name) =>
            new(Kind.CannotOpen, name, "", 0, OurWords.T("Не удалось открыть файл модуля.\n%s", name));

        public static Failure NotASongSource(string name) =>
            new(Kind.NotASongSource, name, "", 0, OurWords.T("%s: в файле не нашлось таблицы с песнями", name));

        public static Failure Empty(string name) =>
            new(Kind.Empty, name, "", 0, OurWords.T("%s: песен не найдено", name));

        /// Та сама біда буває різною: і «всередині не те», і «всередині те, але
        /// порожньо». Тому спільний заголовок нейтральний, а подробиця завжди
        /// своя — оператор має зрозуміти, лагодити йому файл чи брати інший.
        public static Failure UnexpectedStructure(string name, string detail) =>
            new(Kind.UnexpectedStructure, name, detail, 0,
                OurWords.T("Не удалось прочитать «%s» как песенник SoftProjector.\n%s", name, detail));

        /// Пісенник новіший, ніж розуміє розбір (у SoftProjector це `PRAGMA user_version`).
        public static Failure UnsupportedVersion(string name, int version) =>
            new(Kind.UnsupportedVersion, name, "", version,
                $"{name}: песенник версии {version}, а разбор знает версию 2.\n"
                + OurWords.T("Откройте его в SoftProjector и выгрузите заново."));

        public override string ToString() => Message;
    }

    // ── BibleQuote ──────────────────────────────────────────────────────────

    /// Модуль «Цитати з Біблії» влаштовано як книгу: у неї розділи, у розділів вірші.
    /// У пісенному модулі розділ — це пісня, а вірш — куплет; інакше такі
    /// модулі просто не збирають. Рівно так їх і розбираємо.
    ///
    /// `refrainMarker` — той самий «рядок-ознака» з вікна імпорту: у різних
    /// модулях приспів позначають по-різному, ознака не стандартизована,
    /// тому її вводить людина. Порожня ознака — не позначати нічого.
    public static SongBook FromBibleQuote(string path, string? refrainMarker, SongChunkPalette? palette = null)
    {
        palette ??= SongChunkPalette.FactoryDefault;
        var directory = Directory.Exists(path) ? path : SwiftPath.Parent(path);
        BibleModule module;
        try
        {
            module = new BibleModule(directory);
        }
        catch (Exception)
        {
            throw Failure.CannotOpen(SwiftPath.LastComponent(directory));
        }

        var verseName = palette.ChunkByKey("Verse")?.Title ?? "Куплет";
        var chorusName = palette.ChunkByKey("Chorus")?.Title ?? "Припев";
        var marker = refrainMarker?.TrimWhitespaces() ?? "";

        var songs = new List<Song>();
        foreach (var book in module.Books)
        {
            IReadOnlyList<Chapter> chapters;
            try { chapters = module.Chapters(book); }
            catch (Exception) { chapters = Array.Empty<Chapter>(); }
            foreach (var chapter in chapters)
            {
                var parts = new List<SongPart>();
                var verseNumber = 0;

                foreach (var verse in chapter.Verses)
                {
                    var text = verse.Text.TrimWhitespacesAndNewlines();
                    if (text.Length == 0) continue;

                    var isRefrain = marker.Length > 0 && Contains(marker, text);
                    if (isRefrain && marker.Length > 0) text = Strip(marker, text);
                    if (isRefrain)
                    {
                        parts.Add(new SongPart(parts.Count, chorusName, Normalize(text)));
                    }
                    else
                    {
                        verseNumber += 1;
                        parts.Add(new SongPart(parts.Count, $"{verseName} {verseNumber}", Normalize(text)));
                    }
                }
                if (parts.Count == 0) continue;

                var title = chapter.Heading?.TrimWhitespacesAndNewlines();
                var song = new Song(songs.Count,
                                    !string.IsNullOrEmpty(title) ? title : FirstLine(parts),
                                    properties: $"$ID$={songs.Count + 1}");
                song.Parts = parts;
                songs.Add(song);
            }
        }
        if (songs.Count == 0) throw Failure.Empty(SwiftPath.LastComponent(directory));

        return new SongBook(module.Info.Name.Length == 0 ? SwiftPath.LastComponent(directory) : module.Info.Name,
                            module.Info.ShortName,
                            publisher: module.Info.Copyright ?? "",
                            revisionDate: "",
                            comment: OurWords.T("Импортировано из модуля «Цитата из Библии»"),
                            songs: songs);
    }

    // ── SoftProjector: що лежить у файлі ────────────────────────────────────

    /// Пісенник SoftProjector, прочитаний «як є», до перекладання в наш
    /// формат. Окремий тип потрібен самоперевірці: вона має вміти сказати,
    /// що саме знайшлося у файлі, не створюючи при цьому Пісенника.
    public sealed class SoftProjectorBook
    {
        public string Title;
        public string Info;
        /// Звідки прочитано: «база SQLite, версія 2» або «XML, версія 2.0».
        public string Origin;
        public List<SoftProjectorSong> Songs;

        public SoftProjectorBook(string title, string info, string origin, List<SoftProjectorSong> songs)
        {
            Title = title;
            Info = info;
            Origin = origin;
            Songs = songs;
        }
    }

    /// Рядок таблиці `Songs` файла `.sps`. Імена полів — ті самі, що в самому
    /// SoftProjector, щоб відповідність читалася без словника.
    public sealed class SoftProjectorSong
    {
        public int? Number;
        public string Title = "";
        public string Tune = "";
        public string Words = "";     // автор слів
        public string Music = "";     // автор музики
        public string Text = "";      // song_text — весь текст пісні
        public string Notes = "";
        public string Date = "";
    }

    // ── SoftProjector ───────────────────────────────────────────────────────

    /// «Імпортувати з модуля SoftProjector» (5.3.8.3). Ознаку приспіву
    /// вводити не треба: «в этом формате припевы промаркированы однозначно».
    public static SongBook FromSoftProjector(string path, SongChunkPalette? palette = null)
    {
        palette ??= SongChunkPalette.FactoryDefault;
        var source = ReadSoftProjector(path);

        var songs = new List<Song>();
        foreach (var row in source.Songs)
        {
            var parts = SoftProjectorParts(row.Text, palette);
            // Пісня без тексту в Пісеннику марна, але й мовчки губити її
            // не можна: номери сусідів від цього не поїдуть — їх ми беремо з
            // самого файла, а не з позиції.
            if (parts.Count == 0 && row.Title.Length == 0) continue;

            var song = new Song(songs.Count,
                                row.Title.Length == 0 ? $"Песня {songs.Count + 1}" : row.Title,
                                author: row.Words,
                                composer: row.Music,
                                note: row.Date);
            song.Parts = parts;
            song.SetProperty("$ID$", (row.Number ?? songs.Count + 1).ToString(CultureInfo.InvariantCulture));
            if (row.Tune.Length > 0) song.SetProperty("$TUNE$", row.Tune);
            // Нотатки пісні в нашому форматі окремого поля не мають, а
            // губити їх шкода — кладемо у властивість, як це робить сам оригінал
            // з іншими «$Ключ$=значення».
            if (row.Notes.Length > 0) song.SetProperty("$NOTES$", OneLine(row.Notes));
            songs.Add(song);
        }
        if (songs.Count == 0)
        {
            // Рядки у файлі були, а пісень не вийшло — отже колонка
            // тексту прочиталася не та. Це найприкріше мовчання, тому
            // кажемо прямо, що читали і скільки рядків бачили.
            throw Failure.UnexpectedStructure(SwiftPath.LastComponent(path),
                $"прочитано строк: {source.Songs.Count}, но ни в одной нет ни названия, ни текста.\n"
                + $"Читали: {source.Origin}.");
        }

        var stem = SwiftPath.LastComponent(SwiftPath.DeletingExtension(path));
        var name = source.Title.Length == 0 ? stem : source.Title;
        var comment = OurWords.T("Импортировано из модуля SoftProjector (%s)", source.Origin);
        if (source.Info.Length > 0) comment = source.Info + "\n" + comment;

        return new SongBook(name, stem, comment: comment, songs: songs);
    }

    /// Прочитати `.sps`, не перекладаючи його в наш формат.
    ///
    /// Файл буває двох видів, і обидва треба впізнавати за вмістом, а не за
    /// розширенням: у SoftProjector 2 це база SQLite з `user_version = 2`,
    /// а до неї був XML `<spSongBook version="2.0">`. Усе інше — привід
    /// сказати людині, що саме ми побачили, а не промовчати.
    public static SoftProjectorBook ReadSoftProjector(string path)
    {
        var name = SwiftPath.LastComponent(path);
        byte[] head;
        try { head = Peek(path, 96); }
        catch (Exception) { throw Failure.CannotOpen(name); }
        if (head.Length == 0) throw Failure.UnexpectedStructure(name, "файл пуст (0 байт).");

        if (head.AsSpan().StartsWith("SQLite format 3\0"u8)) return ReadSoftProjectorDatabase(path, name);
        // Вивантаження буває і в UTF-16 з міткою порядку байтів — тоді UTF-8 на
        // початку файла нічого осмисленого не дасть. Мітку знімаємо самі:
        // обрізання пробілів U+FEFF не прибирає, і файл з міткою раніше
        // відкидався як «не той формат».
        if (LooksLikeXML(head)) return ReadSoftProjectorXML(path, name);
        if (head.AsSpan().StartsWith("##"u8) || head.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF, 0x23, 0x23 }))
            return ReadSoftProjectorText(path, name);
        throw Failure.UnexpectedStructure(name,
            "Ожидались база SQLite (SoftProjector 2), XML <spSongBook> или текст "
            + $"SoftProjector 1.x (начинается на «##»), а файл начинается на «{Preview(head)}».");
    }

    /// Найстаріший формат SoftProjector (1.x) — текст, рядок на пісню.
    ///
    /// Так досі лежать пісенники на softprojector.org («Євангельські пісні»,
    /// «Пісні спасенних», «Псалмоспіви», «Песнь Возрождения»). Шапка — рядки
    /// «##версія», «##назва», «##опис»; далі пісня — десять полів через «#$#»:
    /// номер, назва, категорія, тональність, слова, музика, текст, нотатки,
    /// вирівнювання, шрифт. У тексті «@$» розділяє частини, «@%» — рядки;
    /// перший рядок частини — її назва («Куплет 1.», «Приспів», «Verse 1.»).
    private static SoftProjectorBook ReadSoftProjectorText(string path, string name)
    {
        byte[] data;
        try { data = File.ReadAllBytes(path); }
        catch (Exception) { throw Failure.CannotOpen(name); }
        if (data.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF })) data = data[3..];
        var text = CodePage.TryDecode(data, CodePage.Utf8) ?? CodePage.TryDecode(data, CodePage.WindowsCP1251)
                   ?? throw Failure.CannotOpen(name);
        var header = new List<string>();
        var songs = new List<SoftProjectorSong>();
        foreach (var line in text.ComponentsSeparatedByNewlines())
        {
            if (line.StartsWith("##", StringComparison.Ordinal))
            {
                header.Add(SwiftText.DropFirstCharacters(line, 2).TrimWhitespaces());
                continue;
            }
            var fields = line.Split("#$#");
            if (fields.Length < 7) continue;
            string Field(int index) => index < fields.Length ? fields[index].TrimWhitespaces() : "";
            var lyrics = Field(6).Replace("@$", "\n\n").Replace("@%", "\n");
            songs.Add(new SoftProjectorSong
            {
                Number = SwiftText.ParseInt(Field(0)), Title = Field(1), Tune = Field(3),
                Words = Field(4), Music = Field(5), Text = lyrics,
                Notes = Field(7).Replace("@%", "\n"),
            });
        }
        if (songs.Count == 0)
            throw Failure.UnexpectedStructure(name, "текст SoftProjector 1.x без песен: строк с полями «#$#» не нашлось.");
        // Перший рядок шапки — номер версії («##0», «##4»), далі назва й опис.
        var rest = header.Count > 0 && SwiftText.Characters(header[0]).All(SwiftText.IsNumber)
            ? header.Skip(1).ToList()
            : header;
        return new SoftProjectorBook(rest.Count > 0 ? rest[0] : "",
                                     string.Join("\n", rest.Skip(1)).Replace("@%", "\n"),
                                     "текст SoftProjector 1.x", songs);
    }

    /// Початок файла схожий на XML? Дивимося і однобайтовий текст, і UTF-16 —
    /// в обох порядках байтів.
    private static bool LooksLikeXML(byte[] head)
    {
        var bytes = head.ToList();
        if (head.AsSpan().StartsWith(new byte[] { 0xEF, 0xBB, 0xBF })) bytes.RemoveRange(0, 3);

        var array = bytes.ToArray();
        var littleEndian = array.AsSpan().StartsWith(new byte[] { 0xFF, 0xFE });
        var bigEndian = array.AsSpan().StartsWith(new byte[] { 0xFE, 0xFF });
        if (littleEndian || bigEndian)
        {
            bytes.RemoveRange(0, 2);
            // Кожен другий байт латинського тексту в UTF-16 — нуль; збираємо
            // з нього однобайтовий рядок і дивимося на нього звичайним способом.
            var ascii = new List<byte>();
            for (var index = bigEndian ? 1 : 0; index < bytes.Count; index += 2) ascii.Add(bytes[index]);
            bytes = ascii;
        }
        var text = Encoding.UTF8.GetString(bytes.ToArray())
            .TrimWhitespacesAndNewlines()
            .Replace("\uFEFF", "")
            .Replace("\0", "");
        return text.StartsWith("<?xml", StringComparison.Ordinal)
               || text.ToLowerInvariant().StartsWith("<spsongbook", StringComparison.Ordinal);
    }

    // ── SoftProjector: база SQLite ──────────────────────────────────────────

    /// Розбір `.sps` версії 2. Схему взято з самого SoftProjector
    /// (`exportSongbook`): таблиця `SongBook` (title, info) і таблиця `Songs`
    /// (number, title, category, tune, words, music, song_text, notes, …).
    ///
    /// Колонки все одно шукаємо за іменами, а не одним зашитим запитом: у
    /// пісенників з інтернету трапляються і врізані таблиці, і зайві
    /// колонки, і падати на них нема чого.
    private static SoftProjectorBook ReadSoftProjectorDatabase(string path, string name)
    {
        var builder = new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadOnly, Pooling = false };
        using var database = new SqliteConnection(builder.ToString());
        try
        {
            database.Open();
        }
        catch (SqliteException error)
        {
            throw Failure.UnexpectedStructure(name, OurWords.T("SQLite не открыл файл: %s.", SqliteMessage(error)));
        }

        var version = UserVersion(database);
        if (version > 2) throw Failure.UnsupportedVersion(name, version);

        var tables = TableNames(database);
        if (tables.Count == 0) throw Failure.UnexpectedStructure(name, OurWords.T("в базе нет ни одной таблицы."));
        if (SongTableIn(database, tables) is not { } table)
            throw Failure.UnexpectedStructure(name, StructureReport(tables, database));

        // Колонки перелічуємо по одній: у файлі їх два десятки, і більша
        // частина — оформлення слайда, яке до тексту стосунку не має.
        var picked = new[] { table.Title, table.Lyrics, table.Number, table.Tune, table.Words, table.Music, table.Notes, table.Date };
        var sql = "SELECT " + string.Join(", ", picked.Select(column => column == null ? "NULL" : Quoted(column)))
                  + $" FROM {Quoted(table.Name)}";

        var songs = new List<SoftProjectorSong>();
        using (var command = database.CreateCommand())
        {
            command.CommandText = sql;
            SqliteDataReader reader;
            try
            {
                reader = command.ExecuteReader();
            }
            catch (SqliteException error)
            {
                throw Failure.UnexpectedStructure(name, OurWords.T("таблица «%s» не читается: %s.", table.Name, SqliteMessage(error)));
            }
            using (reader)
            {
                while (SqliteAccess.Step(reader))
                {
                    songs.Add(new SoftProjectorSong
                    {
                        Number = Number(reader, 2),
                        Title = Column(reader, 0),
                        Tune = Column(reader, 3),
                        Words = Column(reader, 4),
                        Music = Column(reader, 5),
                        Text = UnpackRhythmicLines(Column(reader, 1)),
                        Notes = Column(reader, 6),
                        Date = Column(reader, 7),
                    });
                }
            }
        }
        if (songs.Count == 0)
            throw Failure.UnexpectedStructure(name, OurWords.T("таблица «%s» есть, но в ней ни одной строки.", table.Name));

        var head = BookRow(database, tables);
        // У «звідки» пишемо і таблицю з колонками: коли пісенник з інтернету
        // виявиться з іншою схемою і частина полів приїде порожньою, за цим
        // рядком видно, що саме програма читала.
        return new SoftProjectorBook(head.Title, head.Info,
                                     $"база SQLite, версия {version}, таблица «{table.Name}»,"
                                     + $" текст «{table.Lyrics}», название «{table.Title}»",
                                     songs);
    }

    /// Заголовок Пісенника — таблиця `SongBook` з одного рядка.
    private static (string Title, string Info) BookRow(SqliteConnection database, List<string> tables)
    {
        var table = tables.FirstOrDefault(name => SwiftText.SameIgnoringCase(name, "SongBook"));
        if (table == null) return ("", "");
        var columns = ColumnNames(table, database);
        if (Pick(["title", "name"], columns) is not { } title) return ("", "");
        var info = Pick(["info", "comment", "description"], columns);

        var sql = $"SELECT {Quoted(title)}, {(info == null ? "NULL" : Quoted(info))} FROM {Quoted(table)} LIMIT 1";
        try
        {
            using var command = database.CreateCommand();
            command.CommandText = sql;
            using var reader = command.ExecuteReader();
            if (!SqliteAccess.Step(reader)) return ("", "");
            return (Column(reader, 0), OneLine(Column(reader, 1)));
        }
        catch (SqliteException)
        {
            return ("", "");
        }
    }

    // ── SoftProjector: XML ──────────────────────────────────────────────────

    /// Старе вивантаження `<spSongBook version="2.0">`. Склад полів той самий, що
    /// й у базі, — це видно за кодом імпорту самого SoftProjector.
    private static SoftProjectorBook ReadSoftProjectorXML(string path, string name)
    {
        byte[] data;
        try { data = File.ReadAllBytes(path); }
        catch (Exception) { throw Failure.CannotOpen(name); }
        var reader = new SoftProjectorXMLReader();
        try
        {
            reader.Parse(data);
        }
        catch (XmlException error)
        {
            var line = error.LineNumber.ToString(CultureInfo.InvariantCulture);
            throw Failure.UnexpectedStructure(name, OurWords.T("XML не разобрался (строка %s): %s.", line, error.Message));
        }
        if (!reader.SawSongBookElement)
            throw Failure.UnexpectedStructure(name,
                "в XML нет узла <spSongBook> — это не выгрузка SoftProjector.\n"
                + $"Встретились узлы: {string.Join(", ", reader.SeenElements)}.");
        if (reader.Songs.Count == 0)
            throw Failure.UnexpectedStructure(name,
                "в XML нет ни одного узла <Song>.\n"
                + $"Встретились узлы: {string.Join(", ", reader.SeenElements)}.");
        var version = reader.Version.Length == 0 ? OurWords.T("без номера") : reader.Version;
        return new SoftProjectorBook(reader.Title, OneLine(reader.Info), $"XML, версия {version}", reader.Songs);
    }

    /// Розбір XML за подіями: файл може бути на тисячі пісень, тримати з
    /// нього дерево в пам'яті нема чого.
    private sealed class SoftProjectorXMLReader
    {
        public string Title = "";
        public string Info = "";
        public string Version = "";
        public readonly List<SoftProjectorSong> Songs = new();
        public bool SawSongBookElement;
        /// Які вузли взагалі трапилися. Потрібно лише для повідомлення про
        /// помилку: «немає <Song>» без переліку побаченого — глухий кут.
        public readonly List<string> SeenElements = new();
        private readonly HashSet<string> seen = new(StringComparer.Ordinal);

        private StringBuilder value = new();
        private SoftProjectorSong? current;
        private bool inHeader;

        public void Parse(byte[] data)
        {
            var settings = new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Ignore,
                XmlResolver = null,
                IgnoreWhitespace = false,
                IgnoreComments = true,
                IgnoreProcessingInstructions = true,
                CheckCharacters = false,
            };
            using var stream = new MemoryStream(data, writable: false);
            using var reader = XmlReader.Create(stream, settings);
            while (reader.Read())
            {
                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                    {
                        var element = reader.Name;
                        var attributes = new List<(string Name, string Value)>();
                        if (reader.MoveToFirstAttribute())
                        {
                            do attributes.Add((reader.Name, reader.Value));
                            while (reader.MoveToNextAttribute());
                            reader.MoveToElement();
                        }
                        Start(element, attributes);
                        if (reader.IsEmptyElement) End(element);
                        break;
                    }
                    case XmlNodeType.EndElement:
                        End(reader.Name);
                        break;
                    case XmlNodeType.Text:
                    case XmlNodeType.Whitespace:
                    case XmlNodeType.SignificantWhitespace:
                    // Текст пісні у вивантаженнях нерідко загорнуто в CDATA — без
                    // цього він просто пропадав би.
                    case XmlNodeType.CDATA:
                        value.Append(reader.Value);
                        break;
                }
            }
        }

        /// Імена вузлів порівнюємо без урахування регістру і підкреслень: у різних
        /// збірок SoftProjector трапляються і `song_text`, і `songText`, і
        /// `<song>` з малої літери. Розбір через таку дрібницю мовчки
        /// повертати порожній Пісенник не повинен.
        private static string Tag(string element) => element.ToLowerInvariant().Replace("_", "");

        private static string? Attribute(List<(string Name, string Value)> attributes, string name) =>
            attributes.FirstOrDefault(pair => SwiftText.SameIgnoringCase(pair.Name, name)).Value;

        private void Start(string element, List<(string Name, string Value)> attributes)
        {
            value.Clear();
            if (seen.Add(element) && SeenElements.Count < 24) SeenElements.Add(element);
            switch (Tag(element))
            {
                case "spsongbook":
                    SawSongBookElement = true;
                    Version = Attribute(attributes, "version") ?? "";
                    break;
                case "songbook":
                    inHeader = true;
                    break;
                case "song":
                    inHeader = false;
                    current = new SoftProjectorSong
                    {
                        Number = Attribute(attributes, "number") is { } raw ? SwiftText.ParseInt(raw.TrimWhitespaces()) : null,
                    };
                    break;
            }
        }

        private void End(string element)
        {
            var text = value.ToString();
            value.Clear();
            var tag = Tag(element);
            if (tag == "song")
            {
                if (current != null) Songs.Add(current);
                current = null;
                return;
            }
            if (tag == "songbook")
            {
                inHeader = false;
                return;
            }

            if (inHeader)
            {
                switch (tag)
                {
                    case "title": case "name": Title = text; break;
                    case "info": case "comment": case "about": Info = text; break;
                }
                return;
            }
            if (current == null) return;
            switch (tag)
            {
                case "title": case "songtitle": case "name": current.Title = text; break;
                case "tune": case "key": current.Tune = text; break;
                case "words": case "author": case "poet": case "writer": current.Words = text; break;
                case "music": case "composer": current.Music = text; break;
                case "songtext": case "lyrics": case "text": case "body": current.Text = UnpackRhythmicLines(text); break;
                case "notes": case "note": current.Notes = text; break;
                case "date": case "created": current.Date = text; break;
                case "number": case "songnumber":
                    current.Number = SwiftText.ParseInt(text.TrimWhitespaces()) ?? current.Number;
                    break;
            }
        }
    }

    // ── SoftProjector: текст пісні ──────────────────────────────────────────

    /// Частини в SoftProjector позначено рядком-заголовком: «Verse 1»,
    /// «Куплет 2», «Chorus», «Припев». Список слів узято з його вихідників
    /// (`song.cpp`, функції `isStanza*Title`) — програма вважає початком
    /// нової частини рівно їх, тому й ми читаємо так само, а не за порожніми
    /// рядками.
    internal static List<SongPart> SoftProjectorParts(string lyrics, SongChunkPalette palette)
    {
        var lines = SongTextMarkup.NormalizedLines(lyrics);
        var parts = new List<SongPart>();
        var kind = "";
        var buffer = new List<string>();
        var sawHeading = false;

        void Flush()
        {
            var body = SongTextMarkup.TrimBlankEdges(buffer);
            if (body.Count > 0) parts.Add(new SongPart(parts.Count, kind, string.Join("\r\n", body)));
            buffer = new List<string>();
            kind = "";
        }

        foreach (var line in lines)
        {
            if (SoftProjectorHeading(line, palette) is { } heading)
            {
                Flush();
                kind = heading;
                sawHeading = true;
                continue;
            }
            buffer.Add(line);
        }
        Flush();

        // Жодного заголовка не знайшлося — отже текст набрано суцільно.
        // Тоді лишається єдина ознака, яка в ньому є: порожній
        // рядок між куплетами.
        return sawHeading ? parts : SoftProjectorBlocks(lines, palette);
    }

    /// Заголовок частини SoftProjector → назва частини мовою палітри.
    /// Повертає `null`, якщо рядок звичайний.
    private static string? SoftProjectorHeading(string line, SongChunkPalette palette)
    {
        // «&Chorus» у SoftProjector означає «продовження того самого приспіву» —
        // для нас це просто ще одна частина з тією самою назвою.
        var head = line.TrimWhitespaces();
        while (SwiftText.HasPrefix(head, "&")) head = SwiftText.DropFirstCharacters(head, 1);
        if (head.Length == 0 || SwiftText.CharacterCount(head) > 32) return null;

        foreach (var (prefix, key) in SoftProjectorHeadings)
        {
            if (!SwiftText.HasPrefix(head, prefix)) continue;
            // Хвіст заголовка буває лише номером або розділовим знаком:
            // «Verse 2», «Chorus:», «Слайд 3». Рядок пісні, який просто
            // починається на це слово, за заголовок приймати не можна.
            var tail = SwiftText.Characters(SwiftText.DropFirstCharacters(head, SwiftText.CharacterCount(prefix)));
            if (!tail.All(c => SwiftText.IsNumber(c) || SwiftText.IsWhitespace(c) || SwiftText.IsPunctuation(c))) continue;
            var name = palette.ChunkByKey(key)?.Title ?? key;
            var digits = string.Concat(tail.Where(SwiftText.IsNumber));
            return digits.Length == 0 ? name : $"{name} {digits}";
        }
        return null;
    }

    /// Слова-заголовки SoftProjector та їхня відповідність типам частин старої програми.
    /// Порядок важливий: спершу довгі, інакше «Verš» не відрізнити від «Verse».
    private static readonly IReadOnlyList<(string Prefix, string Key)> SoftProjectorHeadings =
        new (string, string)[]
        {
            ("Verse", "Verse"), ("Куплет", "Verse"), ("Strophe", "Verse"), ("Verš", "Verse"),
            ("Chorus", "Chorus"), ("Refrain", "Chorus"), ("Sbor", "Chorus"),
            ("Припев", "Chorus"), ("Приспів", "Chorus"), ("Refrén", "Chorus"),
            // «Слайд» і «Вставка» — вставний шматок між куплетами; найближче
            // за змістом «Місток», окремого типу для них у старій програмі немає.
            ("Slide", "Bridge"), ("Слайд", "Bridge"), ("Snímek", "Bridge"),
            ("Insert", "Bridge"), ("Вставка", "Bridge"), ("Einfügung", "Bridge"), ("Vložka", "Bridge"),
            ("Intro", "Intro"), ("Вступление", "Intro"), ("Einleitung", "Intro"), ("Úvod", "Intro"),
            ("Ending", "End"), ("Окончание", "End"), ("Закінчення", "End"),
            ("Ende", "End"), ("Závěr", "End"),
        }.OrderByDescending(pair => SwiftText.CharacterCount(pair.Item1)).ToList();

    /// Запасний розбір: частини розділено порожнім рядком, назв немає.
    private static List<SongPart> SoftProjectorBlocks(List<string> lines, SongChunkPalette palette)
    {
        var verseName = palette.ChunkByKey("Verse")?.Title ?? "Куплет";
        var parts = new List<SongPart>();
        var number = 0;
        var blocks = new List<List<string>>();
        var current = new List<string>();
        foreach (var line in lines)
        {
            if (line.TrimWhitespaces().Length == 0)
            {
                if (current.Count > 0) blocks.Add(current);
                current = new List<string>();
                continue;
            }
            current.Add(line);
        }
        if (current.Count > 0) blocks.Add(current);

        foreach (var block in blocks)
        {
            var body = SongTextMarkup.TrimBlankEdges(block);
            if (body.Count == 0) continue;
            number += 1;
            parts.Add(new SongPart(parts.Count, $"{verseName} {number}", string.Join("\r\n", body)));
        }
        return parts;
    }

    /// Старі вивантаження зберігають весь текст одним рядком: `@$` розділяє частини,
    /// `@%` — рядки всередині частини. Так це розпаковує і сам SoftProjector
    /// (`cleanSongLines`), інакше пісня приїде одним довгим рядком.
    internal static string UnpackRhythmicLines(string text)
    {
        if (!text.Contains("@$", StringComparison.Ordinal) && !text.Contains("@%", StringComparison.Ordinal)) return text;
        return text.Replace("@%", "\n").Replace("@$", "\n\n");
    }

    // ── Внутрішнє ───────────────────────────────────────────────────────────

    private sealed record SongTable(string Name, string Title, string Lyrics, string? Number, string? Tune,
                                    string? Words, string? Music, string? Notes, string? Date);

    private static SongTable? SongTableIn(SqliteConnection database, List<string> tables)
    {
        foreach (var table in tables)
        {
            var columns = ColumnNames(table, database);
            if (Pick(["song_text", "songtext", "lyrics", "text", "body", "verses"], columns) is not { } lyrics
                || Pick(["title", "song_title", "name", "song_name"], columns) is not { } title) continue;
            return new SongTable(table, title, lyrics,
                                 Pick(["number", "song_number", "songnumber", "num"], columns),
                                 Pick(["tune", "key"], columns),
                                 // У SoftProjector автор слів — «words», автор
                                 // музики — «music»; у чужих базах буває «author».
                                 Pick(["words", "author", "writer", "poet"], columns),
                                 Pick(["music", "composer"], columns),
                                 Pick(["notes", "note", "comment"], columns),
                                 Pick(["date", "created", "song_date"], columns));
        }
        return null;
    }

    /// Що саме знайшлося в базі — цей текст бачить оператор, коли пісенник
    /// виявився не тим, чого чекали.
    private static string StructureReport(List<string> tables, SqliteConnection database)
    {
        var lines = new List<string> { OurWords.T("Нужны таблица с песнями и в ней колонки текста (song_text) и названия (title).") };
        lines.Add(OurWords.T("В файле есть таблицы: ") + string.Join(", ", tables) + ".");
        foreach (var table in tables.Take(4))
        {
            var columns = ColumnNames(table, database);
            if (columns.Count == 0) continue;
            lines.Add($"  {table}: " + string.Join(", ", columns.Take(16)));
        }
        return string.Join("\n", lines);
    }

    private static string? Pick(string[] candidates, List<string> columns)
    {
        foreach (var candidate in candidates)
        {
            var match = columns.FirstOrDefault(column => SwiftText.SameIgnoringCase(column, candidate));
            if (match != null) return match;
        }
        return null;
    }

    private static int UserVersion(SqliteConnection database)
    {
        var version = 0;
        var done = false;
        SqliteAccess.Each(database, "PRAGMA user_version", reader =>
        {
            if (done) return;
            version = SqliteAccess.Int(reader, 0);
            done = true;
        });
        return version;
    }

    private static List<string> TableNames(SqliteConnection database)
    {
        var names = new List<string>();
        SqliteAccess.Each(database, "SELECT name FROM sqlite_master WHERE type='table'", reader => names.Add(Column(reader, 0)));
        // Таблиця «Songs» — та сама, що пише SoftProjector, тому її
        // пробуємо першою; службові таблиці SQLite не чіпаємо зовсім.
        //
        // Розкладаємо у два списки, а не сортуємо: порівняння «зліва стоїть
        // Songs» — не відношення порядку (для двох чужих таблиць воно і в той, і
        // в інший бік хибне), і сортування на такому порівнянні має право
        // видати що завгодно.
        var usable = names.Where(name => !name.ToLowerInvariant().StartsWith("sqlite_", StringComparison.Ordinal)).ToList();
        var songs = usable.Where(name => SwiftText.SameIgnoringCase(name, "Songs"));
        var rest = usable.Where(name => !SwiftText.SameIgnoringCase(name, "Songs"));
        return songs.Concat(rest).ToList();
    }

    private static List<string> ColumnNames(string table, SqliteConnection database)
    {
        var names = new List<string>();
        SqliteAccess.Each(database, $"PRAGMA table_info({Quoted(table)})", reader => names.Add(Column(reader, 1)));
        return names;
    }

    private static string Column(SqliteDataReader reader, int index) => SqliteAccess.Text(reader, index) ?? "";

    /// Номер пісні буває і числом, і рядком — колонку оголошено INTEGER,
    /// але у вивантаженнях трапляється текст.
    private static int? Number(SqliteDataReader reader, int index)
    {
        if (reader.IsDBNull(index)) return null;
        var raw = reader.GetValue(index);
        if (raw is long or double) return unchecked((int)reader.GetInt64(index));
        return SwiftText.ParseInt(Column(reader, index).TrimWhitespaces());
    }

    private static string Quoted(string identifier) => "\"" + identifier.Replace("\"", "\"\"") + "\"";

    /// Текст помилки так, як його дає `sqlite3_errmsg`.
    private static string SqliteMessage(SqliteException error)
    {
        var message = error.Message;
        var open = message.IndexOf('\'');
        var close = message.LastIndexOf('\'');
        return open >= 0 && close > open ? message[(open + 1)..close] : message;
    }

    /// Перші байти файла — за ними й упізнаємо формат.
    private static byte[] Peek(string path, int count)
    {
        using var stream = File.OpenRead(path);
        var buffer = new byte[count];
        var total = 0;
        int read;
        while (total < count && (read = stream.Read(buffer, total, count - total)) > 0) total += read;
        return buffer[..total];
    }

    /// Початок файла в читабельному вигляді — для повідомлення про помилку.
    private static string Preview(byte[] bytes) =>
        string.Concat(bytes.Take(24).Select(value => value >= 32 && value < 127 ? ((char)value).ToString() : "·"));

    private static string OneLine(string text) =>
        string.Join(" ", SongTextMarkup.NormalizedLines(text).Select(line => line.TrimWhitespaces()).Where(line => line.Length > 0));

    private static bool Contains(string marker, string text) =>
        text.Contains(marker, StringComparison.OrdinalIgnoreCase);

    private static string Strip(string marker, string text) =>
        text.Replace(marker, "", StringComparison.OrdinalIgnoreCase).TrimWhitespacesAndNewlines();

    private static string Normalize(string text) =>
        string.Join("\r\n", SongTextMarkup.TrimBlankEdges(SongTextMarkup.NormalizedLines(text)));

    private static string FirstLine(List<SongPart> parts)
    {
        foreach (var part in parts)
            foreach (var line in part.Lines)
                if (line.TrimWhitespaces().Length > 0) return line.TrimWhitespaces();
        return OurWords.T("Без названия");
    }
}

// ── Самоперевірка розбору SoftProjector ────────────────────────────────────

/// Перевірка імпорту `.sps` на свідомо відомих файлах.
///
/// Модулі SoftProjector лежать в інтернеті, і приходять вони різні: і база
/// SQLite версії 2, і старе вивантаження XML, і просто чужий файл з тим самим
/// розширенням. Перевіряти таке «на око» не можна — помилка вилізе в оператора
/// перед служінням. Тому зразки кожного випадку програма робить сама, у
/// тимчасовій теці, і сама ж дивиться, що вийшло: справжні дані
/// користувача при цьому не чіпаються зовсім.
public static class SoftProjectorSelfTest
{
    public sealed record Case(string Name, bool ExpectsSuccess, bool Passed, string Outcome);
    // ExpectsSuccess — чи чекаємо ми, що файл прочитається;
    // Outcome — що вийшло насправді: цей рядок і бачить людина у звіті.

    public static List<Case> Run()
    {
        var folder = Path.Combine(Path.GetTempPath(), "slovo-sps-selftest-" + Guid.NewGuid().ToString().ToUpperInvariant());
        try
        {
            Directory.CreateDirectory(folder);
        }
        catch (Exception)
        {
            return [new Case("Тимчасова тека", true, false, $"не створилася: {folder}")];
        }
        try
        {
            var cases = new List<Case>
            {
                Check("база SoftProjector 2", true,
                      MakeDatabase(folder, "good", 2, full: true),
                      book => book.Songs.Count == 2 && book.Songs.All(song => song.Parts.Count > 0),
                      "2 пісні, обидві з частинами"),
                Check("вивантаження XML із міткою порядку байтів", true,
                      MakeXML(folder, "xmlbom", withBOM: true),
                      book => book.Songs.Count == 2,
                      "2 пісні"),
                Check("база з чужими таблицями", false,
                      MakeDatabase(folder, "wrong", 2, full: false),
                      _ => false,
                      "перелік знайдених таблиць і колонок"),
                Check("пісенник версії з майбутнього", false,
                      MakeDatabase(folder, "newver", 9, full: true),
                      _ => false,
                      "номер версії в повідомленні"),
                Check("порожній файл", false,
                      Write(Array.Empty<byte>(), folder, "empty"),
                      _ => false,
                      "«файл порожній»"),
                Check("чужий файл із тим самим розширенням", false,
                      Write(Encoding.UTF8.GetBytes("PK\u0003\u0004not a songbook"), folder, "junk"),
                      _ => false,
                      "початок файлу в повідомленні"),
                Check("чужий XML", false,
                      Write(Encoding.UTF8.GetBytes("<?xml version=\"1.0\"?><playlist><item/></playlist>"), folder, "otherxml"),
                      _ => false,
                      "«немає вузла <spSongBook>»"),
            };
            return cases;
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            try { Directory.Delete(folder, recursive: true); } catch { }
        }
    }

    // ── Один випадок ────────────────────────────────────────────────────────

    private static Case Check(string name, bool expectsSuccess, string? path, Func<SongBook, bool> expecting, string expectation)
    {
        if (path == null) return new Case(name, expectsSuccess, false, "зразок не вдалося записати");
        try
        {
            var book = SongBookImporter.FromSoftProjector(path);
            if (!expectsSuccess)
                return new Case(name, false, false, $"прочитався мовчки, хоча не мав би: пісень {book.Songs.Count}");
            var ok = expecting(book);
            return new Case(name, true, ok,
                            ok ? $"пісень {book.Songs.Count}, частин {book.Songs.Sum(song => song.Parts.Count)}"
                               : $"прочиталося не те: чекали {expectation}, вийшло пісень {book.Songs.Count}");
        }
        catch (Exception error)
        {
            var message = error.Message.Replace("\n", " ");
            if (expectsSuccess) return new Case(name, true, false, $"відмова: {message}");
            // Відмова має бути зрозумілою: порожня або односкладова відмовка
            // тут не краща за мовчання.
            var explained = SwiftText.CharacterCount(message) > 40;
            return new Case(name, false, explained,
                            explained ? $"відмова з поясненням: {message}" : $"відмова без пояснення: «{message}»");
        }
    }

    // ── Зразки ──────────────────────────────────────────────────────────────

    private static string? Write(byte[] data, string folder, string name)
    {
        var path = Path.Combine(folder, name + ".sps");
        try
        {
            File.WriteAllBytes(path, data);
            return path;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// Текст пісні у двох видах одразу: із заголовками частин і зі «стиснутими»
    /// рядками `@%` / `@$`, якими старі вивантаження склеюють весь текст.
    private const string Lyrics = "Verse 1\nГосподь, мой Бог, когда на мир смотрю я\nChorus\nТогда поет душа моя";
    private const string PackedLyrics = "Куплет 1\nТихая ночь@%Дивная ночь@$Припев\nСпит всё, лишь не спит";

    private static string? MakeDatabase(string folder, string name, int userVersion, bool full)
    {
        var path = Path.Combine(folder, name + ".sps");
        var script = $"PRAGMA user_version = {userVersion};";
        if (full)
        {
            script += "CREATE TABLE SongBook (id INTEGER PRIMARY KEY, title TEXT, info TEXT);\n"
                      + "INSERT INTO SongBook VALUES (1, 'Гимны надежды', 'Пробный сборник');\n"
                      + "CREATE TABLE Songs (id INTEGER PRIMARY KEY, number INTEGER, title TEXT,\n"
                      + "    category TEXT, tune TEXT, words TEXT, music TEXT, song_text TEXT,\n"
                      + "    notes TEXT, date TEXT);\n"
                      + "INSERT INTO Songs VALUES (1, 12, 'Великий Бог', '', 'C', 'К. Боберг', 'Ш. Хайн',\n"
                      + $"    '{Escaped(Lyrics)}', 'проба', '01.01.2020');\n"
                      + "INSERT INTO Songs VALUES (2, 13, 'Тихая ночь', '', '', '', '',\n"
                      + $"    '{Escaped(PackedLyrics)}', '', '');";
        }
        else
        {
            script += "CREATE TABLE Slides (id INTEGER PRIMARY KEY, caption TEXT, body TEXT);\n"
                      + "INSERT INTO Slides VALUES (1, 'а', 'б');\n"
                      + "CREATE TABLE Settings (name TEXT, value TEXT);";
        }
        try
        {
            var builder = new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = false };
            using var database = new SqliteConnection(builder.ToString());
            database.Open();
            using var command = database.CreateCommand();
            command.CommandText = script;
            command.ExecuteNonQuery();
            return path;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static string Escaped(string text) => text.Replace("'", "''");

    private static string? MakeXML(string folder, string name, bool withBOM)
    {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                  + "<spSongBook version=\"2.0\">\n"
                  + " <SongBook><title>Старая выгрузка</title><info>XML вариант</info></SongBook>\n"
                  + " <Song number=\"5\">\n"
                  + "  <title>Как Ты велик</title><words>автор слов</words><music>автор музыки</music>\n"
                  + $"  <song_text><![CDATA[{Lyrics}]]></song_text>\n"
                  + " </Song>\n"
                  + " <Song number=\"6\">\n"
                  + "  <title>Без частей</title><song_text>Одна строка\n"
                  + "\n"
                  + "Другая строка</song_text>\n"
                  + " </Song>\n"
                  + "</spSongBook>";
        var data = new List<byte>();
        if (withBOM) data.AddRange([0xEF, 0xBB, 0xBF]);
        data.AddRange(new UTF8Encoding(false).GetBytes(xml));
        return Write(data.ToArray(), folder, name);
    }
}
