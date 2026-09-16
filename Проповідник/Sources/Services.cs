// =============================================================================
//  Services.cs — звідки брати модулі й як везти план у «Слово»
// =============================================================================
//  Робота без вікна: її кличе і екран, і перевірка з командного рядка
//  (--selftest), тож обидва шляхи ходять одним кодом.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;

namespace Propovidnyk;

/// Що можна взяти в бібліотеку: вид, ідентифікатор чи ім'я файла, назва.
public sealed record Offer(string Kind, string Key, string Name);

public static class Sources
{
    public const string GitHub = "https://raw.githubusercontent.com/BibleQuote/BibleQuote-Modules/master/";
    static readonly HttpClient Web = new() { Timeout = TimeSpan.FromMinutes(3) };

    // MARK: Зі «Слова»

    /// Переклади рядками, пісенники файлами .vbm — те, чого в бібліотеці ще нема.
    public static async Task<List<Offer>> FromSlovo(Api api, Library library)
    {
        var answer = await api.Get("/api/library");
        var offer = new List<Offer>();
        foreach (var item in (answer["bibles"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
        {
            var id = (string?)item["id"] ?? "";
            if (id.Length == 0 || library.Find("slovo:" + id) != null) continue;
            offer.Add(new Offer(Library.Bible, id, (string?)item["name"] ?? id));
        }
        foreach (var item in (answer["songbooks"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
        {
            if ((string?)item["format"] != "vbm") continue;
            var file = (string?)item["file"] ?? "";
            if (file.Length == 0 || library.Find("songs:" + file) != null) continue;
            offer.Add(new Offer(Library.Songs, file, (string?)item["name"] ?? file));
        }
        return offer;
    }

    public static async Task TakeFromSlovo(Api api, Library library, Offer item)
    {
        if (item.Kind == Library.Bible)
        {
            var bytes = await api.Bytes("/api/library/bible?id=" + Uri.EscapeDataString(item.Key));
            ModuleReaders.ReadSlovoBible(library, bytes);
        }
        else
        {
            var bytes = await api.Bytes("/api/library/songbook?file=" + Uri.EscapeDataString(item.Key));
            ModuleReaders.ImportVbm(library, bytes, item.Key, "slovo", "");
        }
    }

    // MARK: З GitHub

    /// Каталог модулів «Цитати з Біблії» — лише переклади Біблії.
    public static async Task<List<Offer>> FromGitHub(Library library)
    {
        var ini = await Web.GetStringAsync(GitHub + "modules.ini");
        var offer = new List<Offer>();
        string? id = null;
        foreach (var raw in ini.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                id = line[1..^1];
            }
            else if (id != null && line.StartsWith("ModuleName=", StringComparison.Ordinal))
            {
                if (id.StartsWith("Bible_", StringComparison.Ordinal) && library.Find("gh:" + id) == null)
                    offer.Add(new Offer(Library.Bible, id, line["ModuleName=".Length..].Trim()));
                id = null;
            }
        }
        return offer.OrderBy(o => o.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    public static async Task TakeFromGitHub(Library library, Offer item)
    {
        var zip = Path.Combine(Paths.Modules, item.Key + ".zip");
        try
        {
            var bytes = await Web.GetByteArrayAsync(GitHub + "modules/" + Uri.EscapeDataString(item.Key) + ".zip");
            await File.WriteAllBytesAsync(zip, bytes);
            ModuleReaders.ImportBibleQuoteZip(library, zip, "gh:" + item.Key, "github");
        }
        catch
        {
            try { File.Delete(zip); } catch { /* нема що прибирати */ }
            throw;
        }
    }

    // MARK: З файла

    public static bool IsModuleFile(string path)
    {
        var lower = path.ToLowerInvariant();
        return lower.EndsWith(".zip") || lower.EndsWith(".sqlite3") || lower.EndsWith(".vbm") || lower.EndsWith(".songbook");
    }

    /// zip «Цитати з Біблії», MyBible .SQLite3, пісенник .vbm чи .songbook.
    /// Файл копіюється в бібліотеку: на служінні його можна відвезти в «Слово».
    public static string ImportFile(Library library, string source)
    {
        var name = Path.GetFileName(source);
        if (!IsModuleFile(name))
            throw new RefusedException(Lang.T(
                "Це не модуль: потрібен .zip («Цитата з Біблії»), .SQLite3 (MyBible), .vbm чи .songbook (пісенник)",
                "Not a module: a .zip (Bible Quote), .SQLite3 (MyBible), .vbm or .songbook (songbook) is needed"));
        var kept = Path.Combine(Paths.Modules, name);
        if (!Path.GetFullPath(source).Equals(Path.GetFullPath(kept), StringComparison.OrdinalIgnoreCase))
            File.Copy(source, kept, true);
        try
        {
            var lower = name.ToLowerInvariant();
            if (lower.EndsWith(".zip")) return ModuleReaders.ImportBibleQuoteZip(library, kept, "file:" + name, "file");
            if (lower.EndsWith(".sqlite3")) return ModuleReaders.ImportMyBible(library, kept, "file:" + name, "file");
            if (lower.EndsWith(".songbook")) return ModuleReaders.ImportSongbookJson(library, File.ReadAllBytes(kept), name, "file", kept);
            return ModuleReaders.ImportVbm(library, File.ReadAllBytes(kept), name, "file", kept);
        }
        catch
        {
            try { File.Delete(kept); } catch { /* нема що прибирати */ }
            throw;
        }
    }
}

public sealed record UploadResult(int Added, List<string> Notes);

public static class Uploader
{
    /// Везе план у «Слово»: файли плану, переклади й пісенники, яких у програмі
    /// нема, — і сам план, який стає головним. `status` — рядок стану для людини.
    public static async Task<UploadResult> Upload(Api api, Library library, SermonPlan plan, Action<string> status)
    {
        status(Lang.T("Надсилаю план у «Слово»…", "Sending the plan to Slovo…"));
        var answer = await api.Get("/api/library");
        var bibleIds = new HashSet<string>();
        var bibleByName = new Dictionary<string, string>();
        foreach (var item in (answer["bibles"] as JsonArray ?? new JsonArray()).OfType<JsonObject>())
        {
            var id = (string?)item["id"] ?? "";
            bibleIds.Add(id);
            bibleByName.TryAdd(((string?)item["name"] ?? "").ToLowerInvariant(), id);
        }
        // Пісенник упізнається за основою імені: «Слово» називає його «….vbm»,
        // а з файла чи ресурсів він приходить «….songbook» — той самий.
        var songFiles = new HashSet<string>((answer["songbooks"] as JsonArray ?? new JsonArray())
            .OfType<JsonObject>().Select(i => Stem((string?)i["file"] ?? "")));

        var resolved = new Dictionary<string, string>();
        var notes = new List<string>();
        var items = new JsonArray();
        foreach (var item in plan.Items.ToList())
        {
            var json = new JsonObject { ["type"] = item.Type, ["title"] = item.Title };
            switch (item.Type)
            {
                case PlanItem.Scripture:
                    json["module"] = await ResolveBible(api, library, item, bibleIds, bibleByName, resolved, status);
                    json["moduleName"] = item.ModuleName;
                    json["canon"] = item.Canon;
                    json["bookName"] = item.BookName;
                    json["chapter"] = item.Chapter;
                    json["verses"] = new JsonArray(item.Verses.Select(v => (JsonNode)v).ToArray());
                    json["text"] = item.Body;
                    break;
                case PlanItem.Song:
                    await EnsureSongbook(api, library, item, songFiles, status);
                    json["songBook"] = item.SongBook;
                    json["song"] = item.SongIndex;
                    json["parts"] = new JsonArray(item.Parts.Select(p => (JsonNode)new JsonObject { ["kind"] = p.Kind, ["text"] = p.Text }).ToArray());
                    break;
                case PlanItem.Text:
                    json["heading"] = item.Heading;
                    json["body"] = item.Announcement;
                    break;
                default:
                    if (!File.Exists(item.Path))
                    {
                        notes.Add(Lang.F("Файл «{0}» пропав — пункт пропущено", "The file “{0}” is gone — item skipped", item.Name));
                        continue;
                    }
                    status(Lang.F("Надсилаю файл «{0}»…", "Sending the file “{0}”…", item.Name));
                    json["file"] = await api.StoreFile(item.Name, await File.ReadAllBytesAsync(item.Path));
                    break;
            }
            items.Add(json);
        }
        status(Lang.T("Надсилаю план у «Слово»…", "Sending the plan to Slovo…"));
        var result = await api.SermonPlan(new JsonObject { ["title"] = plan.Title.Trim(), ["items"] = items });
        var added = (int?)result["added"] ?? 0;
        foreach (var note in (result["notes"] as JsonArray ?? new JsonArray())) notes.Add((string?)note ?? "");
        Paths.Say($"план «{plan.Title}» у «Слово»: пунктів {added}" + (notes.Count == 0 ? "" : "; " + string.Join("; ", notes)));
        return new UploadResult(added, notes);
    }

    /// Переклад пункту так, як його знає програма: той самий зі «Слова», той самий
    /// за назвою або щойно поставлений із файла, який привіз «Проповідник».
    static async Task<string> ResolveBible(Api api, Library library, PlanItem item, HashSet<string> ids,
                                           Dictionary<string, string> byName, Dictionary<string, string> resolved,
                                           Action<string> status)
    {
        if (resolved.TryGetValue(item.Module, out var known)) return known;
        string? found = null;
        if (item.Module.StartsWith("slovo:", StringComparison.Ordinal) && ids.Contains(item.Module[6..])) found = item.Module[6..];
        if (found == null && byName.TryGetValue(item.ModuleName.ToLowerInvariant(), out var named)) found = named;
        if (found == null)
        {
            var module = library.Find(item.Module);
            if (module != null && module.Original.Length > 0 && File.Exists(module.Original))
            {
                status(Lang.F("Ставлю в «Слово» «{0}»…", "Installing “{0}” in Slovo…", module.Name));
                var answer = await api.ImportModule(Path.GetFileName(module.Original), await File.ReadAllBytesAsync(module.Original));
                if (answer["modules"] is JsonArray modules && modules.Count > 0) found = (string?)modules[0];
            }
        }
        found ??= "";
        resolved[item.Module] = found;
        return found;
    }

    /// Пісенника в програмі нема — довезти файл, з якого він прийшов у бібліотеку.
    static string Stem(string file) => Path.GetFileNameWithoutExtension(file).ToLowerInvariant();

    static async Task EnsureSongbook(Api api, Library library, PlanItem item, HashSet<string> files, Action<string> status)
    {
        if (files.Contains(Stem(item.SongBook))) return;
        var module = library.Find(item.Module);
        if (module == null || module.Original.Length == 0 || !File.Exists(module.Original)) return;
        status(Lang.F("Ставлю в «Слово» «{0}»…", "Installing “{0}” in Slovo…", module.Name));
        await api.ImportModule(item.SongBook, await File.ReadAllBytesAsync(module.Original));
        files.Add(Stem(item.SongBook));
    }
}
