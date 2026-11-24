// =============================================================================
//  Resources.cs — звідки беруться переклади, пісенники, фони й шаблони
// =============================================================================
//  Джерела — як у «Слова» на Mac (ResourceCatalog.swift):
//   • каталог «Слова» — roman885-85/slovo-resources: catalog.json у гілці
//     main, файли — у релізі «files» (переклади, пісенники, фони, шаблони,
//     шрифти);
//   • модулі «Цитата з Біблії» — BibleQuote/BibleQuote-Modules: modules.ini
//     і modules/<ім'я>.zip;
//   • файл з диска — zip модуля, MyBible .SQLite3, .vbm, .songbook, .sch,
//     картинка; тека встановленого VisioBible — усе разом;
//   • «Слово» в мережі (Mac чи інший Windows) — /api/library.
//  Усе лягає в бібліотеку й у теки даних; що лягло — повертається списком.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Slovo;

public sealed record ResourceItem(string Id, string Kind, string Title, string Subtitle, long Size, string Version, string Url, string FileName, string Language);

public sealed class ImportResult
{
    public List<string> Modules { get; } = new();
    public List<string> Names { get; } = new();
    public List<string> Failures { get; } = new();
    public int Templates, Backgrounds, Fonts;

    public string Summary()
    {
        var parts = new List<string>();
        if (Modules.Count > 0) parts.Add(Lang.F("модулів: {0}", "modules: {0}", Modules.Count));
        if (Templates > 0) parts.Add(Lang.F("шаблонів: {0}", "templates: {0}", Templates));
        if (Backgrounds > 0) parts.Add(Lang.F("фонів: {0}", "backgrounds: {0}", Backgrounds));
        if (Fonts > 0) parts.Add(Lang.F("шрифтів: {0}", "fonts: {0}", Fonts));
        if (Failures.Count > 0) parts.Add(Lang.F("помилок: {0}", "failures: {0}", Failures.Count));
        return parts.Count == 0 ? Lang.T("нічого не знайшлося", "nothing was found") : string.Join(", ", parts);
    }
}

public static class ResourceStore
{
    public const string SlovoCatalogUrl = "https://raw.githubusercontent.com/roman885-85/slovo-resources/main/catalog.json";
    public const string BibleQuoteBase = "https://raw.githubusercontent.com/BibleQuote/BibleQuote-Modules/master/";
    static readonly HttpClient Web = new() { Timeout = TimeSpan.FromMinutes(5) };

    static ResourceStore() => Web.DefaultRequestHeaders.Add("User-Agent", "Slovo-Windows");

    // MARK: Каталоги

    public static async Task<List<ResourceItem>> SlovoCatalog(CancellationToken cancel = default)
    {
        var text = await Web.GetStringAsync(SlovoCatalogUrl, cancel);
        var json = JsonNode.Parse(text) as JsonObject ?? throw new RefusedException(Lang.T("Каталог не прочитався", "The catalog could not be read"));
        if ((string?)json["format"] != "slovo-resources") throw new RefusedException(Lang.T("Це не каталог «Слова»", "Not a Slovo catalog"));
        var items = new List<ResourceItem>();
        foreach (var node in json["items"] as JsonArray ?? new JsonArray())
        {
            if (node is not JsonObject item) continue;
            items.Add(new ResourceItem((string?)item["id"] ?? "", (string?)item["kind"] ?? "", (string?)item["title"] ?? "",
                                       (string?)item["subtitle"] ?? "", (long?)item["size"] ?? 0, (string?)item["version"] ?? "",
                                       (string?)item["url"] ?? "", (string?)item["fileName"] ?? "", (string?)item["language"] ?? ""));
        }
        return items;
    }

