// =============================================================================
//  PlanItem.cs — пункт плану служіння (з Plan/PlanItem.swift)
// =============================================================================
//  Вкладені типи Swift `PlanItem.Kind/Scripture/SongPartReference/FileReference/
//  Content` тут — PlanItemKind, PlanScripture, PlanSongPartReference,
//  PlanFileReference, PlanContent: у C# вкладений тип не може зватися так само,
//  як властивість (`item.Scripture`, `item.File`).
//
//  JSON пункту — рівно той, що пише Mac (`"ключ" : значення`, ключі за абеткою,
//  UUID великими); читання таке саме поблажливе: «3» замість 3, «16-18»
//  замість списку, пункт без поля `type`.
// =============================================================================

using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Slovo.Core;

/// Тип пункту окремим переліком, а не розбором `Content`: за ним
/// будуються значок у списку, фільтри і пункти меню додавання.
public enum PlanItemKind { Scripture, Song, Text, File }

public static class PlanItemKinds
{
    public static readonly IReadOnlyList<PlanItemKind> All =
        [PlanItemKind.Scripture, PlanItemKind.Song, PlanItemKind.Text, PlanItemKind.File];

    public static string RawValue(this PlanItemKind kind) => kind switch
    {
        PlanItemKind.Scripture => "scripture",
        PlanItemKind.Song => "song",
        PlanItemKind.Text => "text",
        _ => "file",
    };

    public static string Title(this PlanItemKind kind) => kind switch
    {
        PlanItemKind.Scripture => OurWords.T("Отрывок"),
        PlanItemKind.Song => OurWords.T("Песня"),
        PlanItemKind.Text => OurWords.T("Текст"),
        _ => OurWords.T("Файл"),
    };
}

/// Файл, який пункт відкриває: презентація, картинки чи відео. Такі
/// пункти приносить план проповіді з планшета: файли лягають у теку
/// пульта, а пункт тримає шлях до свого.
public readonly record struct PlanFileReference(string Path)
{
    public string Url => Path;
    public string Name => SwiftPath.LastComponent(Path);
}

/// Посилання на біблійний уривок.
///
/// Книга зберігається індексом, а не назвою: порядок книг у перекладів спільний,
/// а назви і скорочення різні. За індексом уривок знаходиться в будь-якому
/// модулі, навіть якщо план збирали в іншому перекладі.
public sealed record PlanScripture
{
    public string ModuleID { get; init; }
    public int BookIndex { get; init; }
    public int Chapter { get; init; }
    /// Порожній список означає «розділ цілком».
    public ValueList<int> Verses { get; init; }

    public PlanScripture(string moduleID, int bookIndex, int chapter, IEnumerable<int>? verses = null)
    {
        ModuleID = moduleID;
        BookIndex = bookIndex;
        Chapter = chapter;
        Verses = new ValueList<int>(verses ?? Array.Empty<int>());
    }

    // ── Розв'язання посилання в справжній текст ─────────────────────────────

    /// Книга цього уривка у вказаному модулі — null, якщо книг у ньому менше
    /// (так буває в модулів, де лише Новий Заповіт).
    public BookInfo? Book(TextModule module) =>
        BookIndex >= 0 && BookIndex < module.Books.Count ? module.Books[BookIndex] : null;

    /// Вірші уривка (`verses(in:)`). Порожній список у посиланні означає «весь
    /// розділ», тому тут він розгортається у справжні вірші.
    public IReadOnlyList<Verse> VersesIn(TextModule module)
    {
        if (Book(module) is not { } book) return Array.Empty<Verse>();
        Chapter? chapter;
        try { chapter = module.Chapter(Chapter, book); }
        catch (Exception) { return Array.Empty<Verse>(); }
        if (chapter == null) return Array.Empty<Verse>();
        if (Verses.Count == 0) return chapter.Verses;
        return Verses.OrderBy(number => number).Select(number => chapter.VerseNumbered(number))
            .Where(verse => verse != null).Select(verse => verse!.Value).ToList();
    }

