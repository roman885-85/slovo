// =============================================================================
//  WebSlideSeeder.cs — заготовки для Біблії й пісень готовими сторінками
//  (з Views/WebEditor/WebSlideSeeder.swift)
// =============================================================================
//  Власник просив «10 шаблонів для Біблії і 10 для пісень» і чекав їх у списку
//  веб-слайдів, а не в діалозі «Нова із заготовки». Тому при вмиканні веб-слайдів
//  недостатні сторінки створюються файлами в теці своїх сторінок і потрапляють у
//  список «Web слайди». Посів одноразовий: видалена власником сторінка не
//  вертається — імена посіяних заготовок пам'ятає файл `.seeded-templates` поруч
//  (той самий, що пише Mac: теку можна переносити між системами).
// =============================================================================

using System.Text;
using Slovo.Core;

namespace Slovo.App;

public static class WebSlideSeeder
{
    public static readonly IReadOnlyList<string> Prefixes = ["bible-", "song-"];

    static string MarkerFile => Path.Combine(WebOutputServer.UserPagesFolder, ".seeded-templates");

    /// Повертає число створених сторінок.
    public static int Seed(SettingsStore store)
    {
        var folder = WebOutputServer.UserPagesFolder;
        try { Directory.CreateDirectory(folder); } catch { }
        // Мітка: ім'я заготовки і відбиток того, що ми записали. Файл на диску
        // все ще наш (відбиток збігся), а заготовка змінилася — переписуємо;
        // правлену власником сторінку не чіпаємо.
        var recorded = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            if (File.Exists(MarkerFile))
                foreach (var line in File.ReadAllText(MarkerFile, Encoding.UTF8).Split('\n', StringSplitOptions.RemoveEmptyEntries))
                {
                    var parts = line.Split(' ', 2);
                    if (parts[0].Length > 0) recorded[parts[0]] = parts.Length > 1 ? parts[1] : "";
                }
        }
        catch { }
        var seeded = new HashSet<string>(recorded.Keys, StringComparer.Ordinal);
        var created = 0;
        var entries = store.Settings.WebSlides.ToList();
        foreach (var template in WebSlideTemplates.All)
        {
            if (!Prefixes.Any(prefix => template.Id.StartsWith(prefix, StringComparison.Ordinal))) continue;
            var fileName = template.Id + ".html";
            var file = Path.Combine(folder, fileName);
            var fresh = template.Html;
            var freshHash = Hash(fresh);
            if (!seeded.Contains(template.Id) && !File.Exists(file))
            {
                if (!Write(file, fresh)) continue;
                created++;
            }
            else if (File.Exists(file) && Read(file) is { } onDisk)
            {
                // Каркас сторінки оновлюємо завжди, а налаштування власника переносимо в
                // нього як є: заготовка міняється разом із програмою, а його правки — його.
                if (Hash(onDisk) != freshHash && WebSlideParameters.MarkerRange(WebSlideParameters.VarsMarkers, onDisk) != null)
                {
                    var updated = WebSlideParameters.CarryOverSettings(onDisk, fresh);
                    if (updated != onDisk) Write(file, updated);
                }
            }
            recorded[template.Id] = freshHash;
            seeded.Add(template.Id);
            if (File.Exists(file))
            {
                var entry = new WebSlideEntry(OurWords.T(template.Title), fileName, OurWords.T(template.Purpose));
                var at = entries.FindIndex(item => string.Equals(item.FileName, fileName, StringComparison.OrdinalIgnoreCase));
                // Підпис у списку теж оновлюємо: він розповідає, що сторінка робить.
                if (at >= 0) { if (entries[at].Details != entry.Details) entries[at] = entry; }
                else entries.Add(entry);
            }
            // Своя сторінка накладання — теж у списку.
            if (!entries.Any(item => string.Equals(item.FileName, "slovo-slide-overlay.html", StringComparison.OrdinalIgnoreCase)))
                entries.Add(new WebSlideEntry(OurWords.T("Слайд поверх видео"), "slovo-slide-overlay.html",
                                              OurWords.T("Слайд поверх видео: без фона, только текст")));
        }
        Write(MarkerFile, string.Join("\n", seeded.OrderBy(id => id, StringComparer.Ordinal)
                                                  .Select(id => $"{id} {(recorded.TryGetValue(id, out var hash) ? hash : "")}")));
        if (!entries.SequenceEqual(store.Settings.WebSlides))
        {
            store.Settings.WebSlides = entries;
            if (!store.IsEditing) store.Save();
        }
        return created;
    }

    static bool Write(string file, string text)
    {
        try { SwiftPath.WriteAtomically(file, new UTF8Encoding(false).GetBytes(text)); return true; }
        catch (Exception error) { Journal.Say($"веб-слайди: {Path.GetFileName(file)} не записався — {error.Message}"); return false; }
    }

    static string? Read(string file)
    {
        try { return new UTF8Encoding(false, true).GetString(File.ReadAllBytes(file)); } catch { return null; }
    }

    /// Відбиток тексту: короткий, стійкий, без криптографії (той самий, що на Mac).
    static string Hash(string text)
    {
        var hash = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(text)) hash = unchecked((hash ^ b) * 0x100000001b3UL);
        return hash.ToString("x");
    }

    /// Скільки посіяних сторінок лежить на місці — для перевірки.
    public static int PresentCount() =>
        WebSlideTemplates.All.Count(template => Prefixes.Any(prefix => template.Id.StartsWith(prefix, StringComparison.Ordinal))
                                                && File.Exists(Path.Combine(WebOutputServer.UserPagesFolder, template.Id + ".html")));
}
