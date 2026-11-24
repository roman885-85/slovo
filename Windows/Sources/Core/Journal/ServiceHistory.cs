// =============================================================================
//  ServiceHistory.cs — Історія (11) (з Journal/ServiceHistory.swift)
// =============================================================================

namespace Slovo.Core;

/// Рядок Історії (11) — розділ 5.1.11 посібника.
///
/// «В историю заносятся адреса всех стихов, которые были первыми показаны в
/// окне слайда после их выбора.» Тому запис зберігає не лише адресу, а й
/// усе, чим це місце потім відкривається заново. Склад полів узято з
/// `History.ini` оригіналу.
public sealed record HistoryRecord
{
    /// Журнал, у який пункт потрапляє: в оригіналу історія ведеться окремо
    /// для кожної вкладки модулів (18).
    public enum Kind { Bible, Text, Song }

    public Guid Id { get; set; }
    public Kind RecordKind { get; set; }
    /// Рядок списку цілком — «Быт.- В начале сотворил Бог небо и землю.»
    public string Caption { get; set; }
    /// Адреса місця Писання в тому вигляді, в якому вона пішла на слайд.
    public string Reference { get; set; }
    /// Текст показаного — вірш, частина пісні або оголошення.
    public string Quote { get; set; }

    // Місце Писання
    public int BookClass { get; set; }
    public int BookIndex { get; set; }
    public int Chapter { get; set; }
    public ValueList<int> Verses { get; set; }
    public string ModuleShortName { get; set; }
    public string ModuleShortNameSecond { get; set; }
    /// Скорочення книги через кому — так їх зберігає оригінал.
    public string ShortNames { get; set; }
    public string FullName { get; set; }

    // Частина пісні
    public string SongBookFileName { get; set; }
    public int SongIndex { get; set; }
    public int PartIndex { get; set; }

    public HistoryRecord(Kind kind,
                         string caption = "",
                         string reference = "",
                         string quote = "",
                         int bookClass = 0,
                         int bookIndex = 0,
                         int chapter = 0,
                         IEnumerable<int>? verses = null,
                         string moduleShortName = "",
                         string moduleShortNameSecond = "",
                         string shortNames = "",
                         string fullName = "",
                         string songBookFileName = "",
                         int songIndex = 0,
                         int partIndex = 0,
                         Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        RecordKind = kind;
        Reference = reference;
        Quote = quote;
        Caption = caption.Length == 0 ? CaptionFor(reference, quote) : caption;
        BookClass = bookClass;
        BookIndex = bookIndex;
        Chapter = chapter;
        Verses = new ValueList<int>(verses ?? Array.Empty<int>());
        ModuleShortName = moduleShortName;
        ModuleShortNameSecond = moduleShortNameSecond;
        ShortNames = shortNames;
        FullName = fullName;
        SongBookFileName = songBookFileName;
        SongIndex = songIndex;
        PartIndex = partIndex;
    }

    public static JournalFile.Section SectionOf(Kind kind) => kind switch
    {
        Kind.Bible => JournalFile.Section.Bible,
        Kind.Text => JournalFile.Section.Text,
        _ => JournalFile.Section.Songs,
    };

    /// Підпис рядка рівно як у файлі оригіналу: «Руф.- В те дни, когда…».
    /// Між адресою і текстом стоїть дефіс без пробілу зліва — так в автора.
    public static string CaptionFor(string reference, string quote)
    {
        var text = quote.TrimWhitespacesAndNewlines().Replace("\n", " ");
        if (reference.Length == 0) return text;
        return text.Length == 0 ? reference : $"{reference}- {text}";
    }

    /// Ключ повтору: те саме місце підряд другим рядком не заводиться.
    public string Identity => RecordKind switch
    {
        Kind.Bible => $"b:{BookIndex}:{Chapter}:{string.Join(",", Verses)}",
        Kind.Song => $"s:{SongBookFileName}:{SongIndex}:{PartIndex}",
        _ => $"t:{Caption}",
    };

    public HistoryRecord Copy() => this with { Verses = new ValueList<int>(Verses) };
}

/// Історія (11) цілком, разом із читанням і записом у файл оригіналу.
///
/// «Оригінал історію зберігає між запусками»: у користувача поруч із
/// програмою лежить `History.ini` у форматі журналу. Читаємо ми і його, і
/// свій файл, а пишемо лише у свій.
public sealed class ServiceHistory
{
    /// Ім'я файлу — те саме, що в оригіналу.
    public const string FileName = "History.ini";
    /// Скільки рядків тримаємо. В оригіналу список теж не нескінченний.
    public const int Limit = 60;

    private readonly List<HistoryRecord> records;

    public IReadOnlyList<HistoryRecord> Records => records;

    public ServiceHistory(IEnumerable<HistoryRecord>? records = null) =>
        this.records = records?.ToList() ?? new List<HistoryRecord>();

    public bool IsEmpty => records.Count == 0;
    public int Count => records.Count;

    /// Нове місце нагору списку. Повтор того самого місця одразу за собою не
    /// заводиться, а знайдений нижче — піднімається нагору, як в оригіналі.
    public void Remember(HistoryRecord record)
    {
        var key = record.Identity;
        if (records.Count > 0 && records[0].Identity == key) return;
        records.RemoveAll(existing => existing.Identity == key);
        records.Insert(0, record);
        if (records.Count > Limit) records.RemoveRange(Limit, records.Count - Limit);
    }

