// =============================================================================
//  Cli.cs — самоперевірка без вікна: --selftest
// =============================================================================
//  Проганяє те, що робить людина, — без миші, щоб перевіряти на чистій
//  Windows: бібліотека з файлів і з GitHub, план із усіх видів пунктів,
//  збереження й читання плану, пошук «Слова» в мережі і (коли «Слово» знайдено
//  або вказано --host) завантаження плану й повернення плану служіння.
//  Дані — у тимчасовій теці: справжня бібліотека людини не чіпається.
//
//      Propovidnyk.exe --selftest [--module файл]… [--host адреса] [--port 8103] [--pin 1234] [--no-github]
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Propovidnyk;

public static class Cli
{
    static int _failed;

    static void Report(bool ok, string name, string detail)
    {
        if (!ok) _failed++;
        Console.WriteLine($"{(ok ? "  ок      " : "  ПОМИЛКА")} {name}: {detail}");
    }

    static string? Arg(string[] args, string name)
    {
        var at = Array.IndexOf(args, name);
        return at >= 0 && at + 1 < args.Length ? args[at + 1] : null;
    }

    /// Керування показом — ті самі шляхи, якими ходить робоче місце вікна:
    /// вкладки, Біблія, Пісні, Презентація, Медіа, Зображення, Екран, Текст,
    /// План, Історія і кнопки залу. Наприкінці все вертається, як було.
    static async Task ControlChecks(Api api)
    {
        JsonObject state;
        try { state = await api.State(0, CancellationToken.None); }
        catch (Exception error) { Report(false, "Стан програми", Api.Describe(error)); return; }
        var wasMode = (string?)state["mode"] ?? "bible";

        // Вкладки: перемикаються всі сім.
        var switched = new List<string>();
        foreach (var mode in new[] { "bible", "songs", "presentation", "media", "pictures", "screen", "text" })
        {
            try
            {
                await api.Command("mode", mode);
                var now = await api.State(0, CancellationToken.None);
                if ((string?)now["mode"] == mode) switched.Add(mode);
            }
            catch (Exception error) { Report(false, "Вкладка " + mode, Api.Describe(error)); }
        }
        Report(switched.Count == 7, "Вкладки програми перемикаються", "перемкнулося " + switched.Count + " із 7: " + string.Join(", ", switched));

        // Біблія: переклади, книги, розділ, вибір віршів у передпоказ і в зал.
        try
        {
            var books = await api.Get("/api/bible/books");
            var list = (books["books"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
            var translations = (books["translations"] as JsonArray ?? new JsonArray()).Count;
            var john = list.FirstOrDefault(b => ((string?)b["name"] ?? "").StartsWith("Иоан") || ((string?)b["name"] ?? "").StartsWith("Ів")) ?? list.FirstOrDefault();
            var position = (int?)john?["position"] ?? 0;
            var chapter = await api.Get($"/api/bible/chapter?book={position}&chapter=3");
            var verses = (chapter["verses"] as JsonArray ?? new JsonArray()).Count;
            await api.BibleSelect(position, 3, new[] { 16, 17, 19 }, false);
            var preview = await api.State(0, CancellationToken.None);
            var reference = (string?)(preview["preview"] as JsonObject)?["reference"] ?? "";
            await api.BibleSelect(position, 3, new[] { 16 }, true);
            var live = await api.State(0, CancellationToken.None);
            var hall = (string?)(live["slide"] as JsonObject)?["reference"] ?? "";
            // Адреса розрізнених віршів: «3:16-17,19», а не «3:16,17,19».
            var addressOK = reference.Contains("16-17,19");
            Report(list.Count > 60 && verses > 20 && reference.Length > 0 && hall.Length > 0 && addressOK, "Біблія: книги, розділ, вибір віршів",
                   $"перекладів {translations}, книг {list.Count}, віршів у розділі {verses}; передпоказ «{reference}»; у залі «{hall}»" +
                   (addressOK ? "" : "; АДРЕСА РОЗРІЗНЕНИХ ВІРШІВ НЕ ПРОМІЖКАМИ"));
        }
        catch (Exception error) { Report(false, "Біблія: книги, розділ, вибір віршів", Api.Describe(error)); }

        // Пошук за словами.
        try
        {
            await api.Command("bible-search", "любов");
            JsonObject search = new();
            for (var i = 0; i < 20; i++)
            {
                await Task.Delay(500);
                search = await api.Get("/api/search");
                if ((bool?)search["searching"] != true && (search["hits"] as JsonArray)?.Count > 0) break;
            }
            var hits = (search["hits"] as JsonArray)?.Count ?? 0;
            if (hits > 0) await api.Command("search-hit", new JsonObject { ["index"] = 0, ["live"] = false }, 15);
            Report(hits > 0, "Біблія: пошук за словами", hits > 0 ? $"знайдено {hits}, перший пункт — у передпоказі" : "нічого не знайшлося");
        }
        catch (Exception error) { Report(false, "Біблія: пошук за словами", Api.Describe(error)); }

        // Пісні: пісенники, список, пісня в передпоказ, частина в зал.
        try
        {
            var books = await api.Get("/api/songs/books");
            var songbooks = (books["books"] as JsonArray ?? new JsonArray()).Count;
            var list = await api.Get("/api/songs/list");
            var songs = (list["songs"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
            var index = (int?)songs.FirstOrDefault()?["index"] ?? 0;
            await api.Command("song", index);
            await Task.Delay(400);
            var afterSong = await api.State(0, CancellationToken.None);
            var song = afterSong["song"] as JsonObject;
            var parts = (song?["parts"] as JsonArray ?? new JsonArray()).Count;
            if (parts > 0) await api.Command("part", 0);
            await Task.Delay(400);
            var afterPart = await api.State(0, CancellationToken.None);
            var hall = (string?)(afterPart["slide"] as JsonObject)?["text"] ?? "";
            Report(songbooks > 0 && songs.Count > 0 && parts > 0 && hall.Length > 0, "Пісні: пісенник, пісня, частина в зал",
                   $"пісенників {songbooks}, пісень {songs.Count}, частин у пісні «{(string?)song?["title"]}» {parts}; у залі {(hall.Length > 0 ? "текст частини" : "порожньо")}");
        }
        catch (Exception error) { Report(false, "Пісні: пісенник, пісня, частина в зал", Api.Describe(error)); }

        // Презентація: колоди, сторінки, картинка сторінки.
        try
        {
            await api.Command("mode", "presentation");
            var now = await api.State(0, CancellationToken.None);
            var show = now["presentation"] as JsonObject;
            var decks = (show?["decks"] as JsonArray ?? new JsonArray()).Count;
            var pages = (show?["pages"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
            byte[]? image = null;
            if (pages.Count > 0)
            {
                var index = (int?)pages[0]["index"] ?? 0;
                await api.Command("page", index);
                image = await api.PageImage(index, 480);
            }
            Report(decks == 0 || (pages.Count > 0 && image != null && image.Length > 2000), "Презентація: колоди, сторінки, картинка",
                   decks == 0 ? "колод у програмі немає — пропущено"
                              : $"колод {decks}, сторінок {pages.Count}, картинка сторінки {(image?.Length ?? 0) / 1024} КБ");
        }
        catch (Exception error) { Report(false, "Презентація: колоди, сторінки, картинка", Api.Describe(error)); }

        // Зображення.
        try
        {
            var pictures = await api.Get("/api/pictures");
            var pages = (pictures["pages"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
            byte[]? image = null;
            if (pages.Count > 0)
            {
                var index = (int?)pages[0]["index"] ?? 0;
                await api.Command("picture", index);
                image = await api.PageImage(index, 480, "pictures");
            }
            Report(pages.Count == 0 || (image != null && image.Length > 2000), "Зображення: список і показ",
                   pages.Count == 0 ? "картинок у програмі немає — пропущено" : $"картинок {pages.Count}, мініатюра {(image?.Length ?? 0) / 1024} КБ");
        }
        catch (Exception error) { Report(false, "Зображення: список і показ", Api.Describe(error)); }

        // Медіа: список, гучність, звук.
        try
        {
            var media = await api.Get("/api/media");
            var playlist = (media["playlist"] as JsonArray ?? new JsonArray()).Count;
            var wasVolume = (double?)media["volume"] ?? 0.8;
            await api.Command("media-volume", new JsonObject { ["x"] = 0.35 }, 15);
            await Task.Delay(300);
            var after = await api.Get("/api/media");
            var volume = (double?)after["volume"] ?? 0;
            await api.Command("media-volume", new JsonObject { ["x"] = wasVolume }, 15);
            Report(Math.Abs(volume - 0.35) < 0.02, "Медіа: список і гучність", $"у списку {playlist}; гучність {wasVolume:0.00} → {volume:0.00} → назад");
        }
        catch (Exception error) { Report(false, "Медіа: список і гучність", Api.Describe(error)); }

        // Екран: список джерел.
        try
        {
            var screen = await api.Get("/api/screen");
            var sources = (screen["sources"] as JsonArray ?? new JsonArray()).Count;
            var permission = (bool?)screen["permission"] ?? false;
            Report(true, "Екран: джерела захоплення", $"джерел {sources}; дозвіл на запис екрана: {(permission ? "є" : "немає")}");
        }
        catch (Exception error) { Report(false, "Екран: джерела захоплення", Api.Describe(error)); }

        // Текст: оголошення з цього комп'ютера — у передпоказ і в зал.
        try
        {
            var wasText = await api.Get("/api/text");
            await api.Command("text-set", new JsonObject { ["title"] = "Перевірка", ["text"] = "Оголошення з «Проповідника»." }, 15);
            await api.Command("text-show");
            await Task.Delay(500);
            var now = await api.State(0, CancellationToken.None);
            var hall = (string?)(now["slide"] as JsonObject)?["text"] ?? "";
            await api.Command("text-set", new JsonObject { ["title"] = (string?)wasText["title"] ?? "", ["text"] = (string?)wasText["body"] ?? "" }, 15);
            Report(hall.Contains("Проповідник"), "Текст: оголошення в зал", hall.Length > 0 ? "у залі: " + hall.Split('\n')[0] : "у залі порожньо");
        }
        catch (Exception error) { Report(false, "Текст: оголошення в зал", Api.Describe(error)); }

        // План та Історія: додати вибране, пересунути, прибрати; Історія.
        try
        {
            var before = ((await api.State(0, CancellationToken.None))["plan"] as JsonArray)?.Count ?? 0;
            await api.Command("plan-add");
            await Task.Delay(400);
            var added = ((await api.State(0, CancellationToken.None))["plan"] as JsonArray)?.Count ?? 0;
            if (added > 1) await api.Command("plan-move", new JsonObject { ["index"] = added - 1, ["delta"] = -1 }, 15);
            await api.Command("plan-remove", added > before ? added - 1 : 0);
            await Task.Delay(400);
            var after = ((await api.State(0, CancellationToken.None))["plan"] as JsonArray)?.Count ?? 0;
            var history = await api.Get("/api/history");
            var records = (history["records"] as JsonArray)?.Count ?? 0;
            Report(added == before + 1 && after == before, "План та Історія: додати, пересунути, прибрати",
                   $"у Плані було {before}, стало {added}, після прибирання {after}; в Історії записів {records}");
        }
        catch (Exception error) { Report(false, "План та Історія: додати, пересунути, прибрати", Api.Describe(error)); }

        // Кнопки залу.
        try
        {
            await api.Command("black");
            await Task.Delay(300);
            var black = (bool?)(await api.State(0, CancellationToken.None))["black"] ?? false;
            await api.Command("black");
            await api.Command("hide");
            await Task.Delay(300);
            var hidden = !((bool?)(await api.State(0, CancellationToken.None))["live"] ?? true);
            await api.Command("next");
            await api.Command("prev");
            Report(black && hidden, "Кнопки залу: чорний екран, сховати, гортання",
                   $"чорний екран: {(black ? "так" : "НІ")}; сховати: {(hidden ? "так" : "НІ")}; «Далі» й «Назад» без помилки");
        }
        catch (Exception error) { Report(false, "Кнопки залу: чорний екран, сховати, гортання", Api.Describe(error)); }

        // Указка й наближення — те, що робить миша по картинці залу.
        try
        {
            await api.Command("pointer", new JsonObject { ["x"] = 0.4, ["y"] = 0.6, ["colour"] = "#FFD400", ["size"] = 0.05, ["opacity"] = 0.85 }, 10);
            await Task.Delay(300);
            var on = await api.State(0, CancellationToken.None);
            var pointer = on["pointer"] as JsonObject;
            var lit = (bool?)pointer?["on"] ?? false;
            await api.Command("pointer-off");
            await api.Command("zoom", new JsonObject { ["zoom"] = 2, ["x"] = 0.5, ["y"] = 0.5 }, 10);
            await Task.Delay(300);
            var zoomed = (double?)((await api.State(0, CancellationToken.None))["zoom"] as JsonObject)?["zoom"] ?? 1;
            await api.Command("zoom", new JsonObject { ["zoom"] = 1, ["x"] = 0.5, ["y"] = 0.5 }, 10);
            Report(lit && zoomed > 1.5, "Указка й наближення",
                   $"указка: {(lit ? "горить" : "НЕ горить")}; наближення {zoomed:0.0}× і назад");
        }
        catch (Exception error) { Report(false, "Указка й наближення", Api.Describe(error)); }

        // Картинка залу — те, що вікно показує замість проектора.
        try
        {
            await api.Command("mode", "bible");
            var image = await api.HallImage(640);
            Report(image == null || image.Length > 1000, "Зал картинкою", image == null ? "у залі відео чи порожньо" : $"{image.Length / 1024} КБ");
        }
        catch (Exception error) { Report(false, "Зал картинкою", Api.Describe(error)); }

        try { await api.Command("mode", wasMode); } catch { /* вернути вкладку — не критично */ }
    }

    public static async Task<int> Run(string[] args)
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        if (args.Contains("--help"))
        {
            Console.WriteLine("Propovidnyk.exe — «Проповідник Слова»\n" +
                              "  (без прапорців)   вікно плану проповіді\n" +
                              "  --selftest        перевірка без вікна: [--module файл]… [--host адреса] [--port 8103] [--pin PIN] [--no-github] [--keep]\n" +
                              "  --help            ця довідка");
            return 0;
        }
        Lang.Choice = "uk";
        // --keep: справжня тека даних — бібліотека, план і підключення лишаються
        // для вікна (так готується показ програми на чистій Windows).
        var keep = args.Contains("--keep");
        var temp = Path.Combine(Path.GetTempPath(), "propovidnyk-selftest-" + Environment.ProcessId);
        if (!keep) Paths.Override = temp;
        Console.WriteLine($"Самоперевірка «Проповідника Слова» — {DateTime.Now:yyyy-MM-dd HH:mm:ss}, дані: {temp}");
        try
        {
            using var library = new Library();
            var bibles = new List<string>();
            var songbooks = new List<string>();

            // 1. Модулі з файлів.
            for (var i = 0; i < args.Length - 1; i++)
            {
                if (args[i] != "--module") continue;
                var file = args[i + 1];
                try
                {
                    var id = Sources.ImportFile(library, file);
                    var module = library.Find(id)!;
                    var count = module.Kind == Library.Bible ? library.Count("verses", id) : library.Count("songs", id);
                    (module.Kind == Library.Bible ? bibles : songbooks).Add(id);
                    Report(count > 0, "Модуль з файла " + Path.GetFileName(file),
                           $"«{module.Name}», {(module.Kind == Library.Bible ? "віршів" : "пісень")} {count}");
                }
                catch (Exception error)
                {
                    Report(false, "Модуль з файла " + Path.GetFileName(file), error.Message);
                }
            }

            // 2. Пошук «Слова» в мережі — і переклад із пісенником зі «Слова».
            var host = Arg(args, "--host");
            var port = int.TryParse(Arg(args, "--port"), out var p) ? p : 8103;
            var pin = Arg(args, "--pin") ?? "";
            var found = await Discovery.Search();
            Report(found.Count > 0 || host != null, "Пошук «Слова» в мережі",
                   found.Count == 0 ? "ніхто не відповів на розсилку" : string.Join(", ", found.Select(f => $"{f.Name} {f.Host}:{f.Port}")));
            if (host == null && found.Count > 0) { host = found[0].Host; port = found[0].Port; }
            if (keep && host != null)
            {
                var settings = Settings.Load();
                settings.Host = host;
                settings.Port = port;
                settings.Pin = pin;
                settings.Name = found.FirstOrDefault()?.Name ?? settings.Name;
                settings.Save();
            }
            if (host != null)
            {
                try
                {
                    var api = new Api(host, port, pin);
                    var offer = await Sources.FromSlovo(api, library);
                    var bible = offer.FirstOrDefault(o => o.Kind == Library.Bible && o.Name.Contains("Синодал")) ?? offer.First(o => o.Kind == Library.Bible);
                    var songbook = offer.FirstOrDefault(o => o.Kind == Library.Songs && o.Key.StartsWith("englishworship")) ?? offer.First(o => o.Kind == Library.Songs);
                    await Sources.TakeFromSlovo(api, library, bible);
                    await Sources.TakeFromSlovo(api, library, songbook);
                    var bibleId = "slovo:" + bible.Key;
                    var songsId = "songs:" + songbook.Key;
                    bibles.Add(bibleId);
                    songbooks.Add(songsId);
                    Report(library.Count("verses", bibleId) > 20000 && library.Count("songs", songsId) > 10, "Переклад і пісенник зі «Слова»",
                           $"у «Слові» пропонується {offer.Count}; «{bible.Name}»: віршів {library.Count("verses", bibleId)}; «{songbook.Name}»: пісень {library.Count("songs", songsId)}");
                }
                catch (Exception error)
                {
                    Report(false, "Переклад і пісенник зі «Слова»", Api.Describe(error));
                }
            }

            // 3. Переклад з GitHub (найменший із Bible_*).
            if (!args.Contains("--no-github"))
            {
                try
                {
                    var offer = await Sources.FromGitHub(library);
                    var pick = offer.FirstOrDefault(o => o.Key.Contains("RST", StringComparison.OrdinalIgnoreCase)) ?? offer.First();
                    await Sources.TakeFromGitHub(library, pick);
                    var id = "gh:" + pick.Key;
                    bibles.Add(id);
                    var books = library.Books(id);
                    Report(library.Count("verses", id) > 20000, "Переклад з GitHub",
                           $"у каталозі {offer.Count}; узято «{pick.Name}»: книг {books.Count}, віршів {library.Count("verses", id)}, " +
                           $"перша книга «{books.FirstOrDefault()?.Name}» (канон {books.FirstOrDefault()?.Canon})");
                }
                catch (Exception error)
                {
                    Report(false, "Переклад з GitHub", error.Message);
                }
            }

            // 4. План з усіх видів пунктів — зберегти й прочитати.
            var plan = new SermonPlan { Title = (keep ? "Неділя, " : "Перевірка ") + DateTime.Now.ToString("dd.MM HH:mm") };
            if (bibles.Count > 0)
            {
                var bible = library.Find(bibles[^1])!;
                var book = library.Books(bible.Id).FirstOrDefault(b => b.Canon == 500) ?? library.Books(bible.Id).First();
                var chapter = library.Chapters(bible.Id, book.Index).Contains(3) ? 3 : library.Chapters(bible.Id, book.Index).First();
                var verses = library.Verses(bible.Id, book.Index, chapter).Where(v => v.Number is >= 16 and <= 17).ToList();
                if (verses.Count == 0) verses = library.Verses(bible.Id, book.Index, chapter).Take(2).ToList();
                var shortName = book.ShortName.Length == 0 ? book.Name : book.ShortName.Split(' ')[0];
                plan.Items.Add(new PlanItem
                {
                    Type = PlanItem.Scripture, Module = bible.Id, ModuleName = bible.Name, BookName = book.Name,
                    Canon = book.Canon, Book = book.Index, Chapter = chapter, Verses = verses.Select(v => v.Number).ToList(),
                    Body = string.Join(" ", verses.Select(v => v.Text)),
                    Title = shortName + " " + chapter + ":" + SermonPlan.Span(verses.Select(v => v.Number).ToList()),
                });
            }
            if (songbooks.Count > 0)
            {
                var songbook = library.Find(songbooks[0])!;
                var song = library.SongsOf(songbook.Id, "").First();
                plan.Items.Add(new PlanItem
                {
                    Type = PlanItem.Song, Module = songbook.Id, SongBook = songbook.Id[6..], SongIndex = song.Index, Title = song.Title,
                    Parts = library.Parts(songbook.Id, song.Index).Select(p => (p.Kind, p.Text)).ToList(),
                });
            }
            plan.Items.Add(new PlanItem { Type = PlanItem.Text, Heading = "Оголошення", Announcement = "Перевірка «Проповідника Слова».", Title = "Оголошення" });
            var picture = Path.Combine(Paths.PlanFiles, Guid.NewGuid() + "-перевірка.png");
            await File.WriteAllBytesAsync(picture, Convert.FromBase64String(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="));
            plan.Items.Add(new PlanItem { Type = PlanItem.File, Path = picture, Name = "перевірка.png", Title = "перевірка.png" });
            plan.Save();
            var again = SermonPlan.Load(plan.Id, true);
            var same = again != null && again.Items.Count == plan.Items.Count
                       && again.Items.Select(i => i.ToJson().ToJsonString()).SequenceEqual(plan.Items.Select(i => i.ToJson().ToJsonString()));
            Report(same, "План зберігається й читається", string.Join(" · ", plan.Items.Select(i => i.Icon + " " + i.Title)));

            if (keep)
            {
                var settings = Settings.Load();
                settings.LastPlan = plan.Id;
                settings.Save();
            }

            // 4а. Керування показом: усе, що вміє робоче місце.
            if (host != null) await ControlChecks(new Api(host, port, pin));

            // 5. Завантаження плану в «Слово» і повернення плану служіння.
            if (host != null && !keep)
            {
                var api = new Api(host, port, pin);
                try
                {
                    var steps = new List<string>();
                    var result = await Uploader.Upload(api, library, plan, s => steps.Add(s));
                    var state = await api.State(0, CancellationToken.None);
                    var sermon = state["sermon"] as JsonObject;
                    var on = (bool?)sermon?["on"] ?? false;
                    var planRows = (state["plan"] as JsonArray)?.Count ?? 0;
                    Report(result.Added == plan.Items.Count && on && planRows == plan.Items.Count, "План проповіді в «Слові»",
                           $"додано {result.Added} з {plan.Items.Count}; у стані програми: план проповіді {(on ? "увімкнено" : "НЕ увімкнено")} «{(string?)sermon?["title"]}», пунктів {planRows}" +
                           (result.Notes.Count == 0 ? "" : "; примітки: " + string.Join("; ", result.Notes)) + "; кроки: " + string.Join(" → ", steps.Distinct()));
                    await api.Command("plan", 0);
                    await Task.Delay(700);
                    var hall = await api.HallImage(320);
                    Report(hall != null && hall.Length > 1000, "Перший пункт — у залі", hall == null ? "картинки залу немає" : $"картинка залу {hall.Length / 1024} КБ");
                    await api.Command("sermon-end");
                    var after = await api.State(0, CancellationToken.None);
                    var off = !((bool?)(after["sermon"] as JsonObject)?["on"] ?? false);
                    Report(off, "Повернути план служіння", off ? "план служіння повернуто" : "план проповіді лишився головним");
                }
                catch (Exception error)
                {
                    Report(false, "План проповіді в «Слові»", Api.Describe(error));
                }
            }
        }
        catch (Exception error)
        {
            Report(false, "Самоперевірка", error.ToString());
        }
        finally
        {
            Paths.Override = null;
            if (!keep)
            {
                try { Directory.Delete(temp, true); } catch { /* тимчасова тека */ }
            }
        }
        Console.WriteLine(_failed == 0 ? "Усе пройшло." : $"Помилок: {_failed}.");
        return _failed == 0 ? 0 : 1;
    }
}