    /// Готовий текст уривка — те, що піде на слайд.
    public string? Text(TextModule module, bool withNumbers = false)
    {
        var found = VersesIn(module);
        if (found.Count == 0) return null;
        return string.Join(" ", found.Select(verse => withNumbers ? $"{verse.Number} {verse.Text}" : verse.Text));
    }
}

/// Посилання на частину пісні.
public readonly record struct PlanSongPartReference
{
    /// Ім'я файлу пісенника без шляху: теку з модулями користувач вільний
    /// перенести або перепідключити, а ім'я файлу переїзд переживає.
    public string BookFileName { get; init; }
    public int SongIndex { get; init; }
    public int? PartIndex { get; init; }

    public PlanSongPartReference(string bookFileName, int songIndex, int? partIndex = null)
    {
        BookFileName = bookFileName;
        SongIndex = songIndex;
        PartIndex = partIndex;
    }

    /// Порожній — пісня цілком: в автора пісню кладуть у план одним пунктом,
    /// а частини гортають уже при показі; частина кладеться окремо (5.3.3).
    public bool IsWholeSong => PartIndex == null;

    /// Файл пісенника серед знайдених у теці модулів. Порівнюємо без урахування
    /// регістру: імена збірників набирали у Windows, там регістр не значущий.
    public string? FileAmong(IEnumerable<string> files)
    {
        var wanted = BookFileName;
        return files.FirstOrDefault(file => SwiftText.SameIgnoringCase(SwiftPath.LastComponent(file), wanted));
    }

    public Song? SongIn(SongBook book) =>
        SongIndex >= 0 && SongIndex < book.Songs.Count ? book.Songs[SongIndex] : null;

    public SongPart? PartIn(SongBook book)
    {
        if (SongIn(book) is not { } song || PartIndex is not { } part || part < 0 || part >= song.Parts.Count) return null;
        return song.Parts[part];
    }
}

/// Вміст пункту — `PlanItem.Content` у Swift: рівно один із чотирьох.
public sealed record PlanContent
{
    public PlanItemKind Kind { get; }
    public PlanScripture? Scripture { get; }
    public PlanSongPartReference? Song { get; }
    /// Довільний текст модуля «Текст» — кнопка `SBAddTextToPlan` (24).
    public PlainTextDocument? Text { get; }
    /// Презентація, картинки чи відео з плану проповіді.
    public PlanFileReference? File { get; }

    private PlanContent(PlanItemKind kind, PlanScripture? scripture = null, PlanSongPartReference? song = null,
                        PlainTextDocument? text = null, PlanFileReference? file = null)
    {
        Kind = kind;
        Scripture = scripture;
        Song = song;
        Text = text;
        File = file;
    }

    public static PlanContent OfScripture(PlanScripture value) => new(PlanItemKind.Scripture, scripture: value);
    public static PlanContent OfSong(PlanSongPartReference value) => new(PlanItemKind.Song, song: value);
    public static PlanContent OfText(PlainTextDocument value) => new(PlanItemKind.Text, text: value);
    public static PlanContent OfFile(PlanFileReference value) => new(PlanItemKind.File, file: value);
}

/// Елемент плану служіння — одна зупинка в порядку подачі: біблійний
/// уривок, частина пісні або довільний текст модуля «Текст».
///
/// У перших двох у плані лежить посилання, а не текст. Текст живе в модулях і
/// пісенниках; якщо користувач оновить модуль або поправить пісню, план
/// зобов'язаний показати новий вміст, а не законсервовану копію, зняту
/// при складанні.
///
/// Пункту «Текст» посилатися нема на що: оголошення набрано просто в полі (25)
/// і ніде більше не зберігається. Тому він — єдиний, хто везе свій
/// вміст із собою (див. `PlainTextDocument`).
public sealed partial record PlanItem
{
    public Guid Id { get; init; }
    /// Підпис у списку: «Ів 3:16-18», «Великий Бог — Куплет 1».
    public string Title { get; init; }
    /// Початок тексту цитати — друга половина рядка списку.
    ///
    /// На знімку посібника (5.1.10) рядок плану виглядає як
    /// «1Кор. 11:23-32 - Ибо я от Самого Господа принял то, что…»: адреса і
    /// одразу за нею початок самої цитати, в один рядок. Тому тут лежить
    /// саме текст, а не назва перекладу: знімати його при подачі в список
    /// не можна — це читання модуля в головному потоці на кожну перемальовку.
    public string? Subtitle { get; init; }
    public PlanContent Content { get; init; }

