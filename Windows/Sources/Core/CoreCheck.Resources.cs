// =============================================================================
//  CoreCheck.Resources.cs — перевірка ядра: ресурси (`--section resources`)
// =============================================================================
//  Без мережі: каталоги — зі зразків тексту, установлення — з посилань
//  `file://` на готові архіви ($SLOVO_RES_FIXTURES, ті самі для Mac і C#).
//  Дзеркало еталона на Mac (slovo-ref, Resources.swift).
// =============================================================================

using System.Text;
using Microsoft.Data.Sqlite;

namespace Slovo.Core;

public static partial class CoreCheck
{
    private static string ItemText(ResourceItem item) =>
        $"{item.Id} | {item.Kind.RawValue()} | {Esc(item.Title)} | {Esc(item.Subtitle)} | {item.Size} | {item.Version} | {item.Url} | {item.FileName} | {item.Language ?? "nil"}";

    private static void PrintCatalog(string label, ResourceCatalog? catalog)
    {
        if (catalog == null)
        {
            P($"{label}: nil");
            return;
        }
        P($"{label}: format {catalog.Format} updated «{catalog.Updated}» items {catalog.Items.Count}");
        foreach (var item in catalog.Items) P("  " + ItemText(item));
    }

    private const string ModulesIni =
        "\uFEFF[Bible_RST]\nModuleName= Синодальный перевод \nModuleAuthor=РБО\n[Commentary_X]\nModuleName=Comm\n[Bible_UA Ogienko]\nModuleName=\nModuleAuthor= Огієнко\r\n[Bible_Переклад]\nModuleName=Переклад\n  [Bible_Spaced]  \nModuleName=Spaced\n[Bible_a?b#c%d:e]\n[]\n[\n[Bible_Last]\nModuleAuthor=x";

    private const string Registry =
        "{\"version\": 12, \"hosts\": [" +
        "{\"alias\":\"mz\",\"path\":\"https://mybible.zone/dl/?file=%s\",\"priority\":2}," +
        "{\"alias\":\"mz\",\"path\":\"https://mirror.example/%s.zip\",\"priority\":1}," +
        "{\"alias\":\"ht\",\"path\":\"http://insecure/%s\"}," +
        "{\"alias\":\"gh\",\"path\":\"https://github.example/%s\",\"priority\":true}," +
        "{\"alias\":\"x\"}]," +
        "\"downloads\":[" +
        "{\"fil\":\"AGP\",\"abr\":\"AGP\",\"des\":\"Агапе\\n76 книг \",\"lng\":\"uk\",\"upd\":\"2023-01-02\",\"siz\":\"589K\",\"url\":[\"{ht}AGP\",\"{mz}AGP\"]}," +
        "{\"fil\":\"Brux.dictionary\",\"abr\":\"BRX\",\"url\":[\"{mz}Brux\"]}," +
        "{\"fil\":\"UBIO'62\",\"abr\":\"UBIO'62\",\"des\":\"\",\"siz\":\"2.6M\",\"url\":[\"{mz}UBIO%2762\"]}," +
        "{\"fil\":\"ФІЛ\",\"abr\":\"ФІЛ\",\"siz\":\"1G\",\"url\":[\"{mz}%D0%A4%D0%86%D0%9B\"]}," +
        "{\"fil\":\"Raw\",\"abr\":\"Raw name\",\"url\":[\"{gh}Raw name'x\"],\"siz\":\"12\"}," +
        "{\"fil\":\"Bad\",\"abr\":\"Bad\",\"url\":[\"mz}AGP\",\"{zz}AGP\"]}," +
        "{\"fil\":\"Num\",\"abr\":5,\"url\":[\"{mz}N\"]}," +
        "{\"fil\":\"Pct\",\"abr\":\"Pct\",\"url\":[\"{mz}50%zz\"],\"siz\":\"x\"}," +
        "{\"fil\":\"Arr\",\"abr\":\"Arr\",\"url\":[\"{mz}A\", 5]}," +
        "{\"fil\":\"Multi\",\"abr\":\"Multi\",\"des\":\"  \\n  \",\"lng\":null,\"upd\":5,\"url\":[\"{gh}M\"]}]}";

