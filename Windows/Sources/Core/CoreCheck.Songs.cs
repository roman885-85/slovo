// =============================================================================
//  CoreCheck.Songs.cs — перевірка ядра: пісенники (`--section songs`)
// =============================================================================
//  Те саме друкує еталон на Mac (slovo-ref, Songs.swift) — вивід звіряється
//  `diff`-ом. Розділи `vbmwrite` / `vbmread` — перехресна перевірка формату:
//  одна програма пише `.vbm` у теку $SLOVO_CHECK_OUT, друга читає.
// =============================================================================

using System.Globalization;
using System.Text;
using Microsoft.Data.Sqlite;

namespace Slovo.Core;

public static partial class CoreCheck
{
    /// Рядок для звірки: переноси видимими знаками, щоб вивід лишався рядковим.
    private static string Esc(string text) => text.Replace("\r", "␍").Replace("\n", "⏎");

    private static string FnvBytes(byte[] bytes)
    {
        var hash = 0xcbf29ce484222325UL;
        foreach (var b in bytes)
        {
            hash ^= b;
            hash = unchecked(hash * 0x100000001b3UL);
        }
        return hash.ToString("x16");
    }

    private static string Hex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();

    private static string Rgb(SlideStyle.RGBA? color) => color is { } c
        ? $"{Channel(c.Red)}/{Channel(c.Green)}/{Channel(c.Blue)}/{Channel(c.Alpha)}"
        : "-";

    private static int Channel(double value) => (int)Math.Round(value * 255, MidpointRounding.AwayFromZero);

    private static string SongLine(Song song)
    {
        var text = new StringBuilder();
        text.Append($"S{song.Index}\u0001{song.Title}\u0001{song.AlternateTitle}\u0001{song.Author}\u0001{song.Composer}\u0001{song.Note}\u0001{song.Properties}\n");
        foreach (var part in song.Parts) text.Append($"P{part.Index}\u0001{part.Kind}\u0001{part.Text}\u0001{(uint)part.Align}\n");
        return text.ToString();
    }

    private static string SongDigest(SongBook book)
    {
        var text = new StringBuilder();
        text.Append($"{book.Title}\u0001{book.ShortName}\u0001{book.Publisher}\u0001{book.RevisionDate}\u0001{book.Comment}\u0001{book.FormatVersion}\u0001{book.Flags}\u0001{book.Charset}\n");
        foreach (var song in book.Songs) text.Append(SongLine(song));
        foreach (var group in book.Groups) text.Append($"G{group.Name}\u0001{Join(group.SongIndices)}\n");
        return Fnv(text.ToString());
    }

    private static string ReasonName(SongMatch.Reasons reason) => reason switch
    {
        SongMatch.Reasons.Listing => "listing",
        SongMatch.Reasons.Number => "number",
        SongMatch.Reasons.CatalogNumber => "catalogNumber",
        SongMatch.Reasons.Title => "title",
        SongMatch.Reasons.AlternateTitle => "alternateTitle",
        _ => "author",
    };

    private static void PrintSong(Song song, SongTitleFormat format, SongChunkPalette palette, string indent = "  ")
    {
        P($"{indent}song {song.Index} n{song.Number} cat {I(song.CatalogNumber)} «{Esc(song.Title)}» alt «{Esc(song.AlternateTitle)}» by «{Esc(song.Author)}» / «{Esc(song.Composer)}» note «{Esc(song.Note)}» sub {song.Subtitle ?? "-"} first «{Esc(song.FirstLine)}» tune «{song.Tune}» catText «{song.CatalogNumberText}» list «{format.Title(song)}»");
        P($"{indent}  props {Join(song.PropertyPairs.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => $"{pair.Key}={pair.Value}"), ";")} raw «{Esc(song.Properties)}»");
        foreach (var part in song.Parts)
            P($"{indent}  part {part.Index} «{Esc(part.Kind)}» {(uint)part.Align} chunk {palette.ChunkFor(part.Kind)?.Key ?? "-"} lines {part.Lines.Length} «{Esc(part.Text)}»");
    }

    private static readonly string[] SongQueries =
        ["1", "12", "100", "бог", "Бог", "ГОСПОДЬ", "spiewnik", "ё", "Ісус", "иисус", "  ", "", "xyz", "1728", "+5", "Ｇｏｄ", "lord", "Свят"];

