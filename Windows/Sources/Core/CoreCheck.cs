// =============================================================================
//  CoreCheck.cs — перевірка ядра на теці даних (`--core-check <тека>`)
// =============================================================================
//  Друкує все, що вміє ядро, у тому самому вигляді, що й еталон на Mac
//  (slovo-ref — та сама програма на Swift поверх SlovoCore): виводи двох
//  програм порівнюються `diff`-ом рядок у рядок.
//
//  Тека даних не змінюється: перевірка працює на її копії в тимчасовій теці,
//  і дім даних (DataHome) на час перевірки показує туди ж.
//
//  ./dev.sh run --core-check <тека даних> [--section modules|verses|refs|…]
// =============================================================================

using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace Slovo.Core;

public static partial class CoreCheck
{
    private static TextWriter Out = Console.Out;

    public static int Run(string[] args)
    {
        var at = Array.IndexOf(args, "--core-check");
        if (at < 0 || at + 1 >= args.Length)
        {
            Console.WriteLine("--core-check <тека даних> [--section назва]");
            return 2;
        }
        var source = Path.GetFullPath(args[at + 1]);
        var sectionAt = Array.IndexOf(args, "--section");
        var only = sectionAt >= 0 && sectionAt + 1 < args.Length ? args[sectionAt + 1] : "";
        if (!Directory.Exists(source))
        {
            Console.WriteLine($"немає теки {source}");
            return 2;
        }

        // Копія даних: перевірка не має права нічого змінити в оригіналі.
        var temp = Path.Combine(Path.GetTempPath(), "slovo-core-check-" + Guid.NewGuid().ToString("N"));
        var data = Path.Combine(temp, "Slovo");
        CopyFolder(source, data);
        typeof(Slovo.Program).GetProperty("DataOverride")!.SetValue(null, data);

        var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = false, NewLine = "\n" };
        Out = stdout;
        CodePage.Register();
        try
        {
            Check(data, only);
        }
        finally
        {
            stdout.Flush();
            try { Directory.Delete(temp, recursive: true); } catch { }
        }
        return 0;
    }

    private static void CopyFolder(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.EnumerateFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
        foreach (var folder in Directory.EnumerateDirectories(from)) CopyFolder(folder, Path.Combine(to, Path.GetFileName(folder)));
    }

    // ── Вигляд як у Swift ───────────────────────────────────────────────────

    private static void P(string line) => Out.Write(line + "\n");
    private static string B(bool value) => value ? "true" : "false";
    private static string I(int? value) => value is { } number ? number.ToString(CultureInfo.InvariantCulture) : "-";

    /// `"\(double)"` у Swift: ціле — з «.0».
    private static string D(double value)
    {
        if (double.IsFinite(value) && Math.Floor(value) == value && Math.Abs(value) < 1e16)
            return value.ToString("0", CultureInfo.InvariantCulture) + ".0";
        return value.ToString("R", CultureInfo.InvariantCulture).Replace("E", "e");
    }

    private static string Fnv(string text)
    {
        var hash = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(text))
        {
            hash ^= b;
            hash = unchecked(hash * 0x100000001b3UL);
        }
        return hash.ToString("x16");
    }

    private static string Join<T>(IEnumerable<T> items, string separator = ",") => string.Join(separator, items);

    private static string Ranges(IEnumerable<IntRange> ranges) => Join(ranges.Select(r => $"{r.LowerBound}-{r.UpperBound}"));

    // ── Сама перевірка ──────────────────────────────────────────────────────

    private static void Check(string dataPath, string only)
    {
        bool Want(string section) => only.Length == 0 || only == section;
        var library = new ModuleLibrary(Path.Combine(dataPath, "Modules"));

        if (Want("modules")) Modules(library);
        if (Want("verses")) Verses(library);
        if (Want("refs")) References(library);
        if (Want("shortest"))
        {
            P("# shortest");
            foreach (var module in library.Modules)
                P($"{module.Identifier}: " + Join(ShortBookNames.Shortest(module.Books).Select(e => $"{e.Name}={e.Abbreviation}"), "; "));
        }
        if (Want("search")) Search(library);
        if (Want("numbering")) Numbering(library, dataPath);
        if (Want("lang")) Languages(dataPath);
        if (Want("ourwords")) Words();
        if (Want("ini")) Ini(dataPath);
        if (Want("hotkeys")) Hotkeys(dataPath);
        if (Want("settingsjson")) SettingsJson(dataPath);
        if (Want("history")) History(dataPath);
        if (Want("text")) Texts();
        if (Want("slides")) Slides(dataPath);
        if (only == "writes") Writes(dataPath, library);
        if (Want("songs")) Songs(dataPath);
        if (only == "vbmwrite") VbmWrite(dataPath);
        if (only == "vbmread") VbmRead();
        if (Want("plan")) Plan(dataPath, library);
        if (Want("outputs")) Outputs(dataPath);
        if (Want("media")) Media();
        if (Want("resources")) Resources(dataPath);
        if (Want("import")) Import(dataPath);
        if (Want("presentation")) Presentation();
        if (Want("web")) Web(dataPath);
    }

    private static void Modules(ModuleLibrary library)
    {
        P("# modules");
        P($"modules {library.Modules.Count} songs {library.SongFiles.Count} failures {library.Failures.Count}");
        foreach (var failure in library.Failures) P($"failure {failure.Directory}: {failure.Reason}");
        foreach (var song in library.SongFiles) P($"song {SwiftPath.LastComponent(song)}");
        foreach (var module in library.Modules)
        {
            int chapters = 0, verses = 0;
            var text = new StringBuilder();
            var folded = new StringBuilder();
            var mismatched = new List<string>();
            foreach (var book in module.Books)
            {
                IReadOnlyList<Chapter> list;
                try { list = module.Chapters(book); }
                catch (Exception error)
                {
                    // У stderr: вивід для звірки з еталоном лишається тим самим.
                    Console.Error.WriteLine($"{module.Identifier}/{book.FileName}: {error.GetType().Name}: {error.Message}");
                    list = Array.Empty<Chapter>();
                }
                chapters += list.Count;
                foreach (var chapter in list)
                {
                    verses += chapter.Verses.Count;
                    text.Append($"{book.Index}:{chapter.Number}:{chapter.Heading ?? "-"}\n");
                    foreach (var verse in chapter.Verses)
                    {
                        text.Append($"{chapter.Number}:{verse.Number}:{verse.Text}\n");
                        folded.Append(SwiftText.Fold(verse.Text)).Append('\n');
                    }
                }
                if (book.ChapterCount > 0 && list.Count != book.ChapterCount)
                    mismatched.Add($"{book.FullName}: parsed {list.Count} declared {book.ChapterCount}");
            }
            P($"module {module.Identifier} | {module.Format.Title()} | {module.DisplayName} | {module.Info.ShortName} | books {module.Books.Count} chapters {chapters} verses {verses} | text {Fnv(text.ToString())} | folded {Fnv(folded.ToString())}");
            var info = module.Info;
            P($"  info: bible={B(info.IsBible)} ot={B(info.HasOldTestament)} nt={B(info.HasNewTestament)} strong={B(info.HasStrongNumbers)} zero={B(info.ChapterZero)} rtl={B(info.RightToLeft)} chapterSign={info.ChapterSign} verseSign={info.VerseSign} filter={Join(info.HtmlFilter)} lang={info.Language ?? "-"}");
            foreach (var line in mismatched) P($"  ! {line}");
            foreach (var book in module.Books)
                P($"  book {book.Index} {book.FileName} | {book.FullName} | {Join(book.ShortNames, " ")} | {book.ChapterCount} | {I(book.CanonicalNumber)}");
            module.ReleaseCache();
        }
    }

    private static void Verses(ModuleLibrary library)
    {
        P("# verses");
        (int Canon, int Chapter, int Verse)[] places =
            [(500, 3, 16), (10, 1, 1), (230, 22, 1), (230, 151, 1), (360, 2, 28), (360, 3, 1), (460, 4, 1), (190, 1, 1)];
        foreach (var module in library.Modules)
        {
            foreach (var (canon, ch, vs) in places)
            {
                var book = module.Books.FirstOrDefault(b => b.CanonicalNumber == canon);
                if (book == null) { P($"{module.Identifier} {canon} {ch}:{vs} — no book"); continue; }
                Chapter? chapter = null;
                try { chapter = module.Chapter(ch, book); } catch { }
                var verse = chapter?.VerseNumbered(vs);
                P($"{module.Identifier} {book.ButtonTitle} {ch}:{vs} = {verse?.Text ?? "—"}");
                if (chapter?.Heading is { } heading) P($"  heading: {heading}");
            }
        }
    }

    private static readonly string[] Samples =
    [
        "Ів 3:16", "Іван 3:16", "Ин 3:16", "Быт 1:1-3", "1Кор 13", "1 Кор 13:4-7", "John 3:16", "Пс 22", "Мт 5:3,5,7",
        "иак 4 -", "Об 22:21", "1 Ів 1:9", "Йоіл 3:1", "Иоан", "ин 3 16 18", "Буття 1", "Ps 23:1", "Gen 1:1-5",
        "коринф 1", "иис нав 1", "1-9223372036854775807", "Пс 119:1-333", "Мал 4", "Мк. 16:15", "Рим 8:28-39,1",
    ];

    private static void References(ModuleLibrary library)
    {
        P("# refs");
        var available = Enumerable.Range(1, 40).ToList();
        foreach (var module in library.Modules)
        {
            foreach (var sample in Samples)
            {
                var found = ReferenceParser.Parse(sample, module);
                P($"{module.Identifier} «{sample}» → " + Join(found.Select(f =>
                    $"{f.Book.FullName}/{I(f.Chapter)}/{Join(f.Verses)}/{(int)f.Kind}/{B(f.IsChapterValid)}/{f.DisplayText}"), " ; "));
                P($"  resolve: {ReferenceParser.Resolve(sample, module)?.DisplayText ?? "—"}");
                if (ScriptureAddress.Parse(sample, module.Books) is { } a)
                    P($"  address: {a.Book.FullName} ch={I(a.Chapter)} first={I(a.FirstVerse)} last={I(a.LastVerse)} whole={B(a.WantsWholeChapter)} listed={Join(a.ListedVerses)} sel={Join(a.VerseNumbers(available))} disp={a.DisplayText([1, 2, 3])}");
                else
                    P("  address: —");
            }
        }
        P("verseList: " + Join(ReferenceParser.VerseList("7,3,5-9,12–14,20-18,1-9223372036854775807")));
        P("format: " + ReferenceParser.Format([3, 4, 5]) + " " + ReferenceParser.Format([1, 3, 5]) + " " + ReferenceParser.Format([]));
        P("position: " + ReferenceFormat.Position(3, [1, 2, 3, 7, 9, 10]) + " " + ReferenceFormat.Position(5, []));
    }

    private static void Search(ModuleLibrary library)
    {
        P("# search");
        string[] queries = ["Бог любов", "возлюбил", "світ", "йосип", "иосиф", "Ісус Христос", "  ", "Господь, Бог!", "аа", "ss"];
        foreach (var module in library.Modules)
        {
            var index = TextSearch.Index.Build(module)!;
            foreach (var query in queries)
            {
                foreach (var whole in new[] { false, true })
                {
                    var trimmed = query.TrimWhitespacesAndNewlines();
                    var outcome = trimmed.Length == 0
                        ? TextSearch.Outcome.Empty(trimmed)
                        : TextSearch.Search(trimmed, index, new TextSearch.Options { Limit = 300, WholeWords = whole });
                    P($"{module.Identifier} «{query}» whole={B(whole)} hits {outcome.Hits.Count} truncated {B(outcome.IsTruncated)} scanned {outcome.ScannedVerses}");
                    foreach (var hit in outcome.Hits.Take(4))
                        P($"  {hit.Reference} [{Ranges(hit.Highlights)}] {Join(hit.Segments.Where(s => s.IsMatch).Select(s => s.Text), "|")}");
                }
            }
            module.ReleaseCache();
        }
    }

    private static string Spans(IEnumerable<VerseSpan> spans) =>
        Join(spans.Select(span => $"{span.Chapter}:{Join(span.Verses)}"), " ");

    private static void Numbering(ModuleLibrary library, string dataPath)
    {
        P("# numbering");
        var numbering = NumberingBase.Load(dataPath);
        P($"base standards {Join(numbering.Standards.Select(s => $"{s.Code}={s.Description}"), "; ")} modules {Join(numbering.Modules.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => $"{p.Key}={p.Value}"))} rules {numbering.Rules.Count}");
        P($"rule0 {(numbering.Rules.Count > 0 ? $"{numbering.Rules[0].Kind.RawValue()} {numbering.Rules[0].SourceText} → {numbering.Rules[0].TargetText}" : "-")}");
        var engine = VerseNumbering.Shared;
        var ok = engine.LoadRules(Path.Combine(dataPath, "inconsistencies.sqlite3"));
        P($"rules loaded {B(ok)} count {engine.RuleCount} corrections {engine.CorrectionCount} standards {Join(engine.Standards.Select(s => $"{s.Id}={s.Title}"), "; ")}");
        var ru = engine.Standard("ru");
        var en = engine.Standard("en");
        var ua = engine.Standard("ua");
        var pl = engine.Standard("pl");
        (int Book, int Chapter, int[] Verses, VerseNumberingStandard From, VerseNumberingStandard To)[] cases =
        [
            (230, 22, [1], ru, en), (230, 22, [1], en, ru), (230, 22, [1, 2, 3], ua, ru), (230, 22, [1], ru, ua),
            (230, 22, [1], ua, pl), (230, 12, [6], ru, en), (230, 113, [9], ru, en), (360, 2, [27, 28, 29], ru, ua),
            (460, 4, [1, 2, 6], ru, ua), (110, 4, [21, 22], ru, ua), (230, 9, [], ru, en), (230, 151, [1], ru, en),
            (350, 11, [1], ru, en), (40, 30, [1, 2], ru, en), (510, 19, [40], ru, en), (230, 51, [3], ua, pl),
        ];
        foreach (var (book, chapter, verses, from, to) in cases)
        {
            var spans = engine.Translate(book, chapter, verses, from, to, _ => 20);
            P($"{from.Id}→{to.Id} {book} {chapter}:{Join(verses)} = {Spans(spans)} | {engine.Trace(book, chapter, verses.Length > 0 ? verses[0] : 1, from, to)}");
        }
        var temp = Path.Combine(Path.GetTempPath(), $"core-check-numbering-{Guid.NewGuid():N}.json");
        if (File.Exists(Path.Combine(dataPath, "numbering.json"))) File.Copy(Path.Combine(dataPath, "numbering.json"), temp);
        var assignments = new NumberingAssignments(temp);
        foreach (var a in assignments.Apply(library.Modules, engine))
            P($"assign {a.ModuleID} = {a.StandardID} [{NumberingAssignment.RawValue(a.Origin)}] {a.Reason}");
        foreach (var module in library.Modules) P($"standard of {module.Identifier} = {engine.StandardOf(module).Id}");
        var emptyFile = Path.Combine(Path.GetTempPath(), $"core-check-empty-{Guid.NewGuid():N}.json");
        var empty = new NumberingAssignments(emptyFile);
        foreach (var module in library.Modules)
        {
            var e = NumberingGuess.EvidenceFor(module);
            P($"evidence {module.Identifier}: count={I(e.PsalmCount)} p9={I(e.Psalm9)} p3={I(e.Psalm3)} p147={I(e.Psalm147)} e8={I(e.Ecclesiastes8)} r16={I(e.Romans16)} guess={empty.AssignmentFor(module).StandardID}");
        }
        try { File.Delete(temp); File.Delete(emptyFile); } catch { }
        (int Canon, int Chapter, int[] Verses)[] places = [(230, 22, [1]), (230, 9, [21]), (360, 2, [28]), (460, 4, [1]), (110, 4, [21])];
        foreach (var from in library.Modules)
        {
            foreach (var to in library.Modules)
            {
                if (to.Identifier == from.Identifier) continue;
                foreach (var (canon, chapter, verses) in places)
                {
                    var book = from.Books.FirstOrDefault(b => b.CanonicalNumber == canon);
                    if (book == null || to.Counterpart(book) is not { } other) continue;
                    IReadOnlyList<Chapter> chapters;
                    try { chapters = to.Chapters(other); } catch { continue; }
                    var spans = engine.ExistingSpans(book, chapter, verses, engine.StandardOf(from), to, chapters);
                    var suffix = engine.ParallelSuffix(book, chapter, verses, engine.StandardOf(from), to, chapters);
                    P($"parallel {from.Identifier}→{to.Identifier} {canon} {chapter}:{Join(verses)} = {Spans(spans)} suffix «{suffix}»");
                }
            }
        }
        P($"near: {ModuleNameMatch.Nearest("UA_Ogienko", ["ua_ogienka", "ubt2020"]) ?? "-"} {ModuleNameMatch.Nearest("ubt2022", ["ubt2020"]) ?? "-"}");
    }

    private static void Languages(string dataPath)
    {
        P("# lang");
        var catalog = new LanguageCatalog(Path.Combine(dataPath, "Language"));
        P($"languages {catalog.Languages.Count}: " + Join(catalog.Languages.Select(l => $"{l.Code}={l.DisplayName}"), ", "));
        foreach (var code in new[] { "ru", "uk", "en" })
        {
            if (catalog.Language(code) is not { } language) { P($"{code} missing"); continue; }
            P($"{code} forms {language.Forms.Count} lines {language.Forms.Values.Sum(f => f.Count)}");
            foreach (var key in new[] { "Label9", "Label8", "Label1", "Label3", "N1", "N18", "N13", "N39", "N14", "N4", "N24", "N25", "N35", "N34" })
            {
                var entry = language.EntryFor(key, "MainForm");
                P($"  MainForm.{key} = «{entry?.Caption ?? "—"}» hint «{entry?.Hint ?? "—"}»");
            }
            foreach (var key in new[] { "Label21", "BBOk", "Label44" })
                P($"  SettingsForm.{key} = «{language.Caption(key, "SettingsForm", "?")}»");
            var all = new StringBuilder();
            foreach (var form in language.Forms.Keys.OrderBy(k => k, StringComparer.Ordinal))
                foreach (var key in language.Forms[form].Keys.OrderBy(k => k, StringComparer.Ordinal))
                {
                    var entry = language.Forms[form][key];
                    all.Append($"{form}.{key}={entry.Caption}|{entry.Hint ?? ""}\n");
                }
            P($"  digest {Fnv(all.ToString())}");
        }
    }

    private static void Words()
    {
        P("# ourwords");
        using (var stream = typeof(CoreCheck).Assembly.GetManifestResourceStream("en.json"))
        {
            if (stream != null && JsonNode.Parse(stream) is JsonObject root && root["words"] is JsonObject words)
                OurWords.Register(words.ToDictionary(p => p.Key, p => p.Value?.GetValue<string>() ?? ""), "en");
        }
        P("coverage " + Join(OurWords.Coverage.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => $"{p.Key}={p.Value}")));
        P("duplicates " + Join(OurWords.DuplicateWords, "|"));
        P($"keys {OurWords.RussianKeys.Count} digest {Fnv(string.Join("\n", OurWords.RussianKeys))}");
        var covered = OurWords.Covered("en");
        P($"covered en {covered.Translated}/{covered.Total} missing {covered.Missing.Count}");
        foreach (var language in new[] { "ru", "uk", "en", "de" })
        {
            OurWords.Language = language;
            P($"{language}: {OurWords.T("Всё загруженное и настроенное лежит в папке: %s", "/x")} | {OurWords.T("Сдвиг глав")} | {OurWords.T("в папке %s нет bibleqt.ini", "A", "B")} | {OurWords.T("Растворение")} | {OurWords.T("%s из %s", "1")} | {B(OurWords.HasRussianKey("Сдвиг глав"))}");
        }
        foreach (var language in new[] { "uk", "en" })
        {
            OurWords.Language = language;
            var all = new StringBuilder();
            foreach (var key in OurWords.RussianKeys) all.Append(key).Append('=').Append(OurWords.T(key)).Append('\n');
            P($"{language} digest {Fnv(all.ToString())}");
        }
        OurWords.Language = "ru";
    }

    private static string Json<T>(T value) => SwiftJson.Encode(value, pretty: true, sortedKeys: true);

    private static void Ini(string dataPath)
    {
        P("# ini");
        var config = IniSettings.FromFile(Path.Combine(dataPath, "Slovo.ini"));
        P($"located {(IniSettings.LocateConfig() is { } located ? SwiftPath.LastComponent(located) : "-")} sections {config.Sections.Count} keys {config.Sections.Values.Sum(s => s.Count)}");
        P("order " + Join(config.ModuleEntries().Select(e => $"{e.Name}:{B(e.IsEnabled)}")));
        var options = new ProgramOptions(config);
        P(Json(options));
        P($"ndiFrameRate {options.NdiFrameRate} placement {SlideWindowPlacement.From(options).Summary}");
        var settings = new SlovoSettings(config, HotkeySets.Load(), dataPath);
        P(Json(settings));
        var style = new SlideStyle(config, "Bible", dataPath);
        P(Json(style));
        var textStyle = new SlideStyle(config, "Text", dataPath);
        P(Json(textStyle));
        var output = new OutputSettings(config);
        P($"output {output.MonitorIndex} {B(output.ShowVerseNumbers)} {B(output.ShowSecondaryVerseNumbers)} {D(output.HideSlideDuration)} {output.SlideWidth}x{output.SlideHeight}");
        var format = new ReferenceFormat(config);
        P($"refformat {(int)format.CombinedMain} {(int)format.CombinedSecondary} {(int)format.SeparateMain} {(int)format.SeparateSecondary}");
        var palette = new SongChunkPalette(config);
        P("palette " + Join(palette.Chunks.Select(c => $"{c.Key}={c.Names.Count}")) + " | "
          + Join(new[] { "Куплет 2", "Припев:", "1 Куплет", "Бридж", "Zwrotka3", "Кода.", "xyz" }
                 .Select(k => $"{k}→{palette.ChunkFor(k)?.Key ?? "-"}/{I(SongChunkPalette.Number(k))}")));
        var pagination = new PlainTextDocument.Pagination(config, "Text", textStyle);
        P($"pagination {pagination.CharactersPerLine} {pagination.LinesPerPage} {D(pagination.MinimumFillPercent)} {B(pagination.SplitsIntoPages)} {B(pagination.SplitsIntoParagraphs)} {B(pagination.WrapsWords)}");
        var doc = new PlainTextDocument("Оголошення",
            "Дорогі! Настройтеся на служіння.\r\n\r\nСьогодні о 18:00 молитовне зібрання в малому залі, приходьте всі, хто може, і запрошуйте друзів та рідних.\nЗавтра — недільна школа.\n\n\nДуже-довге-слово-яке-не-влазить-у-жоден-рядок-слайда-ніяк-зовсім");
        foreach (var p in new[] { new PlainTextDocument.Pagination(), pagination, new PlainTextDocument.Pagination(splitsIntoPages: false),
                                  new PlainTextDocument.Pagination(splitsIntoParagraphs: true),
                                  new PlainTextDocument.Pagination(charactersPerLine: 10, linesPerPage: 2, showsPageNumber: true) })
        {
            P("pages " + Join(doc.Pages(p).Select(page => page.Replace("\n", "⏎")), " ‖ "));
            P("slides " + Join(doc.Slides(p).Select(s => $"{s.Reference}|{B(s.IsBlank)}"), " ‖ "));
        }
        P($"summary {doc.Summary(40)} | snippet {doc.Snippet(30)}");
        P("chunks " + Join(PlainTextDocument.Chunks("один два три чотири п'ять шість сім вісім", 9), "|"));
    }

    private static void Hotkeys(string dataPath)
    {
        P("# hotkeys");
        var sets = HotkeySets.FromFile(Path.Combine(dataPath, "hotkeys.ini"));
        P("order " + Join(sets.Order, "|") + $" preferred {sets.PreferredSetName ?? "-"}");
        foreach (var name in sets.Order)
            P($"  {name}: " + Join(sets.Hotkeys(name).OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => $"{p.Key}={p.Value.Text}/{I(p.Value.FunctionNumber)}")));
        P(sets.Serialized());
        P($"located {(HotkeySets.LocateFile() is { } file ? SwiftPath.LastComponent(file) : "-")} load {Join(HotkeySets.Load().Order, "|")}");
        foreach (var text in new[] { "ctrl+alt+b", "f5", "esc", " Shift + space ", "", "+", "Ctrl+", "pgdn", "x" })
            P($"parse «{text}» → {Hotkey.Parse(text)?.Text ?? "nil"}");
        P(Json(sets));
    }

    private static void SettingsJson(string dataPath)
    {
        P("# settingsjson");
        var data = File.ReadAllBytes(Path.Combine(dataPath, "settings.json"));
        if (SlovoSettings.Decode(data) is { } settings)
        {
            P($"decoded modules {settings.Modules.Count} webSlides {settings.WebSlides.Count} chunks {settings.SongChunks.Count}");
            P(Json(settings));
        }
        else P("decode failed");
        var root = JsonNode.Parse(data)!.AsObject();
        var options = root["options"]!.AsObject();
        options.Remove("updateInterval");
        P($"missing required → {(SlovoSettings.Decode(Encoding.UTF8.GetBytes(root.ToJsonString())) == null ? "fail" : "ok")}");
        options["updateInterval"] = 7;
        options.Remove("ndiSendAudio");
        options["buttonAction"] = 5;
        P($"bad enum → {(SlovoSettings.Decode(Encoding.UTF8.GetBytes(root.ToJsonString())) == null ? "fail" : "ok")}");
    }

    private static void History(string dataPath)
    {
        P("# history");
        var path = Path.Combine(dataPath, "History.ini");
        var history = ServiceHistory.Read(path);
        P($"records {history.Count}");
        foreach (var r in history.Records) P($"  {r.Identity} | {r.Caption} | {r.Reference} | v={r.Verses.Count}");
        P(history.Journal().Xml());
        var raw = JournalFile.Read(path);
        P($"raw total {raw.TotalCount} looks {B(JournalFile.LooksLikeJournal(File.ReadAllText(path)))}");
        P(Fnv(raw.Xml()));
        var j = JournalFile.Parse("<x><Journal Name=\"Text\"><Item Caption='a &amp; b &#1049; &#x41; &nbsp; &unknown;' Bad=noquote Next=\"q\" />\n<Item/></Journal><Journal Name=\"Bible\"/><Item Caption=\"lost\"/><Journal Name=\"Songs\"><Item A=\"1\r\n2\" B=\"x" + (char)0x301 + "&\"/></Journal>");
        P(j.Xml());
    }

    private static string Escaped(string text)
    {
        var output = new StringBuilder();
        foreach (var rune in text.EnumerateRunes())
            output.Append(rune.Value < 128 ? rune.ToString() : $"\\u{{{rune.Value:X}}}");
        return output.ToString();
    }

    private static void Texts()
    {
        P("# text");
        var zwsp = ((char)0x200B).ToString();
        foreach (var s in new[]
                 {
                     "<p>1 <b>Вначале</b> сотворил <s>7225</s>Бог&nbsp;небо&amp;землю</p>",
                     "a<br>b<div>c</div>&#x41;&#66;&#xD800;&mdash;&unknown;x",
                     "<s>drop<s>inner</s>tail</s>after", "unclosed <tag",
                     "  lots   of" + zwsp + "\n\t space  \r\n", "&#1049;&#123456789;", "a " + (char)0x301 + "b",
                 })
            P($"plain «{Escaped(HTMLText.Plain(s))}»");
        foreach (var s in new[] { "Εν<E>В начале<Fr>.<RF>прим<Rf> было <TS>Заголовок<Ts>Слово<X>logos<x>, и<D>слово",
                                  "<FI>курсив<Fi> и <RF q=a>сноска без конца" })
            P($"mysword «{MySwordText.Plain(s)}»");
        var acute = ((char)0x301).ToString();
        foreach (var s in new[] { "Йосип і Ёлка", "ǅungla ΐ ᾳ ß ﬁ İ ı", "сло" + acute + "во", "א" + (char)0x5B8 + "ב", "a" + (char)0x5B8 + "b",
                                  "Ԑ" + acute + "ԑ" + acute, "e" + acute + (char)0x308 + "x" })
            P($"fold «{Join(SwiftText.Fold(s).EnumerateRunes().Select(r => r.Value.ToString("X4")), " ")}»");
        string[] names = ["psalm_lviv_2008-if.songbook", "psalm2000.songbook", "UA_Gyzha", "ubt2020", "umt'07", "glory.songbook", "UA_Kulish",
                          "p_s_ua.songbook", "ivangeliya2.songbook", "vidrodzhennia.songbook", "a10", "a9", "A2", "Ёлка", "елка", "Яблуко", "ábc",
                          "abc", "Zebra", "_x", "1.jpg", "10.jpg", "2.jpg"];
        P("sort " + Join(names.OrderBy(n => n, SwiftText.StandardOrder)));
    }
    private static string Json2<T>(T value) => SwiftJson.Encode(value, pretty: true, sortedKeys: true, escapeSlashes: false);

    private static void Slides(string dataPath)
    {
        P("# slides");
        var config = IniSettings.FromFile(Path.Combine(dataPath, "Slovo.ini"));
        var baseStyle = new SlideStyle(config, "Bible", dataPath);
        var schemes = SchemeLibrary.FromDataRoot(dataPath, config);
        P($"templates {schemes.Templates.Count} failures {schemes.Failures.Count} height {D(schemes.DesignHeight)}");
        foreach (var (file, reason) in schemes.Failures.OrderBy(p => p.Key, StringComparer.Ordinal)) P($"  failure {file}: {reason}");
        string Name(string? path) => path == null ? "-" : SwiftPath.LastComponent(path);
        foreach (var t in schemes.Templates)
        {
            P($"template {t.Name} | {t.Scheme.Name} | bg {Name(t.BackgroundUrl)} | thumbs {Name(t.SingleThumbnailUrl)} {Name(t.DualThumbnailUrl)} | presets {Join(t.Scheme.PresetNames)} | elements {t.Scheme.Elements.Count}");
            foreach (var e in t.Scheme.Elements)
            {
                var p1 = e.PlacementFor(SlideScheme.Variant.Single);
                var p2 = e.PlacementFor(SlideScheme.Variant.Dual);
                var b1 = p1.Box;
                var b2 = p2.Box;
                var scene = e.SceneFor(SlideScheme.Variant.Single);
                var sceneText = scene is { } sc ? $"{sc.Fx}/{B(sc.IsAnimated)}/{D(sc.FromOpacity)}/{D(sc.FromScale)}/{D(sc.MoveFromX)}/{D(sc.Duration)}" : "-";
                P($"  el {e.Name} type {e.RawType} kind {(e.Kind is { } k ? ((int)k).ToString() : "-")} img {e.ImageName ?? "-"} mask {e.ImageMaskName ?? "-"} var {B(e.HasVariantParameters)} box1 {D(b1.X)},{D(b1.Y)},{D(b1.Width)},{D(b1.Height)} box2 {D(b2.X)},{D(b2.Y)},{D(b2.Width)},{D(b2.Height)} anchor {p1.Anchor.RawValue}/{(int)p1.Anchor.Horizontal}/{(int)p1.Anchor.Vertical} scene {sceneText} imageURL {Name(t.ImageUrl(e.ImageName))}");
            }
            P(Json2(t.Scheme));
            foreach (var v in new[] { SlideScheme.Variant.Single, SlideScheme.Variant.Dual })
                P(Json2(schemes.SlideStyleFor(t, baseStyle, v)));
            P(Json2(new SlidePreset(t, baseStyle, schemes.DesignHeight)));
        }
        P($"named {schemes.TemplateNamed("springfade")?.Name ?? "-"} {B(schemes.SlideStyleNamed("nonexistent", baseStyle) == null)}");
        var presets = new PresetLibrary(Path.Combine(dataPath, "Presets"));
        P($"presets {presets.Presets.Count}: " + Join(presets.Presets.Select(p => $"{p.Name}/{B(p.ForSongs)}")));
        foreach (var kind in OutputKinds.All)
            P($"  assign {kind.RawValue()} = {presets.Preset(kind)?.Name ?? "-"} songs {presets.Preset(kind, true)?.Name ?? "-"}");
        foreach (var p in presets.Presets) P(Json2(p));
        foreach (var (name, make) in new (string, Func<string, SlideStyle, SlidePreset>)[]
                 { ("standard", SlidePreset.Standard), ("song", SlidePreset.Song), ("transparent", SlidePreset.Transparent), ("stage", SlidePreset.Stage) })
            P(name + " " + Json2(make(name, baseStyle)));
        var tolerant = "{\"id\":\"DBA9AB16-2069-4A30-8EBA-78EAD9E2F26C\",\"name\":\"T\",\"canvasWidth\":800,\"canvasHeight\":600,\"background\":{\"color\":{\"red\":0,\"green\":0,\"blue\":0,\"alpha\":1},\"fillMode\":\"fit\",\"dim\":0,\"blurRadius\":0,\"isTransparent\":false},\"objects\":[{\"kind\":\"image\",\"id\":\"51722B82-5CF8-4003-B90E-AD55985257B8\"},{\"kind\":\"songTitle\",\"id\":\"51722B82-5CF8-4003-B90E-AD55985257B9\",\"shadow\":{\"isEnabled\":true},\"secondVariant\":{\"opacity\":0.5}}],\"transition\":\"spin\",\"transitionDuration\":1}";
        P(SlidePreset.Decode(Encoding.UTF8.GetBytes(tolerant)) is { } decoded ? "tolerant " + Json2(decoded) : "tolerant failed");
        var strict = "{\"id\":\"DBA9AB16-2069-4A30-8EBA-78EAD9E2F26C\",\"name\":\"T\",\"canvasWidth\":800,\"background\":{\"color\":{\"red\":0,\"green\":0,\"blue\":0,\"alpha\":1},\"fillMode\":\"fit\",\"dim\":0,\"blurRadius\":0,\"isTransparent\":false},\"objects\":[],\"transition\":\"spin\",\"transitionDuration\":1}";
        P($"strict {(SlidePreset.Decode(Encoding.UTF8.GetBytes(strict)) == null ? "fail" : "ok")}");
        var frame = new ObjectFrame(0.1, 0.2, 0.5, 0.25, HorizontalAnchor.Right, VerticalAnchor.Bottom);
        var r = frame.Rect(new SizeD(1920, 1080));
        P($"rect {D(r.X)} {D(r.Y)} {D(r.Width)} {D(r.Height)}");
        var m = new ObjectShadow(isEnabled: true, offsetPercent: 2.7, blurPercent: 7, angleDegrees: 90).Metrics(50, 300);
        P($"metrics {D(m.Offset.Width)} {D(m.Offset.Height)} {D(m.Blur)}");
    }
    /// Запис і читання назад — лише на копії даних (на Mac цього розділу в
    /// еталоні немає: тут перевіряється, що файли, записані ядром, читаються).
    private static void Writes(string dataPath, ModuleLibrary library)
    {
        P("# writes");
        var temp = Path.Combine(dataPath, "core-check-writes");
        Directory.CreateDirectory(temp);

        var numbering = NumberingBase.Load(dataPath);
        var saved = Path.Combine(temp, "inconsistencies.sqlite3");
        numbering.Save(saved);
        var again = NumberingBase.LoadFrom(saved);
        var same = numbering.Rules.Count == again.Rules.Count
                   && numbering.Rules.Zip(again.Rules).All(pair => pair.First with { Id = Guid.Empty } == pair.Second with { Id = Guid.Empty })
                   && numbering.Standards.SequenceEqual(again.Standards)
                   && numbering.Modules.Count == again.Modules.Count && numbering.Modules.All(p => again.Modules.GetValueOrDefault(p.Key) == p.Value);
        P($"numbering save/load: rules {again.Rules.Count} standards {again.Standards.Count} modules {again.Modules.Count} same {B(same)}");
        var over = VerseNumbering.Over(again.Rules, again.Standards);
        var shared = VerseNumbering.Shared;
        shared.LoadRules(saved);
        var probe = over.Translate(230, 22, [1, 2], over.Standard("ua"), over.Standard("pl"));
        var expected = shared.Translate(230, 22, [1, 2], shared.Standard("ua"), shared.Standard("pl"));
        P($"over == shared: {B(probe.SequenceEqual(expected))} ({Spans(probe)} / {Spans(expected)})");

        var history = Path.Combine(dataPath, "History.ini");
        var journal = JournalFile.Read(history);
        var written = Path.Combine(temp, "History.ini");
        journal.Write(written);
        P($"journal write/read: {B(JournalFile.Read(written).Xml() == journal.Xml())} items {journal.TotalCount}");
        var serviceHistory = ServiceHistory.Read(history);
        serviceHistory.Remember(new HistoryRecord(HistoryRecord.Kind.Text, quote: "Оголошення"));
        serviceHistory.Write(written);
        P($"history remember/write/read: {ServiceHistory.Read(written).Count} first {ServiceHistory.Read(written).Records[0].Caption}");

        var settingsData = File.ReadAllBytes(Path.Combine(dataPath, "settings.json"));
        var settings = SlovoSettings.Decode(settingsData)!;
        var encoded = settings.Encode();
        var copy = settings.Copy();
        copy.Options.MonitorIndex = 99;
        P($"settings round trip: {B(Encoding.UTF8.GetString(SlovoSettings.Decode(encoded)!.Encode()) == Encoding.UTF8.GetString(encoded))} copy independent {B(settings.Options.MonitorIndex != 99)}");

        var sets = HotkeySets.FromFile(Path.Combine(dataPath, "hotkeys.ini"));
        P($"hotkeys serialized/parsed: {B(HotkeySets.FromText(sets.Serialized()).Equals(sets))}");
        var changed = false;
        EffectiveHotkeys.HotkeysChanged += () => changed = true;
        var before = EffectiveHotkeys.Layout.Count;
        var adopted = EffectiveHotkeys.Adopt(HotkeySets.FactoryDefault, "");
        P($"effective hotkeys: {before} → {EffectiveHotkeys.Layout.Count} adopted {B(adopted)} event {B(changed)} source {EffectiveHotkeys.Source} F5 {EffectiveHotkeys.Hotkey("ShowSlide")?.Text}");

        P($"bundle: {Join(Directory.GetFiles(DataHome.BundleData).Select(Path.GetFileName).OrderBy(n => n, StringComparer.Ordinal))}");
        P($"config located in data: {B(IniSettings.LocateConfig() == Path.Combine(DataHome.Folder, IniSettings.ConfigFileName))}");
        var migration = DataMigration.Run(Path.Combine(temp, "home"), DataHome.BundleData);
        P($"migration: {migration.Summary}");
        P($"data paths: {(DataPaths.Existing("/Users/x/Library/Application Support/Slovo/Presets/assignments.json") is { } found ? SwiftPath.LastComponent(found) : "-")} {(DataPaths.Existing("C:\\Users\\x\\AppData\\Roaming\\Slovo\\Slovo.ini") is { } win ? SwiftPath.LastComponent(win) : "-")}");

        var presets = new PresetLibrary(Path.Combine(dataPath, "Presets"));
        var style = new SlideStyle(IniSettings.FromFile(Path.Combine(dataPath, "Slovo.ini")), "Bible", dataPath);
        var song = SlidePreset.Song("Пісні: тест/1", style);
        presets.Save(song);
        presets.Assign(song, OutputKind.Screen, songs: true);
        var reloaded = new PresetLibrary(Path.Combine(dataPath, "Presets"));
        P($"presets save/assign/reload: {reloaded.Presets.Count} songs {reloaded.PresetsFor(true).Count} screen-songs {reloaded.Preset(OutputKind.Screen, true)?.Name}");
        reloaded.Delete(reloaded.Preset(OutputKind.Screen, true)!);
        P($"presets delete: {new PresetLibrary(Path.Combine(dataPath, "Presets")).Presets.Count} files {Directory.GetFiles(Path.Combine(dataPath, "Presets")).Length}");

        var module = library.Modules[0];
        var search = new TextSearch();
        using var done = new ManualResetEventSlim();
        TextSearch.Outcome? outcome = null;
        search.Start("Бог", module, new TextSearch.Options { Limit = 5 }, completion: result => { outcome = result; done.Set(); });
        P($"background search: finished {B(done.Wait(60000))} hits {outcome?.Hits.Count} truncated {B(outcome?.IsTruncated == true)}");
        using var second = new ManualResetEventSlim();
        var stale = 0;
        search.Start("світ", module, completion: _ => stale++);
        search.Cancel();
        search.Prepare(module, completion: () => second.Set());
        second.Wait(60000);
        P($"cancelled search delivered: {stale}");

        var plain = new PlainTextDocument("Заголовок", "Текст");
        var json = SwiftJson.Encode(plain);
        P($"plain text json: {json} back {SwiftJson.Decode<PlainTextDocument>(Encoding.UTF8.GetBytes(json)).Title}");
    }
}