    private const string TranslationsCsv =
        "\uFEFFlanguageCode,translationId,languageName,languageNameInEnglish,dialect,homeDomain,title,description,Redistributable,Copyright,UpdateDate,publicationURL,OTbooks,OTchapters,OTverses,NTbooks,NTchapters,NTverses,DCbooks,DCchapters,DCverses,FCBHID,Certified,inScript,swordName,rodCode,textDirection,downloadable,font,shortTitle,PODISBN,script,sourceDate\r\n" +
        "ukr,ukr1996,Українська,Ukrainian,,x,\"Біблія, переклад \"\"Огієнка\"\"\",desc,True,c,2023-04-05,u,39,929,23145,27,260,7957,0,0,0,,,,,,ltr,True,,Огієнко,,Cyrl,2020\r\n" +
        "eng,engkjv,English,English,,x,King James Version,\"multi\nline\",true,c,2024-01-01,u,39,929,23145,27,260,7957,0,0,0,,,,,,ltr,,,KJV,,Latn,2020\n" +
        "rus,rusnr,Русский,Russian,,x,НРП,d,false,c,2025-01-01,u,39,929,23145,27,260,7957,0,0,0,,,,,,ltr,True,,НРП,,Cyrl,2020\n" +
        "xyz,xyz1,X,X,,x,Title,d,True,c,2022-02-02,u,0,0,0,0,0,0,0,0,0,,,,,,ltr,True,,T,,Latn,2020\n" +
        "abc,abc1,A,A,,x,,d,TRUE,c,,u,1,1,5,0,0,0,0,0,x,,,,,,ltr,False,,Short,,Latn,\n" +
        "\n" +
        "qqq,qqq1,Q,Q,,x,, d ,True,c,2026-12-31,u,1,1, 7 ,0,0,0,0,0,0,,,,,,ltr,yes,,Коротко,,Latn,\n" +
        "deu,  ,D,D,,x,T,d,True,c,2021-01-01,u,1,1,1,0,0,0,0,0,0\n" +
        "fra,fra1,F,French,,x,Bible,d,True,c,2020-01-01,u,1,1,1";

    private const string SongbooksHtml =
        "<html><body>\n<h3> Russian </h3>\n<p>* Песнь Возрождения - 3300 песен - <a href=\"songbooks/pv3300.sps\">скачать</a></p>\n" +
        "<p>Гимны &quot;Надежды&quot;&nbsp;<b>новые</b> - <a  href=\"songbooks/hymns%20new.zip\" >zip</a></p>\n" +
        "<h3>Ukrainian</h3>\n<p>Євангельські пісні - <a href=\"songbooks/Євангельські пісні.sps\">x</a></p>\n" +
        "<p><a href=\"songbooks/pv3300.sps\">дубль</a></p>\n<h3>Klingon</h3>\n" +
        "<p>Very long title that goes on and on and on and on and on and on and on and on and on and on and on - <a href=\"songbooks/long.sps\">x</a></p>\n" +
        "<p> - <a HREF=\"songbooks/UPPER.SPS\">x</a></p>\n<a href=\"songbooks/not.txt\">no</a>\n</body></html>";

    private const string OwnCatalog =
        "{\"format\":\"slovo-resources\",\"updated\":\"2026-11-01\",\"items\":[" +
        "{\"id\":\"bible:ubt2020\",\"kind\":\"bible\",\"title\":\"УБТ\",\"subtitle\":\"s\",\"size\":123,\"version\":\"v1\",\"url\":\"https://x/a.zip\",\"fileName\":\"ubt2020\",\"language\":\"uk\",\"extra\":1}," +
        "{\"id\":\"songbook:glory\",\"kind\":\"songbook\",\"title\":\"Glory\",\"subtitle\":\"\",\"size\":0,\"version\":\"\",\"url\":\"https://x/b.zip\",\"fileName\":\"glory.songbook\"}]}";

