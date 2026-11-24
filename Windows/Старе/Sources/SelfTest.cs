// =============================================================================
//  SelfTest.cs — самоперевірка без вікна: --selftest
// =============================================================================
//  Проганяє те, що робить людина, — без миші, щоб перевіряти на чистій
//  Windows: модулі (свій пробний або --module файл), пісенник туди й назад
//  (.songbook і .vbm), швидкий вибір, сторінки довгого тексту, слайди пісні,
//  шаблон .sch, малювання слайда, стан програми (вибір, показ, План,
//  Історія, пошук) і канал пульта по справжньому HTTP на своїх портах.
//  Дані — у тимчасовій теці: справжня бібліотека людини не чіпається.
//
//      Slovo.exe --selftest [--module файл]… [--keep] [--data тека] [--port 18103]
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Slovo;

public static class SelfTest
{
    static int _failed;
    static int _passed;

    static void Report(bool ok, string name, string detail)
    {
        if (ok) _passed++; else _failed++;
        Console.WriteLine($"{(ok ? "  ок      " : "  ПОМИЛКА")} {name}: {detail}");
    }

    static void Crash(string name, Exception error) => Report(false, name, error.GetType().Name + ": " + error.Message);

    public static async Task<int> Run(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        if (Array.IndexOf(args, "--help") >= 0)
        {
            Console.WriteLine("Slovo.exe [--data тека] [--selftest [--module файл]… [--keep] [--port 18103]]");
            return 0;
        }
        var keep = Array.IndexOf(args, "--keep") >= 0;
        var home = Paths.Override ?? (keep ? null : Path.Combine(Path.GetTempPath(), "slovo-selftest-" + Guid.NewGuid().ToString("N")));
        if (home != null) Paths.Override = home;
        var port = int.TryParse(Program.Arg(args, "--port"), out var p) ? p : 18103;
        var modules = new List<string>();
        for (var i = 0; i < args.Length - 1; i++) if (args[i] == "--module") modules.Add(args[i + 1]);
        Console.WriteLine("«Слово» для Windows " + Updates.Ours + " — самоперевірка. Тека даних: " + Paths.Home);
        var started = DateTime.Now;
        try
        {
            var settings = new Settings { RemoteEnabled = true, RemotePort = port, WebEnabled = true, WebPort = port + 2, WebNoPort = false, WebName = "slovo-test" };
            settings.Save();
            var library = new Library();
            CheckModules(library, modules);
            CheckSongBook(library);
            CheckParsing();
            CheckPagination();
            CheckScheme();
            CheckRenderer();
            library.Dispose();
            var state = new AppState(Settings.Load());
            CheckState(state);
            await CheckRemote(state, port);
            state.Shutdown();
        }
        catch (Exception error)
        {
            Crash("Самоперевірка", error);
        }
        Console.WriteLine($"Разом: {_passed} ок, {_failed} помилок, {(DateTime.Now - started).TotalSeconds:0.0} с");
        if (!keep && Paths.Override != null && Paths.Override.Contains("slovo-selftest-"))
        {
            try { Directory.Delete(Paths.Override, true); } catch { /* тимчасова тека */ }
        }
        return _failed == 0 ? 0 : 1;
    }

    // MARK: Модулі

