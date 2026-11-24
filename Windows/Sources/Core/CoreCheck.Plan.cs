// =============================================================================
//  CoreCheck.Plan.cs — перевірка ядра: план служіння (`--section plan`)
// =============================================================================
//  Дзеркало еталона на Mac (slovo-ref, Plan.swift). Файл плану порівнюється
//  байт у байт; мітка часу `savedAt` у виводі замінена на «<час>».
// =============================================================================

using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Slovo.Core;

public static partial class CoreCheck
{
    private static string MaskTime(string json) =>
        Regex.Replace(json, "\"savedAt\" : \"[^\"]*\"", "\"savedAt\" : \"<час>\"");

    private static string ItemLine(PlanItem item, bool withId = true)
    {
        var content = item.Kind switch
        {
            PlanItemKind.Scripture => $"module={item.Scripture!.ModuleID} book={item.Scripture.BookIndex} chapter={item.Scripture.Chapter} verses={Join(item.Scripture.Verses)}",
            PlanItemKind.Song => $"songBook={item.SongPart!.Value.BookFileName} song={item.SongPart.Value.SongIndex} part={I(item.SongPart.Value.PartIndex)} whole={B(item.SongPart.Value.IsWholeSong)}",
            PlanItemKind.Text => $"heading=«{Esc(item.PlainText!.Value.Title)}» body=«{Esc(item.PlainText.Value.Body)}»",
            _ => $"path={item.File!.Value.Path} name={item.File.Value.Name}",
        };
        var id = withId ? item.Id.ToString("D").ToUpperInvariant() + " " : "";
        return $"{id}{item.Kind.RawValue()} «{Esc(item.Title)}» sub «{(item.Subtitle == null ? "nil" : Esc(item.Subtitle))}» {content}";
    }

    private static string PlanState(ServicePlan plan) =>
        $"cur {I(plan.CurrentIndex)} unsaved {B(plan.HasUnsavedChanges)} next {B(plan.CanGoToNext)} prev {B(plan.CanGoToPrevious)} [{Join(plan.Items.Select(item => item.Title), "|")}]";

