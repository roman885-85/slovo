// =============================================================================
//  SongLibrary.cs — каталог пісенників з лінивим завантаженням і пошук
//  (з Songs/SongLibrary.swift)
// =============================================================================
//  `Book(id)` віддає збірник із кешу — спільний екземпляр (у Swift це була б
//  копія-значення). Його читають; правлять лише через SongBookEditor, який
//  бере собі копію, а назад приймають `Adopt`.
// =============================================================================

using System.Globalization;

namespace Slovo.Core;

/// Знайдена пісня і те, чим саме вона підійшла під запит.
public readonly record struct SongMatch(Song Song, SongMatch.Reasons Reason)
{
    public enum Reasons
    {
        Listing,         // запиту не було — це просто весь збірник
        Number,          // збігся номер у збірнику
        CatalogNumber,   // збігся `$ID$` з властивостей пісні
        Title,
        AlternateTitle,
        Author,
    }

    /// Номер пісні у збірнику — те, що оператор набирає на цифрах.
    public int Number => Song.Number;
    public int Id => Song.Index;
}

public sealed partial class Song
{
    /// Номер пісні — її позиція у збірнику, рахуючи з одиниці. Саме так
    /// нумерує пісні старої програми, і за цим номером їх шукають у залі.
    public int Number => Index + 1;

    /// Властивості пісні — рядки виду `$ID$=1728`, `$TUNE$=`.
    public Dictionary<string, string> PropertyPairs
    {
        get
        {
            var result = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var line in Properties.SplitLines())
            {
                var trimmed = line.TrimWhitespaces();
                var eq = trimmed.IndexOf('=');
                if (!trimmed.StartsWith('$') || eq < 0) continue;
                result[trimmed[..eq]] = trimmed[(eq + 1)..];
            }
            return result;
        }
    }

    /// Номер з `$ID$`. У більшості збірників він збігається з позицією, але,
    /// наприклад, у `lepel.vbm` розходиться в 74 пісень із 78 — там номер з
    /// друкованого збірника, а не порядок у файлі.
    public int? CatalogNumber =>
        PropertyPairs.TryGetValue("$ID$", out var value) ? SwiftText.ParseInt(value.TrimWhitespaces()) : null;

    /// Перший непорожній рядок першої частини — за ним пісню впізнають, коли
    /// назва нічого не каже.
    public string FirstLine
    {
        get
        {
            foreach (var part in Parts)
                foreach (var line in part.Lines)
                    if (line.TrimWhitespaces().Length > 0) return line.TrimWhitespaces();
            return "";
        }
    }
}

/// Як підписувати пісню в списку. Налаштування з `[settings]`:
/// `SongNameWithNumInCollection`, `SongNameDotAfterNum`,
/// `SongNameWithNumInCollectionInBrackets`.
public record struct SongTitleFormat
{
    public bool ShowsNumber;
    public bool DotAfterNumber;
    public bool NumberInBrackets;

    public SongTitleFormat() : this(true, true, false) { }

    public SongTitleFormat(bool showsNumber = true, bool dotAfterNumber = true, bool numberInBrackets = false)
    {
        ShowsNumber = showsNumber;
        DotAfterNumber = dotAfterNumber;
        NumberInBrackets = numberInBrackets;
    }

    public SongTitleFormat(IniSettings config)
        : this(config.Bool("SongNameWithNumInCollection", "settings") ?? true,
               config.Bool("SongNameDotAfterNum", "settings") ?? true,
               config.Bool("SongNameWithNumInCollectionInBrackets", "settings") ?? false) { }

    public readonly string NumberText(int number)
    {
        var digits = number.ToString(CultureInfo.InvariantCulture);
        if (NumberInBrackets) return $"({digits})";
        return DotAfterNumber ? digits + "." : digits;
    }

    public readonly string Title(Song song) =>
        ShowsNumber ? $"{NumberText(song.Number)} {song.Title}" : song.Title;
}