    static void CheckModules(Library library, List<string> files)
    {
        try
        {
            var folder = Path.Combine(Paths.Cache, "probe-module");
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "bibleqt.ini"), ProbeIni, new UTF8Encoding(false));
            File.WriteAllText(Path.Combine(folder, "John.htm"), ProbeJohn, new UTF8Encoding(false));
            File.WriteAllText(Path.Combine(folder, "Gen.htm"), ProbeGenesis, new UTF8Encoding(false));
            var id = ModuleReaders.ImportBibleQuoteDirectory(library, folder, "probe", "selftest");
            var books = library.Books(id);
            var verses = library.Verses(id, 1, 3);
            var john316 = verses.FirstOrDefault(v => v.Number == 16)?.Text ?? "";
            Report(books.Count == 2 && verses.Count == 4 && john316.StartsWith("Бо так полюбив"), "Пробний модуль «Цитата з Біблії»",
                   $"книг {books.Count}, віршів у Ів 3 — {verses.Count}, Ів 3:16 «{Short(john316)}»");
            Report(books.Count == 2 && books[0].Canon == 10 && books[1].Canon == 500, "Наскрізні номери канону", books.Count == 2 ? $"Буття {books[0].Canon}, Івана {books[1].Canon}" : "книг " + books.Count);
        }
        catch (Exception error) { Crash("Пробний модуль", error); }

        foreach (var file in files)
        {
            try
            {
                var result = ResourceStore.ImportFile(library, file, "selftest");
                var id = result.Modules.FirstOrDefault();
                var count = id == null ? 0 : library.Count("verses", id) + library.Count("songs", id);
                Report(id != null && result.Failures.Count == 0, "Модуль із файла " + Path.GetFileName(file),
                       id == null ? string.Join("; ", result.Failures) : $"{library.Find(id)?.Name}: записів {count}");
            }
            catch (Exception error) { Crash("Модуль із файла " + Path.GetFileName(file), error); }
        }
    }

    static string Short(string text) => text.Length > 40 ? text[..40] + "…" : text;

    const string ProbeIni = """
        BibleName = Пробний переклад
        BibleShortName = ПРБ
        Bible = Y
        ChapterSign = <h4>
        VerseSign = <sup>
        DefaultEncoding = utf-8

        PathName = Gen.htm
        FullName = Буття
        ShortName = Бут Быт Gen
        ChapterQty = 2

        PathName = John.htm
        FullName = Від Івана
        ShortName = Ів Ин Jn
        ChapterQty = 3
        """;

    const string ProbeGenesis = """
        <html><body>
        <h4>Буття 1</h4>
        <sup>1</sup> На початку Бог створив Небо та землю.<br>
        <sup>2</sup> А земля була пуста та порожня.<br>
        <h4>Буття 2</h4>
        <sup>1</sup> І скінчив Бог небо та землю.<br>
        </body></html>
        """;

    const string ProbeJohn = """
        <html><body>
        <h4>Від Івана 1</h4>
        <sup>1</sup> Споконвіку було Слово, а Слово в Бога було, і Бог було Слово.<br>
        <h4>Від Івана 2</h4>
        <sup>1</sup> А третього дня весілля справляли в Кані Галілейській.<br>
        <h4>Від Івана 3</h4>
        <sup>1</sup> Був один чоловік із фарисеїв, Никодим на ім'я.<br>
        <sup>2</sup> Він до Нього прийшов уночі.<br>
        <sup>16</sup> Бо так полюбив Бог світ, що дав Сина Свого Однородженого, щоб кожен, хто вірує в Нього, не згинув, але мав життя вічне. Бо не послав Бог Сина Свого на світ, щоб світ засудити, але щоб через Нього світ спасся. Хто вірує в Нього, не буде засуджений; хто ж не вірує, засуджений уже, бо не повірив в Ім'я Однородженого Сина Божого.<br>
        <sup>17</sup> Бо Бог не послав Свого Сина на світ, щоб Він світ засудив.<br>
        </body></html>
        """;

    // MARK: Пісенник

    static void CheckSongBook(Library library)
    {
        try
        {
            var book = new SongBookData { Title = "Пробний пісенник", ShortName = "ПП", Publisher = "Самоперевірка" };
            var song = new SongData { Index = 0, Title = "Великий Бог", Author = "К. Боберг" };
            song.Parts.Add(new PartData { Index = 0, Kind = "Куплет 1", Text = "Великий Бог, коли на світ дивлюся,\nНа все, що Ти створив рукою Батька" });
            song.Parts.Add(new PartData { Index = 1, Kind = "Приспів", Text = "Тоді співає дух мій, Боже, Тобі:\nЯкий Ти великий, який Ти великий!", Align = 2 });
            book.Songs.Add(song);
            var second = new SongData { Index = 1, Title = "Ближче, Господь, до Тебе" };
            second.Parts.Add(new PartData { Index = 0, Kind = "Куплет 1", Text = "Ближче, Господь, до Тебе,\nближче до Тебе.\n\nХоч би й хрестом це було,\nщо мене підніме." });
            book.Songs.Add(second);
            var path = Path.Combine(Paths.Modules, "probe.songbook");
            SongBookWriter.WriteSongbook(book, path);
            var id = ResourceStore.ImportSongBookFile(library, path, "selftest");
            var back = library.SongBook(id);
            Report(back.Songs.Count == 2 && back.Songs[0].Parts.Count == 2 && back.Songs[0].Parts[1].Align == 2 && back.Songs[0].Author == "К. Боберг" && back.Publisher == "Самоперевірка",
                   "Пісенник .songbook туди й назад", $"пісень {back.Songs.Count}, частин у першій {back.Songs[0].Parts.Count}, автор «{back.Songs[0].Author}», вирівнювання приспіву {back.Songs[0].Parts[1].Align}");
            var vbm = SongBookWriter.Vbm(back);
            var reread = SongBookWriter.ReadVbm(vbm, "probe.vbm");
            Report(reread.Title == book.Title && reread.Songs.Count == 2 && reread.Songs[1].Parts[0].Text.Contains("\n\n"), "Пісенник .vbm (для планшета й VisioBible) туди й назад",
                   $"{vbm.Length} байт, «{reread.Title}», пісень {reread.Songs.Count}");
            var found = library.SongsOf(id, "ближче");
            var byWords = library.SongsWithWords(id, "хрестом підніме");
            Report(found.Count == 1 && found[0].Index == 1 && byWords.Count == 1, "Пошук пісні за назвою і за словами", $"за назвою {found.Count}, за словами {byWords.Count}");
            var composer = new SongComposer { Palette = SongPalette.Default() };
            var slides = composer.Slides(library.Parts(id, 1), 2, "Ближче");
            var palette = SongPalette.Default();
            Report(slides.Count == 2 && slides[0].Slide.Reference == "Куплет 1 · 1/2" && palette.ChunkFor("Приспів:")?.Key == "Chorus" && palette.ChunkFor("Куплет 1.")?.Key == "Verse",
                   "Слайди пісні: порожній рядок — межа, назва частини в адресі, кольори частин",
                   $"слайдів {slides.Count}, адреса «{(slides.Count > 0 ? slides[0].Slide.Reference : "")}», приспів → {palette.ChunkFor("Приспів:")?.Key}");
        }
        catch (Exception error) { Crash("Пісенник", error); }
    }

    // MARK: Розбір

    static void CheckParsing()
    {
        try
        {
            var books = new List<Book>
            {
                new(0, 10, "Буття", "Бут Быт Gen", 50), new(1, 20, "Вихід", "Вих Исх Ex", 40), new(2, 500, "Від Івана", "Ів Ин Jn", 21),
                new(3, 690, "1 Івана", "1Ів 1Ин 1Jn", 5), new(4, 230, "Псалми", "Пс Ps", 150),
            };
            var john = ReferenceParser.Resolve("Ин 3:16-18", books);
            var genesis = ReferenceParser.Resolve("Быт. 1:1-5", books);
            var mixed = ReferenceParser.Resolve("Ів 3:16,18", books);
            var first = ReferenceParser.Resolve("1Ів 1", books);
            var ambiguous = ReferenceParser.Resolve("В", books);
            Report(john is { Position: 2, Chapter: 3 } && john.Verses.SequenceEqual(new[] { 16, 17, 18 }) && genesis is { Position: 0 } && genesis.Verses.Count == 5
                   && mixed != null && mixed.Verses.SequenceEqual(new[] { 16, 18 }) && first is { Position: 3, Chapter: 1 } && ambiguous == null,
                   "Швидкий вибір: «Ин 3:16-18», «Быт. 1:1-5», «Ів 3:16,18», «1Ів 1», неоднозначне «В»",
                   $"Ів → {john?.DisplayText}, Бут → {genesis?.DisplayText}, мішанина → {mixed?.DisplayText}, 1Ів → {first?.DisplayText}, «В» → {(ambiguous == null ? "питання" : ambiguous.DisplayText)}");
            Report(ReferenceFormat.Position(3, new[] { 16, 17, 18, 20 }) == "3:16-18,20" && ReferenceFormat.FormatVerses(new[] { 7, 3 }) == "3,7",
                   "Адреса: проміжки «3:16-18,20»", ReferenceFormat.Position(3, new[] { 16, 17, 18, 20 }));
            Report(ShortBookNames.Index("ин", books) == 2 && ShortBookNames.Index("б", books) == 0, "Найкоротше скорочення книги (5.1.9)", $"«ин» → {ShortBookNames.Index("ин", books)}, «б» → {ShortBookNames.Index("б", books)}");
            var hotkey = Hotkey.Parse("Ctrl+Alt+B");
            var sets = HotkeySets.FactoryDefault();
            var preferred = sets.Hotkeys(sets.PreferredSetName ?? "");
            Report(hotkey is { Control: true, Alt: true, Key: "B" } && sets.Order.Count >= 1 && preferred.TryGetValue("ShowSlide", out var f5) && f5.Key == "F5" && preferred.TryGetValue("ShowBlackScreen", out var f12) && f12.Key == "F12",
                   "Гарячі клавіші з hotkeys.ini", $"наборів {sets.Order.Count}, останній «{sets.PreferredSetName}», «{hotkey}»");
        }
        catch (Exception error) { Crash("Розбір", error); }
    }

    // MARK: Сторінки

    static void CheckPagination()
    {
        try
        {
            var pagination = new Pagination { CharactersPerLine = 21, LinesPerPage = 6, MinimumFillPercent = 30 };
            var text = string.Join(" ", Enumerable.Repeat("Бо так полюбив Бог світ, що дав Сина Свого Однородженого,", 6));
            var pages = new TextDocument("Ів 3:16", text).Pages(pagination);
            var one = new TextDocument("", "Коротко.").Pages(pagination);
            var blocks = new TextDocument("Оголошення", "Перше.\n\nДруге.").Pages(pagination);
            var none = new TextDocument("Оголошення", "Перше.\n\nДруге.").Pages(new Pagination { SplitsIntoPages = false, CharactersPerLine = 21, LinesPerPage = 6 });
            Report(pages.Count >= 3 && one.Count == 1 && blocks.Count == 2 && none.Count == 1 && pages.All(p => p.Length > 0),
                   "Сторінки довгого тексту й межі за порожнім рядком", $"довгий текст — {pages.Count} сторінок, короткий — {one.Count}, два блоки — {blocks.Count}, без розбиття — {none.Count}");
            var capacity = Pagination.Capacity(800, 600, 0.11, 0.18, 0.06, 0.06);
            Report(capacity.CharactersPerLine == 21 && capacity.LinesPerPage == 6, "Місткість слайда за мінімального кегля (800×600, 11 %)", $"{capacity.CharactersPerLine} знаків × {capacity.LinesPerPage} рядків");
        }
        catch (Exception error) { Crash("Сторінки", error); }
    }

    // MARK: Шаблон .sch

    const string ProbeScheme = """
        <?xml version="1.0"?>
        <VisioBibleScheme>
          <Scheme Name="Пробний" BackImg="fon.jpg" QuoteOutLineEnable="true" QuoteOutLineWidth="2,25" QuoteOutLineColor="90377" QuoteShadowEnabled="true" QuoteShadowBlur="7" QuoteShadowOpacity="255">
            <FXPresetsList><FXPreset Name="Fx1"/></FXPresetsList>
            <Object Name="Цитата" Type="0" Width="94" Height="80" IndentionX="0" IndentionY="5" Align="2" TextColor="16249342" Layout="1">
              <FXPreset><Scene FX="3" Animation="true" FromOpacity="0" TimeLength="400"/><Scene FX="3" Animation="true" FromOpacity="0" TimeLength="400"/></FXPreset>
            </Object>
            <Object Name="Адреса" Type="1" Width="94" Height="10" IndentionX="3" IndentionY="2" Align="5" TextColor="16768994"/>
          </Scheme>
        </VisioBibleScheme>
        """;

    static void CheckScheme()
    {
        try
        {
            var scheme = SlideScheme.Parse(Encoding.UTF8.GetBytes(ProbeScheme), "fallback");
            var style = scheme.ApplyTo(SlideStyle.Default("Bible"), 600, false, null);
            var quote = scheme.ElementOf(SlideScheme.Quote)!;
            var box = quote.Placement(false).Box;
            Report(scheme.Name == "Пробний" && scheme.Elements.Count == 2 && Math.Abs(box.X - 0.03) < 0.001 && Math.Abs(box.Y - 0.05) < 0.001
                   && style.Main.Color == RGBA.FromTColor(16249342).Hex && style.Reference.Color == RGBA.FromTColor(16768994).Hex
                   && Math.Abs(style.Main.OutlineThickness - 2.25 / 600) < 1e-6 && style.Transition == "fade" && Math.Abs(style.TransitionDuration - 0.4) < 0.01,
                   "Шаблон .sch: XML, кома в числах, TColor, якір рамки, перехід", $"«{scheme.Name}», елементів {scheme.Elements.Count}, рамка x={box.X:0.###} y={box.Y:0.###}, колір {style.Main.Color}, контур {style.Main.OutlineThickness:0.####}, перехід {style.Transition} {style.TransitionDuration}с");
            var folder = Path.Combine(Paths.Templates, "Пробний");
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(Paths.Templates, "Пробний.sch"), ProbeScheme, new UTF8Encoding(false));
            using (var bg = SlideRenderer.Render(new RenderOrder { Style = new SlideStyle { BackgroundColor = "#204060" } }, 64, 36))
                File.WriteAllBytes(Path.Combine(folder, "fon.jpg"), SlideRenderer.Jpeg(bg, 0, 90));
            var library = TemplateLibrary.Scan(Paths.Templates);
            var template = library.Named("пробний");
            Report(template != null && template.BackgroundPath != null && library.Failures.Count == 0, "Тека шаблонів: файл .sch + тека з фоном", $"шаблонів {library.Templates.Count}, фон {(template?.BackgroundPath == null ? "не знайдено" : Path.GetFileName(template.BackgroundPath))}");
        }
        catch (Exception error) { Crash("Шаблон .sch", error); }
    }

    // MARK: Малювання

    static void CheckRenderer()
    {
        try
        {
            var style = SlideStyle.Default("Bible");
            style.BackgroundColor = "#102040";
            var order = new RenderOrder { Slide = new Slide("Бо так полюбив Бог світ, що дав Сина Свого Однородженого, щоб кожен, хто вірує в Нього, не згинув, але мав життя вічне.", new List<string>(), "Ів. 3:16", false), Style = style };
            using var bitmap = SlideRenderer.Render(order, 640, 360);
            var background = bitmap.GetPixel(5, 5);
            int light = 0, total = 0;
            for (var y = 40; y < 320; y += 4)
                for (var x = 40; x < 600; x += 4)
                {
                    total++;
                    var px = bitmap.GetPixel(x, y);
                    if (px.Red > 200 && px.Green > 200 && px.Blue > 200) light++;
                }
            var jpeg = SlideRenderer.Jpeg(bitmap, 320);
            Report(background.Blue > 50 && background.Red < 40 && light > total / 100 && jpeg.Length > 2000 && jpeg[0] == 0xFF && jpeg[1] == 0xD8,
                   "Малювання слайда: фон, білі літери, JPEG для пульта", $"фон {background}, світлих точок {light} із {total}, JPEG {jpeg.Length} байт");
            using var blank = SlideRenderer.Render(new RenderOrder { Slide = Slide.Blank, Style = style }, 64, 36);
            using var black = SlideRenderer.Render(new RenderOrder { Black = true, Style = style }, 64, 36);
            Report(blank.GetPixel(32, 18).Blue > 50 && black.GetPixel(32, 18).Blue == 0 && black.GetPixel(32, 18).Red == 0, "Порожній слайд — фон, затемнення — чорне", $"порожній {blank.GetPixel(32, 18)}, чорний {black.GetPixel(32, 18)}");
            var fonts = Fonts.Families();
            Report(fonts.Count > 0, "Шрифти системи для списку в параметрах", $"сімей {fonts.Count}, Arial → «{Fonts.Typeface("Arial", true, false).FamilyName}»");
        }
        catch (Exception error) { Crash("Малювання", error); }
    }

    // MARK: Стан програми

    static void CheckState(AppState state)
    {
        try
        {
            Report(state.Modules.Count >= 1 && state.PrimaryModule != null && state.Books.Count == 2, "Стан: переклади з бібліотеки ввімкнено, книги прочитано",
                   $"перекладів {state.Modules.Count}, основний «{state.PrimaryModule?.Name}», книг {state.Books.Count}");
            state.SelectBook(1);
            state.SelectChapter(3);
            state.SelectVerses(new[] { 16, 17 }, false);
            var preview = state.Slide;
            state.ShowCurrent();
            Report(preview.Reference == "Від Івана 3:16-17" && state.IsLive && state.LiveSlide.MainText.Contains("Бо так полюбив") && state.HallKind == "text",
                   "Вибір віршів → передпоказ → «Показати»", $"адреса «{preview.Reference}», у залі «{Short(state.LiveSlide.MainText)}», зал: {state.HallKind}");
            state.SelectVerses(new[] { 16 }, false);
            var pages = state.BiblePages.Count;
            state.Step(1, true);
            Report(pages >= 1 && state.LiveSlide.Reference is "Від Івана 3:16" or "Від Івана 3:17", "Довгий вірш по сторінках і «Далі» в зал", $"сторінок у Ів 3:16 — {pages}, після «Далі» в залі «{state.LiveSlide.Reference}»");
            state.Hide();
            Report(!state.IsLive && state.HallKind == "empty", "«Сховати» гасить зал до фону", "зал: " + state.HallKind);
            state.ToggleBlackScreen();
            var black = state.HallKind;
            state.ToggleBlackScreen();
            Report(black == "black" && state.HallKind == "empty", "Затемнення (F12) і назад", $"{black} → {state.HallKind}");
            Report(state.ApplyQuickInput("Бут 2:1", true) && state.LiveSlide.Reference == "Буття 2:1" && state.History.Records.Count >= 2 && state.History.Records[0].Reference == "Буття 2:1",
                   "Швидкий вибір «Бут 2:1» одразу в зал + Історія", $"у залі «{state.LiveSlide.Reference}», в Історії {state.History.Records.Count}, перша «{(state.History.Records.Count > 0 ? state.History.Records[0].Caption : "")}»");
            state.RunSearch("полюбив світ");
            var waited = 0;
            while (state.IsSearching && waited < 100) { Thread.Sleep(50); waited++; }
            Report(!state.IsSearching && state.Hits.Count == 1 && state.Hits[0].Verse == 16, "Пошук за словами «полюбив світ»", $"знайдено {state.Hits.Count}, перший {state.Hits.FirstOrDefault()?.Reference}");
            state.ShowHit(0, false);
            Report(state.Slide.Reference == "Від Івана 3:16", "Знайдене — у передпоказ", "передпоказ «" + state.Slide.Reference + "»");

            // Пісні
            state.Mode = "songs";
            Report(state.SongBooks.Count == 1 && state.SongList.Count == 2, "Пісенники й список пісень", $"пісенників {state.SongBooks.Count}, пісень {state.SongList.Count}");
            state.SelectSong(0, false);
            state.SelectPart(1, true);
            Report(state.LiveSlide.MainText.StartsWith("Тоді співає") && state.LiveSlide.Reference == "Приспів" && state.PartIndex == 1, "Пісня: частина в зал", $"у залі «{Short(state.LiveSlide.MainText)}», адреса «{state.LiveSlide.Reference}»");
            state.Step(-1, true);
            Report(state.LiveSlide.Reference == "Куплет 1", "«Назад» у пісні — попередня частина", "адреса «" + state.LiveSlide.Reference + "»");

            // Текст
            state.Mode = "text";
            state.SetText("Оголошення", "Після служіння — спілкування.\n\nУ середу — молитовне зібрання.");
            state.ShowText();
            Report(state.TextPages.Count == 2 && state.LiveSlide.Reference == "Оголошення" && state.LiveSlide.MainText.StartsWith("Після служіння"), "Текст: сторінки й показ", $"сторінок {state.TextPages.Count}, у залі «{Short(state.LiveSlide.MainText)}»");
            state.Step(1, true);
            Report(state.LiveSlide.MainText.StartsWith("У середу"), "«Далі» в тексті — друга сторінка", "у залі «" + Short(state.LiveSlide.MainText) + "»");

            // Зображення
            using (var picture = SlideRenderer.Render(new RenderOrder { Style = new SlideStyle { BackgroundColor = "#A02020" } }, 64, 36))
                File.WriteAllBytes(Path.Combine(Paths.Backgrounds, "probe.png"), SlideRenderer.Png(picture));
            state.ReloadPictures();
            var pictureAt = state.Pictures.FindIndex(p => p.EndsWith("probe.png"));
            if (pictureAt >= 0) state.ShowPicture(pictureAt);
            Report(pictureAt >= 0 && state.HallKind == "still" && state.LivePicture != null, "Зображення в зал", $"картинок {state.Pictures.Count}, зал: {state.HallKind}");
            var jpeg = state.HallJpeg(320);
            Report(jpeg.Length > 500 && jpeg[0] == 0xFF, "Картинка залу для пульта", jpeg.Length + " байт");

            // План
            state.Mode = "bible";
            state.ApplyQuickInput("Ів 3:16-17", false);
            state.AddCurrentToPlan();
            state.Mode = "songs";
            state.AddToPlan(state.PlanItemForWholeSong()!);
            state.Mode = "text";
            state.AddCurrentToPlan();
            var planPath = Path.Combine(Paths.Plans, "проба.json");
            state.SavePlanAs(planPath);
            var reloaded = ServicePlan.Load(planPath);
            Report(state.Plan.Items.Count == 3 && reloaded.Items.Count == 3 && reloaded.Items[0].Kind == PlanKind.Scripture && reloaded.Items[1].Kind == PlanKind.Song && reloaded.Items[1].PartIndex == null && reloaded.Items[2].Kind == PlanKind.Text,
                   "План: уривок, пісня цілком, текст — у файл slovo.plan і назад", $"пунктів {state.Plan.Items.Count}, з файла {reloaded.Items.Count}: {string.Join(", ", reloaded.Items.Select(i => i.Title))}");
            state.ActivatePlan(0, true);
            Report(state.Mode == "bible" && state.LiveSlide.Reference == "Від Івана 3:16-17", "Пункт плану (уривок) — у зал", "у залі «" + state.LiveSlide.Reference + "»");
            state.ActivatePlan(1, true);
            Report(state.Mode == "songs" && state.LiveSlide.Reference == "Куплет 1", "Пункт плану (пісня) — у зал, перша частина", "у залі «" + state.LiveSlide.Reference + "»");
            state.MovePlanItem(2, -1);
            state.RemovePlanItem(0);
            Report(state.Plan.Items.Count == 2 && state.Plan.Items[0].Kind == PlanKind.Text, "План: перестановка й видалення", string.Join(", ", state.Plan.Items.Select(i => i.KindTitle)));
            var aside = state.Plan.Title;
            state.BeginSermon(new List<PlanItem> { PlanItem.Text(new TextDocument("Проповідь", "Текст проповіді")) }, "План проповіді");
            var sermon = state.IsSermon && state.Plan.Items.Count == 1;
            state.EndSermon();
            Report(sermon && !state.IsSermon && state.Plan.Title == aside && state.Plan.Items.Count == 2, "План проповіді заступає план служіння й повертає його", $"проповідь: {sermon}, повернуто «{state.Plan.Title}» з {state.Plan.Items.Count} пунктами");
            Report(state.History.Records.Count > 0 && state.ActivateHistory(0, false), "Пункт Історії відкривається", state.History.Records.Count > 0 ? "перший: «" + state.History.Records[0].Caption + "»" : "Історія порожня");
        }
        catch (Exception error) { Crash("Стан програми", error); }
    }

    // MARK: Пульт

    static async Task CheckRemote(AppState state, int port)
    {
        try
        {
            state.StartServices();
            var pult = state.Pult!;
            Report(pult.IsRunning && pult.Port == port && pult.WebRunning, "Пульт: слухачі телефона й браузера піднялися", $"телефон {pult.Port} ({pult.Error ?? "ок"}), браузер {pult.WebPort} ({pult.WebError ?? "ок"}), ім'я {pult.MdnsName ?? "—"}");
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
            var baseUrl = "http://127.0.0.1:" + port;
            async Task<JsonObject> Get(string path) => JsonNode.Parse(await http.GetStringAsync(baseUrl + path)) as JsonObject ?? new JsonObject();
            async Task<JsonObject> Post(string command, JsonObject body)
            {
                using var response = await http.PostAsync(baseUrl + "/api/" + command, new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json"));
                var text = await response.Content.ReadAsStringAsync();
                var json = JsonNode.Parse(text) as JsonObject ?? new JsonObject();
                json["_status"] = (int)response.StatusCode;
                return json;
            }

            var stateJson = await Get("/api/state?since=0");
            Report((string?)stateJson["app"] == "Slovo" && stateJson["plan"] is JsonArray && stateJson["presentation"] is JsonObject && (int?)stateJson["seq"] >= 1,
                   "GET /api/state — стан як у «Слова»", $"seq {stateJson["seq"]}, mode {stateJson["mode"]}, plan {((JsonArray)stateJson["plan"]!).Count}, hall {stateJson["hall"]?["kind"]}");
            var books = await Get("/api/bible/books");
            var chapter = await Get("/api/bible/chapter?book=1&chapter=3");
            Report(((JsonArray)books["books"]!).Count == 2 && ((JsonArray)chapter["verses"]!).Count == 4 && (string?)chapter["name"] == "Від Івана", "GET /api/bible/books і /api/bible/chapter", $"книг {((JsonArray)books["books"]!).Count}, віршів {((JsonArray)chapter["verses"]!).Count}");
            var select = await Post("bible-select", new JsonObject { ["book"] = 1, ["chapter"] = 3, ["verses"] = new JsonArray(16, 17), ["live"] = true });
            var after = await Get("/api/state?since=0");
            Report((int)select["_status"]! == 200 && (string?)after["slide"]?["reference"] == "Від Івана 3:16-17" && (bool?)after["live"] == true, "POST bible-select live — у залі «Від Івана 3:16-17»", $"{after["slide"]?["reference"]}, live {after["live"]}");
            await Post("bible-select", new JsonObject { ["book"] = 1, ["chapter"] = 3, ["verses"] = new JsonArray(1), ["live"] = true });
            var before = await Get("/api/state?since=0");
            var seq = (int)before["seq"]!;
            var waiter = http.GetStringAsync(baseUrl + "/api/state?since=" + seq);
            await Task.Delay(300);
            var next = await Post("next", new JsonObject());
            var woken = JsonNode.Parse(await waiter) as JsonObject;
            Report((int)next["_status"]! == 200 && woken != null && (int)woken["seq"]! > seq && (string?)woken["slide"]?["reference"] == "Від Івана 3:2", "Довгий опит прокидається від команди «next» (вірш 1 → 2)", $"seq {seq} → {woken?["seq"]}, у залі «{woken?["slide"]?["reference"]}»");
            var hall = await http.GetByteArrayAsync(baseUrl + "/api/hall.jpg?w=480");
            Report(hall.Length > 1000 && hall[0] == 0xFF && hall[1] == 0xD8, "GET /api/hall.jpg", hall.Length + " байт");
            var library = await Get("/api/library");
            var bible = await http.GetStringAsync(baseUrl + "/api/library/bible?id=" + Uri.EscapeDataString(state.PrimaryModuleId));
            var songbookFile = (string?)((JsonArray)library["songbooks"]!)[0]?["file"] ?? "";
            var vbm = await http.GetByteArrayAsync(baseUrl + "/api/library/songbook?file=" + Uri.EscapeDataString(songbookFile));
            var reread = SongBookWriter.ReadVbm(vbm, songbookFile);
            Report(((JsonArray)library["bibles"]!).Count >= 1 && bible.StartsWith("SLOVO-BIBLE 1\nM\t") && bible.Contains("\nB\t1\t500\t") && bible.Contains("\nV\t3\t16\t") && reread.Songs.Count == 2,
                   "Бібліотека для планшета: /api/library, переклад рядками, пісенник .vbm", $"переклад {bible.Length} знаків, пісенник «{songbookFile}» → {reread.Songs.Count} пісень");
            var songs = await Get("/api/songs/list");
            await Post("song", new JsonObject { ["index"] = 0 });
            await Post("part", new JsonObject { ["index"] = 1 });
            var songState = await Get("/api/state?since=0");
            Report(((JsonArray)songs["songs"]!).Count == 2 && (string?)songState["mode"] == "songs" && (string?)songState["slide"]?["reference"] == "Приспів", "Пісні з пульта: список, «song», «part»", $"пісень {((JsonArray)songs["songs"]!).Count}, у залі «{songState["slide"]?["reference"]}»");
            var text = await Post("text-set", new JsonObject { ["title"] = "З пульта", ["text"] = "Рядок один\n\nРядок два" });
            await Post("text-show", new JsonObject());
            var textState = await Get("/api/text");
            Report((int?)text["pages"] == 2 && (string?)textState["title"] == "З пульта" && (int?)textState["pages"] == 2, "Текст з пульта: text-set, text-show, /api/text", $"сторінок {text["pages"]}");
            var sermon = await Post("sermon-plan", new JsonObject
            {
                ["title"] = "Проповідь із планшета",
                ["items"] = new JsonArray(
                    new JsonObject { ["type"] = "scripture", ["title"] = "Ів 3:16", ["module"] = state.PrimaryModuleId, ["canon"] = 500, ["chapter"] = 3, ["verses"] = new JsonArray(16), ["text"] = "…" },
                    new JsonObject { ["type"] = "song", ["title"] = "Великий Бог", ["songBook"] = "probe.vbm", ["song"] = 0 },
                    new JsonObject { ["type"] = "text", ["heading"] = "Заголовок", ["body"] = "Текст" },
                    new JsonObject { ["type"] = "scripture", ["title"] = "Чужа 1:1", ["module"] = "немає", ["moduleName"] = "немає", ["canon"] = 999, ["chapter"] = 1, ["verses"] = new JsonArray(1), ["text"] = "текст уривка" }),
            });
            var sermonState = await Get("/api/state?since=0");
            await Post("plan", new JsonObject { ["index"] = 1 });
            var planState = await Get("/api/state?since=0");
            await Post("sermon-end", new JsonObject());
            var endState = await Get("/api/state?since=0");
            Report((int?)sermon["added"] == 4 && ((JsonArray)sermon["notes"]!).Count == 1 && (bool?)sermonState["sermon"]?["on"] == true && ((JsonArray)sermonState["plan"]!).Count == 4
                   && (string?)planState["slide"]?["reference"] == "Куплет 1" && (bool?)endState["sermon"]?["on"] == false && ((JsonArray)endState["plan"]!).Count == 2,
                   "План проповіді з планшета: sermon-plan (пісня за основою імені, чужа книга → текст), «plan», sermon-end",
                   $"лягло {sermon["added"]}, нотаток {((JsonArray)sermon["notes"]!).Count}, пункт 1 у залі «{planState["slide"]?["reference"]}», після повернення пунктів {((JsonArray)endState["plan"]!).Count}");
            var web = await http.GetStringAsync("http://127.0.0.1:" + (port + 2) + "/");
            var apps = await http.GetStringAsync("http://127.0.0.1:" + (port + 2) + "/api/apps");
            Report(web.StartsWith("<!doctype html>") && web.Contains("пульт у браузері") && apps.Contains("\"apps\""), "Пульт у браузері: сторінка й /api/apps", $"сторінка {web.Length} знаків");
            var modeFail = await Post("mode", new JsonObject { ["text"] = "media" });
            var unknown = await Post("щось-таке", new JsonObject());
            Report((int)modeFail["_status"]! == 400 && (int)unknown["_status"]! == 404, "Відмови: вкладка, якої ще немає — 400; невідома команда — 404", $"{modeFail["error"]} / {unknown["error"]}");

            // PIN
            state.Settings.RemotePin = "1234";
            state.ApplySettings(state.Settings);
            await Task.Delay(500);
            using var noPin = await http.GetAsync(baseUrl + "/api/state?since=0");
            using var request = new HttpRequestMessage(HttpMethod.Get, baseUrl + "/api/state?since=0");
            request.Headers.Add("X-Slovo-Pin", "1234");
            using var withPin = await http.SendAsync(request);
            Report((int)noPin.StatusCode == 401 && (int)withPin.StatusCode == 200, "PIN телефона: без PIN — 401, з PIN — 200", $"{(int)noPin.StatusCode} / {(int)withPin.StatusCode}");
            state.Settings.RemotePin = "";
            state.ApplySettings(state.Settings);
            await Task.Delay(300);

            // Розсилка
            try
            {
                using var udp = new UdpClient(AddressFamily.InterNetwork);
                var question = Encoding.UTF8.GetBytes("SLOVO?");
                await udp.SendAsync(question, question.Length, new System.Net.IPEndPoint(System.Net.IPAddress.Loopback, Remote.Beacon.Port));
                var receive = udp.ReceiveAsync();
                var done = await Task.WhenAny(receive, Task.Delay(2000));
                var reply = done == receive ? Encoding.UTF8.GetString(receive.Result.Buffer) : "";
                Report(reply.Contains("\"app\":\"Slovo\"") && reply.Contains("\"port\":" + port), "Розсилка «SLOVO?» на UDP 8104", reply.Length == 0 ? "відповіді нема (порт зайнятий іншим «Словом» на цій машині?)" : reply);
            }
            catch (Exception error) { Report(false, "Розсилка «SLOVO?»", error.Message); }
        }
        catch (Exception error) { Crash("Пульт", error); }
    }
}