    private static string Relative(string path, string root)
    {
        // У Windows роздільник «\\» — шлях друкується так само, як на Mac (через «/»), щоб вивід звірявся рядок у рядок.
        foreach (var prefix in new[] { root, "/private" + root })
            foreach (var separator in new[] { '/', Path.DirectorySeparatorChar })
                if (path.StartsWith(prefix + separator, StringComparison.Ordinal)) return path[(prefix.Length + 1)..].Replace(Path.DirectorySeparatorChar, '/');
        // На macOS /var — посилання на /private/var: той самий корінь буває записаний обома способами.
        return path == root || path == "/private" + root ? "." : path;
    }

    private static List<string> Tree(string root) =>
        EBibleVPL.EnumerateAll(root).Select(path => Relative(path, root) + (Directory.Exists(path) ? "/" : ""))
            .OrderBy(path => path, StringComparer.Ordinal).ToList();

    /// Вміст модуля: книги й вірші (щоб звіряти без байтів самого файла).
    private static string ModuleText(TextModule module)
    {
        var text = new StringBuilder();
        text.Append($"{module.Info.Name}|{module.Info.ShortName}|{module.Info.Language ?? "-"}|{B(module.Info.RightToLeft)}\n");
        foreach (var book in module.Books)
        {
            text.Append($"{book.Index}:{book.FullName}:{Join(book.ShortNames, " ")}:{I(book.CanonicalNumber)}\n");
            IReadOnlyList<Chapter> chapters;
            try { chapters = module.Chapters(book); }
            catch (Exception) { chapters = Array.Empty<Chapter>(); }
            foreach (var chapter in chapters)
                foreach (var verse in chapter.Verses) text.Append($"{chapter.Number}:{verse.Number}:{verse.Text}\n");
        }
        return text.ToString();
    }

    private static string FailureCategory(string reason)
    {
        var colon = reason.IndexOf(':');
        var head = colon >= 0 ? reason[..colon] : reason;
        var detail = colon >= 0 ? reason[(colon + 1)..].Trim() : "";
        return detail == OurWords.T("в архиве нет модуля") ? $"{head}: {detail}" : head;
    }

