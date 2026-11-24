// =============================================================================
//  ServicePlan+Journal.cs — план у форматі оригіналу `<JournalFile>`
//  (з Plan/ServicePlan+Journal.swift)
// =============================================================================

using System.Globalization;

namespace Slovo.Core;

/// План (10) у форматі оригіналу.
///
/// Посібник (5.1.10): «Для каждого случая можно сохранить свой план в
/// отдельный файл и загружать нужный. При запуске прежней программы отображает
/// последний использовавшийся вариант плана». В оригіналу останній план
/// лежить у `PlanDef.ini`, збережені — у теці `Plans`, і обидва в тій самій
/// розмітці `<JournalFile>`, що й `History.ini`.
///
/// Раніше «Слово» писало свій JSON і файлів старої програми не відкривало зовсім.
/// Тепер читаються обидва види: журнал упізнається за першим рядком, а все
/// інше як і раніше розбирається як JSON.
public sealed partial class ServicePlan
{
    /// Ім'я файлу останнього плану — те саме, що в оригіналу.
    public const string DefaultFileName = "PlanDef.ini";
    /// Розширення збережених планів оригіналу.
    public const string JournalFileExtension = "ini";

    private static readonly JournalFile.Section[] JournalSections =
        [JournalFile.Section.Bible, JournalFile.Section.Text, JournalFile.Section.Songs];

    // ── Читання ─────────────────────────────────────────────────────────────

    /// План із файла будь-якого з двох видів.
    public static LoadResult ReadAny(string path)
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(path);
        }
        catch (Exception error)
        {
            throw PlanError.Unreadable(SwiftPath.LastComponent(path), error.Message);
        }

        var text = CodePage.Decode(data, null);
        if (!JournalFile.LooksLikeJournal(text)) return Read(path);

        var plan = FromJournal(JournalFile.Parse(text));
        plan.Title = SwiftPath.LastComponent(SwiftPath.DeletingExtension(path));
        plan.MarkSaved(path);
        return new LoadResult(plan, 0);
    }

    /// Пункти з трьох журналів (`init(journal:)`).
    ///
    /// У нашому плані список один і порядок у ньому — порядок подачі, а в
    /// оригіналу пункти розкладено за вкладками модулів. Свій порядок пишемо
    /// окремим полем `Order`; у чужому файлі його немає, і тоді пункти йдуть
    /// журналами підряд — Біблія, Текст, Пісні.
    public static ServicePlan FromJournal(JournalFile journal)
    {
        var numbered = new List<(int Order, PlanItem Item)>();
        var fallback = 0;

        foreach (var section in JournalSections)
        {
            foreach (var entry in journal[section])
            {
                if (PlanItem.FromJournalItem(entry, section) is not { } item) continue;
                numbered.Add((entry.Int("Order") ?? 1_000_000 + fallback, item));
                fallback += 1;
            }
        }
        // Сортування Swift стабільне — однакові `Order` лишаються в порядку журналів.
        return new ServicePlan(items: numbered.OrderBy(pair => pair.Order).Select(pair => pair.Item));
    }

    // ── Запис ───────────────────────────────────────────────────────────────

    public JournalFile Journal()
    {
        var result = new JournalFile();
        for (var position = 0; position < items.Count; position++)
        {
            var (section, entry) = items[position].JournalItem(position);
            if (!result.Items.TryGetValue(section, out var list)) result.Items[section] = list = new List<JournalFile.Item>();
            list.Add(entry);
        }
        return result;
    }

    /// Збереження у файл оригіналу.
    public void SaveAsJournal(string path)
    {
        Journal().Write(path);
        MarkSaved(path);
    }
}

// ── Пункт плану ────────────────────────────────────────────────────────────

