// =============================================================================
//  AppState.Scripture.cs — збирання слайда з Писання й навігація (як AppState.swift)
// =============================================================================
//  Слайд: вибрані вірші основного перекладу (і другого — у його нумерації:
//  22-й псалом Синодального — це 23-й західного рахунку), адреса за форматом із
//  «Параметрів» (довга/коротка назва, окремо й разом). Довгий один вірш ділиться
//  на сторінки — стрілка спершу гортає їх. Вибір: клацання, Shift — відрізок,
//  Ctrl — додати/прибрати, Ctrl+A — увесь розділ. Стрілки зі «Активна» ведуть
//  зал за собою. Місце між запусками запам'ятовується.
// =============================================================================

using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    // --- Формат адреси, номери віршів, нумерація -------------------------------------

    public ReferenceFormat ReferenceFormat { get; private set; } = new();
    public bool VersesOnOwnLines { get; private set; } = true;
    bool _showVerseNumbers, _showSecondaryVerseNumbers;

    NumberingBase? _numbering;
    readonly Dictionary<string, string> _numberingCodes = new();

    /// Розписати переклади за стандартами нумерації — у фоні: спершу ті, що зараз
    /// на слайді, потім усі (розбір Псалтиря в півсотні перекладів — понад пів хвилини).
    public void ReloadNumbering()
    {
        var dataRoot = DataHome.Folder;
        var modules = AllModules.ToList();
        var inUse = new[] { _primary }.Concat(_secondary).Select(Module).Where(m => m != null).Select(m => m!).ToList();
        Task.Run(() =>
        {
            try
            {
                var loaded = NumberingBase.Load(dataRoot);
                VerseNumbering.Shared.LoadRules();
                Dispatcher.UIThread.Post(() => _numbering = loaded);
                if (inUse.Count > 0)
                {
                    NumberingAssignments.Shared.Apply(inUse, VerseNumbering.Shared);
                    Dispatcher.UIThread.Post(() => { _numberingCodes.Clear(); RefreshSlide(); });
                }
                NumberingAssignments.Shared.Apply(modules, VerseNumbering.Shared);
                Dispatcher.UIThread.Post(() => { _numberingCodes.Clear(); RefreshSlide(); });
            }
            catch (Exception error) { Dispatcher.UIThread.Post(() => Journal.Say($"нумерація: {error.Message}")); }
        });
    }

    /// Код стандарту нумерації перекладу: вибір власника → догадка за книгами → таблиця автора.
    /// Порожньо — стандарт не впізнано: тоді не перераховуємо зовсім.
    public string NumberingCode(string id)
    {
        if (_numberingCodes.TryGetValue(id, out var known)) return known;
        var code = VerseNumbering.Shared.StandardOfModule(id).Id;
        if (string.IsNullOrEmpty(code))
        {
            var names = new List<string> { id };
            if (Module(id) is { } module && module.Info.ShortName.Length > 0) names.Insert(0, module.Info.ShortName);
            code = _numbering?.StandardCode(names) ?? "";
        }
        _numberingCodes[id] = code;
        return code;
    }

    /// Текст вибраних віршів у перекладі. Тут не можна читати з диска: розбір книги
    /// коштує сотні мілісекунд, а збирання слайда — на кожне натискання. Книги ще
    /// немає — ставимо в чергу й переберемо слайд, коли з'явиться.
    string? Text(string id)
    {
        if (Module(id) is not { } module || CurrentBook is not { } book) return null;
        // Ту саму книгу в іншому перекладі шукаємо за наскрізним номером канону.
        var counterpart = id == _primary ? book : module.Counterpart(book);
        if (counterpart == null) return null;
        if (module.CachedChapters(counterpart) is not { } ready) { ScheduleFill(module, counterpart); return null; }
        var spans = new List<VerseSpan> { new(_chapter, _verses.ToList()) };
        var target = NumberingCode(id);
        var source = NumberingCode(_primary);
        if (id != _primary && target != source && book.CanonicalNumber is { } canonical)
        {
            var engine = VerseNumbering.Shared;
            spans = engine.Translate(canonical, _chapter, _verses.ToList(), engine.Standard(source), engine.Standard(target),
                                     number => ready.FirstOrDefault(c => c.Number == number)?.Verses.Count);
        }
        // Кілька віршів — кожен зі свого рядка й зі своїм номером (без номера рядки
        // однакові на вигляд і незрозуміло, де кінчається вірш).
        var many = spans.Sum(s => s.Verses.Count) > 1;
        var ownLines = VersesOnOwnLines && many;
        var withNumbers = ownLines || (id == _primary ? _showVerseNumbers : _showSecondaryVerseNumbers);
        var picked = spans.SelectMany(span =>
        {
            var chapter = ready.FirstOrDefault(c => c.Number == span.Chapter);
            if (chapter == null) return Enumerable.Empty<string>();
            return span.Verses.OrderBy(n => n).Select(n => chapter.VerseNumbered(n) is { } v ? (withNumbers ? $"{n} {v.Text}" : v.Text) : null)
                              .Where(t => t != null).Select(t => t!);
        }).ToList();
        return picked.Count == 0 ? null : string.Join(ownLines ? "\n" : " ", picked);
    }

    /// Адреса за форматом «Параметрів»: окремо — або разом із другим перекладом.
    string Reference(BookInfo book)
    {
        var secondBook = _secondary.Count > 0 && Module(_secondary[0]) is { } second ? second.Counterpart(book) : null;
        return secondBook == null
            ? ReferenceFormat.Separate(book, _chapter, _verses, false)
            : ReferenceFormat.Combined(book, secondBook, _chapter, _verses);
    }

    // --- Сторінки довгого вірша ------------------------------------------------------------

    PlainTextDocument.Pagination _biblePagination = new();
    public List<string> BiblePages { get; private set; } = new();
    public int BiblePageIndex { get; private set; }
    string _paginatedAddress = "";
    public bool HasPreviousSlidePage => BiblePageIndex > 0;
    public bool HasNextSlidePage => BiblePageIndex + 1 < BiblePages.Count;

    /// Гортання сторінок усередині одного місця Писання.
    public bool StepSlidePage(int delta, bool live)
    {
        var next = BiblePageIndex + delta;
        if (next < 0 || next >= BiblePages.Count) return false;
        BiblePageIndex = next;
        RefreshSlide();
        if (live) ShowCurrentSlide();
        return true;
    }

    // --- Слайд ------------------------------------------------------------------------

    public Slide Slide { get; private set; } = Slide.Blank;
    public event Action? SlideChanged;

    /// Чи веде зміна вибору зал за собою (стрілки з «Активна», подвійне клацання).
    bool _followLive;

    /// Готовий слайд збоку — з модуля «Текст», з плану: одиночний показ — у
    /// передпоказ, «у зал» — ще й у зал (і в «Історію»).
    public void Present(Slide ready, bool live)
    {
        Slide = ready;
        if (live)
        {
            if (IsBlackout || IsTextHidden) ResumeFromHiddenStates();
            LiveStill = null;
            LiveSlide = ready;
            MarkLive();
            HallTakesText();
            IsLive = true;
            RememberLive();
            Signals.Shared.Send(Signals.Kind.Live);
            LiveChanged?.Invoke();
        }
        Publish();
    }

    /// Слайд — рівно під вкладку, а не те, що готувала попередня (зміна вкладки).
    public void SyncSlideToMode()
    {
        switch (Mode)
        {
            case WorkMode.Bible: RefreshSlide(); break;
            case WorkMode.Text: TextModuleModel.Shared.RefreshPreview(); break;
            case WorkMode.Songs:
                if (_shownSong != null || _songPages.Count > 0) RefreshSongSlide();
                else { Slide = Slide.Blank; Publish(); }
                break;
        }
        Signals.Shared.Send(Signals.Kind.Slide);
    }

    /// «Додати в План» з вкладки «Текст» (підключається з перенесенням Плану).
    public Action<PlainTextDocument>? AddTextToPlan;

    void Publish()
    {
        SlideChanged?.Invoke();
        Signals.Shared.Send(Signals.Kind.Slide);
    }

    public void RefreshSlide()
    {
        RememberState();
        // Затемнення (F12) і «фон без тексту» (Ctrl+F5) гасять зал цілком — і
        // перевіряти їх треба до будь-якої вкладки.
        if (IsBlackout || IsTextHidden) { Slide = Slide.Blank; Publish(); return; }
        // На вкладці «Текст» слайд — сторінка набору (будь-яке перезбирання — фон,
        // шаблон — лишає ту саму сторінку, а не підставляє вірш із Біблії).
        if (Mode == WorkMode.Text) { TextModuleModel.Shared.RefreshPreview(); return; }
        // На вкладці «Пісні» слайд збирає пісенник — Писання з відкритої у фоні глави
        // не підміняє куплет.
        if (Mode == WorkMode.Songs) { RefreshSongSlide(); return; }
        if (Mode != WorkMode.Bible) { Publish(); return; }
        if (CurrentBook is not { } book || _verses.Count == 0) { Slide = Slide.Blank; Publish(); return; }

        var main = Text(_primary) ?? "";
        var secondary = _secondary.Select(Text).Where(t => t != null).Select(t => t!).ToList();
        var address = Reference(book);

        // Ділимо лише ОДИН довгий вірш: кілька виділених оператор просив на один
        // екран — дробити його вибір не можна. З двома перекладами — як було.
        var shown = main;
        if (secondary.Count == 0 && main.Length > 0 && _verses.Count == 1)
        {
            if (address != _paginatedAddress)
            {
                _paginatedAddress = address;
                BiblePages = new PlainTextDocument("", main).Pages(_biblePagination);
                BiblePageIndex = 0;
            }
            if (BiblePages.Count > 1 && BiblePageIndex >= 0 && BiblePageIndex < BiblePages.Count) shown = BiblePages[BiblePageIndex];
        }
        else
        {
            BiblePages = new List<string>();
            BiblePageIndex = 0;
            _paginatedAddress = "";
        }

        Slide = new Slide(shown, secondary, address, shown.Length == 0 && secondary.Count == 0);
        if (_followLive)
        {
            // Зв'язані стрілки виводять вірш у зал так само, як «Показати»;
            // у «Історію» — лише те, що зал справді бачив.
            LiveStill = null;
            LiveSlide = Slide;
            MarkLive();
            // Зв'язані стрілки виводять вірш так само, як «Показати»: кадр плеєра поступається.
            HallTakesText();
            if (IsLive) RememberLive();
            Signals.Shared.Send(Signals.Kind.Live);
            LiveChanged?.Invoke();
        }
        else if (!Slide.IsBlank && LiveSlide.Reference == Slide.Reference && LiveSlide.MainText.Length == 0)
        {
            // Стрілка могла вивести адресу раніше, ніж книга дочиталася: адреса та
            // сама, текст з'явився — це він і є, наздоганяємо зал.
            LiveSlide = Slide;
            LiveChanged?.Invoke();
        }
        Publish();
    }

    // --- Вибір віршів -----------------------------------------------------------------

    public enum VerseSelection { Replace, Extend, Toggle }
    int? _selectionAnchor;

    public void SelectVerse(int number, bool extending) => SelectVerse(number, extending ? VerseSelection.Extend : VerseSelection.Replace);

    public void SelectVerse(int number, VerseSelection mode)
    {
        ResumeFromHiddenStates();
        switch (mode)
        {
            case VerseSelection.Replace:
                _selectionAnchor = number;
                SelectedVerseNumbers = new[] { number };
                break;
            case VerseSelection.Extend:
            {
                // Опорний — той, з якого почали виділяти: інакше Shift угору згортав би відрізок.
                var anchor = _selectionAnchor ?? (_verses.Count > 0 ? _verses[0] : number);
                _selectionAnchor = anchor;
                SelectedVerseNumbers = Enumerable.Range(Math.Min(anchor, number), Math.Abs(anchor - number) + 1).ToList();
                break;
            }
            default:
            {
                var picked = new SortedSet<int>(_verses);
                if (picked.Contains(number) && picked.Count > 1) picked.Remove(number);
                else { picked.Add(number); _selectionAnchor = number; }
                SelectedVerseNumbers = picked.ToList();
                break;
            }
        }
    }

    /// Клацання по вірші: одиночне — лише передпоказ, подвійне — одразу в зал.
    /// Подвійне по вже виділеному не руйнує набраний відрізок.
    public void ChooseVerse(int number, VerseSelection mode, bool live)
    {
        if (live && mode == VerseSelection.Replace && _verses.Contains(number)) { ShowCurrentSlide(); return; }
        SelectVerse(number, mode);
        if (live) ShowCurrentSlide();
    }

    /// Ctrl+A — увесь розділ на один слайд.
    public void SelectAllVerses()
    {
        if (CurrentChapter is not { } chapter || chapter.Verses.Count == 0) return;
        ResumeFromHiddenStates();
        _selectionAnchor = chapter.Verses[0].Number;
        SelectedVerseNumbers = chapter.Verses.Select(v => v.Number).ToList();
    }

    /// Shift зі стрілкою — розсунути виділення на сусідній вірш.
    public void ExtendSelection(int delta, bool live)
    {
        if (CurrentChapter is not { } chapter || _verses.Count == 0) return;
        var numbers = chapter.Verses.Select(v => v.Number).ToList();
        var edge = delta > 0 ? _verses.Max() : _verses.Min();
        var position = numbers.IndexOf(edge);
        if (position < 0) return;
        var next = position + delta;
        if (next < 0 || next >= numbers.Count) return;
        _followLive = live;
        try { SelectVerse(numbers[next], VerseSelection.Extend); }
        finally { _followLive = false; }
        if (live) ShowCurrentSlide();
    }

    // --- Кроки ------------------------------------------------------------------------

    public void StepVerse(int delta, bool live)
    {
        _followLive = live;
        try { StepVerse(delta); }
        finally { _followLive = false; }
    }

    public void StepChapter(int delta, bool live)
    {
        _followLive = live;
        try { StepChapter(delta); }
        finally { _followLive = false; }
    }

    /// Наступний/попередній вірш (кнопки «Керування», меню, стрілки).
    public void StepVerse(int delta)
    {
        if (Mode == WorkMode.Text && TextModuleModel.Shared.HandleStep(delta, _followLive)) return;
        if (Mode == WorkMode.Songs) { StepSongPart(delta, _followLive); return; }
        if (Mode != WorkMode.Bible) return;
        ResumeFromHiddenStates();
        // Довгий вірш поділено на частини — стрілка спершу гортає їх, і вказівник
        // не йде далі, поки весь вірш не пролистають у залі.
        if (StepSlidePage(delta, _followLive)) return;
        if (CurrentChapter is not { } chapter || _verses.Count == 0) return;
        var numbers = chapter.Verses.Select(v => v.Number).ToList();
        var position = numbers.IndexOf(_verses[^1]);
        if (position < 0) return;
        var next = position + delta;
        if (next >= 0 && next < numbers.Count)
        {
            SelectedVerseNumbers = new[] { numbers[next] };
            // Назад — стаємо на ОСТАННЮ частину попереднього вірша.
            if (delta < 0 && BiblePages.Count > 1)
            {
                BiblePageIndex = BiblePages.Count - 1;
                RefreshSlide();
                if (_followLive) ShowCurrentSlide();
            }
        }
        else if (delta > 0) StepChapter(1);
        else if (delta < 0)
        {
            // Зміна розділу сама ставить перший вірш; щоб у зал не пішов проміжний
            // перший вірш і в «Історію» не лягли два записи — відпускаємо на час переходу.
            var wasLive = _followLive;
            _followLive = false;
            StepChapter(-1);
            _followLive = wasLive;
            void Last() => SelectedVerseNumbers = new[] { CurrentChapter is { Verses.Count: > 0 } c ? c.Verses[^1].Number : 1 };
            if (IsLoadingChapters) _pendingOpen = Last; else Last();
        }
    }

    public void StepChapter(int delta)
    {
        if (Mode != WorkMode.Bible) return;
        ResumeFromHiddenStates();
        var numbers = Chapters.Select(c => c.Number).ToList();
        var position = numbers.IndexOf(_chapter);
        if (position < 0) return;
        var next = position + delta;
        if (next >= 0 && next < numbers.Count) SelectedChapterNumber = numbers[next];
        else if (delta > 0 && _book + 1 < Books.Count) SelectedBookIndex = _book + 1;
        else if (delta < 0 && _book > 0)
        {
            var wanted = _book - 1;
            _pendingOpen = () => { if (_book == wanted) SelectedChapterNumber = Chapters.LastOrDefault()?.Number ?? 1; };
            SelectedBookIndex = wanted;
        }
    }

    /// «Поточний»: список віршів — до вибраного (scrollToCurrentVerse на Mac).
    public event Action? ScrollToCurrentVerseRequested;
    public void ScrollToCurrentVerse() => ScrollToCurrentVerseRequested?.Invoke();

    /// Ctrl+E у пісеннику — режим правки (вкладка «Пісні»).
    public Func<bool>? ToggleSongEditMode;

    // --- Відкрити місце ---------------------------------------------------------------

    /// Відкрити місце цілком: книга, розділ, вірші — одним рухом. Розділи книги можуть
    /// ще читатися з диска — тоді прохання чекає на них; розділ поза межами книги
    /// підтягується до найближчого; `then` — коли все стало на місце.
    public void OpenScripture(int bookPosition, int chapter, Func<IReadOnlyList<int>, IReadOnlyList<int>> pick, Action? then = null)
    {
        void Resolve()
        {
            if (Chapters.Count == 0) return;
            var numbers = Chapters.Select(c => c.Number).ToList();
            var target = numbers.Contains(chapter) ? chapter : Math.Min(Math.Max(chapter, numbers[0]), numbers[^1]);
            if (_chapter != target) SelectedChapterNumber = target;
            var available = CurrentChapter?.Verses.Select(v => v.Number).ToList() ?? new List<int>();
            var wanted = pick(available);
            if (wanted.Count > 0) SelectedVerseNumbers = wanted;
            then?.Invoke();
        }
        if (_book != bookPosition)
        {
            _pendingOpen = () => { if (_book == bookPosition) Resolve(); };
            SelectedBookIndex = bookPosition;
        }
        else if (IsLoadingChapters) _pendingOpen = Resolve;
        else Resolve();
    }

    /// Те саме за номером книги в модулі (історія, план, пошук).
    public void OpenPlace(int bookIndex, int chapter, IReadOnlyList<int> verses, bool show)
    {
        var position = Books.FindIndex(b => b.Index == bookIndex);
        if (position < 0) return;
        var wanted = verses.ToList();
        OpenScripture(position, chapter, available => wanted.Where(available.Contains).ToList(), show ? ShowCurrentSlide : null);
    }

    /// Швидкий вибір місця (9): «Ів 3:16-18» — формат розділу 5.1.9.
    public bool ApplyAddress(string text, Action? then = null)
    {
        if (ScriptureAddress.Parse(text, Books) is not { } address) return false;
        var position = Books.FindIndex(b => b.Index == address.Book.Index);
        if (position < 0) return false;
        OpenScripture(position, address.Chapter ?? 1, available => address.VerseNumbers(available), then);
        return true;
    }

    // --- Запам'ятати місце ------------------------------------------------------------

    bool _isRestored;

    /// Записати, на чому зупинилися (показ у залі навмисно не запам'ятовуємо).
    void RememberState()
    {
        if (IsLoadingLibrary || !_isRestored) return;
        Defaults.Set("lastMode", Mode.RawValue());
        Defaults.Set("lastBookClass", BookClassRaw.RawValue(BookClass));
        Defaults.Set("lastBookIndex", _book);
        Defaults.Set("lastChapter", _chapter);
        Defaults.Set("lastVerses", string.Join(",", _verses));
    }

    /// Повернути, на чому зупинилися, — один раз, коли бібліотека вже відкрита.
    void RestoreState()
    {
        if (_isRestored) return;
        try
        {
            if (BookClassRaw.FromRaw(Defaults.String("lastBookClass")) is { } bookClass) BookClass = bookClass;
            if (Defaults.Has("lastBookIndex") && Defaults.Int("lastBookIndex") is var index && index >= 0 && index < Books.Count)
            {
                var chapter = Defaults.Has("lastChapter") ? Defaults.Int("lastChapter") : 1;
                var verses = (Defaults.String("lastVerses") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries)
                             .Select(s => int.TryParse(s, out var n) ? n : -1).Where(n => n > 0).ToList();
                OpenScripture(index, chapter, available => verses.Where(available.Contains).ToList());
            }
            if (WorkModeInfo.FromRaw(Defaults.String("lastMode")) is { } mode) Mode = mode;
        }
        finally { _isRestored = true; }
    }

    // --- «Параметри» → стан -----------------------------------------------------------

    /// Застосувати «Параметри» (як applyProgramOptions на Mac): переходи слайда,
    /// номери віршів, вигляд адреси, вірші з нового рядка, указка, місце вікна слайда.
    public void ApplyProgramOptions(ProgramOptions options)
    {
        var style = Style;
        // В оригіналі — мілісекунди; 0 і 1 мс — миттєва зміна: перехід вимикаємо.
        style.TransitionDuration = Math.Max(0.001, options.CrossfadeTime / 1000.0);
        if (options.SlideTransition is { } raw && SlideStyleEnums.TransitionFromRaw(raw) is { } kind) style.TransitionKind = kind;
        if (options.SlideTransitionEasing is { } rawEasing && SlideStyleEnums.EasingFromRaw(rawEasing) is { } easing) style.TransitionEasing = easing;
        if (options.CrossfadeTime <= 1) style.TransitionKind = SlideStyle.Transition.None;
        _style = style;
        _showVerseNumbers = options.ShowVerseNumbers;
        _showSecondaryVerseNumbers = options.ShowSecondaryVerseNumbers;
        ReferenceFormat = new ReferenceFormat(
            (ReferenceFormat.NameLength)(int)options.RefAllMain, (ReferenceFormat.NameLength)(int)options.RefAllSec,
            (ReferenceFormat.NameLength)(int)options.RefMain, (ReferenceFormat.NameLength)(int)options.RefSec);
        VersesOnOwnLines = options.VersesOnOwnLines ?? true;
        SlidePointer.Shared.Apply(SlidePointer.Look.From(options));
        // Медіа (6.1.7): звуковий вихід і відео в передпоказі.
        if (_media != null || options.AudioDeviceID != 0)
        {
            Media.SelectAudioDevice(options.AudioDeviceID);
            Media.VideoToPreview = options.ShowVideoOnPreview;
        }
        _paginatedAddress = "";
        RefreshSlide();
        LiveChanged?.Invoke();
        // Пульт на телефоні й у браузері: увімкнені, поки їх не вимкнули навмисно. Знімки без
        // екрана пульта не піднімають (хіба що перевірці дали свої порти).
        if (!Program.Snapshotting || RemoteControlServer.PortOverride != null)
        {
            RemoteControlServer.Shared.Apply(options.RemoteEnabled ?? true, options.RemotePort ?? 8103, options.RemotePin ?? "", this);
            RemoteControlServer.Shared.ApplyWeb(options.RemoteWebEnabled ?? true, options.RemoteWebPort ?? 8105, options.RemoteWebPassword ?? "",
                                                options.RemoteWebName ?? "slovo", options.RemoteWebViewOnly ?? false, options.RemoteWebNoPort ?? true);
        }
        // Веб-слайди: Web і WebSocket-сервер за налаштуваннями (AppState.Web.cs).
        ApplyWebOutput(options);
        // Трансляція NDI — за «Параметри → Медіа» (у знімках — лише для перевірки).
        if (!Program.Snapshotting || NdiOutput.ForceEnabled) NdiOutput.Shared.Apply(options);
    }

    // --- Знімок слайда (F11) ------------------------------------------------------------

    /// Зберегти слайд тим самим малювальником, що й зал, у теку ScreenShots і
    /// показати файл у Провіднику (тихе збереження не відрізнити від «нічого»).
    public void SaveScreenshot()
    {
        var (width, height) = ProjectionController.Shared.FrameSize();
        var order = new SlideDrawing.Order
        {
            Slide = Slide, Style = Style, Preset = SlidePreset, Texts = Texts(Slide), BackgroundOverride = BackgroundOverride,
            WithSecondTranslation = Slide.SecondaryTexts.Count > 0, ImagePath = PresetImagePath,
        };
        order.ResolveImages();
        try
        {
            using var surface = SkiaSharp.SKSurface.Create(new SkiaSharp.SKImageInfo(width, height));
            SlideDrawing.Draw(order, surface.Canvas, width, height);
            using var image = surface.Snapshot();
            using var png = image.Encode(SkiaSharp.SKEncodedImageFormat.Png, 100);
            var folder = Path.Combine(DataHome.Folder, "ScreenShots");
            Directory.CreateDirectory(folder);
            var file = Path.Combine(folder, $"slide_{DateTime.Now:yyyy-MM-dd'T'HH-mm-ss}.png");
            using (var stream = File.Create(file)) png.SaveTo(stream);
            Journal.Say($"знімок слайда: {file}");
            if (OperatingSystem.IsWindows())
                System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{file}\"");
        }
        catch (Exception error) { Journal.Say($"знімок слайда не записався: {error.Message}"); }
    }
}

/// Клас книг у записі «на чому зупинилися» — як rawValue на Mac.
public static class BookClassRaw
{
    public static string RawValue(BookClass c) => c switch
    {
        BookClass.Old => "old", BookClass.New => "new", BookClass.Apocrypha => "apocrypha", _ => "all",
    };
    public static BookClass? FromRaw(string? raw) => raw switch
    {
        "all" => BookClass.All, "old" => BookClass.Old, "new" => BookClass.New, "apocrypha" => BookClass.Apocrypha, _ => null,
    };
}