/// Каталог пісенників з лінивим завантаженням.
///
/// Файли великі: `pv3400.vbm` — це 3400 пісень і 17 тисяч частин, а таких
/// збірників у користувача два десятки. Читати їх усі при старті — це
/// секунди очікування і десятки мегабайтів марно, тому збірник відкривається
/// лише коли його вибрали, і в пам'яті тримається лише кілька останніх.
/// Так само поводиться й оригінал — у нього це `LazyLoadModule=1`.
public sealed class SongLibrary
{
    /// Пісенник у каталозі. Поки файл не відкрито, про нього відомо лише ім'я.
    public record struct Entry
    {
        public string Id;                // ім'я файлу без розширення
        public string Url;
        public string Title;             // до завантаження — ім'я файлу
        public string ShortName;
        public string Publisher;
        public string RevisionDate;
        public string Comment;
        public int? SongCount;           // відомо лише після завантаження
        public bool IsLoaded;
        public string? Failure;

        public readonly string DisplayName => Title.Length == 0 ? Id : Title;

        public Entry(string id, string url, string title = "", string shortName = "",
                     string publisher = "", string revisionDate = "", string comment = "",
                     int? songCount = null, bool isLoaded = false, string? failure = null)
        {
            Id = id;
            Url = url;
            Title = title.Length == 0 ? id : title;
            ShortName = shortName;
            Publisher = publisher;
            RevisionDate = revisionDate;
            Comment = comment;
            SongCount = songCount;
            IsLoaded = isLoaded;
            Failure = failure;
        }
    }

    private readonly List<Entry> books;
    public IReadOnlyList<Entry> Books => books;

    /// Скільки збірників тримаємо відкритими. Три — це вибраний, попередній
    /// і той, куди оператор зазирнув мимохідь; далі витісняємо.
    private int cacheLimit;
    public int CacheLimit
    {
        get => cacheLimit;
        set
        {
            cacheLimit = value;
            TrimCache();
        }
    }

    private sealed record Loaded(SongBook Book, string[] FoldedTitles, string[] FoldedAlternates, string[] FoldedAuthors);
    // Заголовки, згорнуті для пошуку, — щоб не згортати 3400 рядків
    // заново на кожне натискання клавіші в полі пошуку.

    private readonly Dictionary<string, Loaded> cache = new(StringComparer.Ordinal);
    private readonly List<string> recent = new();     // найсвіжіший — у кінці

    public SongLibrary(IEnumerable<string> songFiles, int cacheLimit = 3)
    {
        this.cacheLimit = Math.Max(1, cacheLimit);
        books = songFiles
            .OrderBy(url => SwiftPath.LastComponent(url), SwiftText.StandardOrder)
            .Select(url =>
            {
                var stem = SwiftPath.LastComponent(SwiftPath.DeletingExtension(url));
                return new Entry(stem, url, stem);
            })
            .ToList();
    }

    /// `SongLibrary(modulesDirectory:)` — пісенники з теки модулів.
    public SongLibrary(string modulesDirectory, int cacheLimit = 3)
        : this(new ModuleLibrary(modulesDirectory).SongFiles, cacheLimit) { }

    // ── Завантаження ────────────────────────────────────────────────────────

    public Entry? EntryFor(string id)
    {
        var position = IndexOf(id);
        return position is { } found ? books[found] : null;
    }

    /// Збірник за ім'ям файла — повним або без розширення: План та «Історія»
    /// пам'ятають «pv3055.vbm», а збірник уже лежить як «pv3055.songbook».
    public Entry? EntryForFileName(string fileName)
    {
        foreach (var book in books)
            if (SwiftText.SameIgnoringCase(SwiftPath.LastComponent(book.Url), fileName)) return book;
        var stem = SwiftPath.DeletingExtension(fileName);
        return EntryFor(stem);
    }

    private int? IndexOf(string id)
    {
        for (var position = 0; position < books.Count; position++)
            if (SwiftText.SameIgnoringCase(books[position].Id, id)) return position;
        return null;
    }

    /// Уже відкритий збірник, без звертання до диска.
    public SongBook? LoadedBook(string id) =>
        IndexOf(id) is { } position && cache.TryGetValue(books[position].Id, out var loaded) ? loaded.Book : null;

