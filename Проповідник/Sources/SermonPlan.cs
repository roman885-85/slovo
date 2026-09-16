// =============================================================================
//  SermonPlan.cs — план проповіді: назва й пункти в порядку подачі
// =============================================================================
//  Перенесено з планшета (SermonPlan.java), формат файла той самий.
//  Кожен план — окремий файл у теці plans: проповідник може скласти кілька
//  наперед і взяти на служіння потрібний. Пункт везе з собою не лише
//  посилання, а й сам текст — вірші чи слова пісні: якщо в програмі на
//  служінні не виявиться того перекладу чи пісенника, пункт усе одно
//  покажеться — текстом.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Propovidnyk;

public sealed class PlanItem
{
    public const string Scripture = "scripture";
    public const string Song = "song";
    public const string Text = "text";
    public const string File = "file";

    public string Type = Text;
    /// Рядок у списку: «Ів 3:16-18», назва пісні, заголовок, ім'я файла.
    public string Title = "";

    // Уривок.
    public string Module = "";
    public string ModuleName = "";
    public string BookName = "";
    public int Canon;
    public int Book;
    public int Chapter;
    public List<int> Verses = new();
    public string Body = "";   // текст віршів (для уривка) — у файлі поле "text"

    // Пісня.
    public string SongBook = "";
    public int SongIndex;
    public List<(string Kind, string Text)> Parts = new();

    // Довільний текст.
    public string Heading = "";
    public string Announcement = "";   // у файлі поле "body"

    // Файл: копія в теці програми і його справжнє ім'я.
    public string Path = "";
    public string Name = "";

    public string Icon => Type switch
    {
        Scripture => "📖",
        Song => "🎵",
        File => "📄",
        _ => "✎",
    };

    /// Друга половина рядка списку — початок тексту.
    public string Subtitle
    {
        get
        {
            var value = Type switch
            {
                Scripture => Body,
                Song => Parts.Count == 0 ? "" : Parts[0].Text,
                Text => Announcement,
                _ => Name,
            };
            value = value.Replace('\r', ' ').Replace('\n', ' ').Trim();
            return value.Length > 120 ? value[..120] + "…" : value;
        }
    }

    public JsonObject ToJson()
    {
        var json = new JsonObject { ["type"] = Type, ["title"] = Title };
        switch (Type)
        {
            case Scripture:
                json["module"] = Module;
                json["moduleName"] = ModuleName;
                json["bookName"] = BookName;
                json["canon"] = Canon;
                json["book"] = Book;
                json["chapter"] = Chapter;
                json["verses"] = new JsonArray(Verses.Select(v => (JsonNode)v).ToArray());
                json["text"] = Body;
                break;
            case Song:
                json["module"] = Module;
                json["songBook"] = SongBook;
                json["song"] = SongIndex;
                json["parts"] = new JsonArray(Parts.Select(p => (JsonNode)new JsonObject { ["kind"] = p.Kind, ["text"] = p.Text }).ToArray());
                break;
            case Text:
                json["heading"] = Heading;
                json["body"] = Announcement;
                break;
            default:
                json["path"] = Path;
                json["name"] = Name;
                break;
        }
        return json;
    }

    public static PlanItem FromJson(JsonObject json)
    {
        var item = new PlanItem
        {
            Type = (string?)json["type"] ?? Text,
            Title = (string?)json["title"] ?? "",
            Module = (string?)json["module"] ?? "",
            ModuleName = (string?)json["moduleName"] ?? "",
            BookName = (string?)json["bookName"] ?? "",
            Canon = (int?)json["canon"] ?? 0,
            Book = (int?)json["book"] ?? 0,
            Chapter = (int?)json["chapter"] ?? 0,
            SongBook = (string?)json["songBook"] ?? "",
            SongIndex = (int?)json["song"] ?? 0,
            Heading = (string?)json["heading"] ?? "",
            Path = (string?)json["path"] ?? "",
            Name = (string?)json["name"] ?? "",
        };
        if (json["verses"] is JsonArray verses) item.Verses = verses.Select(v => (int?)v ?? 0).ToList();
        if (json["parts"] is JsonArray parts)
            item.Parts = parts.OfType<JsonObject>().Select(p => ((string?)p["kind"] ?? "", (string?)p["text"] ?? "")).ToList();
        // «text» — текст віршів, «body» — текст оголошення.
        item.Body = item.Type == Scripture ? (string?)json["text"] ?? "" : "";
        item.Announcement = item.Type == Text ? (string?)json["body"] ?? "" : "";
        return item;
    }
}