public sealed partial record PlanItem
{
    /// Розбір пункту з журналу (`init?(journalItem:section:)`). `null` — пункт ні
    /// про що: в оригіналу в журналі «Текст» може лежати порожній рядок, і списку
    /// він не потрібен.
    public static PlanItem? FromJournalItem(JournalFile.Item item, JournalFile.Section section)
    {
        var caption = item.String("Caption");
        var reference = item.String("Reference");
        var quote = item.String("Quote");

        switch (section)
        {
            case JournalFile.Section.Bible:
            {
                if (item.Int("Book") is not { } book || book < 0) return null;
                // Розділ і вірш у файлі рахуються з нуля, довжина уривка лежить
                // окремим полем. Свій список віршів пишемо рядком «16,17,18»:
                // виділення може бути й не суцільним, а поле довжини цього не виражає.
                var chapter = (item.Int("Chapter") ?? 0) + 1;
                var listed = ParseVerses(item.String("Verses"));
                List<int> verses;
                if (listed.Count > 0)
                {
                    verses = listed;
                }
                else
                {
                    var first = (item.Int("Verse") ?? 0) + 1;
                    var extra = Math.Min(Math.Max(item.Int("VersesRangeCount") ?? 0, 0), 400);
                    verses = Enumerable.Range(first, extra + 1).ToList();
                }
                // Підпис рядка — лише адреса: текст цитати в оригіналу лежить
                // окремим полем Quote, а Caption склеює їх через дефіс.
                var title = reference.Length == 0 ? caption : reference;
                return new PlanItem(title.Length == 0 ? OurWords.T("Отрывок %s", chapter.ToString(CultureInfo.InvariantCulture)) : title,
                                    Shorten(quote),
                                    PlanContent.OfScripture(new PlanScripture(item.String("Module"), book, chapter, verses)));
            }
            case JournalFile.Section.Songs:
            {
                var file = item.String("SongBook");
                if (file.Length == 0) return null;
                // Немає частини або вона від'ємна — пісня цілком.
                var part = item.Int("Part") is { } value && value >= 0 ? value : (int?)null;
                return new PlanItem(caption.Length == 0 ? file : caption, Shorten(quote),
                                    PlanContent.OfSong(new PlanSongPartReference(file, Math.Max(item.Int("Song") ?? 0, 0), part)));
            }
            default:
            {
                // Пункт-файл лежить у журналі «Текст» зі своїм полем `File`:
                // окремого журналу для файлів в оригіналу немає, і стара програма
                // побачить такий пункт звичайним текстом із назвою файла.
                var file = item.String("File");
                if (file.Length > 0)
                    return new PlanItem(caption.Length == 0 ? SwiftPath.LastComponent(file) : caption, null,
                                        PlanContent.OfFile(new PlanFileReference(file)));
                var heading = item.String("Heading", reference);
                var body = item.String("Body", quote);
                if (heading.Length == 0 && body.Length == 0 && caption.Length == 0) return null;
                var document = new PlainTextDocument(heading, body.Length == 0 ? caption : body);
                return new PlanItem(caption.Length == 0 ? document.Summary(80) : caption, null, PlanContent.OfText(document));
            }
        }
    }

    /// Пункт для запису в журнал разом із журналом, якому він належить.
    public (JournalFile.Section Section, JournalFile.Item Item) JournalItem(int order)
    {
        var orderText = order.ToString(CultureInfo.InvariantCulture);
        switch (Content.Kind)
        {
            case PlanItemKind.Scripture:
            {
                var reference = Content.Scripture!;
                var first = reference.Verses.Count > 0 ? reference.Verses[0] : 1;
                var entry = new JournalFile.Item(new (string, string)[]
                {
                    ("Caption", HistoryRecord.CaptionFor(Title, Subtitle ?? "")),
                    ("Reference", Title),
                    ("Quote", Subtitle ?? ""),
                    ("Class", "0"),
                    ("Book", reference.BookIndex.ToString(CultureInfo.InvariantCulture)),
                    ("Chapter", Math.Max(reference.Chapter - 1, 0).ToString(CultureInfo.InvariantCulture)),
                    ("Verse", Math.Max(first - 1, 0).ToString(CultureInfo.InvariantCulture)),
                    ("VersesRangeCount", Math.Max(reference.Verses.Count - 1, 0).ToString(CultureInfo.InvariantCulture)),
                });
                // Свої поля йдуть у кінці: стара програма зайвих атрибутів не читає і
                // на них не спотикається, а нам вони повертають точний уривок.
                entry["Verses"] = FormatVerses(reference.Verses);
                entry["Module"] = reference.ModuleID;
                entry["Order"] = orderText;
                return (JournalFile.Section.Bible, entry);
            }
            case PlanItemKind.Song:
            {
                var reference = Content.Song!.Value;
                var fields = new List<(string, string)>
                {
                    ("Caption", Title),
                    ("Quote", Subtitle ?? ""),
                    ("SongBook", reference.BookFileName),
                    ("Song", reference.SongIndex.ToString(CultureInfo.InvariantCulture)),
                };
                // Пісня цілком — без частини.
                if (reference.PartIndex is { } part) fields.Add(("Part", part.ToString(CultureInfo.InvariantCulture)));
                var entry = new JournalFile.Item(fields);
                entry["Order"] = orderText;
                return (JournalFile.Section.Songs, entry);
            }
            case PlanItemKind.Text:
            {
                var document = Content.Text!.Value;
                var entry = new JournalFile.Item(new (string, string)[]
                {
                    ("Caption", Title),
                    ("Reference", document.Title),
                    ("Quote", document.Body),
                });
                entry["Heading"] = document.Title;
                entry["Body"] = document.Body;
                entry["Order"] = orderText;
                return (JournalFile.Section.Text, entry);
            }
            default:
            {
                var reference = Content.File!.Value;
                var entry = new JournalFile.Item(new (string, string)[]
                {
                    ("Caption", Title),
                    ("Reference", Title),
                    ("Quote", ""),
                });
                entry["Heading"] = Title;
                entry["Body"] = "";
                entry["File"] = reference.Path;
                entry["Order"] = orderText;
                return (JournalFile.Section.Text, entry);
            }
        }
    }
}