    public void Remove(Guid id) => records.RemoveAll(record => record.Id == id);

    public void RemoveAll() => records.Clear();

    // ── Файл ────────────────────────────────────────────────────────────────

    public static ServiceHistory Read(string path)
    {
        try
        {
            return FromJournal(JournalFile.Read(path));
        }
        catch
        {
            return new ServiceHistory();
        }
    }

    /// `init(journal:)`: спершу Біблія, потім пісні, потім текст — як на Mac.
    public static ServiceHistory FromJournal(JournalFile journal)
    {
        var result = new List<HistoryRecord>();
        foreach (var item in journal[JournalFile.Section.Bible]) result.Add(BibleRecord(item));
        foreach (var item in journal[JournalFile.Section.Songs]) result.Add(SongRecord(item));
        foreach (var item in journal[JournalFile.Section.Text]) result.Add(TextRecord(item));
        return new ServiceHistory(result.Take(Limit));
    }

    public JournalFile Journal()
    {
        var journal = new JournalFile();
        foreach (var record in records)
        {
            var section = HistoryRecord.SectionOf(record.RecordKind);
            if (!journal.Items.TryGetValue(section, out var list))
            {
                list = new List<JournalFile.Item>();
                journal.Items[section] = list;
            }
            list.Add(ItemFor(record));
        }
        return journal;
    }

    public void Write(string path) => Journal().Write(path);

    // ── Пункт файла ─────────────────────────────────────────────────────────

    private static JournalFile.Item ItemFor(HistoryRecord record)
    {
        switch (record.RecordKind)
        {
            case HistoryRecord.Kind.Bible:
                // Порядок та імена полів — як у History.ini оригіналу. Номери
                // розділу і вірша там рахуються з нуля, а довжина уривка записана
                // окремим полем VersesRangeCount.
                var first = record.Verses.Count > 0 ? record.Verses[0] : 1;
                return new JournalFile.Item(new[]
                {
                    ("Caption", record.Caption),
                    ("Reference", record.Reference),
                    ("Quote", record.Quote),
                    ("Class", $"{record.BookClass}"),
                    ("Book", $"{record.BookIndex}"),
                    ("Chapter", $"{Math.Max(record.Chapter - 1, 0)}"),
                    ("Verse", $"{Math.Max(first - 1, 0)}"),
                    ("QuoteFont", ""),
                    ("QuoteCharSet", "512"),
                    ("ModuleShortName", record.ModuleShortName),
                    ("ModuleShortNameSecond", record.ModuleShortNameSecond),
                    ("ShortName", record.ShortNames),
                    ("FullName", record.FullName),
                    ("VersesRangeCount", $"{Math.Max(record.Verses.Count - 1, 0)}"),
                });
            case HistoryRecord.Kind.Song:
                return new JournalFile.Item(new[]
                {
                    ("Caption", record.Caption),
                    ("Reference", record.Reference),
                    ("Quote", record.Quote),
                    ("SongBook", record.SongBookFileName),
                    ("Song", $"{record.SongIndex}"),
                    ("Part", $"{record.PartIndex}"),
                });
            default:
                return new JournalFile.Item(new[]
                {
                    ("Caption", record.Caption),
                    ("Reference", record.Reference),
                    ("Quote", record.Quote),
                });
        }
    }

    private static HistoryRecord BibleRecord(JournalFile.Item item)
    {
        var chapter = (item.Int("Chapter") ?? 0) + 1;
        var first = (item.Int("Verse") ?? 0) + 1;
        var extra = Math.Max(item.Int("VersesRangeCount") ?? 0, 0);
        // Уривок у файлі задано першим віршем і довжиною; більшим за розділ він бути
        // не може, і чуже число сюди краще не пускати.
        var verses = Enumerable.Range(first, Math.Min(extra, 400) + 1);

        return new HistoryRecord(HistoryRecord.Kind.Bible,
                                 caption: item.String("Caption"),
                                 reference: item.String("Reference"),
                                 quote: item.String("Quote"),
                                 bookClass: item.Int("Class") ?? 0,
                                 bookIndex: item.Int("Book") ?? 0,
                                 chapter: chapter,
                                 verses: verses,
                                 moduleShortName: item.String("ModuleShortName"),
                                 moduleShortNameSecond: item.String("ModuleShortNameSecond"),
                                 shortNames: item.String("ShortName"),
                                 fullName: item.String("FullName"));
    }

    private static HistoryRecord SongRecord(JournalFile.Item item) =>
        new(HistoryRecord.Kind.Song,
            caption: item.String("Caption"),
            reference: item.String("Reference"),
            quote: item.String("Quote"),
            songBookFileName: item.String("SongBook"),
            songIndex: item.Int("Song") ?? 0,
            partIndex: item.Int("Part") ?? 0);

    private static HistoryRecord TextRecord(JournalFile.Item item) =>
        new(HistoryRecord.Kind.Text,
            caption: item.String("Caption"),
            reference: item.String("Reference"),
            quote: item.String("Quote"));
}