    private static void Songs(string dataPath)
    {
        P("# songs");
        var config = IniSettings.FromFile(Path.Combine(dataPath, "Slovo.ini"));
        var palette = new SongChunkPalette(config);
        var format = new SongTitleFormat(config);
        var library = new SongLibrary(Path.Combine(dataPath, "Modules"));
        P($"library {library.Books.Count}: " + Join(library.Books.Select(entry => entry.Id)));
        P($"titleFormat {B(format.ShowsNumber)} {B(format.DotAfterNumber)} {B(format.NumberInBrackets)} {format.NumberText(7)} {new SongTitleFormat(numberInBrackets: true).NumberText(7)} {new SongTitleFormat(dotAfterNumber: false).NumberText(7)}");
        var composers = new (string Name, SongSlideComposer Composer)[]
        {
            ("default", new SongSlideComposer()),
            ("config", new SongSlideComposer(config)),
            ("split", new SongSlideComposer(new SongSlideComposer.Options(splitsLongParts: true, linesPerPage: 2, showsNumber: true,
                                                                          showsTitle: true, showsBookShortName: true, endMarker: "***"), palette)),
        };
        var loaded = new List<(string Id, SongBook Book)>();
        foreach (var id in library.Books.Select(entry => entry.Id).ToList())
        {
            var book = library.Book(id);
            var entry = library.EntryFor(id)!.Value;
            P($"book {entry.Id} | {SwiftPath.LastComponent(entry.Url)} | {Esc(entry.Title)} | {Esc(entry.ShortName)} | {Esc(entry.Publisher)} | {Esc(entry.RevisionDate)} | {Esc(entry.Comment)} | count {I(entry.SongCount)} loaded {B(entry.IsLoaded)} | {Esc(entry.DisplayName)}");
            if (book == null)
            {
                P($"  failure {entry.Failure}");
                continue;
            }
            loaded.Add((id, book));
            P($"  songs {book.Songs.Count} parts {book.Songs.Sum(song => song.Parts.Count)} groups {book.Groups.Count} header {book.FormatVersion} {book.Flags} {book.Charset} digest {SongDigest(book)}");
            foreach (var group in book.Groups) P($"  group {Esc(group.Name)}: {Join(group.SongIndices)}");
            var picks = new SortedSet<int> { 0, 1, 2, book.Songs.Count - 1 }.Where(index => index >= 0 && index < book.Songs.Count).ToList();
            foreach (var index in picks) PrintSong(book.Songs[index], format, palette);

            foreach (var query in SongQueries)
            {
                var found = library.Search(query, id);
                P($"  search «{query}» {found.Count}: " + Join(found.Take(6).Select(match => $"{match.Id}:{ReasonName(match.Reason)}"), " "));
            }
            P($"  numbered 5 {library.SongNumbered(5, id)?.Index.ToString(CultureInfo.InvariantCulture) ?? "-"} 99999 {library.SongNumbered(99999, id)?.Index.ToString(CultureInfo.InvariantCulture) ?? "-"} at 3 {library.SongAt(3, id)?.Title ?? "-"}");

            var richest = book.Songs.Count == 0 ? -1 : book.Songs.FindIndex(song => song.Parts.Count == book.Songs.Max(other => other.Parts.Count));
            var slideSongs = new SortedSet<int> { 0, book.Songs.Count - 1, richest }.Where(index => index >= 0 && index < book.Songs.Count).ToList();
            foreach (var (name, composer) in composers)
            {
                foreach (var index in slideSongs)
                {
                    var song = book.Songs[index];
                    var slides = composer.Slides(song, book.ShortName);
                    P($"  slides {name} {song.Index}: {slides.Count} part1 {composer.SlidesForPart(1, song, book.ShortName).Count}");
                    foreach (var slide in slides)
                        P($"    {slide.Id} {slide.PageCount} {B(slide.IsSinglePage)} «{Esc(slide.PartKind)}» {slide.ChunkKey ?? "-"} {Rgb(slide.Color)} blank {B(slide.Slide.IsBlank)} ref «{slide.Slide.Reference}» «{Esc(slide.Slide.MainText)}»");
                }
            }

            var json = SongBookJSON.Data(book);
            P($"  json {json.Length} {FnvBytes(json)} back {SongDigest(SongBookJSON.Book(json, "x"))}");
            var vbm = SongBookWriter.Data(book);
            var compressed = (int)BitConverter.ToUInt32(vbm, 20);
            var start = vbm.Length - 4 - compressed;
            var body = Inflate.Zlib(vbm[start..]);
            P($"  vbm head {Hex(vbm[..20])} {BitConverter.ToUInt32(vbm, 24)} {Hex(vbm[28..72])} names {Hex(vbm[72..start])} tail {Hex(vbm[^4..])} body {body.Length} {FnvBytes(body)} back {SongDigest(SongBook.FromData(vbm, "x"))}");

            var exported = SongBookTextFile.ExportWithServiceInfo(book);
            var reimported = SongBookTextFile.Songs(exported, palette);
            var differing = Enumerable.Range(0, Math.Min(reimported.Count, book.Songs.Count))
                .Count(index => SongLine(reimported[index]) != SongLine(book.Songs[index]));
            var rebook = book.Copy();
            rebook.Songs = reimported;
            P($"  text {Encoding.UTF8.GetByteCount(exported)} {Fnv(exported)} songs {reimported.Count} differing {differing} digest {SongDigest(rebook)}");
            P($"  plain {Fnv(SongBookTextFile.ExportPlain(book))} {Fnv(SongBookTextFile.ExportPlain(book, SongBookTextFile.Numbering.Catalog))}");
        }
        library.UnloadAll();
        P($"after unload: " + Join(library.Books.Select(entry => $"{entry.Id}={B(entry.IsLoaded)}")));
        P($"entry by file: {library.EntryForFileName("GLORY.VBM")?.Id ?? "-"} {library.EntryForFileName("pv3055.songbook")?.Id ?? "-"} {library.EntryForFileName("nope.vbm")?.Id ?? "-"} cache {library.CacheLimit}");

        SongEditing(loaded, palette, format);
        SongFormatting(palette);
        SongImports(dataPath, palette, format);
    }