    public PlanItem(string title, string? subtitle, PlanContent content, Guid? id = null)
    {
        Id = id ?? Guid.NewGuid();
        Title = title;
        Subtitle = subtitle;
        Content = content;
    }

    public PlanItemKind Kind => Content.Kind;
    public PlanScripture? Scripture => Content.Scripture;
    public PlanSongPartReference? SongPart => Content.Song;
    public PlainTextDocument? PlainText => Content.Text;
    public PlanFileReference? File => Content.File;

    /// Пункт-файл. Підпис — те, що дав проповідник, а без нього ім'я файла.
    public static PlanItem FileItem(string path, string? title = null)
    {
        var caption = title?.TrimWhitespacesAndNewlines() ?? "";
        return new PlanItem(caption.Length == 0 ? SwiftPath.LastComponent(path) : caption, null,
                            PlanContent.OfFile(new PlanFileReference(path)));
    }

    // ── Збирання пунктів ────────────────────────────────────────────────────

    /// Пункт з поточного положення курсора по тексту.
    ///
    /// `quote` — початок тексту уривка; він і стане другою половиною рядка
    /// списку. Береться в момент додавання, коли вірш уже розібрано і він лежить
    /// перед очима, а не при малюванні плану.
    public static PlanItem ScriptureItem(string moduleID, BookInfo book, int chapter, IEnumerable<int> verses, string? quote = null)
    {
        var list = verses.ToList();
        return new PlanItem(Reference(book, chapter, list), Shorten(quote),
                            PlanContent.OfScripture(new PlanScripture(moduleID, book.Index, chapter, list.OrderBy(v => v))));
    }

    /// Пункт із частини пісні. Ім'я файлу беремо у збірника, а не в пісні: шукати
    /// пісенник при відкритті плану будемо саме за ним.
    public static PlanItem SongPartItem(string bookFileName, Song song, SongPart part)
    {
        var name = song.Title.Length == 0 ? $"Песня {song.Index + 1}" : song.Title;
        var kind = part.Kind.TrimWhitespacesAndNewlines();
        return new PlanItem(kind.Length == 0 ? name : $"{name} — {kind}",
                            Shorten(string.Join(" ", part.Lines)),
                            PlanContent.OfSong(new PlanSongPartReference(bookFileName, song.Index, part.Index)));
    }

    /// `songPart(bookFile:book:song:part:)` — ім'я файла з повного шляху.
    public static PlanItem SongPartItem(string bookFile, SongBook book, Song song, SongPart part) =>
        SongPartItem(SwiftPath.LastComponent(bookFile), song, part);

    /// Пісня цілком — один пункт плану. Власник побачив: «при добавлении
    /// песни вместо песни добавляются куплеты» — план засипало частинами.
    public static PlanItem SongItem(string bookFileName, Song song)
    {
        var name = song.Title.Length == 0 ? $"Песня {song.Index + 1}" : song.Title;
        var first = song.Parts.Count > 0 ? string.Join(" ", song.Parts[0].Lines) : null;
        return new PlanItem(name, Shorten(first),
                            PlanContent.OfSong(new PlanSongPartReference(bookFileName, song.Index, null)));
    }

    /// Початок цитати для рядка списку: довше за один рядок у вузькій панелі
    /// плану все одно не видно, а тягати у файлі весь уривок нема чого.
    internal static string? Shorten(string? text, int limit = 160)
    {
        if (text == null) return null;
        var single = text.Replace("\n", " ").TrimWhitespacesAndNewlines();
        if (single.Length == 0) return null;
        return SwiftText.CharacterCount(single) <= limit ? single : SwiftText.PrefixCharacters(single, limit) + "…";
    }

