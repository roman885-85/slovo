// =============================================================================
//  Plan.cs — План служіння (F2) та Історія (11)
// =============================================================================
//  Той самий файл плану, що й у «Слова» на Mac (`slovo.plan`, версія 1, JSON):
//  план, складений на одній машині, відкривається на іншій. Пункти — уривок,
//  частина пісні (чи пісня цілком), текст, файл. Читання поблажливе: описка в
//  одному пункті не ронить план.
//
//  Історія — те, що вже показували в залі: адреса, текст і все, чим це місце
//  відкривається знову. Пишемо у свій History.json.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Slovo;

public enum PlanKind { Scripture, Song, Text, File }

public sealed class PlanItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public PlanKind Kind { get; set; }
    /// Підпис у списку: «Ів 3:16-18», «Великий Бог — Куплет 1».
    public string Title { get; set; } = "";
    /// Початок тексту цитати — друга половина рядка списку.
    public string Subtitle { get; set; } = "";

    // Уривок: книга зберігається індексом у модулі (порядок книг спільний),
    // порожній список віршів — «розділ цілком».
    public string ModuleId { get; set; } = "";
    public int BookIndex { get; set; }
    public int Chapter { get; set; }
    public List<int> Verses { get; set; } = new();

    // Частина пісні: ім'я файлу пісенника (ідентифікатор модуля пісень) і
    // номер пісні; `PartIndex` null — пісня цілком.
    public string SongBook { get; set; } = "";
    public int SongIndex { get; set; }
    public int? PartIndex { get; set; }

    // Текст
    public string Heading { get; set; } = "";
    public string Body { get; set; } = "";

    // Файл
    public string Path { get; set; } = "";

    public string KindTitle => Kind switch
    {
        PlanKind.Scripture => Lang.T("Уривок", "Passage"),
        PlanKind.Song => Lang.T("Пісня", "Song"),
        PlanKind.Text => Lang.T("Текст", "Text"),
        _ => Lang.T("Файл", "File"),
    };

    public string Icon => Kind switch
    {
        PlanKind.Scripture => "📖",
        PlanKind.Song => "🎵",
        PlanKind.Text => "📝",
        _ => "📄",
    };

    // MARK: Збирання пунктів

    public static PlanItem Scripture(string moduleId, Book book, int bookIndex, int chapter, IEnumerable<int> verses, string? quote)
    {
        var list = verses.Distinct().OrderBy(v => v).ToList();
        return new PlanItem
        {
            Kind = PlanKind.Scripture,
            Title = Reference(book, chapter, list),
            Subtitle = Shorten(quote),
            ModuleId = moduleId, BookIndex = bookIndex, Chapter = chapter, Verses = list,
        };
    }

    public static PlanItem SongPart(string bookFileName, int songIndex, string songTitle, Part part)
    {
        var name = songTitle.Length == 0 ? Lang.T("Пісня ", "Song ") + (songIndex + 1) : songTitle;
        var kind = part.Kind.Trim();
        return new PlanItem
        {
            Kind = PlanKind.Song,
            Title = kind.Length == 0 ? name : name + " — " + kind,
            Subtitle = Shorten(part.Text.Replace("\n", " ")),
            SongBook = bookFileName, SongIndex = songIndex, PartIndex = part.Index,
        };
    }

    /// Пісня цілком — один пункт плану (власник: «при добавлении песни вместо
    /// песни добавляются куплеты»).
    public static PlanItem Song(string bookFileName, int songIndex, string songTitle, string? firstPartText)
    {
        var name = songTitle.Length == 0 ? Lang.T("Пісня ", "Song ") + (songIndex + 1) : songTitle;
        return new PlanItem
        {
            Kind = PlanKind.Song, Title = name, Subtitle = Shorten(firstPartText?.Replace("\n", " ")),
            SongBook = bookFileName, SongIndex = songIndex, PartIndex = null,
        };
    }

    public static PlanItem Text(TextDocument document)
    {
        var summary = document.Summary(80);
        return new PlanItem
        {
            Kind = PlanKind.Text, Title = summary.Length == 0 ? Lang.T("Текст", "Text") : summary,
            Heading = document.Title, Body = document.Body,
        };
    }

    public static PlanItem File(string path, string? title = null)
    {
        var caption = (title ?? "").Trim();
        return new PlanItem { Kind = PlanKind.File, Title = caption.Length == 0 ? System.IO.Path.GetFileName(path) : caption, Path = path };
    }

    public static string Reference(Book book, int chapter, List<int> verses)
    {
        var name = BookNames.ButtonTitle(book);
        var numbers = ReferenceFormat.FormatVerses(verses);
        return numbers.Length == 0 ? name + " " + chapter : name + " " + chapter + ":" + numbers;
    }

    static string Shorten(string? text, int limit = 160)
    {
        if (text == null) return "";
        var single = text.Replace("\n", " ").Trim();
        return single.Length <= limit ? single : single[..limit] + "…";
    }

    // MARK: JSON

    public JsonObject ToJson()
    {
        var json = new JsonObject
        {
            ["id"] = Id.ToString().ToUpperInvariant(),
            ["type"] = Kind switch { PlanKind.Scripture => "scripture", PlanKind.Song => "song", PlanKind.Text => "text", _ => "file" },
            ["title"] = Title,
        };
        if (Subtitle.Length > 0) json["subtitle"] = Subtitle;
        switch (Kind)
        {
            case PlanKind.Scripture:
                json["module"] = ModuleId; json["book"] = BookIndex; json["chapter"] = Chapter;
                json["verses"] = new JsonArray(Verses.Select(v => (JsonNode)v).ToArray());
                break;
            case PlanKind.Song:
                json["songBook"] = SongBook; json["song"] = SongIndex;
                json["part"] = PartIndex == null ? null : PartIndex.Value;
                break;
            case PlanKind.Text:
                json["heading"] = Heading; json["body"] = Body;
                break;
            default:
                json["path"] = Path;
                break;
        }
        return json;
    }

    /// Пункт із JSON; null — пункт не розібрався (план його пропускає).
    public static PlanItem? FromJson(JsonObject json)
    {
        string S(string key)
        {
            var node = json[key];
            if (node is JsonValue value)
            {
                if (value.TryGetValue<string>(out var text)) return text;
                if (value.TryGetValue<long>(out var number)) return number.ToString();
                if (value.TryGetValue<double>(out var real)) return ((long)real).ToString();
            }
            return "";
        }
        int? N(string key)
        {
            var node = json[key];
            if (node is JsonValue value)
            {
                if (value.TryGetValue<long>(out var number)) return (int)Math.Clamp(number, int.MinValue, int.MaxValue);
                if (value.TryGetValue<double>(out var real) && double.IsFinite(real)) return (int)Math.Clamp(real, int.MinValue, int.MaxValue);
                if (value.TryGetValue<string>(out var text) && int.TryParse(text.Trim(), out var parsed)) return parsed;
            }
            return null;
        }
        List<int> VersesOf()
        {
            var node = json["verses"];
            if (node is JsonArray array)
                return array.Select(n => n is JsonValue v && v.TryGetValue<long>(out var l) ? (int)l : -1).Where(v => v >= 0).OrderBy(v => v).ToList();
            if (node is JsonValue single)
            {
                if (single.TryGetValue<string>(out var text)) return ReferenceFormat.ParseVerses(text).OrderBy(v => v).ToList();
                if (single.TryGetValue<long>(out var one) && one >= 0) return new List<int> { (int)one };
            }
            return new List<int>();
        }

        var declared = S("type").ToLowerInvariant();
        var looksLikeSong = json.ContainsKey("songBook") || json.ContainsKey("song") || json.ContainsKey("part");
        var looksLikeText = json.ContainsKey("body") || json.ContainsKey("heading");
        if (declared.Length == 0)
        {
            if (json.ContainsKey("path")) declared = "file";
            else if (looksLikeText) declared = "text";
            else declared = looksLikeSong ? "song" : "scripture";
        }

        var item = new PlanItem { Title = S("title").Trim(), Subtitle = S("subtitle") };
        if (Guid.TryParse(S("id"), out var id)) item.Id = id;
        switch (declared)
        {
            case "scripture": case "bible": case "verse": case "verses":
                var book = N("book"); var chapter = N("chapter");
                if (book == null || book < 0 || chapter == null || chapter < 0) return null;
                item.Kind = PlanKind.Scripture; item.ModuleId = S("module"); item.BookIndex = book.Value;
                item.Chapter = chapter.Value; item.Verses = VersesOf();
                if (item.Title.Length == 0)
                {
                    var numbers = ReferenceFormat.FormatVerses(item.Verses);
                    item.Title = numbers.Length == 0 ? Lang.F("Уривок, розділ {0}", "Passage, chapter {0}", item.Chapter)
                                                     : Lang.F("Уривок {0}:{1}", "Passage {0}:{1}", item.Chapter, numbers);
                }
                break;
            case "song": case "songpart": case "song-part":
                var file = S("songBook"); var song = N("song");
                if (file.Length == 0 || song == null || song < 0) return null;
                item.Kind = PlanKind.Song; item.SongBook = file; item.SongIndex = song.Value;
                var part = N("part");
                item.PartIndex = part == null || part < 0 ? null : part;
                if (item.Title.Length == 0)
                    item.Title = item.PartIndex == null ? Lang.T("Пісня ", "Song ") + (item.SongIndex + 1)
                        : Lang.F("Пісня {0}, частина {1}", "Song {0}, part {1}", item.SongIndex + 1, item.PartIndex + 1);
                break;
            case "text": case "plaintext": case "plain-text":
                item.Kind = PlanKind.Text; item.Heading = S("heading"); item.Body = S("body");
                if (item.Title.Length == 0)
                {
                    var summary = new TextDocument(item.Heading, item.Body).Summary(80);
                    item.Title = summary.Length == 0 ? Lang.T("Текст", "Text") : summary;
                }
                break;
            case "file":
                var path = S("path");
                if (path.Length == 0) return null;
                item.Kind = PlanKind.File; item.Path = path;
                if (item.Title.Length == 0) item.Title = System.IO.Path.GetFileName(path);
                break;
            default:
                return null;
        }
        return item;
    }
}