    private static void SongEditing(List<(string Id, SongBook Book)> loaded, SongChunkPalette palette, SongTitleFormat format)
    {
        P("# songs editing");
        var chosen = loaded.Where(item => item.Book.Songs.Count >= 6).Take(2).ToList();
        if (loaded.Count > 0) chosen.Add(loaded.OrderByDescending(item => item.Book.Songs.Count).First());
        foreach (var (id, original) in chosen)
        {
            P($"edit {id}");
            var originalDigest = SongDigest(original);
            var editor = new SongBookEditor(original, "/tmp/" + id + ".vbm");
            string Groups() => Join(editor.Book.Groups.Select(group => $"{group.Name}[{Join(group.SongIndices)}]"), " ");
            string Titles(int count) => Join(editor.Book.Songs.Take(count).Select(song => $"{song.Index}:{song.Title}"), "|");
            P($"  modified {B(editor.IsModified)} url {editor.Url}");
            var g = editor.AddGroup("Тест");
            editor.AddSong(5, g);
            editor.AddSong(0, g);
            editor.AddSong(3, g);
            editor.AddSong(3, g);
            editor.AddSong(999999, g);
            var g2 = editor.AddGroup("Другий");
            editor.AddSong(1, g2);
            P($"  groups {Groups()} modified {B(editor.IsModified)} in group {Join(editor.SongIndices(g))} all {editor.SongIndices(null).Count} bad {editor.SongIndices(99).Count}");
            P($"  dup group {I(editor.DuplicateGroup(g))} {Groups()}");
            P($"  move group {I(editor.MoveGroup(0, 1))} {I(editor.MoveGroup(0, -1))} {Groups()}");
            editor.RenameGroup(1, "Перейменована");
            editor.RemoveSong(0, 1);
            P($"  renamed {Groups()} isSong {B(editor.IsSong(5, 1))} {B(editor.IsSong(0, 1))}");
            var inserted = editor.InsertSong(new Song(0, "Нова пісня", author: "Я", parts: [new SongPart(0, "Куплет 1", "Рядок один\r\nРядок два"), new SongPart(1, "Припев", "Хор")]), 2);
            P($"  insert {inserted} {Groups()} {Titles(5)}");
            editor.RemoveSong(1);
            P($"  remove {Groups()} {Titles(4)}");
            P($"  dup song {I(editor.DuplicateSong(0))} {I(editor.DuplicateSong(0))} {Titles(4)} {Groups()}");
            P($"  position {I(editor.SetSongPosition(0, 4))} {Titles(5)} {Groups()}");
            P($"  move {I(editor.MoveSong(3, -1))} {I(editor.MoveSong(0, -1))} {Titles(5)} {Groups()}");
            editor.ShiftCatalogNumbers(2, 10);
            P($"  shift {Join(editor.Book.Songs.Take(6).Select(song => song.CatalogNumberText), ",")}");
            editor.ShiftCatalogNumbers(0, -100000);
            P($"  shift down {Join(editor.Book.Songs.Take(6).Select(song => song.CatalogNumberText), ",")}");
            editor.SetCatalogNumbersToOrdinal();
            P($"  ordinal {Join(editor.Book.Songs.Take(6).Select(song => song.CatalogNumberText), ",")} {Esc(editor.Book.Songs[0].Properties)}");
            editor.ClearCatalogNumbers();
            P($"  cleared {Join(editor.Book.Songs.Take(6).Select(song => song.CatalogNumberText), ",")} «{Esc(editor.Book.Songs[0].Properties)}»");
            var target = 2;
            P($"  part insert {I(editor.InsertPart(new SongPart(9, "Бридж", "Міст  через\nрічку"), target, 1))} dup {I(editor.DuplicatePart(0, target))} move {I(editor.MovePart(0, target, 2))} {I(editor.MovePart(0, target, -1))}");
            editor.RemovePart(1, target);
            editor.SetAlign(SongPartAlign.Center, 0, target);
            editor.Format(SongTextFormat.ByLiters, 1, target);
            editor.Format(SongTextFormat.ByOptimalSize, 0, target);
            editor.UpdatePart(2, target, (ref SongPart part) => part.Kind = "Змінено");
            editor.UpdateSong(target, song => song.Title += " (змінено)");
            PrintSong(editor.Book.Songs[target], format, palette, "  ");
            editor.Unformat(0, target);
            editor.FormatSong(SongTextFormat.ByLiters, 3);
            PrintSong(editor.Book.Songs[3], format, palette, "  ");
            editor.UnformatSong(3);
            P($"  unformat «{Esc(editor.Book.Songs[target].Parts[0].Text)}» «{Esc(editor.Book.Songs[3].Parts.FirstOrDefault().Text ?? "")}»");
            P($"  refrain {editor.DuplicateRefrain(target)} {editor.DuplicateRefrain(target, "через")} all {editor.DuplicateRefrainsInAllSongs(palette: palette)} marker {editor.DuplicateRefrainsInAllSongs("Господь", palette)}");
            P($"  after refrain {SongDigest(editor.Book)}");
            editor.SortSongs(SongBookEditor.SongSort.ByTitle);
            P($"  by title {SongDigest(editor.Book)} {Titles(8)} {Groups()}");
            editor.SortSongs(SongBookEditor.SongSort.ByNumber);
            P($"  by number {SongDigest(editor.Book)} {Titles(8)} {Groups()}");
            var fresh = new SongBookEditor(original, null);
            fresh.SortSongs(SongBookEditor.SongSort.ByNumber);
            P($"  original by number {SongDigest(fresh.Book)} {Join(fresh.Book.Songs.Take(8).Select(song => $"{song.CatalogNumberText}:{song.Title}"), "|")}");
            fresh.SortSongs(SongBookEditor.SongSort.ByTitle);
            P($"  original by title {SongDigest(fresh.Book)} {Join(fresh.Book.Songs.Take(12).Select(song => song.Title), "|")}");
            fresh.FormatAllSongs(SongTextFormat.ByOptimalSize);
            P($"  format all optimal {SongDigest(fresh.Book)}");
            fresh.FormatAllSongs(SongTextFormat.ByLiters);
            P($"  format all liters {SongDigest(fresh.Book)}");
            fresh.UnformatAllSongs();
            P($"  unformat all {SongDigest(fresh.Book)}");
            editor.UpdateAttributes("Нова назва", "НН", "Видавець", "2026", "Примітка", 1);
            P($"  attributes {SongDigest(editor.Book)} original untouched {B(SongDigest(original) == originalDigest)}");
            var destination = loaded[0].Book.Copy();
            var turn = 0;
            var counts = SongBookEditor.CopySongs([2, 0, 5, 0, 999], original, destination, _ => (turn++ % 3) switch
            {
                0 => SongBookEditor.CopyConflict.Overwrite,
                1 => SongBookEditor.CopyConflict.Skip,
                _ => SongBookEditor.CopyConflict.Append,
            });
            P($"  copy {counts.Added} {counts.Overwritten} asked {turn} {SongDigest(destination)}");
            var self = original.Copy();
            var again = SongBookEditor.CopySongs([0, 1], original, self, _ => SongBookEditor.CopyConflict.Append);
            P($"  copy self {again.Added} {again.Overwritten} {self.Songs.Count} {Join(self.Songs.Skip(self.Songs.Count - 2).Select(song => $"{song.Index}:{song.Title}"), "|")}");
        }
        var empty = SongBookEditor.NewBook("Новий", "Н");
        var newEditor = new SongBookEditor(empty, null);
        newEditor.SortSongs(SongBookEditor.SongSort.ByTitle);
        P($"new book {SongDigest(newEditor.Book)} modified {B(newEditor.IsModified)} index {newEditor.AppendSong(new Song(5, "Одна"))} {newEditor.Book.Songs[0].Index}");
        try { newEditor.Save(); }
        catch (SongBookError error) { P($"save without url: {error.Message}"); }
    }