    /// Відкрити збірник (або повернути вже відкритий). Невдача не кидається
    /// винятком, а лишається в `Entry.Failure`: один битий файл у теці не
    /// привід ронити список — у користувача такий є, `UNTTP.vbm`.
    public SongBook? Book(string id)
    {
        if (IndexOf(id) is not { } position) return null;
        var key = books[position].Id;

        if (cache.TryGetValue(key, out var loaded))
        {
            Touch(key);
            return loaded.Book;
        }
        try
        {
            var book = SongBook.FromFile(books[position].Url);
            cache[key] = Prepare(book);
            Touch(key);
            TrimCache();

            var entry = books[position];
            entry.Title = book.Title.Length == 0 ? key : book.Title;
            entry.ShortName = book.ShortName;
            entry.Publisher = book.Publisher;
            entry.RevisionDate = book.RevisionDate;
            entry.Comment = book.Comment;
            entry.SongCount = book.Songs.Count;
            entry.IsLoaded = true;
            entry.Failure = null;
            books[position] = entry;
            return book;
        }
        catch (Exception error)
        {
            var entry = books[position];
            entry.IsLoaded = false;
            entry.Failure = error.Message;
            books[position] = entry;
            return null;
        }
    }

    private static Loaded Prepare(SongBook book) =>
        new(book,
            book.Songs.Select(song => Fold(song.Title)).ToArray(),
            book.Songs.Select(song => Fold(song.AlternateTitle)).ToArray(),
            book.Songs.Select(song => Fold(song.Author)).ToArray());

    /// Прийняти вже зібраний у пам'яті Пісенник як вміст запису каталогу.
    ///
    /// Потрібно після збереження з редактора: «Название либо Короткое название
    /// отображаются в названии Песенника на панели Выбора Песенника (33)»
    /// (5.3.9.3), а `Unload` назву не чіпає — вона лишилася б колишньою до
    /// наступного відкриття файла. Перечитувати з диска те, що ми щойно
    /// туди записали, нема чого: це зайві секунди на збірнику в 3400 пісень.
    ///
    /// Береться копія: редактор править далі свій екземпляр.
    public void Adopt(SongBook book, string id)
    {
        if (IndexOf(id) is not { } position) return;
        var key = books[position].Id;
        var own = book.Copy();
        cache[key] = Prepare(own);
        Touch(key);
        TrimCache();

        // Редактор пише у своєму форматі поруч із `.vbm`: відтоді збірник —
        // це `.songbook`, і саме його віддають планшету й експорту.
        var entry = books[position];
        if (SwiftPath.Extension(entry.Url).ToLowerInvariant() == "vbm")
        {
            var ownFile = SwiftPath.DeletingExtension(entry.Url) + "." + SongBookJSON.PathExtension;
            if (SwiftPath.Exists(ownFile))
                entry = new Entry(key, ownFile, entry.Title, entry.ShortName, entry.Publisher, entry.RevisionDate,
                                  entry.Comment, entry.SongCount, entry.IsLoaded, entry.Failure);
        }
        entry.Title = own.Title.Length == 0 ? key : own.Title;
        entry.ShortName = own.ShortName;
        entry.Publisher = own.Publisher;
        entry.RevisionDate = own.RevisionDate;
        entry.Comment = own.Comment;
        entry.SongCount = own.Songs.Count;
        entry.IsLoaded = true;
        entry.Failure = null;
        books[position] = entry;
    }

    public void Unload(string id)
    {
        if (IndexOf(id) is not { } position) return;
        var key = books[position].Id;
        cache.Remove(key);
        recent.RemoveAll(item => item == key);
        var entry = books[position];
        entry.IsLoaded = false;
        books[position] = entry;
    }

    public void UnloadAll()
    {
        cache.Clear();
        recent.Clear();
        for (var position = 0; position < books.Count; position++)
        {
            var entry = books[position];
            entry.IsLoaded = false;
            books[position] = entry;
        }
    }

    private void Touch(string key)
    {
        recent.RemoveAll(item => item == key);
        recent.Add(key);
    }

    private void TrimCache()
    {
        while (recent.Count > cacheLimit && recent.Count > 0)
        {
            var oldest = recent[0];
            recent.RemoveAt(0);
            cache.Remove(oldest);
            if (IndexOf(oldest) is { } position)
            {
                var entry = books[position];
                entry.IsLoaded = false;
                books[position] = entry;
            }
        }
    }