/// План служіння — порядок того, що піде на екран.
public sealed class ServicePlan
{
    public const string FormatMarker = "slovo.plan";
    public const int FormatVersion = 1;

    public string Title { get; set; } = "";
    public List<PlanItem> Items { get; } = new();
    public string? FilePath { get; set; }
    public bool HasUnsavedChanges { get; set; }
    /// Скільки пунктів файл не розібрав.
    public int SkippedOnRead { get; private set; }

    public ServicePlan(string? title = null)
    {
        Title = title ?? Lang.T("План служіння", "Service plan");
    }

    public void Append(PlanItem item) { Items.Add(item); HasUnsavedChanges = true; }
    public void Append(IEnumerable<PlanItem> items) { Items.AddRange(items); HasUnsavedChanges = true; }
    public void Insert(int index, PlanItem item) { Items.Insert(Math.Clamp(index, 0, Items.Count), item); HasUnsavedChanges = true; }

    public PlanItem? RemoveAt(int index)
    {
        if (index < 0 || index >= Items.Count) return null;
        var removed = Items[index];
        Items.RemoveAt(index);
        HasUnsavedChanges = true;
        return removed;
    }

    public void Clear() { if (Items.Count == 0) return; Items.Clear(); HasUnsavedChanges = true; }

    /// Перестановка на один рядок угору чи вниз; повертає нове місце.
    public int Move(int index, int delta)
    {
        var target = index + delta;
        if (index < 0 || index >= Items.Count || target < 0 || target >= Items.Count) return index;
        var item = Items[index];
        Items.RemoveAt(index);
        Items.Insert(target, item);
        HasUnsavedChanges = true;
        return target;
    }

