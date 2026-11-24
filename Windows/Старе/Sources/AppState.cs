// =============================================================================
//  AppState.cs — стан програми: режим, вибране місце, слайд, зал
// =============================================================================
//  Одне джерело правди для вікна, вікна слайда, пульта й самоперевірки — як
//  AppState на Mac. Усі зміни йдуть на одному потоці (інтерфейсу; у перевірці
//  без вікна — під замком), а все, що хоче знати про зміну, слухає `Changed`.
//
//  Тут — ядро: бібліотека й переклади, вибір книги/розділу/віршів, складання
//  слайда, показ у залі (живий слайд, затемнення, порожній), гарячі клавіші.
//  Пісні, Текст, Зображення, План, Історія, пошук — у AppState.Desk.cs.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Threading;
using SkiaSharp;

namespace Slovo;

public enum Change
{
    Mode, Library, Bible, Verses, Songs, SongParts, Text, Pictures, Slide, Live, Plan, History, Search, Settings, Pointer, Remote
}

public sealed partial class AppState
{
    static AppState? _shared;
    public static AppState Shared => _shared ??= new AppState(Settings.Load());

    public Settings Settings { get; private set; }
    public Library Library { get; }
    public TemplateLibrary Templates { get; private set; }
    public SongPalette Palette { get; private set; }
    public HotkeySets HotkeySets { get; private set; }
    public Dictionary<string, Hotkey> Hotkeys { get; private set; } = new();

    public event Action<Change>? Changed;
    /// Вікну: поставити фокус у поле (Search, FastInput, Plan, MainWin…).
    public event Action<string>? FocusRequested;
    /// Вікну: зняти себе у файл PNG (команда пульта window-snapshot — для перевірок без екрана).
    public Func<string, string?>? WindowSnapshot { get; set; }
    /// Вікну: відкрити чи закрити службове вікно за назвою (settings, resources, editor, close) — лише для перевірок.
    public Action<string>? WindowRequested { get; set; }
    /// Номер стану — росте на кожну зміну; за ним пульт чекає.
    public int Seq { get; private set; } = 1;
    public int HallSeq { get; private set; } = 1;

    readonly object _sync = new();

    public AppState(Settings settings)
    {
        Settings = settings;
        Library = new Library();
        Templates = TemplateLibrary.Scan(Paths.Templates);
        Palette = SongPalette.Default();
        HotkeySets = HotkeySets.Load();
        ReloadHotkeys();
        ReloadModules(initial: true);
        LoadDesk();
    }

    // MARK: Потік

    /// Виконати на потоці стану: з вікна — одразу, з мережі — через диспетчер.
    public Task<T> Invoke<T>(Func<T> body)
    {
        if (Avalonia.Application.Current != null && !Dispatcher.UIThread.CheckAccess())
            return Dispatcher.UIThread.InvokeAsync(body).GetTask();
        lock (_sync) return Task.FromResult(body());
    }

    public Task Invoke(Action body) => Invoke(() => { body(); return 0; });

    void Raise(Change change)
    {
        Seq++;
        if (change != Change.Pointer && change != Change.Search && change != Change.Settings) HallSeq++;
        Changed?.Invoke(change);
    }

    // MARK: Режим

    public static readonly string[] Modes = { "bible", "songs", "text", "pictures" };

    string _mode = "bible";
    public string Mode
    {
        get => _mode;
        set
        {
            if (!Modes.Contains(value) || value == _mode) return;
            _mode = value;
            Settings.LastMode = value;
            RefreshSlide();
            Raise(Change.Mode);
        }
    }

    public static string ModeTitle(string mode) => mode switch
    {
        "songs" => Lang.T("Пісні", "Songs"),
        "text" => Lang.T("Текст", "Text"),
        "pictures" => Lang.T("Зображення", "Pictures"),
        _ => Lang.T("Біблія", "Bible"),
    };

    // MARK: Переклади

    public List<Module> AllModules { get; private set; } = new();
    /// Увімкнені переклади в порядку вкладок.
    public List<Module> Modules { get; private set; } = new();
    public string PrimaryModuleId => Settings.PrimaryModule;
    public Module? PrimaryModule => Modules.FirstOrDefault(m => m.Id == PrimaryModuleId);
    public List<string> SecondaryModuleIds => Settings.SecondaryModules;

