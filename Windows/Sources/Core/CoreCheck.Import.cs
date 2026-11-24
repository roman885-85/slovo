// =============================================================================
//  CoreCheck.Import.cs — перевірка ядра: майстер імпорту (`--section import`)
// =============================================================================
//  Джерело — готова тека й архіви $SLOVO_IMPORT_FIXTURES (ті самі для Mac і C#),
//  імпорт — у тимчасову теку під $SLOVO_CHECK_OUT. Шляхи у виводі замінено на
//  <FX>, <WORK>, <TMP>. Дзеркало еталона на Mac (slovo-ref, Import.swift).
// =============================================================================

using System.Text;
using Microsoft.Data.Sqlite;

namespace Slovo.Core;

public static partial class CoreCheck
{
    private static string MaskPaths(string text, params (string Root, string Name)[] roots)
    {
        foreach (var (root, name) in roots)
        {
            var bare = root.StartsWith("/private/", StringComparison.Ordinal) ? root["/private".Length..] : root;
            text = text.Replace("/private" + bare, name).Replace(bare, name);
        }
        var temp = Path.GetTempPath().TrimEnd('/');
        text = System.Text.RegularExpressions.Regex.Replace(text, "(/private)?" + System.Text.RegularExpressions.Regex.Escape(temp.StartsWith("/private/", StringComparison.Ordinal) ? temp["/private".Length..] : temp) + "/slovo-import-[0-9A-F-]{36}", "<TMP>");
        return text;
    }

    private static long UnixSeconds(DateTime? date) =>
        date is { } value ? (long)Math.Floor((value.ToUniversalTime() - DateTime.UnixEpoch).TotalSeconds) : -1;

    private static string CategoryName(ImportCategory category) => category switch
    {
        ImportCategory.Module => "module",
        ImportCategory.SongBook => "songBook",
        ImportCategory.Template => "template",
        _ => "image",
    };

    private static string ConditionName(ImportCondition condition) => condition switch
    {
        ImportCondition.Missing => "missing",
        ImportCondition.Outdated => "outdated",
        _ => "upToDate",
    };