    private static void SongFormatting(SongChunkPalette palette)
    {
        P("# songs formatting");
        string[] samples =
        [
            "Боже, я Тебе люблю\nІ серцем, і душею\r\nХвалу Тобі співаю",
            "  один   два\tтри\u000Bчотири  \r\n\r\n п'ять",
            "ВІН ЖИВИЙ! він воскрес. Алилуя Амінь",
            "",
            "слово",
            "Ångström élan Ünter ǅungla «Лапки» Ⅻ ⓐ Ⓐ 1Друге",
            "á b́c É Éd",
            "Хвала Тобі, Господи, хвала Тобі навіки, бо Ти великий і святий, і милість Твоя вічна",
            "Слава Богу за все що Він зробив для нас у цьому житті і в майбутньому віці",
        ];
        foreach (var sample in samples)
            P($"format «{Esc(sample)}» un «{Esc(SongTextFormatter.Unformat(sample))}» lit «{Esc(SongTextFormatter.ByLiters(sample))}» opt «{Esc(SongTextFormatter.ByOptimalSize(sample))}» opt10 «{Esc(SongTextFormatter.ByOptimalSize(sample, 10))}»");

        var text = "вступ без назви\r\n\r\n#Куплет 1\r\n$Align$=Center\r\nРядок\r\n\r\nПриспів\nТекст приспіву\n#Своя назва \n$Foo$=bar\nМостом шли\nМост\n$ALIGN$=left\nкінець\r#\n#Verse 3.\n\n";
        var parts = SongTextMarkup.Parts(text, palette);
        foreach (var part in parts) P($"markup part {part.Index} «{Esc(part.Kind)}» {(uint)part.Align} «{Esc(part.Text)}»");
        P($"markup text «{Esc(SongTextMarkup.Text(parts))}»");
        P($"markup default {SongTextMarkup.Parts(text).Count} empty {SongTextMarkup.Parts("").Count} blank {SongTextMarkup.Parts("\n\n").Count}");
        foreach (var line in SongTextMarkup.Markup(text + "\u2028Кода\u2029$X$=1\r\n#Приспів:", palette))
            P($"markup line {line.Start} {line.Length} {line.Role.Kind} {Rgb(line.Role.Color)}");

        var file = "\uFEFFпреамбула\r\n---\r\nПерша\r\n$AltTitle$=Друга назва\r\n$Poet$=Автор\r\n$Composer$=Композитор\r\n$DateCreate$=03.12.2013\r\n$Tune$=C\r\n$ID$=12\r\n$Custom$=x\r\n#Куплет 1\r\n$Align$=Left\r\nРядок 1\r\n\r\n#Приспів\r\nПри\r\n----\r\n---\r\n\r\n---\r\n Пробіл\r\n\r\n$Note$=стара\r\nбез частин\r\nПриспів\r\nхор\r\n";
        var songs = SongBookTextFile.Songs(file, palette);
        P($"textfile songs {songs.Count}");
        foreach (var song in songs) PrintSong(song, new SongTitleFormat(), palette, "  ");
        var book = new SongBook("Т", "т", groups: [new SongGroup("Г", [0, 1, 7])], songs: [new Song(0, "Стара")]);
        P($"import append {SongBookTextFile.ImportSongs(file, book, SongBookTextFile.ImportMode.Append, palette)} {book.Songs.Count} {Join(book.Songs.Select(song => song.Index))} groups {Join(book.Groups[0].SongIndices)}");
        P($"import replace {SongBookTextFile.ImportSongs(file, book, SongBookTextFile.ImportMode.Replace, palette)} {book.Songs.Count} groups [{Join(book.Groups[0].SongIndices)}] none {SongBookTextFile.ImportSongs("без пісень", book, SongBookTextFile.ImportMode.Replace)}");
        P($"export «{Esc(SongBookTextFile.ExportWithServiceInfo(book))}»");
        P($"plain «{Esc(SongBookTextFile.ExportPlain(book, SongBookTextFile.Numbering.Catalog))}»");
        var aligns = SongPartAligns.All.Select(align => $"{(uint)align}:{align.ExportName() ?? "-"}");
        P($"aligns {Join(aligns, " ")} parse {Join(new[] { " Left ", "RIGHT", "center", "", "middle" }.Select(name => SongPartAligns.FromExportName(name) is { } a ? ((uint)a).ToString(CultureInfo.InvariantCulture) : "nil"))}");
        var props = new Song(0, "x", properties: "$ID$=1\r\n$TUNE$= G \n\n$ID$=2\rfoo=bar\n $X$=a=b");
        P($"props {Join(props.PropertyPairs.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => $"{pair.Key}={pair.Value}"), ";")} cat {I(props.CatalogNumber)} tune «{props.Tune}»");
        props.SetProperty("ID", "5");
        props.SetProperty("$X$", "");
        P($"props set «{Esc(props.Properties)}»");
        P($"subtitle «{new Song(0, "a", author: "Іван", composer: "Іван").Subtitle}» «{new Song(0, "a", author: "", composer: "Петро").Subtitle}» «{new Song(0, "a", author: "Й", composer: "Й").Subtitle}» «{new Song(0, "a").Subtitle ?? "nil"}»");
    }

