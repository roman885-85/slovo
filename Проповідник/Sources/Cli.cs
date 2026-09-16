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