    public Module? Module(string id) => AllModules.FirstOrDefault(m => m.Id == id);

    /// Перечитати бібліотеку: після імпорту, видалення чи зміни порядку.
    public void ReloadModules(bool initial = false)
    {
        AllModules = Library.Modules(Library.Bible);
        var known = AllModules.ToDictionary(m => m.Id);
        var order = Settings.ModuleOrder.Where(known.ContainsKey).ToList();
        if (order.Count == 0 && Settings.ModuleOrder.Count == 0) order = AllModules.Select(m => m.Id).ToList();
        Settings.ModuleOrder = order;
        Modules = order.Select(id => known[id]).ToList();
        if (!Modules.Any(m => m.Id == Settings.PrimaryModule)) Settings.PrimaryModule = Modules.FirstOrDefault()?.Id ?? "";
        Settings.SecondaryModules = Settings.SecondaryModules.Where(id => Modules.Any(m => m.Id == id) && id != Settings.PrimaryModule).ToList();
        ReloadBooks(keepPlace: !initial);
        ReloadSongBooks();
        if (!initial) Raise(Change.Library);
    }

    /// Увімкнені переклади й їх порядок — з вікна параметрів.
    public void SetModuleOrder(List<string> ids)
    {
        Settings.ModuleOrder = ids;
        ReloadModules();
    }

    public void SelectPrimary(string id)
    {
        if (Module(id) == null) return;
        if (!Settings.ModuleOrder.Contains(id)) { Settings.ModuleOrder.Add(id); ReloadModules(); }
        if (Settings.PrimaryModule == id) return;
        Settings.PrimaryModule = id;
        Settings.SecondaryModules.Remove(id);
        ReloadBooks(keepPlace: true);
        Raise(Change.Bible);
    }

    public void ToggleSecondary(string id)
    {
        if (id == Settings.PrimaryModule || Module(id) == null) return;
        if (!Settings.SecondaryModules.Remove(id)) Settings.SecondaryModules.Add(id);
        RefreshSlide();
        Raise(Change.Bible);
    }

    /// Один переклад: прибрати всі другі.
    public void ShowSingleTranslation()
    {
        if (Settings.SecondaryModules.Count == 0) return;
        Settings.SecondaryModules.Clear();
        RefreshSlide();
        Raise(Change.Bible);
    }

    // MARK: Книги, розділи, вірші

    public List<Book> Books { get; private set; } = new();
    public int SelectedBookIndex { get; private set; }
    public List<int> Chapters { get; private set; } = new();
    public int SelectedChapter { get; private set; } = 1;
    public List<Verse> Verses { get; private set; } = new();
    public List<int> SelectedVerses { get; private set; } = new();
    /// Клас книг для списку: all, old, new, other.
    public string BookClass { get; set; } = "all";

    public Book? CurrentBook => SelectedBookIndex >= 0 && SelectedBookIndex < Books.Count ? Books[SelectedBookIndex] : null;

    public static string Testament(Book book)
    {
        if (book.Canon <= 0) return "other";
        if (book.Canon <= 460) return "old";
        return book.Canon <= 730 ? "new" : "other";
    }

    public List<(int Position, Book Book)> VisibleBooks() =>
        Books.Select((b, i) => (i, b)).Where(p => BookClass == "all" || Testament(p.b) == BookClass).ToList();

    void ReloadBooks(bool keepPlace)
    {
        var module = PrimaryModule;
        Books = module == null ? new List<Book>() : Library.Books(module.Id);
        var wantedBook = keepPlace ? SelectedBookIndex : Settings.LastBook;
        var wantedChapter = keepPlace ? SelectedChapter : Settings.LastChapter;
        var wantedVerses = keepPlace ? SelectedVerses.ToList() : new List<int> { 1 };
        SelectedBookIndex = Math.Clamp(wantedBook, 0, Math.Max(0, Books.Count - 1));
        ReloadChapters();
        SelectedChapter = Chapters.Contains(wantedChapter) ? wantedChapter : (Chapters.FirstOrDefault(c => c >= 1) is var first && Chapters.Count > 0 ? (Chapters.Contains(first) ? first : Chapters[0]) : 1);
        ReloadVerses();
        SelectedVerses = wantedVerses.Where(v => Verses.Any(x => x.Number == v)).ToList();
        if (SelectedVerses.Count == 0 && Verses.Count > 0) SelectedVerses = new List<int> { Verses[0].Number };
        RefreshSlide();
    }