    public void MoveTo(int from, int to)
    {
        if (from < 0 || from >= Items.Count) return;
        var item = Items[from];
        Items.RemoveAt(from);
        Items.Insert(Math.Clamp(to, 0, Items.Count), item);
        HasUnsavedChanges = true;
    }

    // MARK: Файл

    public string Json()
    {
        var json = new JsonObject
        {
            ["format"] = FormatMarker,
            ["version"] = FormatVersion,
            ["title"] = Title,
            ["savedAt"] = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
            ["items"] = new JsonArray(Items.Select(i => (JsonNode)i.ToJson()).ToArray()),
        };
        return json.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        System.IO.File.WriteAllText(temp, Json(), new System.Text.UTF8Encoding(false));
        System.IO.File.Move(temp, path, true);
        FilePath = path;
        HasUnsavedChanges = false;
    }

    /// Ім'я файла за назвою плану — без знаків, яких не любить файлова система.
    public static string FileName(string title)
    {
        var cleaned = new string(title.Select(c => System.IO.Path.GetInvalidFileNameChars().Contains(c) ? ' ' : c).ToArray()).Trim();
        if (cleaned.Length == 0) cleaned = "План";
        return cleaned + ".json";
    }

    public static ServicePlan Load(string path)
    {
        var text = System.IO.File.ReadAllText(path);
        var json = JsonNode.Parse(text) as JsonObject ?? throw new InvalidDataException(Lang.T("Це не файл плану", "Not a plan file"));
        var format = (string?)json["format"] ?? "";
        if (format.Length > 0 && format != FormatMarker) throw new InvalidDataException(Lang.T("Це не план «Слова»", "Not a Slovo plan"));
        var plan = new ServicePlan((string?)json["title"] ?? System.IO.Path.GetFileNameWithoutExtension(path)) { FilePath = path };
        foreach (var node in json["items"] as JsonArray ?? new JsonArray())
        {
            var item = node is JsonObject entry ? PlanItem.FromJson(entry) : null;
            if (item == null) plan.SkippedOnRead++; else plan.Items.Add(item);
        }
        plan.HasUnsavedChanges = false;
        return plan;
    }