    /// Усі частини пісні підряд — звичайний спосіб поставити пісню в план цілком.
    public static List<PlanItem> SongPartItems(string bookFile, SongBook book, Song song) =>
        song.Parts.Select(part => SongPartItem(bookFile, book, song, part)).ToList();

    /// Кнопка «Додати в План» (24, `SBAddTextToPlan`) модуля «Текст».
    ///
    /// Підпис рядка — заголовок і початок тексту: два оголошення з одним і
    /// тим самим заголовком у списку інакше не розрізнити. Якщо заголовка немає,
    /// рядком стає сам початок тексту.
    public static PlanItem TextItem(PlainTextDocument document, string? subtitle = null)
    {
        var summary = document.Summary(80);
        return new PlanItem(summary.Length == 0 ? PlanItemKind.Text.Title() : summary, subtitle, PlanContent.OfText(document));
    }

    // ── Посилання в тексті ──────────────────────────────────────────────────

    /// «Ів 3:16-18» — те саме, що показує рядок посилання на слайді.
    public static string Reference(BookInfo book, int chapter, IEnumerable<int> verses)
    {
        var name = book.ShortNames.Count > 0 ? book.ShortNames[0] : book.FullName;
        var numbers = FormatVerses(verses);
        return numbers.Length == 0 ? $"{name} {chapter}" : $"{name} {chapter}:{numbers}";
    }

    /// Вірші, що йдуть підряд, згортаються в діапазон: 1,2,3,7 → «1-3,7».
    public static string FormatVerses(IEnumerable<int> verses)
    {
        var sorted = verses.Where(verse => verse >= 0).Distinct().OrderBy(verse => verse).ToList();
        if (sorted.Count == 0) return "";

        var groups = new List<string>();
        var start = sorted[0];
        var previous = sorted[0];
        foreach (var number in sorted.Skip(1))
        {
            if (number == previous + 1)
            {
                previous = number;
                continue;
            }
            groups.Add(start == previous ? $"{start}" : $"{start}-{previous}");
            start = number;
            previous = number;
        }
        groups.Add(start == previous ? $"{start}" : $"{start}-{previous}");
        return string.Join(",", groups);
    }

    /// Зворотна операція: «1-3, 7» → [1,2,3,7]. Потрібна, щоб план, набраний
    /// у текстовому редакторі руками, читався нарівні зі збереженим програмою.
    public static List<int> ParseVerses(string text)
    {
        var result = new List<int>();
        foreach (var chunk in text.Split([',', ';', ' '], StringSplitOptions.RemoveEmptyEntries))
        {
            // Int у Swift 64-бітний: «1-9223372036854775807» — законний діапазон.
            var parts = SplitOnce(chunk, '-').Select(part => ParseInt64(part.TrimWhitespaces())).ToList();
            switch (parts.Count)
            {
                case 1:
                    if (parts[0] is { } single && single >= 0 && single <= int.MaxValue) result.Add((int)single);
                    break;
                case 2:
                    if (parts[0] is not { } from || parts[1] is not { } to || from < 0 || to < from) continue;
                    // Діапазон із чужого файла може бути яким завгодно, а віршів
                    // у розділі не тисячі — далі розумного не розгортаємо.
                    //
                    // Межу рахуємо через віднімання, а не як `from + 1000`:
                    // при `from` близько `Int.max` додавання переповнюється.
                    var span = Math.Min(to - from, 1000);
                    for (var verse = from; verse <= from + span && verse <= int.MaxValue; verse++) result.Add((int)verse);
                    break;
            }
        }
        return result;
    }

    /// `Int(String)` Swift (64-бітний).
    private static long? ParseInt64(string text) =>
        text.Length > 0 && long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;

    /// `split(separator: "-", maxSplits: 1)` Swift: порожні шматки відкидаються
    /// і не рахуються до межі розбиття.
    private static List<string> SplitOnce(string text, char separator)
    {
        var result = new List<string>();
        var start = 0;
        for (var index = 0; index < text.Length; index++)
        {
            if (text[index] != separator) continue;
            var appended = index > start;
            if (appended) result.Add(text[start..index]);
            start = index + 1;
            if (appended && result.Count == 1) break;
        }
        if (start < text.Length) result.Add(text[start..]);
        return result;
    }