public sealed class SermonPlan
{
    public string Id = Guid.NewGuid().ToString();
    public string Title = "";
    public long Updated;
    public List<PlanItem> Items = new();

    public string DisplayTitle => string.IsNullOrWhiteSpace(Title) ? Lang.T("План без назви", "Untitled plan") : Title;

    /// Усі плани, свіжіші зверху.
    public static List<SermonPlan> All()
    {
        var result = new List<SermonPlan>();
        foreach (var file in Directory.GetFiles(Paths.Plans, "*.json"))
        {
            var plan = Load(file);
            if (plan != null) result.Add(plan);
        }
        return result.OrderByDescending(p => p.Updated).ToList();
    }

    public static SermonPlan? Load(string file)
    {
        try
        {
            if (JsonNode.Parse(System.IO.File.ReadAllText(file)) is not JsonObject json) return null;
            var plan = new SermonPlan
            {
                Id = (string?)json["id"] ?? System.IO.Path.GetFileNameWithoutExtension(file),
                Title = (string?)json["title"] ?? "",
                Updated = (long?)json["updated"] ?? new DateTimeOffset(System.IO.File.GetLastWriteTimeUtc(file)).ToUnixTimeMilliseconds(),
            };
            if (json["items"] is JsonArray items)
                plan.Items = items.OfType<JsonObject>().Select(PlanItem.FromJson).ToList();
            return plan;
        }
        catch (Exception error)
        {
            Paths.Say($"план {file} не прочитався: {error.Message}");
            return null;
        }
    }

    public static SermonPlan? Load(string? id, bool byId) =>
        string.IsNullOrEmpty(id) ? null : Load(System.IO.Path.Combine(Paths.Plans, id + ".json"));

    public void Save()
    {
        Updated = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var json = new JsonObject
        {
            ["id"] = Id,
            ["title"] = Title,
            ["updated"] = Updated,
            ["items"] = new JsonArray(Items.Select(i => (JsonNode)i.ToJson()).ToArray()),
        };
        var target = System.IO.Path.Combine(Paths.Plans, Id + ".json");
        var temp = System.IO.Path.Combine(Paths.Plans, Id + ".tmp");
        System.IO.File.WriteAllText(temp, json.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        System.IO.File.Move(temp, target, true);
    }

    /// Прибрати план разом із копіями його файлів.
    public void Delete()
    {
        foreach (var item in Items)
        {
            if (item.Type == PlanItem.File && item.Path.Length > 0)
            {
                try { System.IO.File.Delete(item.Path); } catch { /* уже нема */ }
            }
        }
        try { System.IO.File.Delete(System.IO.Path.Combine(Paths.Plans, Id + ".json")); } catch { /* уже нема */ }
    }

    /// Вірші, що йдуть підряд, згортаються в діапазон: 1,2,3,7 → «1-3,7».
    public static string Span(IReadOnlyList<int> numbers)
    {
        var parts = new List<string>();
        var i = 0;
        while (i < numbers.Count)
        {
            var start = numbers[i];
            var end = start;
            while (i + 1 < numbers.Count && numbers[i + 1] == end + 1)
            {
                i++;
                end = numbers[i];
            }
            parts.Add(start == end ? start.ToString() : start + "-" + end);
            i++;
        }
        return string.Join(",", parts);
    }
}