    public static List<string> SavedPlans()
    {
        try
        {
            return Directory.GetFiles(Paths.Plans, "*.json").OrderBy(f => f, StringComparer.CurrentCultureIgnoreCase).ToList();
        }
        catch { return new List<string>(); }
    }
}

public enum HistoryKind { Bible, Song, Text }

/// Рядок Історії (11): адреса всіх віршів, які були першими показані в залі.
public sealed class HistoryRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public HistoryKind Kind { get; set; }
    /// Рядок списку: «Быт.- В начале сотворил Бог небо и землю.»
    public string Caption { get; set; } = "";
    public string Reference { get; set; } = "";
    public string Quote { get; set; } = "";
    public string ModuleId { get; set; } = "";
    public int BookIndex { get; set; }
    public int Chapter { get; set; }
    public List<int> Verses { get; set; } = new();
    public string SongBook { get; set; } = "";
    public int SongIndex { get; set; }
    public int PartIndex { get; set; }
    public string Heading { get; set; } = "";
    public string Body { get; set; } = "";
    public DateTime When { get; set; } = DateTime.Now;

    public static string MakeCaption(string reference, string quote)
    {
        var text = quote.Trim().Replace("\n", " ");
        if (reference.Length == 0) return text;
        return text.Length == 0 ? reference : reference + "- " + text;
    }

    /// Ключ повтору: те саме місце підряд другим рядком не заводиться.
    public string Identity => Kind switch
    {
        HistoryKind.Bible => "b:" + ModuleId + ":" + BookIndex + ":" + Chapter + ":" + string.Join(",", Verses),
        HistoryKind.Song => "s:" + SongBook + ":" + SongIndex + ":" + PartIndex,
        _ => "t:" + Caption,
    };

    public JsonObject ToJson() => new()
    {
        ["id"] = Id.ToString(), ["kind"] = Kind.ToString().ToLowerInvariant(), ["caption"] = Caption,
        ["reference"] = Reference, ["quote"] = Quote, ["module"] = ModuleId, ["book"] = BookIndex,
        ["chapter"] = Chapter, ["verses"] = new JsonArray(Verses.Select(v => (JsonNode)v).ToArray()),
        ["songBook"] = SongBook, ["song"] = SongIndex, ["part"] = PartIndex, ["heading"] = Heading, ["body"] = Body,
        ["when"] = When.ToString("yyyy-MM-dd HH:mm:ss"),
    };

    public static HistoryRecord? FromJson(JsonObject json)
    {
        try
        {
            var record = new HistoryRecord
            {
                Kind = ((string?)json["kind"] ?? "bible") switch { "song" => HistoryKind.Song, "text" => HistoryKind.Text, _ => HistoryKind.Bible },
                Caption = (string?)json["caption"] ?? "", Reference = (string?)json["reference"] ?? "", Quote = (string?)json["quote"] ?? "",
                ModuleId = (string?)json["module"] ?? "", BookIndex = (int?)json["book"] ?? 0, Chapter = (int?)json["chapter"] ?? 0,
                SongBook = (string?)json["songBook"] ?? "", SongIndex = (int?)json["song"] ?? 0, PartIndex = (int?)json["part"] ?? 0,
                Heading = (string?)json["heading"] ?? "", Body = (string?)json["body"] ?? "",
            };
            if (Guid.TryParse((string?)json["id"], out var id)) record.Id = id;
            foreach (var node in json["verses"] as JsonArray ?? new JsonArray()) record.Verses.Add((int?)node ?? 0);
            if (DateTime.TryParse((string?)json["when"], out var when)) record.When = when;
            return record;
        }
        catch { return null; }
    }
}