    void ReloadChapters()
    {
        var module = PrimaryModule;
        var book = CurrentBook;
        Chapters = module == null || book == null ? new List<int>() : Library.Chapters(module.Id, book.Index);
    }

    void ReloadVerses()
    {
        var module = PrimaryModule;
        var book = CurrentBook;
        Verses = module == null || book == null ? new List<Verse>() : Library.Verses(module.Id, book.Index, SelectedChapter);
    }

    public void SelectBook(int position)
    {
        if (position < 0 || position >= Books.Count) return;
        SelectedBookIndex = position;
        Settings.LastBook = position;
        ReloadChapters();
        SelectedChapter = Chapters.Count > 0 ? (Chapters.Contains(1) ? 1 : Chapters[0]) : 1;
        Settings.LastChapter = SelectedChapter;
        ReloadVerses();
        SelectedVerses = Verses.Count > 0 ? new List<int> { Verses[0].Number } : new List<int>();
        RefreshSlide();
        Raise(Change.Bible);
    }

    public void SelectChapter(int number)
    {
        if (!Chapters.Contains(number)) return;
        SelectedChapter = number;
        Settings.LastChapter = number;
        ReloadVerses();
        SelectedVerses = Verses.Count > 0 ? new List<int> { Verses[0].Number } : new List<int>();
        RefreshSlide();
        Raise(Change.Bible);
    }

    /// Вибрати вірші; `live` — одразу в зал.
    public void SelectVerses(IEnumerable<int> numbers, bool live)
    {
        var wanted = numbers.Where(n => Verses.Any(v => v.Number == n)).Distinct().OrderBy(n => n).ToList();
        if (wanted.Count == 0) return;
        SelectedVerses = wanted;
        RefreshSlide();
        Raise(Change.Verses);
        if (live) ShowCurrent();
    }

    public void SelectAllVerses(bool live) => SelectVerses(Verses.Select(v => v.Number), live);

    /// Місце цілком — книга позицією, розділ, вірші (порожньо — перший).
    public bool OpenScripture(int bookPosition, int chapter, List<int> verses, bool live)
    {
        if (bookPosition < 0 || bookPosition >= Books.Count) return false;
        if (SelectedBookIndex != bookPosition)
        {
            SelectedBookIndex = bookPosition;
            Settings.LastBook = bookPosition;
            ReloadChapters();
        }
        if (!Chapters.Contains(chapter)) chapter = Chapters.Count > 0 ? Chapters[0] : chapter;
        SelectedChapter = chapter;
        Settings.LastChapter = chapter;
        ReloadVerses();
        var wanted = verses.Where(n => Verses.Any(v => v.Number == n)).Distinct().OrderBy(n => n).ToList();
        if (wanted.Count == 0 && Verses.Count > 0) wanted.Add(Verses[0].Number);
        SelectedVerses = wanted;
        if (Mode != "bible") { _mode = "bible"; Settings.LastMode = "bible"; Raise(Change.Mode); }
        RefreshSlide();
        Raise(Change.Bible);
        if (live) ShowCurrent();
        return true;
    }

    /// Стрілка: наступний / попередній вірш; через межу розділу й книги.
    public void StepVerse(int delta, bool live)
    {
        if (Verses.Count == 0) return;
        // Довгий вірш по сторінках — спершу сторінки.
        if (StepSlidePage(delta, live)) return;
        var anchor = delta > 0 ? SelectedVerses.LastOrDefault() : SelectedVerses.FirstOrDefault();
        var position = Verses.FindIndex(v => v.Number == anchor);
        var next = position + delta;
        if (next < 0 || next >= Verses.Count)
        {
            if (!StepChapter(delta, live: false, toEnd: delta < 0)) return;
            if (live) ShowCurrent();
            return;
        }
        SelectedVerses = new List<int> { Verses[next].Number };
        RefreshSlide();
        Raise(Change.Verses);
        if (live) ShowCurrent();
    }