    // ── Читання і запис у JSON ──────────────────────────────────────────────
    //
    // Формат пункту у файлі плану (див. `ServicePlan` — там описано документ цілком):
    //
    //     { "type": "scripture", "title": "Ин 3:16-18", "subtitle": "Синодальный",
    //       "module": "RST", "book": 42, "chapter": 3, "verses": [16, 17, 18] }
    //     { "type": "song", "title": "Великий Бог — Куплет 1", "subtitle": "Песнь возрождения",
    //       "songBook": "Песнь возрождения.vbm", "song": 11, "part": 0 }
    //     { "type": "text", "title": "Объявление - После служения…",
    //       "heading": "Объявление", "body": "После служения — братское общение." }
    //
    // Читання навмисно поблажливе: файл людина може поправити в редакторі, і
    // описка в одному пункті не має ронити весь план. Усе, що не розібралося,
    // перетворюється на помилку `UnsupportedItem`, а `ServicePlan` такий пункт пропускає.

    /// Пункт як вузол JSON (`encode(to:)`).
    public JsonObject ToJson()
    {
        var node = new JsonObject
        {
            ["id"] = Id.ToString("D").ToUpperInvariant(),
            ["type"] = Kind.RawValue(),
            ["title"] = Title,
        };
        if (!string.IsNullOrEmpty(Subtitle)) node["subtitle"] = Subtitle;

        switch (Content.Kind)
        {
            case PlanItemKind.Scripture:
            {
                var reference = Content.Scripture!;
                node["module"] = reference.ModuleID;
                node["book"] = reference.BookIndex;
                node["chapter"] = reference.Chapter;
                node["verses"] = new JsonArray(reference.Verses.Select(verse => (JsonNode?)JsonValue.Create(verse)).ToArray());
                break;
            }
            case PlanItemKind.Song:
            {
                var reference = Content.Song!.Value;
                node["songBook"] = reference.BookFileName;
                node["song"] = reference.SongIndex;
                // `encode(Optional)` у Swift пише null, а не пропускає ключ.
                node["part"] = reference.PartIndex is { } part ? JsonValue.Create(part) : null;
                break;
            }
            case PlanItemKind.Text:
            {
                // Заголовок пишемо завжди, навіть порожній: без ключа `heading` пункт
                // без заголовка при читанні не відрізнити від пункту, де заголовок
                // загубили, — а за ним визначається тип пункту без поля `type`.
                var document = Content.Text!.Value;
                node["heading"] = document.Title;
                node["body"] = document.Body;
                break;
            }
            default:
                node["path"] = Content.File!.Value.Path;
                break;
        }
        return node;
    }

    /// Пункт із вузла JSON (`init(from:)`); кидає PlanError, як `throws`.
    internal static PlanItem FromJson(LenientJson.Object container)
    {
        var declared = (LenientJson.String(container, "type") ?? "").ToLowerInvariant();
        var looksLikeSong = container.Contains("songBook") || container.Contains("song") || container.Contains("part");
        var looksLikeText = container.Contains("body") || container.Contains("heading");
        PlanContent content;

        switch (declared)
        {
            case "scripture": case "bible": case "verse": case "verses":
                content = PlanContent.OfScripture(DecodeScripture(container));
                break;
            case "song": case "songpart": case "song-part":
                content = PlanContent.OfSong(DecodeSong(container));
                break;
            case "text": case "plaintext": case "plain-text":
                content = PlanContent.OfText(DecodeText(container));
                break;
            case "file":
                content = PlanContent.OfFile(DecodeFile(container));
                break;
            case "":
                // Тип не написано — визначаємо за набором полів: так читається план,
                // набраний вручну за зразком сусіднього пункту.
                if (container.Contains("path")) content = PlanContent.OfFile(DecodeFile(container));
                else if (looksLikeText) content = PlanContent.OfText(DecodeText(container));
                else content = looksLikeSong
                    ? PlanContent.OfSong(DecodeSong(container))
                    : PlanContent.OfScripture(DecodeScripture(container));
                break;
            default:
                throw PlanError.UnsupportedItem(OurWords.T("неизвестный тип пункта «%s»", declared));
        }

        var title = LenientJson.String(container, "title")?.TrimWhitespacesAndNewlines() ?? "";
        var id = LenientJson.String(container, "id") is { } raw && TryUuid(raw) is { } parsed ? parsed : Guid.NewGuid();
        return new PlanItem(title.Length == 0 ? FallbackTitle(content) : title,
                            LenientJson.String(container, "subtitle"), content, id);
    }

