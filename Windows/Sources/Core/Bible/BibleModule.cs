// =============================================================================
//  BibleModule.cs — модуль «Цитата з Біблії» (з Bible/BibleModule.swift)
// =============================================================================

namespace Slovo.Core;

/// Завантажений модуль Біблії: шапка, список книг і ліниве читання тексту.
///
/// Тексти не читаються при відкритті модуля — в одного лише BHS+ книги важать
/// сотні кілобайтів, а модулів більше півсотні. Книга читається і розбирається
/// при першому звертанні й лишається в кеші.
public sealed class BibleModule : TextModule
{
    public string Directory { get; }
    public string Identifier { get; }
    public ModuleInfo Info { get; }
    public IReadOnlyList<BookInfo> Books { get; }
    public TextModuleFormat Format => TextModuleFormat.BibleQuote;

    private readonly Dictionary<int, IReadOnlyList<Chapter>> chapterCache = new();
    private readonly object cacheLock = new();

    public BibleModule(string directory)
    {
        var iniPath = LocateIni(directory) ?? throw ModuleError.IniNotFound(directory);
        var parsed = BibleQuoteIni.Parse(iniPath);

        Directory = directory;
        Identifier = SwiftPath.LastComponent(directory);
        Info = parsed.Info;
        // Наскрізні номери проставляємо одразу: без них поруч із цим перекладом
        // не можна правильно показати другий.
        Books = CanonicalBook.AssignNumbers(parsed.Books);
    }

    /// Розділи книги. Перше звертання читає файл з диска.
    public IReadOnlyList<Chapter> Chapters(BookInfo book)
    {
        lock (cacheLock)
        {
            if (chapterCache.TryGetValue(book.Index, out var cached)) return cached;
        }

        var filePath = ResolveBookFile(book.FileName)
                       ?? throw ModuleError.BookFileNotFound(book.FileName, Identifier);
        var data = File.ReadAllBytes(filePath);
        var text = CodePage.Decode(data, Info.Encoding);
        var chapters = ChapterHTML.Parse(text, Info, book.ChapterCount);

        lock (cacheLock) chapterCache[book.Index] = chapters;
        return chapters;
    }

    /// Уже розібрана книга, якщо вона є в кеші. Потрібна, щоб відрізнити
    /// миттєвий випадок від того, заради якого варто йти у фон.
    public IReadOnlyList<Chapter>? CachedChapters(BookInfo book)
    {
        lock (cacheLock) return chapterCache.TryGetValue(book.Index, out var cached) ? cached : null;
    }

    public void ReleaseCache()
    {
        lock (cacheLock) chapterCache.Clear();
    }

    // ── Пошук файлів ────────────────────────────────────────────────────────

    private string? ResolveBookFile(string name)
    {
        var direct = Path.Combine(Directory, name);
        if (SwiftPath.Exists(direct)) return direct;

        // Регістр в ini і на диску збігається не завжди — на чутливій до
        // регістру файловій системі прямий шлях промахнеться.
        var wanted = name.ToLowerInvariant();
        var match = SwiftPath.Names(Directory)?.FirstOrDefault(entry => entry.ToLowerInvariant() == wanted);
        return match == null ? null : Path.Combine(Directory, match);
    }

    private static string? LocateIni(string directory)
    {
        var name = SwiftPath.Names(directory)?.FirstOrDefault(entry => entry.ToLowerInvariant() == "bibleqt.ini");
        return name == null ? null : Path.Combine(directory, name);
    }
}

/// Помилки відкриття модуля «Цитата з Біблії».
public sealed class ModuleError : Exception
{
    public enum Kind { IniNotFound, BookFileNotFound }

    public Kind ErrorKind { get; }

    private ModuleError(Kind kind, string message) : base(message) => ErrorKind = kind;

    public static ModuleError IniNotFound(string directory) =>
        new(Kind.IniNotFound, OurWords.T("в папке %s нет bibleqt.ini", SwiftPath.LastComponent(directory)));

    public static ModuleError BookFileNotFound(string file, string module) =>
        new(Kind.BookFileNotFound, OurWords.T("модуль %s: не найден файл книги %s", module, file));

    /// `description` Swift — те саме, що `Message`.
    public override string ToString() => Message;
}