    /// Наступний / попередній розділ; за межею книги — сусідня книга.
    public bool StepChapter(int delta, bool live, bool toEnd = false)
    {
        var at = Chapters.IndexOf(SelectedChapter);
        var next = at + delta;
        if (next < 0 || next >= Chapters.Count)
        {
            var book = SelectedBookIndex + delta;
            if (book < 0 || book >= Books.Count) return false;
            SelectedBookIndex = book;
            Settings.LastBook = book;
            ReloadChapters();
            if (Chapters.Count == 0) return false;
            SelectedChapter = delta > 0 ? Chapters[0] : Chapters[^1];
        }
        else SelectedChapter = Chapters[next];
        Settings.LastChapter = SelectedChapter;
        ReloadVerses();
        SelectedVerses = Verses.Count == 0 ? new List<int>() : new List<int> { toEnd ? Verses[^1].Number : Verses[0].Number };
        RefreshSlide();
        Raise(Change.Bible);
        if (live) ShowCurrent();
        return true;
    }

    /// Швидкий вибір: «Ин 3:16», «Быт 1:1-5», лише книга, лише номер.
    public bool ApplyQuickInput(string text, bool live)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0 || Books.Count == 0) return false;
        // Лише цифри — вірш у відкритому розділі.
        if (trimmed.All(c => char.IsDigit(c) || c is ',' or '-' or ' '))
        {
            var numbers = ReferenceParser.VerseList(trimmed);
            if (numbers.Count == 0) return false;
            SelectVerses(numbers, live);
            return SelectedVerses.Count > 0;
        }
        var parsed = ReferenceParser.Resolve(trimmed, Books) ?? ReferenceParser.Parse(trimmed, Books, 1).FirstOrDefault();
        if (parsed == null) return false;
        return OpenScripture(parsed.Position, parsed.Chapter ?? 1, parsed.Verses, live);
    }

    public List<ParsedReference> QuickInputSuggestions(string text) =>
        Books.Count == 0 ? new List<ParsedReference>() : ReferenceParser.Parse(text, Books);

    // MARK: Слайд

    /// Передпоказ — те, що вибрано.
    public Slide Slide { get; private set; } = Slide.Blank;
    /// Те, що в залі.
    public Slide LiveSlide { get; private set; } = Slide.Blank;
    public string LiveMode { get; private set; } = "bible";
    public string? LivePicture { get; private set; }
    public bool IsLive { get; private set; }
    public bool IsBlackout { get; private set; }
    public bool IsTextHidden { get; private set; }

    /// Сторінки довгого вірша.
    public List<string> BiblePages { get; private set; } = new();
    public int BiblePageIndex { get; private set; }
    string _paginatedAddress = "";

    public bool HasPreviousPage => BiblePageIndex > 0;
    public bool HasNextPage => BiblePageIndex + 1 < BiblePages.Count;

    bool StepSlidePage(int delta, bool live)
    {
        if (BiblePages.Count <= 1) return false;
        var next = BiblePageIndex + delta;
        if (next < 0 || next >= BiblePages.Count) return false;
        BiblePageIndex = next;
        RefreshSlide();
        Raise(Change.Verses);
        if (live) ShowCurrent();
        return true;
    }

    public Pagination PaginationFor(string mode)
    {
        var look = Settings.Look(mode);
        var style = StyleFor(mode);
        var capacity = Pagination.Capacity(Settings.DefaultWidth, Settings.DefaultHeight, look.FontMinPercent / 100,
                                           style.LineSpacing, style.HorizontalInset, style.VerticalInset);
        return new Pagination
        {
            SplitsIntoPages = look.PageSubDivide, SplitsIntoParagraphs = mode == "text" && look.VersSubDivide,
            WrapsWords = look.WordWrap, CharactersPerLine = capacity.CharactersPerLine, LinesPerPage = capacity.LinesPerPage,
            MinimumFillPercent = Settings.PercentFillingPage,
        };
    }

    /// Текст вибраних віршів у модулі; null — у модулі такого місця нема.
    string? TextIn(string moduleId, bool numbers)
    {
        var book = CurrentBook;
        if (book == null) return null;
        List<Verse> verses;
        if (moduleId == PrimaryModuleId) verses = Verses;
        else
        {
            var other = SecondaryBook(moduleId, book);
            if (other == null) return null;
            verses = Library.Verses(moduleId, other.Index, SelectedChapter);
        }
        var chosen = verses.Where(v => SelectedVerses.Contains(v.Number)).ToList();
        if (chosen.Count == 0) return null;
        var separator = Settings.VersesOnOwnLines ? "\n" : " ";
        return string.Join(separator, chosen.Select(v => numbers ? v.Number + " " + v.Text : v.Text));
    }

    /// Книга другого перекладу — за наскрізним номером канону, а без нього за позицією.
    Book? SecondaryBook(string moduleId, Book primary)
    {
        var books = Library.Books(moduleId);
        if (primary.Canon > 0)
        {
            var byCanon = books.FirstOrDefault(b => b.Canon == primary.Canon);
            if (byCanon != null) return byCanon;
        }
        return SelectedBookIndex < books.Count ? books[SelectedBookIndex] : null;
    }

    public string ReferenceFor(Book book)
    {
        var secondaryIds = SecondaryModuleIds;
        if (secondaryIds.Count == 0) return ReferenceFormat.Separate(book, SelectedChapter, SelectedVerses, Settings.RefMainShort);
        var secondaryBook = SecondaryBook(secondaryIds[0], book);
        return ReferenceFormat.Combined(book, secondaryBook, SelectedChapter, SelectedVerses, Settings.RefAllMainShort, Settings.RefAllSecShort);
    }

    /// Пересібрати передпоказ із вибраного.
    public void RefreshSlide()
    {
        switch (Mode)
        {
            case "songs": Slide = CurrentSongSlide(); break;
            case "text": Slide = CurrentTextSlide(); break;
            case "pictures": Slide = Slide.Blank; break;
            default: Slide = BibleSlide(); break;
        }
        Raise(Change.Slide);
    }

    Slide BibleSlide()
    {
        var book = CurrentBook;
        if (book == null || SelectedVerses.Count == 0) return Slide.Blank;
        var main = TextIn(PrimaryModuleId, Settings.ShowVerseNumbers) ?? "";
        var secondary = SecondaryModuleIds.Select(id => TextIn(id, Settings.ShowSecondaryVerseNumbers)).Where(t => t != null).Select(t => t!).ToList();
        var address = ReferenceFor(book);
        var shown = main;
        // Розбиваємо лише ОДИН вірш, якщо він довгий: кілька вибраних — на один екран.
        if (secondary.Count == 0 && main.Length > 0 && SelectedVerses.Count == 1 && Settings.Bible.PageSubDivide)
        {
            if (address != _paginatedAddress)
            {
                _paginatedAddress = address;
                BiblePages = new TextDocument("", main).Pages(PaginationFor("bible"));
                BiblePageIndex = 0;
            }
            if (BiblePages.Count > 1 && BiblePageIndex < BiblePages.Count) shown = BiblePages[BiblePageIndex];
        }
        else
        {
            BiblePages = new List<string>();
            BiblePageIndex = 0;
            _paginatedAddress = "";
        }
        return new Slide(shown, secondary, address, shown.Length == 0 && secondary.Count == 0);
    }

    // MARK: Зал

    /// «Показати» (F5): передпоказ іде в зал.
    public void ShowCurrent()
    {
        LiveSlide = Slide;
        LiveMode = Mode;
        LivePicture = Mode == "pictures" ? CurrentPicture : null;
        IsLive = true;
        IsBlackout = false;
        IsTextHidden = false;
        RememberLive();
        Raise(Change.Live);
    }

    /// «Сховати» (Esc): зал гасне до фону.
    public void Hide()
    {
        if (!IsLive && !IsBlackout && !IsTextHidden) return;
        IsLive = false;
        IsBlackout = false;
        IsTextHidden = false;
        Raise(Change.Live);
    }

    /// «Затемнення екрана» (F12) — чорний зал; ще раз — назад.
    public void ToggleBlackScreen()
    {
        IsBlackout = !IsBlackout;
        if (IsBlackout) IsTextHidden = false;
        Raise(Change.Live);
    }

    /// «Порожній слайд» (Ctrl+F5) — фон без тексту; ще раз — назад.
    public void ToggleBlankSlide()
    {
        IsTextHidden = !IsTextHidden;
        if (IsTextHidden) IsBlackout = false;
        Raise(Change.Live);
    }

    public void ToggleCommonBackground()
    {
        Settings.ShowCommonBackground = !Settings.ShowCommonBackground;
        Raise(Change.Settings);
        Raise(Change.Live);
    }

    /// Що в залі словами — для пульта: black, text, still, empty.
    public string HallKind => IsBlackout ? "black" : IsLive && !IsTextHidden ? (LivePicture != null ? "still" : "text") : "empty";

    // MARK: Вигляд

    /// Стиль режиму: стиль із налаштувань, поверх — шаблон, поверх — фон людини.
    public SlideStyle StyleFor(string mode, bool dual = false)
    {
        var look = Settings.Look(mode == "pictures" ? "bible" : mode);
        var style = look.Style.Clone();
        if (look.TemplateName.Length > 0)
        {
            var template = Templates.Named(look.TemplateName);
            if (template != null) style = template.Style(look.Style, Settings.DesignHeight, dual);
        }
        if (Settings.SlideBackground.Length > 0 && File.Exists(Settings.SlideBackground)) style.BackgroundImagePath = Settings.SlideBackground;
        if (Settings.ShowCommonBackground && Settings.CommonBackground.Length > 0 && File.Exists(Settings.CommonBackground))
            style.BackgroundImagePath = Settings.CommonBackground;
        style.MinimumScale = Math.Clamp(look.FontMinPercent / 100 / Math.Max(0.02, style.Main.FontSize), 0.2, 0.9);
        return style;
    }

    /// Замовлення на малювання залу — те, що бачать люди.
    public RenderOrder HallOrder()
    {
        var style = StyleFor(LiveMode, LiveSlide.SecondaryTexts.Count > 0);
        if (IsBlackout) return new RenderOrder { Black = true, Style = style };
        if (!IsLive || IsTextHidden) return new RenderOrder { Slide = Slide.Blank, Style = style };
        if (LivePicture != null) return new RenderOrder { Slide = Slide.Blank, Style = style, Picture = LivePicture };
        return new RenderOrder { Slide = LiveSlide, Style = style };
    }

    /// Замовлення на передпоказ — те, що вибрано.
    public RenderOrder PreviewOrder()
    {
        var style = StyleFor(Mode, Slide.SecondaryTexts.Count > 0);
        if (Mode == "pictures") return new RenderOrder { Slide = Slide.Blank, Style = style, Picture = CurrentPicture };
        return new RenderOrder { Slide = Slide, Style = style };
    }

    readonly Dictionary<int, (int Seq, byte[] Jpeg)> _hallJpegs = new();

    /// Картинка залу в JPEG потрібної ширини — пульту; та сама не малюється двічі.
    public byte[] HallJpeg(int width)
    {
        width = Math.Clamp(width, 160, 1920);
        if (_hallJpegs.TryGetValue(width, out var cached) && cached.Seq == HallSeq) return cached.Jpeg;
        var height = (int)Math.Round(width * 9.0 / 16);
        if (Settings.ManualPlacement && Settings.CustomWidth > 0)
            height = (int)Math.Round((double)width * Settings.CustomHeight / Settings.CustomWidth);
        using var bitmap = SlideRenderer.Render(HallOrder(), width, height);
        var jpeg = SlideRenderer.Jpeg(bitmap, 0);
        if (_hallJpegs.Count > 6) _hallJpegs.Clear();
        _hallJpegs[width] = (HallSeq, jpeg);
        return jpeg;
    }

    // MARK: Указка

    public bool PointerOn { get; private set; }
    public double PointerX { get; private set; } = 0.5;
    public double PointerY { get; private set; } = 0.5;
    public string PointerSource { get; private set; } = "";
    public string? PointerColour { get; private set; }
    public double? PointerSizeOverride { get; private set; }
    public double? PointerOpacityOverride { get; private set; }

    public void MovePointer(double x, double y, string source, string? colour = null, double? size = null, double? opacity = null)
    {
        PointerOn = true;
        PointerX = Math.Clamp(x, 0, 1);
        PointerY = Math.Clamp(y, 0, 1);
        PointerSource = source;
        PointerColour = colour; PointerSizeOverride = size; PointerOpacityOverride = opacity;
        Raise(Change.Pointer);
    }

    public void HidePointer()
    {
        if (!PointerOn) return;
        PointerOn = false;
        PointerSource = "";
        Raise(Change.Pointer);
    }

    // MARK: Гарячі клавіші

    public void ReloadHotkeys()
    {
        var name = Settings.HotkeySet.Length > 0 && HotkeySets.Sets.ContainsKey(Settings.HotkeySet) ? Settings.HotkeySet : HotkeySets.PreferredSetName ?? "";
        Settings.HotkeySet = name;
        Hotkeys = HotkeySets.Hotkeys(name);
    }

    public Hotkey? Hotkey(string action) => Hotkeys.TryGetValue(action, out var hotkey) ? hotkey : null;

    /// Натиснута клавіша — яка це функція; порожньо — не наша.
    public string ActionFor(Avalonia.Input.Key key, Avalonia.Input.KeyModifiers modifiers)
    {
        foreach (var (action, hotkey) in Hotkeys)
            if (hotkey.Matches(key, modifiers)) return action;
        return "";
    }

    /// Виконати функцію клавіші; true — виконано тут, false — її робить вікно.
    public bool Perform(string action)
    {
        switch (action)
        {
            case "ShowSlide": ShowCurrent(); return true;
            case "HideSlide": Hide(); return true;
            case "ShowBlackScreen": ToggleBlackScreen(); return true;
            case "ShowBlankSlide": ToggleBlankSlide(); return true;
            case "ShowBackGrOnSlide": ToggleCommonBackground(); return true;
            case "Search": case "FastInput": case "Plan": case "MainWin": case "FastSearchWindow":
            case "FastInputBook": case "FastInputChapter": case "FastInputVers": case "ScreenShot":
            case "OpenCommonBG": case "OpenSlideBG":
                FocusRequested?.Invoke(action);
                return true;
            default:
                return false;
        }
    }

    // MARK: Налаштування

    /// Застосувати налаштування з вікна «Параметри».
    public void ApplySettings(Settings fresh)
    {
        Settings = fresh;
        Settings.Save();
        Lang.Apply(Settings.Language);
        Templates = TemplateLibrary.Scan(Paths.Templates);
        Fonts.Rescan();
        ReloadHotkeys();
        ReloadModules();
        ReloadPictures();
        _paginatedAddress = "";
        RefreshSlide();
        Raise(Change.Settings);
        Raise(Change.Live);
        Pult?.Apply();
    }

    public void ReloadTemplates()
    {
        Templates = TemplateLibrary.Scan(Paths.Templates);
        Raise(Change.Settings);
    }

    public void SaveSettings() => Settings.Save();

    // MARK: Пульт

    /// Канал пульта (телефон, планшет, «Проповідник», браузер).
    public Remote.RemoteServer? Pult { get; private set; }

    /// Підняти служби після старту вікна (у перевірці — на свій розсуд).
    public void StartServices()
    {
        Pult ??= new Remote.RemoteServer(this);
        Pult.Apply();
    }

    public void Shutdown()
    {
        try
        {
            SavePlanQuietly();
            History.Save();
            Settings.Save();
            Pult?.Stop();
        }
        catch (Exception error) { Paths.Say("завершення: " + error.Message); }
    }

    /// Зняти зал у файл PNG — «Знімок екрана» (F11).
    public string SaveScreenshot()
    {
        var folder = Paths.Screenshots;
        var file = Path.Combine(folder, "slide-" + DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss") + ".png");
        using var bitmap = SlideRenderer.Render(HallOrder(), 1920, 1080);
        File.WriteAllBytes(file, SlideRenderer.Png(bitmap));
        return file;
    }
}