    /// Каталог модулів «Цитата з Біблії»: секції `[Bible_…]` з ModuleName і ModuleAuthor.
    public static async Task<List<ResourceItem>> BibleQuoteCatalog(CancellationToken cancel = default)
    {
        var text = await Web.GetStringAsync(BibleQuoteBase + "modules.ini", cancel);
        var items = new List<ResourceItem>();
        string? id = null; var name = ""; var author = "";
        void Flush()
        {
            if (id != null && id.StartsWith("Bible_", StringComparison.Ordinal))
                items.Add(new ResourceItem("bq:" + id, "bible", name.Length == 0 ? id : name, author, 0, "", BibleQuoteBase + "modules/" + Uri.EscapeDataString(id) + ".zip", id, ""));
            id = null;
        }
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim().Replace("﻿", "");
            if (line.StartsWith('[') && line.EndsWith(']')) { Flush(); id = line[1..^1]; name = ""; author = ""; }
            else if (line.StartsWith("ModuleName=")) name = line["ModuleName=".Length..].Trim();
            else if (line.StartsWith("ModuleAuthor=")) author = line["ModuleAuthor=".Length..].Trim();
        }
        Flush();
        return items;
    }

    // MARK: Установлення з каталогу

    /// Завантажити й поставити ресурс. Повертає, що лягло.
    public static async Task<ImportResult> Install(Library library, ResourceItem item, Action<string>? status = null, CancellationToken cancel = default)
    {
        var result = new ImportResult();
        var cacheFile = Path.Combine(Paths.Cache, "download-" + Guid.NewGuid().ToString("N") + ".zip");
        try
        {
            status?.Invoke(Lang.F("Завантаження «{0}»…", "Downloading “{0}”…", item.Title));
            await using (var input = await Web.GetStreamAsync(item.Url, cancel))
            await using (var output = File.Create(cacheFile))
                await input.CopyToAsync(output, cancel);
            status?.Invoke(Lang.F("Установлення «{0}»…", "Installing “{0}”…", item.Title));
            await Task.Run(() =>
            {
                switch (item.Kind)
                {
                    case "bible":
                    {
                        var kept = Path.Combine(Paths.Modules, (item.FileName.Length > 0 ? SafeName(item.FileName) : SafeName(item.Id)) + ".zip");
                        File.Copy(cacheFile, kept, true);
                        var id = ModuleReaders.ImportBibleQuoteZip(library, kept, (item.Id.StartsWith("bq:") ? "bq:" : "slovo:") + (item.FileName.Length > 0 ? item.FileName : item.Id), item.Id.StartsWith("bq:") ? "github" : "slovo");
                        result.Modules.Add(id);
                        result.Names.Add(library.Find(id)?.Name ?? id);
                        break;
                    }
                    case "songbook":
                        foreach (var entry in Unzip(cacheFile, Paths.Modules, flatten: true))
                            if (IsSongBookFile(entry)) { var id = ImportSongBookFile(library, entry, "slovo"); result.Modules.Add(id); result.Names.Add(library.Find(id)?.Name ?? id); }
                        break;
                    case "backgrounds":
                        result.Backgrounds += Unzip(cacheFile, Paths.Backgrounds, flatten: true, stripTop: "BackGrounds").Count(AppState.IsPictureFile);
                        break;
                    case "templates":
                        result.Templates += Unzip(cacheFile, Paths.Templates, flatten: false, stripTop: "Templates").Count(f => f.EndsWith(".sch", StringComparison.OrdinalIgnoreCase));
                        break;
                    case "fonts":
                        result.Fonts += Unzip(cacheFile, Paths.Fonts, flatten: true, stripTop: "Fonts").Count(f => f.EndsWith(".ttf", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".otf", StringComparison.OrdinalIgnoreCase));
                        Fonts.Rescan();
                        break;
                    default:
                        result.Failures.Add(Lang.F("«{0}»: такий ресурс Windows-версія не використовує", "“{0}”: the Windows edition does not use such a resource", item.Title));
                        break;
                }
            }, cancel);
        }
        catch (Exception error)
        {
            result.Failures.Add(item.Title + ": " + error.Message);
        }
        finally
        {
            try { File.Delete(cacheFile); } catch { /* тимчасовий файл */ }
        }
        return result;
    }

    // MARK: Файли з диска

    public static bool IsSongBookFile(string path) =>
        path.EndsWith(".vbm", StringComparison.OrdinalIgnoreCase) || path.EndsWith("." + SongBookWriter.Extension, StringComparison.OrdinalIgnoreCase);

    public static bool IsModuleFile(string path)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        return ext is ".zip" or ".sqlite3" or ".vbm" or ".songbook" or ".sch" or ".ini" || AppState.IsPictureFile(path);
    }

    /// Файл з диска: куди і як — за розширенням. Копія лягає в теку даних.
    public static ImportResult ImportFile(Library library, string path, string source = "file")
    {
        var result = new ImportResult();
        try
        {
            var ext = Path.GetExtension(path).ToLowerInvariant();
            var name = Path.GetFileName(path);
            if (ext == ".ini" && name.Equals("bibleqt.ini", StringComparison.OrdinalIgnoreCase))
            {
                ImportBibleQuoteDirectory(library, Path.GetDirectoryName(path)!, source, result);
            }
            else if (ext == ".zip")
            {
                using var archive = ZipFile.OpenRead(path);
                var names = archive.Entries.Select(e => e.FullName).ToList();
                if (names.Any(n => n.EndsWith("bibleqt.ini", StringComparison.OrdinalIgnoreCase)))
                {
                    var kept = Path.Combine(Paths.Modules, SafeName(Path.GetFileNameWithoutExtension(name)) + ".zip");
                    if (!string.Equals(Path.GetFullPath(kept), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase)) File.Copy(path, kept, true);
                    var id = ModuleReaders.ImportBibleQuoteZip(library, kept, "file:" + Path.GetFileNameWithoutExtension(name), source);
                    result.Modules.Add(id);
                    result.Names.Add(library.Find(id)?.Name ?? id);
                }
                else if (names.Any(n => n.EndsWith(".sch", StringComparison.OrdinalIgnoreCase)))
                    result.Templates += Unzip(path, Paths.Templates, flatten: false, stripTop: "Templates").Count(f => f.EndsWith(".sch", StringComparison.OrdinalIgnoreCase));
                else if (names.Any(IsSongBookFile))
                    foreach (var entry in Unzip(path, Paths.Modules, flatten: true).Where(IsSongBookFile))
                    { var id = ImportSongBookFile(library, entry, source); result.Modules.Add(id); result.Names.Add(library.Find(id)?.Name ?? id); }
                else if (names.Any(n => n.EndsWith(".sqlite3", StringComparison.OrdinalIgnoreCase)))
                    foreach (var entry in Unzip(path, Paths.Modules, flatten: true).Where(f => f.EndsWith(".sqlite3", StringComparison.OrdinalIgnoreCase)))
                    { var id = ModuleReaders.ImportMyBible(library, entry, "mybible:" + Path.GetFileNameWithoutExtension(entry), source); result.Modules.Add(id); result.Names.Add(library.Find(id)?.Name ?? id); }
                else if (names.Any(n => n.EndsWith(".ttf", StringComparison.OrdinalIgnoreCase) || n.EndsWith(".otf", StringComparison.OrdinalIgnoreCase)))
                {
                    result.Fonts += Unzip(path, Paths.Fonts, flatten: true, stripTop: "Fonts").Count(f => f.EndsWith(".ttf", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".otf", StringComparison.OrdinalIgnoreCase));
                    Fonts.Rescan();
                }
                else if (names.Any(AppState.IsPictureFile))
                    result.Backgrounds += Unzip(path, Paths.Backgrounds, flatten: true, stripTop: "BackGrounds").Count(AppState.IsPictureFile);
                else throw new RefusedException(Lang.T("В архіві немає ні модуля, ні пісенника, ні шаблонів, ні картинок", "The archive has no module, songbook, templates or pictures"));
            }
            else if (ext == ".sqlite3")
            {
                var kept = KeepCopy(path, Paths.Modules);
                var id = ModuleReaders.ImportMyBible(library, kept, "mybible:" + Path.GetFileNameWithoutExtension(name), source);
                result.Modules.Add(id);
                result.Names.Add(library.Find(id)?.Name ?? id);
            }
            else if (IsSongBookFile(path))
            {
                var kept = KeepCopy(path, Paths.Modules);
                var id = ImportSongBookFile(library, kept, source);
                result.Modules.Add(id);
                result.Names.Add(library.Find(id)?.Name ?? id);
            }
            else if (ext == ".sch")
            {
                // Шаблон — файл і тека з тим самим ім'ям поруч (картинки, thumbs).
                var stem = Path.GetFileNameWithoutExtension(name);
                File.Copy(path, Path.Combine(Paths.Templates, name), true);
                var folder = Path.Combine(Path.GetDirectoryName(path)!, stem);
                if (Directory.Exists(folder)) CopyDirectory(folder, Path.Combine(Paths.Templates, stem));
                result.Templates++;
            }
            else if (AppState.IsPictureFile(path))
            {
                KeepCopy(path, Paths.Backgrounds);
                result.Backgrounds++;
            }
            else throw new RefusedException(Lang.F("Файл «{0}» не впізнано: потрібен zip модуля, .SQLite3, .vbm, .songbook, .sch або картинка", "File “{0}” is not recognised: a module zip, .SQLite3, .vbm, .songbook, .sch or a picture is expected", name));
        }
        catch (Exception error)
        {
            result.Failures.Add(Path.GetFileName(path) + ": " + error.Message);
        }
        return result;
    }

    /// Тека: своя з модулями чи встановлений VisioBible (Modules, Templates, BackGrounds).
    public static ImportResult ImportFolder(Library library, string folder, string source = "folder", Action<string>? status = null)
    {
        var result = new ImportResult();
        try
        {
            if (File.Exists(Path.Combine(folder, "bibleqt.ini")) || Directory.GetFiles(folder).Any(f => Path.GetFileName(f).Equals("bibleqt.ini", StringComparison.OrdinalIgnoreCase)))
            {
                status?.Invoke(Path.GetFileName(folder));
                ImportBibleQuoteDirectory(library, folder, source, result);
                return result;
            }
            var modulesFolder = Directory.GetDirectories(folder).FirstOrDefault(d => Path.GetFileName(d).Equals("Modules", StringComparison.OrdinalIgnoreCase)) ?? folder;
            foreach (var sub in Directory.GetDirectories(modulesFolder).OrderBy(d => d, StringComparer.CurrentCultureIgnoreCase))
            {
                if (!Directory.GetFiles(sub).Any(f => Path.GetFileName(f).Equals("bibleqt.ini", StringComparison.OrdinalIgnoreCase))) continue;
                status?.Invoke(Path.GetFileName(sub));
                ImportBibleQuoteDirectory(library, sub, source, result);
            }
            foreach (var file in Directory.GetFiles(modulesFolder).Where(IsSongBookFile).OrderBy(f => f, StringComparer.CurrentCultureIgnoreCase))
            {
                status?.Invoke(Path.GetFileName(file));
                try
                {
                    var kept = KeepCopy(file, Paths.Modules);
                    var id = ImportSongBookFile(library, kept, source);
                    result.Modules.Add(id);
                    result.Names.Add(library.Find(id)?.Name ?? id);
                }
                catch (Exception error) { result.Failures.Add(Path.GetFileName(file) + ": " + error.Message); }
            }
            foreach (var file in Directory.GetFiles(modulesFolder).Where(f => f.EndsWith(".sqlite3", StringComparison.OrdinalIgnoreCase)))
            {
                try
                {
                    var kept = KeepCopy(file, Paths.Modules);
                    var id = ModuleReaders.ImportMyBible(library, kept, "mybible:" + Path.GetFileNameWithoutExtension(file), source);
                    result.Modules.Add(id);
                    result.Names.Add(library.Find(id)?.Name ?? id);
                }
                catch (Exception error) { result.Failures.Add(Path.GetFileName(file) + ": " + error.Message); }
            }
            var templates = Directory.GetDirectories(folder).FirstOrDefault(d => Path.GetFileName(d).Equals("Templates", StringComparison.OrdinalIgnoreCase));
            if (templates != null)
            {
                status?.Invoke("Templates");
                foreach (var sch in Directory.GetFiles(templates, "*.sch"))
                {
                    try
                    {
                        var stem = Path.GetFileNameWithoutExtension(sch);
                        File.Copy(sch, Path.Combine(Paths.Templates, Path.GetFileName(sch)), true);
                        var imagesFolder = Path.Combine(templates, stem);
                        if (Directory.Exists(imagesFolder)) CopyDirectory(imagesFolder, Path.Combine(Paths.Templates, stem));
                        result.Templates++;
                    }
                    catch (Exception error) { result.Failures.Add(Path.GetFileName(sch) + ": " + error.Message); }
                }
            }
            var backgrounds = Directory.GetDirectories(folder).FirstOrDefault(d => Path.GetFileName(d).Equals("BackGrounds", StringComparison.OrdinalIgnoreCase));
            if (backgrounds != null)
            {
                status?.Invoke("BackGrounds");
                foreach (var picture in Directory.GetFiles(backgrounds).Where(AppState.IsPictureFile))
                {
                    try { KeepCopy(picture, Paths.Backgrounds); result.Backgrounds++; }
                    catch (Exception error) { result.Failures.Add(Path.GetFileName(picture) + ": " + error.Message); }
                }
            }
            var fonts = Directory.GetDirectories(folder).FirstOrDefault(d => Path.GetFileName(d).Equals("Fonts", StringComparison.OrdinalIgnoreCase));
            if (fonts != null)
            {
                foreach (var font in Directory.GetFiles(fonts).Where(f => f.EndsWith(".ttf", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".otf", StringComparison.OrdinalIgnoreCase)))
                {
                    try { KeepCopy(font, Paths.Fonts); result.Fonts++; } catch { /* шрифт не скопіювався */ }
                }
                Fonts.Rescan();
            }
        }
        catch (Exception error)
        {
            result.Failures.Add(error.Message);
        }
        return result;
    }

    static void ImportBibleQuoteDirectory(Library library, string folder, string source, ImportResult result)
    {
        try
        {
            var stem = SafeName(Path.GetFileName(folder.TrimEnd(Path.DirectorySeparatorChar)));
            var kept = Path.Combine(Paths.Modules, stem);
            if (!string.Equals(Path.GetFullPath(kept), Path.GetFullPath(folder), StringComparison.OrdinalIgnoreCase)) CopyDirectory(folder, kept);
            var id = ModuleReaders.ImportBibleQuoteDirectory(library, kept, "file:" + stem, source);
            result.Modules.Add(id);
            result.Names.Add(library.Find(id)?.Name ?? id);
        }
        catch (Exception error)
        {
            result.Failures.Add(Path.GetFileName(folder) + ": " + error.Message);
        }
    }

    public static string ImportSongBookFile(Library library, string path, string source)
    {
        var bytes = File.ReadAllBytes(path);
        var name = Path.GetFileName(path);
        return path.EndsWith(".vbm", StringComparison.OrdinalIgnoreCase)
            ? ModuleReaders.ImportVbm(library, bytes, name, source, path)
            : ModuleReaders.ImportSongbookJson(library, bytes, name, source, path);
    }

    // MARK: «Слово» в мережі

    public sealed record SlovoOffer(string Kind, string Key, string Name, int Count);

    public static async Task<List<SlovoOffer>> FromSlovo(string host, int port, string pin, CancellationToken cancel = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"http://{host}:{port}/api/library");
        if (pin.Length > 0) request.Headers.Add("X-Slovo-Pin", pin);
        using var response = await Web.SendAsync(request, cancel);
        var text = await response.Content.ReadAsStringAsync(cancel);
        if (!response.IsSuccessStatusCode) throw new RefusedException(Lang.F("«Слово» відповіло {0}", "Slovo answered {0}", (int)response.StatusCode));
        var json = JsonNode.Parse(text) as JsonObject ?? new JsonObject();
        var offers = new List<SlovoOffer>();
        foreach (var node in json["bibles"] as JsonArray ?? new JsonArray())
            offers.Add(new SlovoOffer("bible", (string?)node?["id"] ?? "", (string?)node?["name"] ?? "", (int?)node?["books"] ?? 0));
        foreach (var node in json["songbooks"] as JsonArray ?? new JsonArray())
            offers.Add(new SlovoOffer("songbook", (string?)node?["file"] ?? "", (string?)node?["name"] ?? "", (int?)node?["songs"] ?? 0));
        return offers;
    }

    public static async Task<string> TakeFromSlovo(Library library, string host, int port, string pin, SlovoOffer offer, CancellationToken cancel = default)
    {
        var path = offer.Kind == "bible" ? "/api/library/bible?id=" + Uri.EscapeDataString(offer.Key) : "/api/library/songbook?file=" + Uri.EscapeDataString(offer.Key);
        using var request = new HttpRequestMessage(HttpMethod.Get, $"http://{host}:{port}{path}");
        if (pin.Length > 0) request.Headers.Add("X-Slovo-Pin", pin);
        using var response = await Web.SendAsync(request, cancel);
        if (!response.IsSuccessStatusCode) throw new RefusedException(Lang.F("«Слово» відповіло {0}", "Slovo answered {0}", (int)response.StatusCode));
        var bytes = await response.Content.ReadAsByteArrayAsync(cancel);
        if (offer.Kind == "bible") return await Task.Run(() => ModuleReaders.ReadSlovoBible(library, bytes), cancel);
        var file = Path.Combine(Paths.Modules, SafeName(offer.Key.Length > 0 ? offer.Key : offer.Name + ".vbm"));
        await File.WriteAllBytesAsync(file, bytes, cancel);
        return await Task.Run(() => ImportSongBookFile(library, file, "slovo"), cancel);
    }

    // MARK: Дрібниці

    public static string SafeName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new string(name.Select(c => invalid.Contains(c) ? '_' : c).ToArray()).Trim();
        return cleaned.Length == 0 ? "module" : cleaned;
    }

    static string KeepCopy(string path, string folder)
    {
        var target = Path.Combine(folder, Path.GetFileName(path));
        if (!string.Equals(Path.GetFullPath(target), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase)) File.Copy(path, target, true);
        return target;
    }

    static void CopyDirectory(string source, string target)
    {
        Directory.CreateDirectory(target);
        foreach (var file in Directory.GetFiles(source)) File.Copy(file, Path.Combine(target, Path.GetFileName(file)), true);
        foreach (var sub in Directory.GetDirectories(source)) CopyDirectory(sub, Path.Combine(target, Path.GetFileName(sub)));
    }

    /// Розпакувати архів у теку; шляхи поза текою пропускаються. Повертає файли, що лягли.
    static List<string> Unzip(string zip, string folder, bool flatten, string? stripTop = null)
    {
        var written = new List<string>();
        Directory.CreateDirectory(folder);
        var root = Path.GetFullPath(folder) + Path.DirectorySeparatorChar;
        using var archive = ZipFile.OpenRead(zip);
        foreach (var entry in archive.Entries)
        {
            if (entry.FullName.EndsWith('/') || entry.FullName.EndsWith('\\') || entry.Name.Length == 0) continue;
            var relative = entry.FullName.Replace('\\', '/');
            if (stripTop != null && relative.StartsWith(stripTop + "/", StringComparison.OrdinalIgnoreCase)) relative = relative[(stripTop.Length + 1)..];
            if (flatten) relative = Path.GetFileName(relative);
            if (relative.Length == 0 || relative.EndsWith("Thumbs.db", StringComparison.OrdinalIgnoreCase)) continue;
            var target = Path.GetFullPath(Path.Combine(folder, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            entry.ExtractToFile(target, true);
            written.Add(target);
        }
        return written;
    }
}