    /// `UUID(uuidString:)`: лише вид 8-4-4-4-12, регістр будь-який.
    private static Guid? TryUuid(string text) =>
        text.Length == 36 && Guid.TryParseExact(text, "D", out var value) ? value : null;

    private static PlanScripture DecodeScripture(LenientJson.Object container)
    {
        if (LenientJson.Number(container, "book") is not { } book || book < 0)
            throw PlanError.UnsupportedItem(OurWords.T("у отрывка нет номера книги"));
        // Розділ 0 законний: у деяких модулях нумерація починається з нуля.
        if (LenientJson.Number(container, "chapter") is not { } chapter || chapter < 0)
            throw PlanError.UnsupportedItem(OurWords.T("у отрывка нет главы"));
        return new PlanScripture(LenientJson.String(container, "module") ?? "", book, chapter, VersesOf(container));
    }

    private static PlanSongPartReference DecodeSong(LenientJson.Object container)
    {
        if (LenientJson.String(container, "songBook") is not { Length: > 0 } file)
            throw PlanError.UnsupportedItem(OurWords.T("у части песни не указан песенник"));
        if (LenientJson.Number(container, "song") is not { } song || song < 0
            || LenientJson.Number(container, "part") is not { } part || part < 0)
            throw PlanError.UnsupportedItem(OurWords.T("у части песни нет номера песни или части"));
        return new PlanSongPartReference(file, song, part);
    }

    /// Текст нічого «не розбирає»: порожній пункт — законний, його і покаже
    /// порожній слайд. Тому тут немає `throw`, на відміну від уривка і пісні.
    private static PlainTextDocument DecodeText(LenientJson.Object container) =>
        new(LenientJson.String(container, "heading") ?? "", LenientJson.String(container, "body") ?? "");

    private static PlanFileReference DecodeFile(LenientJson.Object container)
    {
        if (LenientJson.String(container, "path") is not { Length: > 0 } path)
            throw PlanError.UnsupportedItem(OurWords.T("у файла нет пути"));
        return new PlanFileReference(path);
    }

    private static string FallbackTitle(PlanContent content)
    {
        switch (content.Kind)
        {
            case PlanItemKind.Scripture:
            {
                var reference = content.Scripture!;
                var numbers = FormatVerses(reference.Verses);
                var chapter = reference.Chapter.ToString(CultureInfo.InvariantCulture);
                return numbers.Length == 0
                    ? OurWords.T("Отрывок, глава %s", chapter)
                    : OurWords.T("Отрывок %s:%s", chapter, numbers);
            }
            case PlanItemKind.Song:
            {
                var reference = content.Song!.Value;
                if (reference.PartIndex is { } part) return $"Песня {reference.SongIndex + 1}, часть {part + 1}";
                return $"Песня {reference.SongIndex + 1}";
            }
            case PlanItemKind.Text:
            {
                var summary = content.Text!.Value.Summary(80);
                return summary.Length == 0 ? PlanItemKind.Text.Title() : summary;
            }
            default:
                return content.File!.Value.Name;
        }
    }

    // Значення могли записати не тим типом — «3» замість 3 і навпаки.
    // Заради однієї описки втрачати пункт нема чого.