    private static string FailureName(SongBookImporter.Failure.Kind kind) => kind switch
    {
        SongBookImporter.Failure.Kind.CannotOpen => "cannotOpen",
        SongBookImporter.Failure.Kind.NotASongSource => "notASongSource",
        SongBookImporter.Failure.Kind.Empty => "empty",
        SongBookImporter.Failure.Kind.UnexpectedStructure => "unexpectedStructure",
        _ => "unsupportedVersion",
    };

    private static void SongImports(string dataPath, SongChunkPalette palette, SongTitleFormat format)
    {
        P("# songs import");
        foreach (var test in SoftProjectorSelfTest.Run())
            P($"selftest {test.Name} | expects {B(test.ExpectsSuccess)} passed {B(test.Passed)} | {test.Outcome}");

        var folder = Path.Combine(Path.GetTempPath(), "slovo-check-sps-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var text1 = "##4\r\n##Євангельські пісні\r\n##Опис@%другий рядок\r\n"
                        + "1#$#Велика благодать#$#кат#$#G#$#Слова#$#Музика#$#Куплет 1.@%Рядок один@%Рядок два@$Приспів:@%Хор співає@$&Приспів@%ще#$#нотатка@%два#$#0#$#Arial\r\n"
                        + "#$#без номера#$#к#$##$##$##$#Verse 2@%a\r\n"
                        + "не пісня\r\n"
                        + " 12 #$#  Третя  #$#к#$#Am#$#А#$#М#$#Перший рядок@%другий@$@%Третій блок#$#\r\n";
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n<spSongBook version=\"2.0\"><SongBook><name>Збірка XML</name><about>Опис\nу два рядки</about></SongBook>"
                      + "<Song><number> 7 </number><title>Пісня</title><lyrics>Verse 1\nрядок &amp; ще\n&amp;Chorus\nхор</lyrics><key>D</key><poet>Поет</poet><note>н</note><created>2020</created></Song>"
                      + "<song number=\"x\"><songtitle>Друга</songtitle><text>a@%b@$c</text></song><Song number=\"9\"><body/></Song></spSongBook>";
            var files = new List<(string Name, byte[] Data)>
            {
                ("v1-utf8.sps", [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes(text1)]),
                ("v1-cp1251.sps", CodePage.WindowsCP1251.GetBytes(text1)),
                ("v1-empty.sps", Encoding.UTF8.GetBytes("##0\r\n##Порожній\r\n")),
                ("xml-utf16.sps", [0xFF, 0xFE, .. Encoding.Unicode.GetBytes(xml)]),
                ("xml-noroot.sps", Encoding.UTF8.GetBytes("<?xml version=\"1.0\"?><root><Song><title>a</title></Song></root>")),
                ("xml-nosongs.sps", Encoding.UTF8.GetBytes("\n  <spSongBook version=\"1\"><SongBook><title>T</title></SongBook></spSongBook>")),
                ("xml-broken.sps", Encoding.UTF8.GetBytes("<?xml version=\"1.0\"?><spSongBook><Song><title>x</title></spSongBook>")),
                ("junk.sps", [0x4A, 0x55, 0x4E, 0x4B, 0x01, 0x02, 0xFF, 0x20, 0x7E, 0x7F, .. Encoding.UTF8.GetBytes("Привіт, це не пісенник зовсім")]),
            };
            foreach (var (name, bytes) in files) File.WriteAllBytes(Path.Combine(folder, name), bytes);
            MakeSqlite(Path.Combine(folder, "db-custom.sps"), 1,
                       "CREATE TABLE Extra (a TEXT);"
                       + "CREATE TABLE \"SongBook\" (Name TEXT, Description TEXT);"
                       + "INSERT INTO SongBook VALUES ('Своя база', 'Опис\n\nбази');"
                       + "CREATE TABLE Hymns (num TEXT, Song_Title TEXT, LYRICS TEXT, author TEXT, composer TEXT, comment TEXT, created TEXT, key TEXT);"
                       + "INSERT INTO Hymns VALUES ('12a', 'Перший', 'Строфа один\nрядок\n\nСтрофа два', 'А', 'К', 'нотатка\nдва', '2001', 'E');"
                       + "INSERT INTO Hymns VALUES (' 7 ', '', 'Chorus 2:\nхор', NULL, NULL, NULL, NULL, NULL);"
                       + "INSERT INTO Hymns VALUES (NULL, '', '', '', '', '', '', '');"
                       + "INSERT INTO Hymns VALUES (3.7, 'Дробовий', 'Slide 1\nвставка\nEnding\nкінець', '', '', '', '', '');");
            MakeSqlite(Path.Combine(folder, "db-notable.sps"), 2,
                       "CREATE TABLE Alpha (id INTEGER, caption TEXT, note TEXT); CREATE TABLE Beta (x INTEGER);");
            MakeSqlite(Path.Combine(folder, "db-future.sps"), 3, "CREATE TABLE Songs (title TEXT, song_text TEXT);");
            MakeSqlite(Path.Combine(folder, "db-empty.sps"), 2, "CREATE TABLE Songs (title TEXT, song_text TEXT);");
            MakeSqlite(Path.Combine(folder, "db-blank.sps"), 2, "");
            MakeSqlite(Path.Combine(folder, "db-norows.sps"), 2, "CREATE TABLE Songs (title TEXT, song_text TEXT); INSERT INTO Songs VALUES ('', '');");

            foreach (var path in Directory.GetFiles(folder).OrderBy(path => path, StringComparer.Ordinal))
            {
                var name = SwiftPath.LastComponent(path);
                try
                {
                    var raw = SongBookImporter.ReadSoftProjector(path);
                    P($"sps {name}: origin «{raw.Origin}» title «{raw.Title}» info «{Esc(raw.Info)}» rows {raw.Songs.Count} | "
                      + Join(raw.Songs.Select(row => $"{I(row.Number)}/{Esc(row.Title)}/{Esc(row.Tune)}/{Esc(row.Words)}/{Esc(row.Music)}/{Esc(row.Notes)}/{Esc(row.Date)}/{Esc(row.Text)}"), " ; "));
                    var book = SongBookImporter.FromSoftProjector(path, palette);
                    P($"  book «{book.Title}» «{book.ShortName}» «{Esc(book.Comment)}» songs {book.Songs.Count} digest {SongDigest(book)}");
                    foreach (var song in book.Songs) PrintSong(song, format, palette, "  ");
                }
                catch (SongBookImporter.Failure failure)
                {
                    var message = failure.Message.Contains("XML не разобрался", StringComparison.Ordinal) ? "XML не разобрался" : Esc(failure.Message);
                    P($"sps {name}: failure {FailureName(failure.FailureKind)} | {message}");
                }
            }
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            try { Directory.Delete(folder, recursive: true); } catch { }
        }

        var gyzha = Path.Combine(dataPath, "Modules", "UA_Gyzha");
        foreach (var (path, marker) in new (string, string?)[] { (gyzha, null), (Path.Combine(gyzha, "bibleqt.ini"), "Господь"), (gyzha, "  ") })
        {
            try
            {
                var book = SongBookImporter.FromBibleQuote(path, marker, palette);
                P($"bq «{marker ?? "nil"}» «{book.Title}» «{book.ShortName}» «{book.Publisher}» «{book.Comment}» songs {book.Songs.Count} parts {book.Songs.Sum(song => song.Parts.Count)} digest {SongDigest(book)}");
                foreach (var index in new[] { 0, 1, book.Songs.Count - 1 }) PrintSong(book.Songs[index], format, palette, "  ");
            }
            catch (SongBookImporter.Failure failure)
            {
                P($"bq failure {FailureName(failure.FailureKind)} | {Esc(failure.Message)}");
            }
        }
        try
        {
            SongBookImporter.FromBibleQuote(Path.Combine(dataPath, "Modules", "немає"), null);
        }
        catch (SongBookImporter.Failure failure)
        {
            P($"bq missing {FailureName(failure.FailureKind)} | {Esc(failure.Message)}");
        }
    }