/// Історія цілком — нове місце нагору, повтор підряд не заводиться.
public sealed class ServiceHistory
{
    public const int Limit = 60;
    public List<HistoryRecord> Records { get; } = new();

    public void Remember(HistoryRecord record)
    {
        var key = record.Identity;
        if (Records.Count > 0 && Records[0].Identity == key) return;
        Records.RemoveAll(r => r.Identity == key);
        Records.Insert(0, record);
        if (Records.Count > Limit) Records.RemoveRange(Limit, Records.Count - Limit);
    }

    public void Remove(Guid id) => Records.RemoveAll(r => r.Id == id);
    public void Clear() => Records.Clear();

    public void Save()
    {
        try
        {
            var json = new JsonObject { ["format"] = "slovo.history", ["records"] = new JsonArray(Records.Select(r => (JsonNode)r.ToJson()).ToArray()) };
            var temp = Paths.HistoryFile + ".tmp";
            System.IO.File.WriteAllText(temp, json.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
            System.IO.File.Move(temp, Paths.HistoryFile, true);
        }
        catch (Exception error) { Paths.Say("Історія не записалася: " + error.Message); }
    }

    public static ServiceHistory Load()
    {
        var history = new ServiceHistory();
        try
        {
            if (!System.IO.File.Exists(Paths.HistoryFile)) return history;
            var json = JsonNode.Parse(System.IO.File.ReadAllText(Paths.HistoryFile)) as JsonObject;
            foreach (var node in json?["records"] as JsonArray ?? new JsonArray())
            {
                var record = node is JsonObject entry ? HistoryRecord.FromJson(entry) : null;
                if (record != null) history.Records.Add(record);
            }
        }
        catch (Exception error) { Paths.Say("Історія не прочиталася: " + error.Message); }
        return history;
    }
}