    // ── Доступ до пісень ────────────────────────────────────────────────────

    public IReadOnlyList<Song> Songs(string id) => Book(id)?.Songs ?? (IReadOnlyList<Song>)Array.Empty<Song>();

    /// Пісня за її місцем у збірнику, рахуючи з нуля.
    public Song? SongAt(int index, string id)
    {
        if (Book(id) is not { } book || index < 0 || index >= book.Songs.Count) return null;
        return book.Songs[index];
    }

    /// Пісня за номером, як його набирають на цифровій клавіатурі.
    public Song? SongNumbered(int number, string id)
    {
        if (Book(id) is not { } book) return null;
        if (number - 1 >= 0 && number - 1 < book.Songs.Count) return book.Songs[number - 1];
        // Там, де номер у файлі не збігається з позицією, допомагає `$ID$`.
        return book.Songs.FirstOrDefault(song => song.CatalogNumber == number);
    }

    // ── Пошук ───────────────────────────────────────────────────────────────

    /// Пошук за номером і за підрядком назви.
    ///
    /// Цифровий запит — це номер: спершу точне влучання, потім усе, де
    /// цифри трапляються в номері або в назві. Літерний — підрядок у
    /// назві, у другій назві і в авторі, без урахування регістру і
    /// діакритики (`Śpiewnik` знаходиться за `spiewnik`).
    public List<SongMatch> Search(string query, string id, int limit = 300)
    {
        if (Book(id) is not { } book || IndexOf(id) is not { } position
            || !cache.TryGetValue(books[position].Id, out var loaded)) return new List<SongMatch>();
        var trimmed = query.TrimWhitespacesAndNewlines();
        // Порожній запит — це не «нічого не знайдено», а весь збірник цілком.
        if (trimmed.Length == 0)
            return book.Songs.Select(song => new SongMatch(song, SongMatch.Reasons.Listing)).ToList();

        var result = new List<SongMatch>();
        var taken = new HashSet<int>();

        void Add(Song song, SongMatch.Reasons reason)
        {
            if (result.Count >= limit || !taken.Add(song.Index)) return;
            result.Add(new SongMatch(song, reason));
        }

        if (SwiftText.ParseInt(trimmed) is { } number)
        {
            if (number - 1 >= 0 && number - 1 < book.Songs.Count) Add(book.Songs[number - 1], SongMatch.Reasons.Number);
            foreach (var song in book.Songs)
                if (song.CatalogNumber == number) Add(song, SongMatch.Reasons.CatalogNumber);
            foreach (var song in book.Songs)
                if (song.Number.ToString(CultureInfo.InvariantCulture).StartsWith(trimmed, StringComparison.Ordinal))
                    Add(song, SongMatch.Reasons.Number);
        }

        var needle = Fold(trimmed);
        if (needle.Length == 0) return result;

        for (var index = 0; index < loaded.FoldedTitles.Length; index++)
            if (loaded.FoldedTitles[index].Contains(needle, StringComparison.Ordinal))
                Add(book.Songs[index], SongMatch.Reasons.Title);
        for (var index = 0; index < loaded.FoldedAlternates.Length; index++)
        {
            var alternate = loaded.FoldedAlternates[index];
            if (alternate.Length > 0 && alternate.Contains(needle, StringComparison.Ordinal))
                Add(book.Songs[index], SongMatch.Reasons.AlternateTitle);
        }
        for (var index = 0; index < loaded.FoldedAuthors.Length; index++)
        {
            var author = loaded.FoldedAuthors[index];
            if (author.Length > 0 && author.Contains(needle, StringComparison.Ordinal))
                Add(book.Songs[index], SongMatch.Reasons.Author);
        }
        return result;
    }

    /// Згортка для пошуку: регістр і діакритика значення не мають, а `ё`
    /// у пісенниках пишуть і так і так.
    internal static string Fold(string text) =>
        SwiftText.FoldIgnoringWidth(text).Replace("ё", "е").Replace("Ё", "е");
}