    private static void Import(string dataPath)
    {
        P("# import");
        var fixtures = Environment.GetEnvironmentVariable("SLOVO_IMPORT_FIXTURES");
        if (fixtures is not { Length: > 0 })
        {
            P("import skipped: no SLOVO_IMPORT_FIXTURES");
            return;
        }
        var output = Environment.GetEnvironmentVariable("SLOVO_CHECK_OUT") is { Length: > 0 } custom ? custom : Path.GetTempPath();
        var work = Path.Combine(output, "slovo-check-import-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        string M(string text) => MaskPaths(text, (work, "<WORK>"), (fixtures, "<FX>"));
        string ItemLine(ImportItem item) =>
            M($"{item.Id} | {CategoryName(item.Category)} | {item.Title} | {item.Subtitle} | src {item.SourceUrl} | dst {item.DestinationUrl} | comp [{Join(item.Companions)}] | {ConditionName(item.Condition)} | {item.ByteSize} | {(item.SourceUrl.Contains("slovo-import-", StringComparison.Ordinal) ? "-" : UnixSeconds(item.Modified).ToString())} | sel {B(item.IsSelected)}");
        try
        {
            var src = Path.Combine(fixtures, "src");
            foreach (var (label, path, archives) in new[]
                     {
                         ("src", src, false), ("modules", Path.Combine(src, "Modules"), false), ("bq", Path.Combine(src, "Modules", "TestBQ"), false),
                         ("emptydir", Path.Combine(fixtures, "emptydir"), true), ("zipsonly", Path.Combine(fixtures, "zipsonly"), false),
                         ("zipsonly+", Path.Combine(fixtures, "zipsonly"), true), ("songsonly", Path.Combine(fixtures, "songsonly"), false),
                         ("missing", Path.Combine(fixtures, "nope"), true), ("file", Path.Combine(src, "VisioBible.ini"), true),
                     })
                P($"looks {label} {B(ModuleImporter.LooksLikeDataFolder(path, archives))}");

            var dst = Path.Combine(work, "dst");
            var destination = new ImportDestination(dst);
            Directory.CreateDirectory(Path.Combine(dst, "Modules"));
            Directory.CreateDirectory(Path.Combine(dst, "Templates"));
            Directory.CreateDirectory(Path.Combine(dst, "BackGrounds"));
            File.Copy(Path.Combine(src, "Modules", "vidrodzhennia.songbook"), Path.Combine(dst, "Modules", "vidrodzhennia.songbook"));
            File.SetLastWriteTimeUtc(Path.Combine(dst, "Modules", "vidrodzhennia.songbook"), new DateTime(2020, 1, 1, 0, 0, 0, DateTimeKind.Utc));
            File.WriteAllText(Path.Combine(dst, "Templates", "Autumn.sch"), "old");
            File.SetLastWriteTimeUtc(Path.Combine(dst, "Templates", "Autumn.sch"), new DateTime(2019, 12, 31, 23, 59, 0, DateTimeKind.Utc));
            File.WriteAllText(Path.Combine(dst, "BackGrounds", "a.jpg"), "a-old");
            File.SetLastWriteTimeUtc(Path.Combine(dst, "BackGrounds", "a.jpg"), new DateTime(2019, 1, 1, 0, 0, 0, DateTimeKind.Utc));
            P($"destination modules {M(destination.ModulesFolder)} templates {M(destination.TemplatesFolder)} backgrounds {M(destination.BackgroundsFolder)} plans {M(destination.PlansFolder)} safe {B(destination.IsSafeToWrite)} library {SwiftPath.LastComponent(ImportDestination.ApplicationLibrary.DataRoot)}");
            foreach (var path in new[] { "/Applications/VisioBible.app/Contents/Resources/app", "/Users/x/Library/Application Support/CrossOver/Bottles/b/drive_c/x", "/x/drive_c/y", "/Apps/Слово.app/Contents/data", "/Users/x/Data", "C:\\Users\\x\\AppData\\Roaming\\Slovo" })
                P($"safe {path} {B(new ImportDestination(path).IsSafeToWrite)}");

            var source = ModuleImporter.SourceAtFolder(src);
            P(M($"source {source.Kind} «{source.Version}» url {source.Url} origin {source.OriginUrl} id {source.Id} path {source.Path}"));
            foreach (var (label, action) in new (string, Func<ImportSource>)[]
                     {
                         ("again", () => ModuleImporter.SourceAtFolder(src, [source])),
                         ("emptydir", () => ModuleImporter.SourceAtFolder(Path.Combine(fixtures, "emptydir"))),
                         ("badini", () => ModuleImporter.SourceAtFolder(Path.Combine(fixtures, "badini"))),
                         ("file", () => ModuleImporter.SourceAt(Path.Combine(src, "Modules", "bel.songs.vbm"))),
                         ("zipsonly", () => ModuleImporter.SourceAt(Path.Combine(fixtures, "zipsonly"))),
                         ("archive", () => ModuleImporter.SourceAt(Path.Combine(fixtures, "olddata.zip"))),
                         ("archive again", () => ModuleImporter.SourceAtArchive(Path.Combine(fixtures, "olddata.zip"), [new ImportSource("v", "/x", Path.Combine(fixtures, "olddata.zip"), ImportSourceKind.Archive)])),
                         ("empty zip", () => ModuleImporter.SourceAtArchive(Path.Combine(fixtures, "empty.zip"))),
                         ("no modules zip", () => ModuleImporter.SourceAtArchive(Path.Combine(fixtures, "nomodules.zip"))),
                     })
            {
                try
                {
                    var found = action();
                    P(M($"source {label}: {found.Kind} «{found.Version}» url {(found.Kind == ImportSourceKind.Archive ? SwiftPath.LastComponent(found.Url) : found.Url)} origin {found.OriginUrl}"));
                    if (label is "zipsonly" or "archive")
                    {
                        var other = ModuleImporter.Inventory(found, destination);
                        P($"  inventory empty {B(other.IsEmpty)} modules {other.Modules.Count} templates {other.Templates.Count} images {other.Images.Count}");
                        foreach (var item in other.Modules.Concat(other.Templates).Concat(other.Images)) P("  " + ItemLine(item));
                    }
                }
                catch (ImportProblem problem)
                {
                    P(M($"source {label}: {problem.ProblemKind} {(problem.ProblemKind == ImportProblem.Kind.UnpackFailed ? problem.Path : problem.Message)} key {problem.MessageKey ?? "nil"}"));
                }
            }

            var inventory = ModuleImporter.Inventory(source, destination);
            P($"inventory empty {B(inventory.IsEmpty)} modules {inventory.Modules.Count} templates {inventory.Templates.Count} images {inventory.Images.Count} selected {inventory.Selected.Count} songs {inventory.SelectedIn(ImportCategory.SongBook).Count}");
            foreach (var item in inventory.Modules.Concat(inventory.Templates).Concat(inventory.Images)) P(ItemLine(item));
            foreach (var item in inventory.Modules) P($"validate {item.Id}: {(ModuleImporter.Validate(item) is { } reason ? M(Esc(reason)) : "ok")}");

            var steps = new List<string>();
            var outcome = ModuleImporter.Run(inventory, destination, (title, fraction) => steps.Add($"{title}@{(int)(fraction * 1000)}"));
            P($"run modules {Join(outcome.Modules, "|")} templates {Join(outcome.Templates, "|")} images {Join(outcome.Images, "|")} total {outcome.Total}");
            foreach (var failure in outcome.Failures) P(M($"run failure {failure.Title}: {Esc(failure.Reason)}"));
            P(M("run imported " + Join(outcome.ImportedModules, " ")));
            P("run steps " + Join(steps, " "));
            P("tree " + Join(Tree(dst), " "));
            P($"converted {SongDigest(SongBook.FromFile(Path.Combine(dst, "Modules", "bel.songs.songbook")))} kept {SongDigest(SongBook.FromFile(Path.Combine(dst, "Modules", "vidrodzhennia.songbook")))} module {Fnv(ModuleText(new BibleModule(Path.Combine(dst, "Modules", "TestBQ"))))}");
            var after = ModuleImporter.Inventory(source, destination);
            P("after " + Join(after.Modules.Concat(after.Templates).Concat(after.Images).Select(item => $"{item.Id}={ConditionName(item.Condition)}/{B(item.IsSelected)}"), " "));

            // Те, що вибрано вручну: лише одна картинка, при цьому галочку зняли з усього іншого.
            var manual = new ImportInventory(source, inventory.Modules.Select(item => item with { IsSelected = false }),
                                             inventory.Templates.Select(item => item with { IsSelected = false }),
                                             inventory.Images.Select(item => item with { IsSelected = item.Title == "a.jpg" }));
            var second = ModuleImporter.Run(manual, destination);
            P($"manual images {Join(second.Images)} total {second.Total} failures {second.Failures.Count} a.jpg «{File.ReadAllText(Path.Combine(dst, "BackGrounds", "a.jpg"))}»");
            var unsafeRun = ModuleImporter.Run(inventory, new ImportDestination("/x/drive_c/y"));
            P($"unsafe failures {Join(unsafeRun.Failures.Select(f => $"{f.Title}: {f.Reason}"), " | ")} total {unsafeRun.Total}");

            var language = new LanguageCatalog(Path.Combine(dataPath, "Language")).Language("ru");
            foreach (var problem in new[]
                     {
                         ImportProblem.NothingToImport("/a/b"), ImportProblem.BadConfig("/a/b"), ImportProblem.AlreadyAdded("/a/b"),
                         ImportProblem.UnpackFailed("x.zip", "причина"), ImportProblem.DestinationNotWritable("/a/b"),
                     })
                P($"problem {problem.ProblemKind} «{problem.Message}» key {problem.MessageKey ?? "nil"} path {problem.Path} ru «{Esc(problem.Localized(language))}» none «{problem.Localized(null)}» text «{Esc(ImportProblem.Text(problem, language))}»");
            P($"problem other «{ImportProblem.Text(SongBookError.InflateFailed(), language)}»");
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            try { Directory.Delete(work, recursive: true); } catch { }
        }
    }
}