    private static List<int> VersesOf(LenientJson.Object container)
    {
        if (LenientJson.IntList(container, "verses") is { } list)
            return list.Where(verse => verse >= 0).OrderBy(verse => verse).ToList();
        // «16-18» рядком — найзручніший спосіб вписати уривок руками.
        if (LenientJson.StringOnly(container, "verses") is { } text)
            return ParseVerses(text).OrderBy(verse => verse).ToList();
        if (LenientJson.IntOnly(container, "verses") is { } single && single >= 0)
            return [single];
        return new List<int>();
    }
}

/// Читання JSON так, як його читає `JSONDecoder` Swift (macOS 15): кома в кінці
/// масиву чи об'єкта дозволена, мітка порядку байтів теж; повтор ключа — береться
/// ПЕРШИЙ; ціле з «3.0» чи «1e2» читається, з «3.5» — ні.
internal static class LenientJson
{
    /// Об'єкт: ключі в порядку файла, при повторі — перше значення.
    internal sealed class Object
    {
        private readonly Dictionary<string, JsonElement> values = new(StringComparer.Ordinal);

        public Object(JsonElement element)
        {
            foreach (var property in element.EnumerateObject())
                values.TryAdd(property.Name, property.Value);
        }

        public bool Contains(string key) => values.ContainsKey(key);

        public JsonElement? this[string key] => values.TryGetValue(key, out var value) ? value : null;
    }

    public static JsonDocument Parse(byte[] data)
    {
        var bytes = data.AsMemory();
        if (data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) bytes = bytes[3..];
        return JsonDocument.Parse(bytes, new JsonDocumentOptions
        {
            AllowTrailingCommas = true,
            CommentHandling = JsonCommentHandling.Disallow,
            MaxDepth = 512,
        });
    }

    /// `try? decode(Int.self)`.
    public static int? IntOnly(Object container, string key) =>
        container[key] is { } element ? AsInt(element) : null;

    internal static int? AsInt(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Number) return null;
        long value;
        if (element.TryGetInt64(out var exact)) value = exact;
        else if (element.TryGetDouble(out var real) && double.IsFinite(real) && Math.Floor(real) == real
                 && real >= -9.2233720368547758e18 && real < 9.2233720368547758e18) value = (long)real;
        else return null;
        return value is >= int.MinValue and <= int.MaxValue ? (int)value : null;
    }

    /// `try? decode(Double.self)`.
    public static double? DoubleOnly(Object container, string key)
    {
        if (container[key] is not { ValueKind: JsonValueKind.Number } element) return null;
        return element.TryGetDouble(out var value) && double.IsFinite(value) ? value : null;
    }

    /// `try? decode(String.self)`.
    public static string? StringOnly(Object container, string key) =>
        container[key] is { ValueKind: JsonValueKind.String } element ? element.GetString() : null;

    /// `try? decode([Int].self)`: масив, у якому КОЖЕН елемент — ціле.
    public static List<int>? IntList(Object container, string key)
    {
        if (container[key] is not { ValueKind: JsonValueKind.Array } element) return null;
        var result = new List<int>();
        foreach (var item in element.EnumerateArray())
        {
            if (AsInt(item) is not { } value) return null;
            result.Add(value);
        }
        return result;
    }

    /// Рядок, а коли там ціле — ціле рядком.
    public static string? String(Object container, string key)
    {
        if (StringOnly(container, key) is { } text) return text;
        if (IntOnly(container, key) is { } number) return number.ToString(CultureInfo.InvariantCulture);
        return null;
    }

    /// Ціле: число, дробове в межах (відкидаючи дробову частину) або рядок із цілим.
    public static int? Number(Object container, string key)
    {
        if (IntOnly(container, key) is { } value) return value;
        // Дробове поза діапазоном цілого — не помилка, а аварійне завершення
        // у Swift, тому межі перевіряємо до перетворення.
        if (DoubleOnly(container, key) is { } real && real >= -9.2233720368547758e18 && real <= 9.2233720368547758e18)
        {
            var truncated = Math.Truncate(real);
            return truncated is >= int.MinValue and <= int.MaxValue ? (int)truncated : null;
        }
        if (StringOnly(container, key) is { } text) return SwiftText.ParseInt(text.TrimWhitespaces());
        return null;
    }
}
