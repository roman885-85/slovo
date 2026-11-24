// =============================================================================
//  RemoteControlServer.Sermon.cs — бібліотека й план проповіді (як +Sermon на Mac)
// =============================================================================
//  Планшет «Проповідник» бере переклади й пісенники програми, складає план і
//  шле його сюди: план служіння відкладається, план проповіді стає першим.
//  Чого в програмі немає (переклад, пісенник), пункт стає текстом, а планшет
//  отримує пояснення.
// =============================================================================

using System.Text;
using System.Text.Json.Nodes;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed partial class RemoteControlServer
{
    bool LibraryGet(HttpRequest request, AppState state, HttpConnection connection)
    {
        switch (request.Path)
        {
            case "/api/library": Respond(connection, 200, LibraryJson(state)); return true;
            case "/api/library/bible": SendBible(request.Q("id"), state, connection); return true;
            case "/api/library/songbook": SendSongBook(request.Q("file"), state, connection); return true;
            default: return false;
        }
    }

    static JsonObject LibraryJson(AppState state) => new()
    {
        ["bibles"] = new JsonArray(state.AllModules.Select(m => (JsonNode)new JsonObject
        {
            ["id"] = m.Identifier, ["name"] = m.DisplayName, ["short"] = m.Info.ShortName, ["books"] = m.Books.Count,
        }).ToArray()),
        // Свій .songbook планшет не читає — йому збірник іде як .vbm, зібраний на льоту.
        ["songbooks"] = new JsonArray((state.SongLibrary?.Books ?? (IReadOnlyList<SongLibrary.Entry>)Array.Empty<SongLibrary.Entry>()).Select(entry =>
        {
            var own = SongBookJSON.IsSongBookFile(entry.Url);
            return (JsonNode)new JsonObject
            {
                ["file"] = own ? entry.Id + ".vbm" : Path.GetFileName(entry.Url), ["name"] = entry.DisplayName,
                ["format"] = own ? "vbm" : Path.GetExtension(entry.Url).TrimStart('.').ToLowerInvariant(), ["songs"] = entry.SongCount ?? -1,
            };
        }).ToArray()),
    };

    static string Field(string text) => text.Replace("\t", " ").Replace("\r", " ").Replace("\n", " ");

    /// Переклад цілком рядками SLOVO-BIBLE 1 — збираємо у фоні.
    static void SendBible(string id, AppState state, HttpConnection connection)
    {
        if (state.Module(id) is not { } module) { Fail(connection, 404, Captions.T("нет такого перевода")); return; }
        var name = module.DisplayName;
        var isPrimary = string.Equals(module.Identifier, state.PrimaryModuleID, StringComparison.OrdinalIgnoreCase);
        Journal.Say($"пульт: переклад «{name}» на планшет");
        Task.Run(() =>
        {
            var output = new StringBuilder("SLOVO-BIBLE 1\n");
            output.Append($"M\t{Field(module.Identifier)}\t{Field(name)}\t{Field(module.Info.ShortName)}\n");
            foreach (var book in module.Books)
            {
                output.Append($"B\t{book.Index}\t{book.CanonicalNumber?.ToString() ?? ""}\t{Field(book.FullName)}\t{Field(string.Join(" ", book.ShortNames))}\t{book.ChapterCount}\n");
                IReadOnlyList<Chapter> chapters;
                try { chapters = module.Chapters(book); } catch { chapters = Array.Empty<Chapter>(); }
                foreach (var chapter in chapters)
                    foreach (var verse in chapter.Verses)
                        output.Append($"V\t{chapter.Number}\t{verse.Number}\t{Field(verse.Text)}\n");
            }
            // Чужий переклад тримати в пам'яті заради одного завантаження нема чого.
            if (!isPrimary) module.ReleaseCache();
            var data = Encoding.UTF8.GetBytes(output.ToString());
            Dispatcher.UIThread.Post(() => RespondData(connection, 200, data, "text/plain; charset=utf-8"));
        });
    }

    static void SendSongBook(string file, AppState state, HttpConnection connection)
    {
        if (state.SongLibrary is not { } library || library.EntryForFileName(file) is not { } entry)
        {
            Fail(connection, 404, Captions.T("нет такого песенника"));
            return;
        }
        byte[]? data = null;
        try
        {
            // Свій формат — у .vbm на льоту: планшет розбирає лише його.
            data = SongBookJSON.IsSongBookFile(entry.Url)
                ? library.Book(entry.Id) is { } book ? SongBookWriter.Data(book) : null
                : File.ReadAllBytes(entry.Url);
        }
        catch { data = null; }
        if (data == null) { Fail(connection, 404, Captions.T("нет такого песенника")); return; }
        Journal.Say($"пульт: пісенник «{entry.DisplayName}» на планшет");
        RespondData(connection, 200, data, "application/octet-stream");
    }

    // --- Файли плану -----------------------------------------------------------------------

    static (JsonObject? Result, string? Refusal) StoreUpload(string name, byte[] body, AppState state)
    {
        var path = Path.Combine(UploadsFolder, name);
        var ext = Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
        var known = ShowModel.Extensions(ShowModel.Kind.Presentation).Contains(ext) || ShowModel.Extensions(ShowModel.Kind.Pictures).Contains(ext)
                    || MediaExtensions.Contains(ext);
        if (!known) return (null, Captions.T("такой файл не открывают ни показ, ни плеер: .%s", ext));
        try
        {
            Directory.CreateDirectory(UploadsFolder);
            File.WriteAllBytes(path, body);
        }
        catch (Exception error) { return (null, error.Message); }
        Journal.Say($"пульт: файл плану «{name}» ({body.Length} байт)");
        return (new JsonObject { ["file"] = name }, null);
    }

    /// Що відкриває плеєр (фільтр медіа на Mac) — для файлів плану проповіді.
    static readonly string[] MediaExtensions =
        { "mp4", "m4v", "mov", "avi", "mkv", "wmv", "webm", "mpg", "mpeg", "mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff", "aif" };

    // --- План проповіді --------------------------------------------------------------------

    JsonObject AcceptSermonPlan(JsonObject body, AppState state)
    {
        var raw = body["items"] as JsonArray ?? new JsonArray();
        var notes = new List<string>();
        var items = raw.OfType<JsonObject>().Select(entry => SermonItem(entry, state, notes)).OfType<PlanItem>().ToList();
        var title = (Text(body["title"]) ?? "").Trim();
        state.BeginSermon(items, title);
        Journal.Say($"пульт: план проповіді «{title}» — {items.Count} пунктів із {raw.Count}");
        return new JsonObject { ["added"] = items.Count, ["first"] = 0, ["notes"] = new JsonArray(notes.Select(n => (JsonNode)n).ToArray()) };
    }

    /// План — коли бібліотека дочитана (не довше 30 с).
    static void WhenLibraryReady(AppState state, int waited, Action body)
    {
        if (!state.IsLoadingLibrary || waited >= 60) { body(); return; }
        DispatcherTimer.RunOnce(() => WhenLibraryReady(state, waited + 1, body), TimeSpan.FromSeconds(0.5));
    }

    static PlanItem? SermonItem(JsonObject entry, AppState state, List<string> notes)
    {
        string S(string key) => Text(entry[key]) ?? "";
        int? N(string key) => Int(entry[key]);
        var title = S("title").Trim();
        switch (S("type"))
        {
            case "scripture":
            {
                var chapter = N("chapter") ?? 1;
                var verses = (entry["verses"] as JsonArray ?? new JsonArray()).Select(Int).OfType<int>().ToList();
                var module = SermonModule(S("module"), S("moduleName"), state);
                if (module != null && SermonBook(N("canon"), S("bookName"), module) is { } book)
                    return PlanItem.ScriptureItem(module.Identifier, book, chapter, verses, S("text"));
                notes.Add(Captions.T("«%s»: такой книги нет в переводах программы — пункт стал текстом", title));
                return PlanItem.TextItem(new PlainTextDocument(title, S("text")));
            }
            case "song":
            {
                var file = S("songBook");
                var index = N("song") ?? -1;
                // Пісенник упізнається за основою імені: планшет називає його «….vbm».
                var stem = Path.GetFileNameWithoutExtension(file).ToLowerInvariant();
                if (state.SongLibrary is { } library
                    && library.Books.FirstOrDefault(e => string.Equals(Path.GetFileName(e.Url), file, StringComparison.OrdinalIgnoreCase)
                                                         || Path.GetFileNameWithoutExtension(e.Url).ToLowerInvariant() == stem) is { Id: not null } found
                    && library.Book(found.Id) is { } book && index >= 0 && index < book.Songs.Count
                    && (title.Length == 0 || book.Songs[index].Title == title))
                    return PlanItem.SongItem(Path.GetFileName(found.Url), book.Songs[index]);
                // Такого пісенника немає (чи пісня в ньому інша) — слова привіз планшет, їх і показуємо.
                var parts = entry["parts"] as JsonArray ?? new JsonArray();
                var lyrics = string.Join("\n\n", parts.OfType<JsonObject>().Select(p => Text(p["text"])).OfType<string>());
                notes.Add(Captions.T("«%s»: песенника нет в программе — песня стала текстом", title));
                return PlanItem.TextItem(new PlainTextDocument(title, lyrics));
            }
            case "text":
            {
                var heading = S("heading");
                var text = S("body");
                if (heading.Length == 0 && text.Length == 0) return null;
                return PlanItem.TextItem(new PlainTextDocument(heading, text));
            }
            case "file":
            {
                // Лише ім'я: шлях будуємо самі, щоб пункт не вказав за межі теки пульта.
                var name = Path.GetFileName(S("file").Replace('\\', '/').Split('/').Last());
                var path = Path.Combine(UploadsFolder, name);
                if (name.Length == 0 || name == ".." || !File.Exists(path))
                {
                    notes.Add(Captions.T("«%s»: файл не дошёл до программы", title.Length == 0 ? name : title));
                    return null;
                }
                return PlanItem.FileItem(path, title);
            }
            default:
                return null;
        }
    }

    static TextModule? SermonModule(string id, string name, AppState state)
    {
        if (state.Module(id) is { } exact) return exact;
        var wanted = name.Trim();
        if (wanted.Length > 0 && state.AllModules.FirstOrDefault(m => string.Equals(m.DisplayName, wanted, StringComparison.OrdinalIgnoreCase)
                                                                     || string.Equals(m.Info.Name, wanted, StringComparison.OrdinalIgnoreCase)) is { } named)
            return named;
        return state.PrimaryModule;
    }

    static BookInfo? SermonBook(int? canon, string name, TextModule module)
    {
        if (canon is { } number && module.Books.FirstOrDefault(b => b.CanonicalNumber == number) is { } book) return book;
        var wanted = name.Trim();
        return wanted.Length == 0 ? null : module.Books.FirstOrDefault(b => string.Equals(b.FullName, wanted, StringComparison.OrdinalIgnoreCase));
    }

    // --- Модуль із планшета ------------------------------------------------------------------

    /// Модуль із планшета: прийняти файл і поставити модулі й пісенники (без шаблонів і фонів).
    void ImportModule(HttpRequest request, AppState state, HttpConnection connection)
    {
        var name = Path.GetFileName(request.Q("name").Replace('\\', '/').Split('/').Last()).Replace(":", "-").Trim();
        if (name.Length == 0 || name == ".." || request.Body.Length == 0) { Fail(connection, 400, Captions.T("нет имени файла (name=)")); return; }
        var folder = Path.Combine(UploadsFolder, "Модулі", Guid.NewGuid().ToString());
        var file = Path.Combine(folder, name);
        try
        {
            Directory.CreateDirectory(folder);
            File.WriteAllBytes(file, request.Body);
        }
        catch (Exception error) { Fail(connection, 400, error.Message); return; }
        Journal.Say($"пульт: модуль із планшета «{name}» ({request.Body.Length} байт)");
        ModuleImport.Run(file, state, (imported, modules, failures, failure) =>
        {
            try { Directory.Delete(folder, true); } catch { /* тимчасова тека */ }
            if (failure != null) { Fail(connection, 400, failure); return; }
            Journal.Say($"пульт: імпорт «{name}» — {modules.Count} модулів, помилок {failures.Count}");
            Respond(connection, 200, new JsonObject
            {
                ["modules"] = new JsonArray(imported.Select(p => (JsonNode)Path.GetFileName(p.TrimEnd('/', '\\'))).ToArray()),
                ["imported"] = new JsonArray(modules.Select(m => (JsonNode)m).ToArray()),
                ["failures"] = new JsonArray(failures.Select(f => (JsonNode)f).ToArray()),
            });
        });
    }
}

/// Імпорт модулів у фоні (планшет, вікно «Імпорт»): підключається разом із ядром імпорту.
public static class ModuleImport
{
    /// (шляхи поставлених модулів, назви, помилки, причина відмови) — у головному потоці.
    public static Action<string, AppState, Action<IReadOnlyList<string>, IReadOnlyList<string>, IReadOnlyList<string>, string?>> Run =
        (file, state, done) => done(Array.Empty<string>(), Array.Empty<string>(), Array.Empty<string>(), Captions.T("этой функции в Windows-версии ещё нет"));
}
