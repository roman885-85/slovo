// =============================================================================
//  AppState.Bible.cs — Біблія в стані програми (як відповідна частина AppState.swift)
// =============================================================================
//  Бібліотека модулів читається у фоні; на смугу перекладів ідуть увімкнені в
//  «Параметри → Модулі» в їхньому порядку. Книги — основного перекладу; клас
//  книг (Уся Біблія / Стар.Заповіт / Нов.Заповіт / Неканон.) — за наскрізним
//  номером книги. Розділи книги розбираються у фоні, поки крутиться коліщатко.
//  Текст слайда: вибрані вірші основного перекладу й (за наявності) другого;
//  кілька віршів — кожен із нового рядка з номером (налаштування).
// =============================================================================

using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    public ModuleLibrary? Library { get; private set; }
    public List<TextModule> AllModules { get; private set; } = new();
    public List<TextModule> OrderedModules { get; private set; } = new();
    public bool IsLoadingLibrary { get; private set; }
    public bool IsLoadingChapters { get; private set; }
    public string? LoadError { get; private set; }

    /// Тека модулів: вибрана людиною (меню «Файл») або тека даних програми.
    public string ModulesFolder
    {
        get => Defaults.String("modulesFolder") is { Length: > 0 } chosen && Directory.Exists(chosen) ? chosen : DataHome.Modules;
        set { Defaults.Set("modulesFolder", value); ReloadLibrary(); }
    }

    string _primary = "";
    public string PrimaryModuleID
    {
        get => _primary;
        set
        {
            if (_primary == value) return;
            _primary = value;
            Defaults.Set("primaryModule", value);
            ReloadBooks();
            // «При зміні основного перекладу вікно пошуку не ховається, а
            // пошук іде по цьому модулю» — як на Mac, наступним проходом.
            if (SearchedQuery.Length > 0) Dispatcher.UIThread.Post(() => RunSearch(SearchedQuery));
        }
    }

    List<string> _secondary = new();
    public IReadOnlyList<string> SecondaryModuleIDs => _secondary;

    public BookClass BookClass { get; set; } = BookClass.All;
    public List<BookInfo> Books { get; private set; } = new();
    public List<Chapter> Chapters { get; private set; } = new();

    int _book, _chapter = 1;
    List<int> _verses = new() { 1 };

    public int SelectedBookIndex
    {
        get => _book;
        set { _book = value; _chapter = 1; ReloadChapters(); }
    }

    public int SelectedChapterNumber
    {
        get => _chapter;
        set
        {
            _chapter = value;
            _verses = new List<int> { FirstVerseNumber };
            Signals.Shared.Batch(() =>
            {
                Signals.Shared.Send(Signals.Kind.ChapterSelection);
                Signals.Shared.Send(Signals.Kind.Verses);
            });
            RefreshSlide();
        }
    }

    public IReadOnlyList<int> SelectedVerseNumbers
    {
        get => _verses;
        set { _verses = value.ToList(); Signals.Shared.Send(Signals.Kind.VerseSelection); RefreshSlide(); }
    }

    public BookInfo? CurrentBook => _book >= 0 && _book < Books.Count ? Books[_book] : null;
    public Chapter? CurrentChapter => Chapters.FirstOrDefault(c => c.Number == _chapter);
    public int FirstVerseNumber => CurrentChapter?.Verses.FirstOrDefault().Number ?? 1;
    public TextModule? Module(string id) => AllModules.FirstOrDefault(m => string.Equals(m.Identifier, id, StringComparison.OrdinalIgnoreCase));
    public TextModule? PrimaryModule => Module(_primary);

    /// Прочитати бібліотеку у фоні (як reloadLibrary на Mac).
    /// Поставлене імпортом (планшет, «Імпорт», «Ресурси») — у список модулів «Параметрів»
    /// і перечитати бібліотеку, як adoptImported на Mac; тека з перенесеними фонами —
    /// у список тек із фонами (той самий adoptImported).
    public void AdoptImported(IEnumerable<string> modules, string? backgroundsFolder = null)
    {
        var store = SettingsStore.Shared;
        var changed = false;
        foreach (var path in modules) if (store.AddModule(path) == null) changed = true;
        if (backgroundsFolder != null && Directory.Exists(backgroundsFolder) && store.AddPicturePath(backgroundsFolder)) changed = true;
        if (changed) store.SaveOutsideEditing();
        ReloadLibrary();
    }

    /// Прохання перечитати, що прийшло, поки бібліотека ще читалася (reloadWanted на Mac):
    /// інакше воно просто зникало — і поставлений модуль не з'являвся.
    bool _reloadWanted;

    public void ReloadLibrary()
    {
        if (IsLoadingLibrary) { _reloadWanted = true; return; }
        _reloadWanted = false;
        IsLoadingLibrary = true;
        var folder = ModulesFolder;
        var dataRoot = DataHome.Folder;
        var extras = SettingsStore.Shared.Settings.Modules.Where(m => m.IsEnabled).Select(m => m.ResolvedUrl(dataRoot)).ToList();
        Task.Run(() =>
        {
            try { return new ModuleLibrary(folder, extras); }
            catch (Exception error) { Journal.Say($"бібліотека: {error.Message}"); return null; }
        }).ContinueWith(t => Dispatcher.UIThread.Post(() => ApplyLoaded(t.Result)));
    }

    void ApplyLoaded(ModuleLibrary? loaded)
    {
        IsLoadingLibrary = false;
        Library = loaded;
        AllModules = loaded?.Modules.ToList() ?? new List<TextModule>();
        LoadError = AllModules.Count == 0 ? Captions.T("В папке %s не найдено ни одного модуля.", ModulesFolder) : null;
        var store = SettingsStore.Shared;
        if (loaded != null)
            store.SyncModuleRoster(new HashSet<string>(AllModules.Select(m => m.Identifier.ToLowerInvariant())),
                                   new HashSet<string>(loaded.SongFiles.Select(f => Path.GetFileNameWithoutExtension(f).ToLowerInvariant())),
                                   ModulesFolder, DataHome.Folder);
        // Як на Mac: усі модулі — у порядку [BiblePath] із Slovo.ini (чого там немає — за
        // абеткою); на смугу — увімкнені там; основний — запам'ятований, інакше перший
        // із них (тому на чистому старті основним стає ubt2020, а не перша вкладка).
        IniSettings? config = null;
        try { if (IniSettings.LocateConfig() is { } ini) config = IniSettings.FromFile(ini); } catch { }
        AllModules = OrderByConfig(AllModules, config);
        var pinned = PinnedByConfig(AllModules, config);
        var remembered = Defaults.String("primaryModule");
        _primary = remembered != null && AllModules.Any(m => m.Identifier == remembered)
            ? remembered : pinned.FirstOrDefault()?.Identifier ?? "";
        _secondary = (Defaults.String("secondaryModules") ?? "").Split('|', StringSplitOptions.RemoveEmptyEntries)
                     .Where(id => Module(id) != null && id != _primary).ToList();
        if (_secondary.Count == 0 && config?.Int("defmoduletabindexsecond", "Bible") is { } second
            && second >= 0 && second < pinned.Count && pinned[second].Identifier != _primary)
            _secondary = new List<string> { pinned[second].Identifier };
        OrderedModules = pinned;
        // Смуга перекладів — за списком «Модулі» вікна «Параметри» (6.1.4): порядок і
        // галочки задає людина. Розпис не про цю теку (жодного її модуля не названо) —
        // смугу не чіпаємо.
        var roster = store.Settings.Modules.Where(e => !e.IsSongBook).ToList();
        var mentioned = roster.Any(e => AllModules.Any(m => string.Equals(m.Identifier, e.LibraryIdentifier, StringComparison.OrdinalIgnoreCase)));
        if (mentioned)
        {
            OrderedModules = roster.Where(e => e.IsEnabled)
                .Select(e => AllModules.FirstOrDefault(m => string.Equals(m.Identifier, e.LibraryIdentifier, StringComparison.OrdinalIgnoreCase)))
                .Where(m => m != null).Select(m => m!).ToList();
            if (!OrderedModules.Any(m => m.Identifier == _primary)) _primary = OrderedModules.FirstOrDefault()?.Identifier ?? "";
            _secondary = _secondary.Where(id => OrderedModules.Any(m => m.Identifier == id)).ToList();
        }
        if (OrderedModules.Count == 0) OrderedModules = AllModules.ToList();
        LoadTemplates();
        // Шрифти з теки Fonts поруч із модулями — як FontLoader.registerFonts в applyLoaded на Mac:
        // поставлений з «Ресурсів» Fonts.zip (шрифт адреси) підхоплюється без перезапуску.
        var dataRoot = Path.GetDirectoryName(ModulesFolder.TrimEnd(Path.DirectorySeparatorChar, '/'));
        foreach (var root in new[] { dataRoot, DataHome.Folder }.OfType<string>().Distinct(StringComparer.OrdinalIgnoreCase))
            SlideFonts.RegisterFonts(Path.Combine(root, "Fonts"));
        LoadSongs(loaded, config);
        // Розбивка біблійного тексту на сторінки — [Bible] у налаштуваннях автора.
        if (config != null) _biblePagination = new PlainTextDocument.Pagination(config, "Bible", Style);
        ApplyProgramOptions(store.Settings.Options);
        ReloadNumbering();
        Signals.Shared.Batch(() =>
        {
            Signals.Shared.Send(Signals.Kind.Library);
            Signals.Shared.Send(Signals.Kind.Translations);
            ReloadBooks();
        });
        // Повернути, на чому зупинилися, — коли номери книг знову щось значать.
        if (!_isRestored && !Program.Snapshotting) RestoreState();
        else _isRestored = true;
        if (_reloadWanted) ReloadLibrary();
    }

    /// Порядок як у [BiblePath]; чого там немає — у кінець, за абеткою.
    static List<TextModule> OrderByConfig(List<TextModule> modules, IniSettings? config)
    {
        var wanted = config?.ModuleOrder() ?? new List<string>();
        if (wanted.Count == 0) return modules.OrderBy(m => m.Identifier, Comparer<string>.Create(SwiftText.LocalizedStandardCompare)).ToList();
        var rank = new Dictionary<string, int>();
        for (var i = 0; i < wanted.Count; i++) rank.TryAdd(wanted[i].ToLowerInvariant(), i);
        return modules.OrderBy(m => rank.TryGetValue(m.Identifier.ToLowerInvariant(), out var r) ? r : int.MaxValue)
                      .ThenBy(m => m.Identifier, Comparer<string>.Create(SwiftText.LocalizedStandardCompare)).ToList();
    }

    /// Що на смузі за [BiblePath]: увімкнені там; не збіглося з текою — усе.
    static List<TextModule> PinnedByConfig(List<TextModule> modules, IniSettings? config)
    {
        var entries = config?.ModuleEntries() ?? new List<(string Name, bool IsEnabled)>();
        if (entries.Count == 0) return modules;
        var enabled = entries.Where(e => e.IsEnabled).Select(e => e.Name.ToLowerInvariant()).ToHashSet();
        var chosen = modules.Where(m => enabled.Contains(m.Identifier.ToLowerInvariant())).ToList();
        return chosen.Count == 0 ? modules : chosen;
    }

    void ReloadBooks()
    {
        Books = PrimaryModule?.Books.ToList() ?? new List<BookInfo>();
        if (_book >= Books.Count) _book = 0;
        Signals.Shared.Send(Signals.Kind.Translations);
        Signals.Shared.Send(Signals.Kind.Books);
        ReloadChapters();
    }

    int _chapterRequest;

    void ReloadChapters()
    {
        var module = PrimaryModule;
        var book = CurrentBook;
        Signals.Shared.Send(Signals.Kind.BookSelection);
        if (module == null || book == null) { Chapters = new(); Signals.Shared.Send(Signals.Kind.Chapters); RefreshSlide(); return; }
        if (module.CachedChapters(book) is { } ready) { ApplyChapters(ready.ToList()); return; }
        var request = ++_chapterRequest;
        IsLoadingChapters = true;
        Signals.Shared.Send(Signals.Kind.Chapters);
        Task.Run(() => { try { return module.Chapters(book).ToList(); } catch { return new List<Chapter>(); } })
            .ContinueWith(t => Dispatcher.UIThread.Post(() =>
            {
                if (request != _chapterRequest) return;
                IsLoadingChapters = false;
                ApplyChapters(t.Result);
            }));
    }

    void ApplyChapters(List<Chapter> parsed)
    {
        Chapters = parsed;
        if (!parsed.Any(c => c.Number == _chapter)) _chapter = parsed.FirstOrDefault()?.Number ?? 1;
        if (_verses.Count == 0 || CurrentChapter?.VerseNumbered(_verses[0]) == null) _verses = new List<int> { FirstVerseNumber };
        Signals.Shared.Batch(() =>
        {
            Signals.Shared.Send(Signals.Kind.Chapters);
            Signals.Shared.Send(Signals.Kind.ChapterSelection);
            Signals.Shared.Send(Signals.Kind.Verses);
        });
        RefreshSlide();
        RunPendingOpen();
    }

    public void ToggleSecondary(string id)
    {
        if (id == _primary) return;
        if (!_secondary.Remove(id)) _secondary.Add(id);
        Defaults.Set("secondaryModules", string.Join("|", _secondary));
        Signals.Shared.Send(Signals.Kind.Translations);
        RefreshSlide();
    }

    public void ShowSingleTranslation()
    {
        _secondary.Clear();
        Defaults.Set("secondaryModules", "");
        Signals.Shared.Send(Signals.Kind.Translations);
        RefreshSlide();
    }

    /// «Довга назва» на вкладках — повне ім'я перекладу («Синодальний» замість «RST+»).
    public bool TabNamesLong
    {
        get => Defaults.Bool("tabNamesLong");
        set { Defaults.Set("tabNamesLong", value); Signals.Shared.Send(Signals.Kind.Translations); }
    }

    /// Ярлик вкладки перекладу (як tabTitle на Mac): коротке ім'я; однакові короткі
    /// імена різних форматів (RST+ і в «Цитаті з Біблії», і в MyBible) — із форматом.
    public string TabTitle(TextModule module)
    {
        if (TabNamesLong) return module.DisplayName;
        var name = module.Info.ShortName.Length > 0 ? module.Info.ShortName : module.Identifier;
        var twins = AllModules.Count(m => string.Equals(m.Info.ShortName, module.Info.ShortName, StringComparison.OrdinalIgnoreCase));
        return twins > 1 ? $"{name} · {(module.Format == TextModuleFormat.MyBible ? "MB" : "BQ")}" : name;
    }

    /// Показати теку модуля (меню вкладки перекладу).
    public void RevealModule(string id)
    {
        if (Module(id) is not { } module) return;
        var path = module is BibleModule bq ? bq.Directory : Path.Combine(ModulesFolder, module.Identifier + ".SQLite3");
        Explorer.Show(path);
    }

    /// «Перезавантажити модуль»: скинути розібране й перечитати книгу тим самим шляхом,
    /// повернувши вибір.
    public void ReloadModule(string id)
    {
        if (Module(id) is not { } module) return;
        var chapter = _chapter;
        var verses = _verses.ToList();
        module.ReleaseCache();
        var book = _book;
        _pendingOpen = () =>
        {
            if (_book != book || !Chapters.Any(c => c.Number == chapter)) return;
            SelectedChapterNumber = chapter;
            SelectedVerseNumbers = verses;
        };
        SelectedBookIndex = book;
        Signals.Shared.Send(Signals.Kind.Verses);
    }

    /// Клас книги за наскрізним номером MyBible: 10…460 — Старий Заповіт, 470…730 — Новий, решта — неканонічні.
    public static BookClass ClassOf(BookInfo book) => book.CanonicalNumber switch
    {
        >= 10 and <= 460 => BookClass.Old,
        >= 470 and <= 730 => BookClass.New,
        _ => BookClass.Apocrypha,
    };

    /// Книги, видимі в колонці «Книга» за вибраним класом.
    public List<(BookInfo Book, int Position)> VisibleBooks =>
        Books.Select((b, i) => (b, i)).Where(p => BookClass == BookClass.All || ClassOf(p.b) == BookClass).ToList();

    readonly HashSet<string> _filling = new();
    void ScheduleFill(TextModule module, BookInfo book)
    {
        var key = $"{module.Identifier}#{book.Index}";
        if (!_filling.Add(key)) return;
        Task.Run(() => { try { module.Chapters(book); } catch { } })
            .ContinueWith(_ => Dispatcher.UIThread.Post(() => { _filling.Remove(key); RefreshSlide(); }));
    }
}