    private static void Plan(string dataPath, ModuleLibrary library)
    {
        P("# plan");
        var module = library.Modules.FirstOrDefault(m => m.Identifier == "ubt2020") ?? library.Modules[0];
        var songs = new SongLibrary(Path.Combine(dataPath, "Modules"));
        var songBookId = songs.Books[0].Id;
        var songBook = songs.Book(songBookId)!;
        var songFile = SwiftPath.LastComponent(songs.Books[0].Url);
        PlanItem Fixed(PlanItem item, int n) => item with { Id = Guid.Parse($"00000000-0000-4000-8000-{n:D12}") };

        var john = module.Books[Math.Min(42, module.Books.Count - 1)];
        var psalms = module.Books[Math.Min(18, module.Books.Count - 1)];
        var items = new List<PlanItem>
        {
            Fixed(PlanItem.ScriptureItem(module.Identifier, john, 3, [18, 16, 17, 16], "Бо так полюбив Бог світ,\nщо дав Сина\r\n"), 1),
            Fixed(PlanItem.ScriptureItem(module.Identifier, psalms, 23, []), 2),
            Fixed(PlanItem.SongPartItem(songFile, songBook.Songs[3], songBook.Songs[3].Parts[Math.Min(1, songBook.Songs[3].Parts.Count - 1)]), 3),
            Fixed(PlanItem.SongItem(songFile, songBook.Songs[5]), 4),
            Fixed(PlanItem.TextItem(new PlainTextDocument("Оголошення", "Після служіння — братське спілкування.\nВсі запрошені / ласкаво просимо")), 5),
            Fixed(PlanItem.TextItem(new PlainTextDocument("", "")), 6),
            Fixed(PlanItem.FileItem("/tmp/slides/Презентація.pptx", "  "), 7),
            Fixed(PlanItem.FileItem("/tmp/media/відео.mp4", " Проповідь "), 8),
            Fixed(PlanItem.SongPartItem(songFile, new Song(9, "", parts: [new SongPart(2, "  ", "Рядок 1\nРядок 2")]), new SongPart(2, "  ", "Рядок 1\nРядок 2")), 9),
            Fixed(PlanItem.SongItem(songFile, new Song(10, "")), 10),
        };
        items.AddRange(PlanItem.SongPartItems("/x/" + songFile, songBook, songBook.Songs[0]).Select((item, n) => Fixed(item, 20 + n)));
        foreach (var item in items) P("item " + ItemLine(item));

        foreach (var item in items.Take(4))
        {
            if (item.Scripture is { } scripture)
                P($"  resolve book={scripture.Book(module)?.FullName ?? "-"} verses={Join(scripture.VersesIn(module).Select(v => v.Number))} text=«{Esc(scripture.Text(module) ?? "nil")}» numbered=«{Esc(scripture.Text(module, withNumbers: true) ?? "nil")}»");
            if (item.SongPart is { } song)
                P($"  resolve file={(song.FileAmong(songs.Books.Select(b => b.Url).Prepend("/a/GLORY.SONGBOOK")) is { } f ? SwiftPath.LastComponent(f) : "-")} song={song.SongIn(songBook)?.Title ?? "-"} part={(song.PartIn(songBook) is { } p ? Esc(p.Kind) : "-")}");
        }
        var missing = new PlanScripture("x", 999, 1, [1]);
        P($"resolve missing {missing.Book(module)?.FullName ?? "-"} {missing.VersesIn(module).Count} {missing.Text(module) ?? "nil"} chapter0 {new PlanScripture("x", 0, 0).VersesIn(module).Count} absent {Join(new PlanScripture("x", 0, 1, [999, 2, 1]).VersesIn(module).Select(v => v.Number))}");

        ServicePlan.Clock = () => new DateTime(2026, 11, 23, 12, 0, 0, DateTimeKind.Utc);
        var plan = new ServicePlan("Недільне служіння / ранок", items);
        P($"plan {PlanState(plan)} count {plan.Count} empty {B(plan.IsEmpty)} current {plan.Current?.Title ?? "-"} id {plan.CurrentItemID?.ToString("D").ToUpperInvariant() ?? "-"}");
        var json = Encoding.UTF8.GetString(plan.JsonData());
        P(MaskTime(json));
        P($"json bytes {Encoding.UTF8.GetByteCount(MaskTime(json))} {Fnv(MaskTime(json))}");

        var folder = Path.Combine(Path.GetTempPath(), "slovo-check-plan-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var path = Path.Combine(folder, "Plans", ServicePlan.FileName(plan.Title));
            plan.Save(path);
            P($"saved {SwiftPath.LastComponent(plan.FileUrl!)} unsaved {B(plan.HasUnsavedChanges)} same bytes {B(File.ReadAllText(path) == json || MaskTime(File.ReadAllText(path)) == MaskTime(json))}");
            var back = ServicePlan.Read(path);
            P($"read back skipped {back.SkippedItems} has {B(back.HasSkippedItems)} warning {back.Warning ?? "nil"} title «{back.Plan.Title}» file {SwiftPath.LastComponent(back.Plan.FileUrl!)} {PlanState(back.Plan)}");
            foreach (var item in back.Plan.Items) P("  back " + ItemLine(item));
            P($"items equal {B(back.Plan.Items.SequenceEqual(plan.Items))} same as saved json {B(MaskTime(Encoding.UTF8.GetString(back.Plan.JsonData())) == MaskTime(json))}");
            var retitled = back.Plan.Copy();
            retitled.Title = "Інша назва";
            P($"retitled unsaved {B(retitled.HasUnsavedChanges)}");
            try { new ServicePlan().Save(); }
            catch (PlanError error) { P($"save no file: {error.Message} kind {error.ErrorKind}"); }

            var journal = plan.Journal();
            P(journal.Xml());
            var fromJournal = ServicePlan.FromJournal(journal);
            P($"journal back {PlanState(fromJournal)}");
            foreach (var item in fromJournal.Items) P("  journal " + ItemLine(item, withId: false));
            var journalPath = Path.Combine(folder, "Plans", "План.ini");
            plan.SaveAsJournal(journalPath);
            P($"journal saved {SwiftPath.LastComponent(plan.FileUrl!)} unsaved {B(plan.HasUnsavedChanges)}");
            var any = ServicePlan.ReadAny(journalPath);
            P($"readAny journal «{any.Plan.Title}» {any.SkippedItems} file {SwiftPath.LastComponent(any.Plan.FileUrl!)} {PlanState(any.Plan)}");
            var anyJson = ServicePlan.ReadAny(path);
            P($"readAny json «{anyJson.Plan.Title}» {anyJson.SkippedItems} {anyJson.Plan.Count}");

            var original = "\uFEFF<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<VisioBibleJournal>\r\n<Journal Name=\"Songs\">\r\n"
                           + "<Item Caption=\"Пісня перша\" Quote=\"Слова\" SongBook=\"pv3055.vbm\" Song=\"12\" Part=\"-1\"/>\r\n"
                           + "<Item Caption=\"\" SongBook=\"glory.vbm\" Song=\"-4\" Part=\"2\" Order=\"1\"/>\r\n<Item Caption=\"без збірника\"/>\r\n</Journal>\r\n"
                           + "<Journal Name=\"Bible\">\r\n<Item Caption=\"Ин.- Вначале было Слово\" Reference=\"\" Quote=\"Вначале было Слово\" Book=\"42\" Chapter=\"0\" Verse=\"0\" VersesRangeCount=\"2\"/>\r\n"
                           + "<Item Reference=\"Пс 22\" Book=\"18\" Chapter=\"21\" Verse=\"4\" VersesRangeCount=\"9999\" Order=\"0\"/>\r\n<Item Book=\"-1\"/>\r\n"
                           + "<Item Reference=\"\" Caption=\"\" Book=\"1\" Verses=\"3, 1-2\" Module=\"RST\"/>\r\n</Journal>\r\n"
                           + "<Journal Name=\"Text\">\r\n<Item Caption=\"Оголошення\" Reference=\"\" Quote=\"\"/>\r\n<Item Caption=\"\" Reference=\"Заголовок\" Quote=\"Текст\"/>\r\n"
                           + "<Item/>\r\n<Item Caption=\"\" File=\"/a/b/c.pptx\"/>\r\n<Item Caption=\"Файл\" File=\"/a/b/d.mp4\" Heading=\"x\" Body=\"y\" Order=\"2\"/>\r\n</Journal>\r\n</VisioBibleJournal>\r\n";
            var originalPath = Path.Combine(folder, "PlanDef.ini");
            File.WriteAllBytes(originalPath, Encoding.UTF8.GetBytes(original));
            var parsed = ServicePlan.ReadAny(originalPath);
            P($"original «{parsed.Plan.Title}» {PlanState(parsed.Plan)}");
            foreach (var item in parsed.Plan.Items) P("  original " + ItemLine(item, withId: false));

            string[] cases =
            [
                "[{\"type\":\"scripture\",\"book\":\"42\",\"chapter\":3.0,\"verses\":\"16-18, 20\"},{\"book\":1,\"chapter\":-1},{\"songBook\":\"a.vbm\",\"song\":\"2\",\"part\":1.9},{\"heading\":\"\",\"body\":\"\"},{\"path\":\"/x/y.mp4\"},{\"type\":\"video\"},7,null,{\"type\":\"SONG\",\"songBook\":\"\",\"song\":1,\"part\":1},{\"id\":\"dba9ab16-2069-4a30-8eba-78ead9e2f26c\",\"type\":\"text\",\"title\":\"  \",\"heading\":\"Заголовок\",\"body\":\"Тіло\"}]",
                "{\"title\":\"\",\"items\":[]}",
                "{\"format\":\"slovo.plan\"}",
                "{\"foo\":1}",
                "not json",
                "\"string\"",
                "{\"title\":\"T\",\"items\":{\"a\":1}}",
                "\uFEFF{\"title\":\"Перший\",\"title\":\"Другий\",\"items\":[{\"type\":\"scripture\",\"book\":0,\"chapter\":0,\"verses\":[3,1,2.0,],},],}",
                "{\"title\":5,\"items\":[{\"book\":1e2,\"chapter\":\"12\",\"verses\":5},{\"book\":3.7,\"chapter\":2,\"verses\":[1,2.5]},{\"book\":1,\"chapter\":1,\"verses\":\"-5-7;9 1--3 4-2, 1-9223372036854775807\"},{\"book\":1,\"chapter\":1,\"verses\":-1},{\"book\":1,\"chapter\":1,\"verses\":[-3,4]},{\"songBook\":\"s\",\"song\":1,\"part\":\"x\"},{\"songBook\":\"s\",\"song\":1,\"part\":null},{\"type\":\"file\",\"path\":\"\"},{\"type\":\"plaintext\"},{\"type\":\"bible\",\"book\":true,\"chapter\":1},{\"type\":\"verse\",\"book\":1,\"chapter\":1,\"title\":7,\"subtitle\":8,\"id\":5}]}",
                "{\"items\":[{\"book\":1e400,\"chapter\":1},{\"book\":-0,\"chapter\":-0.5},{\"book\":2,\"chapter\":\" 3 \"}]}",
            ];
            for (var n = 0; n < cases.Length; n++)
            {
                var file = Path.Combine(folder, $"case{n}.json");
                File.WriteAllBytes(file, Encoding.UTF8.GetBytes(cases[n]));
                try
                {
                    var result = ServicePlan.Read(file);
                    P($"case {n}: «{result.Plan.Title}» skipped {result.SkippedItems} warning {result.Warning ?? "nil"} {PlanState(result.Plan)}");
                    foreach (var item in result.Plan.Items)
                        P($"  {(item.Id == Guid.Parse("DBA9AB16-2069-4A30-8EBA-78EAD9E2F26C") ? "fixed-id " : "")}{ItemLine(item, withId: false)}");
                }
                catch (PlanError error)
                {
                    P($"case {n}: error {error.ErrorKind} {error.Message}");
                }
            }
            try { ServicePlan.Read(Path.Combine(folder, "нема.json")); }
            catch (PlanError error) { P($"missing file kind {error.ErrorKind} name {error.Name}"); }

            var plansDir = ServicePlan.PlansDirectory(folder);
            foreach (var (name, minutes) in new[] { ("a.json", 30), ("b.JSON", 10), ("c.json", 20), ("d.ini", 5), (".e.json", 1) })
            {
                var target = Path.Combine(plansDir, name);
                File.WriteAllText(target, "{}");
                File.SetLastWriteTimeUtc(target, new DateTime(2026, 1, 1, 0, minutes, 0, DateTimeKind.Utc));
            }
            P($"saved plans {Join(ServicePlan.SavedPlans(plansDir).Select(SwiftPath.LastComponent))} dir {SwiftPath.LastComponent(plansDir)}");
        }
        finally
        {
            try { Directory.Delete(folder, recursive: true); } catch { }
        }

        var nav = new ServicePlan("Навігація", items.Take(5));
        P($"nav start {PlanState(nav)}");
        P($"nav next {nav.GoToNext()?.Title ?? "nil"} {nav.GoToNext()?.Title ?? "nil"} {PlanState(nav)}");
        nav.Insert(items[5], 0);
        P($"nav insert0 {PlanState(nav)}");
        nav.Insert(items[6], 99);
        P($"nav insert99 {PlanState(nav)}");
        nav.Move([0, 2], 5);
        P($"nav move {PlanState(nav)}");
        nav.Move(4, 1);
        P($"nav move1 {PlanState(nav)}");
        nav.Move(1, 4);
        P($"nav move2 {PlanState(nav)}");
        nav.Move([9], 1);
        nav.Move([1], 99);
        P($"nav move bad {PlanState(nav)}");
        P($"nav remove {nav.RemoveAt(2)?.Title ?? "nil"} {nav.RemoveAt(99)?.Title ?? "nil"} {PlanState(nav)}");
        nav.RemoveAt([0, 1, 50]);
        P($"nav remove offsets {PlanState(nav)}");
        nav.Select(99);
        P($"nav select99 {PlanState(nav)} prev {nav.GoToPrevious()?.Title ?? "nil"} {PlanState(nav)}");
        nav.Select(nav.Items[0].Id);
        P($"nav select id {PlanState(nav)} prev {nav.GoToPrevious()?.Title ?? "nil"}");
        nav.Remove(nav.Items[0].Id);
        nav.Replace(0, items[7]);
        nav.Replace(9, items[7]);
        P($"nav replace {PlanState(nav)} at0 {nav[0]?.Title ?? "nil"} at9 {nav[9]?.Title ?? "nil"}");
        nav.Append(items[8]);
        nav.Append([items[9], items[1]]);
        nav.Append(Array.Empty<PlanItem>());
        P($"nav append {PlanState(nav)}");
        nav.RemoveAll();
        P($"nav cleared {PlanState(nav)} next {nav.GoToNext()?.Title ?? "nil"}");
        nav.Append(items[0]);
        P($"nav append after clear {PlanState(nav)}");
        var copy = nav.Copy();
        copy.Append(items[1]);
        P($"copy independent {nav.Count} {copy.Count} equal {B(nav.Equals(nav.Copy()))}");

        P($"format {PlanItem.FormatVerses([7, 3, 1, 2, 3, -1, 9, 8])} | {PlanItem.FormatVerses([])} | {PlanItem.FormatVerses([5])}");
        foreach (var text in new[] { "1-3, 7", "-5-7;9 1--3 4-2", "", "x,1,,2- 4", "3-1000000", " 10 - 12 ", "1-9223372036854775807" })
            P($"parse «{text}» → {Join(PlanItem.ParseVerses(text).Take(12))} ({PlanItem.ParseVerses(text).Count})");
        foreach (var title in new[] { "Недільне служіння / ранок", "  ", "a:b*c?\"d\"<e>|f\\g", "Табуляція\tі\u0007дзвінок", "План" })
            P($"fileName «{Esc(title)}» → {ServicePlan.FileName(title)}");
        P($"reference {PlanItem.Reference(john, 3, [16, 17, 18, 20])} {PlanItem.Reference(john, 3, [])}");
        P($"kinds {Join(PlanItemKinds.All.Select(kind => $"{kind.RawValue()}={kind.Title()}"))}");
        P($"errors {PlanError.NotAPlan().Message} | {PlanError.Unreadable("a.json", "причина").Message} | {PlanError.UnsupportedItem("x").Message} | {PlanError.NoFile().Message}");
        P($"names {ServicePlan.FormatMarker} {ServicePlan.FormatVersion} {ServicePlan.FileExtension} {ServicePlan.FolderName} {ServicePlan.DefaultFileName} {ServicePlan.JournalFileExtension}");
    }
}