    private static void Resources(string dataPath)
    {
        P("# resources");
        PrintCatalog("bibleQuote", ResourceCatalog.BibleQuote(ModulesIni, ResourceHub.BibleQuoteBase));
        PrintCatalog("bibleQuote2", ResourceCatalog.BibleQuote("[Bible_X]\r\nModuleName=X\r\n", "https://base/"));
        PrintCatalog("myBible", ResourceCatalog.MyBible(Encoding.UTF8.GetBytes(Registry)));
        foreach (var (label, text) in new[]
                 {
                     ("myBible bom", "\uFEFF{\"version\":\"v2\",\"downloads\":[]}"), ("myBible float", "{\"version\":1.0,\"downloads\":[]}"),
                     ("myBible bool", "{\"version\":true,\"downloads\":[]}"), ("myBible none", "{\"downloads\":[]}"),
                     ("myBible null", "{\"version\":null,\"downloads\":[]}"), ("myBible bad", "{\"downloads\":5}"),
                     ("myBible array", "[1,2]"), ("myBible broken", "{\"downloads\":["), ("myBible mixed", "{\"downloads\":[{\"fil\":\"A\"},5]}"),
                 })
            PrintCatalog(label, ResourceCatalog.MyBible(Encoding.UTF8.GetBytes(text)));
        PrintCatalog("eBible", ResourceCatalog.EBible(TranslationsCsv));
        PrintCatalog("eBible empty", ResourceCatalog.EBible(""));
        PrintCatalog("eBible noid", ResourceCatalog.EBible("title,x\nA,1\n"));
        PrintCatalog("softProjector", ResourceCatalog.SoftProjector(SongbooksHtml, ResourceHub.SoftProjectorBase));
        PrintCatalog("softProjector noslash", ResourceCatalog.SoftProjector(SongbooksHtml, "https://softprojector.org"));

        var own = ResourceCatalog.Decode(Encoding.UTF8.GetBytes(OwnCatalog));
        PrintCatalog("own", own);
        P(Encoding.UTF8.GetString(own.Encoded()));
        foreach (var (label, text) in new[]
                 {
                     ("own wrong format", OwnCatalog.Replace("slovo-resources", "other")),
                     ("own missing size", OwnCatalog.Replace("\"size\":123,", "")),
                     ("own bad kind", OwnCatalog.Replace("\"kind\":\"bible\"", "\"kind\":\"video\"")),
                     ("own no language", OwnCatalog.Replace(",\"language\":\"uk\"", "")),
                 })
        {
            try { PrintCatalog(label, ResourceCatalog.Decode(Encoding.UTF8.GetBytes(text))); }
            catch (ResourceError error) { P($"{label}: {error.ErrorKind} {error.Message}"); }
            catch (Exception) { P($"{label}: decode fail"); }
        }
        P("errors " + Join(new[] { ResourceError.BadCatalog(), ResourceError.Network("a"), ResourceError.Unpack("b"), ResourceError.Place("c") }.Select(e => e.Message), " | "));
        P("sources " + Join(ResourceSources.All.Select(source => $"{source.RawValue()}={Join(ResourceKinds.All.Where(kind => source.Kinds().Contains(kind)).Select(kind => kind.RawValue()), "+")}")));
        P($"urls {ResourceHub.OwnCatalogURL} {ResourceHub.BibleQuoteBase} {ResourceHub.MyBibleRegistryURL} {ResourceHub.EBibleCatalogURL} {ResourceHub.SoftProjectorPageURL} {ResourceHub.SoftProjectorBase}");
        P($"pct «{SwiftUrl.AddingPercentEncodingForPath("Біблія 1:2?#%[]~'é😀")}» «{SwiftUrl.RemovingPercentEncoding("UBIO%2762") ?? "nil"}» «{SwiftUrl.RemovingPercentEncoding("%zz") ?? "nil"}» «{SwiftUrl.RemovingPercentEncoding("%FF") ?? "nil"}»");

        var output = Environment.GetEnvironmentVariable("SLOVO_CHECK_OUT") is { Length: > 0 } custom ? custom : Path.GetTempPath();
        var work = Path.Combine(output, "slovo-check-res-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        try
        {
            // ── EBibleVPL ──
            var vplFolder = Path.Combine(work, "vpl");
            Directory.CreateDirectory(Path.Combine(vplFolder, "a"));
            Directory.CreateDirectory(Path.Combine(vplFolder, "b"));
            File.WriteAllText(Path.Combine(vplFolder, "a", "readme.txt"), "r");
            File.WriteAllText(Path.Combine(vplFolder, ".hidden.txt"), "h");
            var vplText = "\uFEFFJHN 1:1 In the beginning was the Word\r\nJHN 1:2  The same \r\nJHN 1:3\r\nGEN 2:1-3 Thus the heavens\nXYZ 1:1 no\njhn 3:16 For God so loved\nREV 22:21 The grace\n\nPSA 23 1 The LORD\nMAT 1::1 Колінна\nSNG 1:1 Song\nPSA x:1 bad";
            File.WriteAllText(Path.Combine(vplFolder, "b", "tst_vpl.txt"), vplText);
            P($"findText {Relative(EBibleVPL.FindText(vplFolder) ?? "-", vplFolder)}");
            File.Delete(Path.Combine(vplFolder, "b", "tst_vpl.txt"));
            P($"findText fallback {Relative(EBibleVPL.FindText(vplFolder) ?? "-", vplFolder)} empty {EBibleVPL.FindText(Path.Combine(work, "nothing")) ?? "-"}");
            var vplPath = Path.Combine(work, "tst_vpl.txt");
            File.WriteAllText(vplPath, vplText);
            var moduleDb = Path.Combine(work, "out", "TST.SQLite3");
            var count = EBibleVPL.Convert(vplPath, moduleDb, new EBibleVPL.Description("Тест", "TST", "en", "© x · eBible.org", true));
            var vplModule = new MyBibleModule(moduleDb);
            P($"vpl verses {count} files {Join(Tree(Path.Combine(work, "out")))}");
            P(Esc(ModuleText(vplModule)));
            vplModule.ReleaseCache();
            SqliteConnection.ClearAllPools();
            File.WriteAllText(Path.Combine(work, "none.txt"), "nothing here\nXYZ 1:1 a\n");
            try { EBibleVPL.Convert(Path.Combine(work, "none.txt"), Path.Combine(work, "out", "N.SQLite3"), new EBibleVPL.Description("", "", "", "", false)); }
            catch (EBibleVPL.Failure failure) { P($"vpl failure {failure.FailureKind} {failure.Message}"); }

            // ── Layout ──
            var layout = new ResourceLayout(Path.Combine(work, "data", "Modules"));
            Directory.CreateDirectory(layout.Modules);
            File.WriteAllText(Path.Combine(layout.Modules, "glory.vbm"), "x");
            foreach (var kind in ResourceKinds.All)
            {
                var item = new ResourceItem("t:" + kind.RawValue(), kind, "T", fileName: kind == ResourceKind.Songbook ? "glory.songbook" : "X");
                P($"layout {kind.RawValue()} → {Relative(layout.Destination(item), work)} present {B(layout.IsPresent(item))}");
            }
            P($"layout root {Relative(layout.DataRoot, work)} modules {Relative(layout.Modules, work)}");

            // ── Payload ──
            void Stage(string name, string[] files, string fileName)
            {
                var staging = Path.Combine(work, "stage-" + name);
                foreach (var file in files)
                {
                    var path = Path.Combine(staging, file.TrimEnd('/'));
                    if (file.EndsWith('/')) Directory.CreateDirectory(path);
                    else
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                        File.WriteAllText(path, "x");
                    }
                }
                Directory.CreateDirectory(staging);
                var found = ResourceHub.PayloadIn(staging, new ResourceItem("p", ResourceKind.Bible, "P", fileName: fileName));
                P($"payload {name} → {(found is { } p ? $"{p.Kind} {Relative(p.Path, staging)}" : "nil")}");
            }
            Stage("nested", ["nested/Modules/glory.vbm", "other.vbm"], "glory.vbm");
            Stage("hidden", [".SQLite3", "readme.txt"], "X.SQLite3");
            Stage("two", ["a.sqlite3", "b.SQLite3"], "X.SQLite3");
            Stage("ini", ["Wrapper/Mod/bibleqt.ini", "Wrapper/Mod/01.htm", "Wrapper/x/y/BIBLEQT.INI"], "Mod");
            Stage("flat", ["bibleqt.ini", "01.htm"], "Mod");
            Stage("single", ["Fonts/a.ttf"], "Fonts");
            Stage("many", ["a/x", "b/y"], "Z");
            Stage("macosx", ["__MACOSX/x.vbm", "real/x.vbm"], "x.vbm");
            Stage("mybible", ["deep/UKJV.bbl.mybible"], "UKJV.mybible");
            Stage("empty", [], "Z");

            // ── Установлення з file:// ──
            var fixtures = Environment.GetEnvironmentVariable("SLOVO_RES_FIXTURES");
            if (fixtures is not { Length: > 0 })
            {
                P("install skipped: no SLOVO_RES_FIXTURES");
                return;
            }
            string Url(string name) => new Uri(Path.Combine(fixtures, name)).AbsoluteUri;
            var items = new List<ResourceItem>
            {
                new("bq:TestBQ", ResourceKind.Bible, "Тест BQ", version: "1", url: Url("bq-module.zip"), fileName: "TestBQ"),
                new("bq:Flat", ResourceKind.Bible, "Flat", version: "2", url: Url("bq-flat.zip"), fileName: "Flat"),
                new("mb:MB", ResourceKind.Bible, "MB", version: "3", url: Url("mybible.zip"), fileName: "MB.SQLite3"),
                new("mb:Named", ResourceKind.Bible, "Named", version: "4", url: Url("mybible-named.zip"), fileName: "Named.SQLite3"),
                new("mb:Two", ResourceKind.Bible, "Two", version: "5", url: Url("mybible-two.zip"), fileName: "Two.SQLite3"),
                new("eb:tst", ResourceKind.Bible, "eBible тест", "tst · Test · 2024", 0, "6", Url("ebible.zip"), "tst.SQLite3", "en"),
                new("eb:none", ResourceKind.Bible, "none", version: "7", url: Url("ebible-empty.zip"), fileName: "none.SQLite3"),
                new("songbook:bel", ResourceKind.Songbook, "Bel", version: "8", url: Url("songbook-vbm.zip"), fileName: "bel.songs.vbm"),
                new("songbook:eng", ResourceKind.Songbook, "Eng", version: "9", url: Url("songbook-other.zip"), fileName: "englishworship.vbm"),
                new("songbook:wrong", ResourceKind.Songbook, "Wrong", version: "18", url: Url("songbook-other.zip"), fileName: "english.songbook"),
                new("sp:bare", ResourceKind.Songbook, "Голий SP", version: "10", url: Url("bare.sps"), fileName: "bare.songbook"),
                new("sp:zip", ResourceKind.Songbook, "SP zip", version: "11", url: Url("sps.zip"), fileName: "spzip.songbook"),
                new("backgrounds:a", ResourceKind.Backgrounds, "Фони", version: "12", url: Url("backgrounds.zip"), fileName: "BackGrounds"),
                new("templates:a", ResourceKind.Templates, "Шаблони", version: "13", url: Url("templates.zip"), fileName: "Templates"),
                new("bible:empty", ResourceKind.Bible, "Empty", version: "14", url: Url("empty.zip"), fileName: "Empty"),
                new("bible:notzip", ResourceKind.Bible, "Not zip", version: "15", url: Url("notzip.zip"), fileName: "NotZip"),
                new("bible:missing", ResourceKind.Bible, "Missing", version: "16", url: Url("missing.zip"), fileName: "Missing"),
                new("bible:badurl", ResourceKind.Bible, "Bad url", version: "17", url: "not a url", fileName: "Bad"),
            };
            File.WriteAllText(Path.Combine(layout.Modules, "bare.vbm"), "old twin");
            var hub = new ResourceHub(layout);
            var log = new List<ResourceHub.Progress>();
            var outcome = hub.InstallAsync(items, progress => { lock (log) log.Add(progress); }).GetAwaiter().GetResult();
            P("installed " + Join(outcome.Installed.Select(item => item.Id)));
            foreach (var (item, reason) in outcome.Failures) P($"failed {item.Id}: {FailureCategory(reason)}");
            foreach (var group in log.GroupBy(progress => progress.Item.Id))
            {
                var fractions = group.Select(progress => progress.Fraction).ToList();
                var monotonic = fractions.Zip(fractions.Skip(1)).All(pair => pair.First == null || pair.Second == null || pair.Second >= pair.First);
                P($"progress {group.Key}: first {D(fractions[0] ?? -1)} last {D(fractions[^1] ?? -1)} monotonic {B(monotonic)} index {group.First().Index}/{group.First().Total}");
            }
            P("tree " + Join(Tree(Path.Combine(work, "data")), " "));
            foreach (var module in new[] { "TestBQ", "Flat" })
                P($"module {module} {Fnv(ModuleText(new BibleModule(Path.Combine(layout.Modules, module))))}");
            foreach (var module in new[] { "MB.SQLite3", "Named.SQLite3", "tst.SQLite3" })
            {
                var opened = new MyBibleModule(Path.Combine(layout.Modules, module));
                P($"module {module} {Esc(ModuleText(opened))}");
                opened.ReleaseCache();
            }
            foreach (var book in new[] { "bel.songs.songbook", "englishworship.songbook", "bare.songbook", "spzip.songbook" })
            {
                // Коротке ім'я пісенника SoftProjector — ім'я тимчасового файла
                // «slovo-sps-<UUID>» (так і на Mac): у звірку не йде.
                var opened = SongBook.FromFile(Path.Combine(layout.Modules, book));
                var temporary = opened.ShortName.StartsWith("slovo-sps-", StringComparison.Ordinal) && opened.ShortName.Length == 46;
                if (temporary) opened.ShortName = "slovo-sps-<UUID>";
                P($"songbook {book} {SongDigest(opened)} temporary short name {B(temporary)}");
            }
            var ledger = ResourceLedger.Load();
            P("ledger " + Join(ledger.Installed.Where(pair => items.Any(item => item.Id == pair.Key)).OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => $"{pair.Key}={pair.Value}")));
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            try { Directory.Delete(work, recursive: true); } catch { }
        }
    }
}