    private static void MakeSqlite(string path, int userVersion, string script)
    {
        var builder = new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = false };
        using var database = new SqliteConnection(builder.ToString());
        database.Open();
        using var command = database.CreateCommand();
        command.CommandText = $"PRAGMA user_version = {userVersion};" + script;
        command.ExecuteNonQuery();
    }

    private static string CheckOutput() =>
        Environment.GetEnvironmentVariable("SLOVO_CHECK_OUT") is { Length: > 0 } folder
            ? folder
            : throw new InvalidOperationException("SLOVO_CHECK_OUT не задано");

    /// Записати кожен пісенник у `.vbm` (для читання іншою програмою).
    private static void VbmWrite(string dataPath)
    {
        P("# vbmwrite");
        var output = CheckOutput();
        Directory.CreateDirectory(output);
        var library = new SongLibrary(Path.Combine(dataPath, "Modules"));
        foreach (var id in library.Books.Select(entry => entry.Id).ToList())
        {
            if (library.Book(id) is not { } book) continue;
            File.WriteAllBytes(Path.Combine(output, id + ".vbm"), SongBookWriter.Data(book));
            P($"wrote {id} {SongDigest(book)}");
        }
    }

    /// Прочитати всі `.vbm` із теки $SLOVO_CHECK_OUT.
    private static void VbmRead()
    {
        P("# vbmread");
        foreach (var path in Directory.GetFiles(CheckOutput(), "*.vbm").OrderBy(path => path, StringComparer.Ordinal))
        {
            try
            {
                P($"read {SwiftPath.LastComponent(path)} {SongDigest(SongBook.FromFile(path))}");
            }
            catch (Exception error)
            {
                P($"read {SwiftPath.LastComponent(path)} failed {error.Message}");
            }
        }
    }
}
