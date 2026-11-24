// =============================================================================
//  ShowWorkspace.cs — вкладки «Зображення» і «Презентація» (як NativeShowWorkspace)
// =============================================================================
//  Згори смуга кнопок: додати, прибрати, очистити, назад, далі, «Показати»,
//  «Сховати», «Слайд-шоу» з кроком у секундах. Під нею у презентацій дві
//  колонки — файли й сторінки вибраного файла, у картинок одна; праворуч —
//  кадр сторінки й рядок стану («Слайд 3 — 3 з 12 · у залі»). Клацання —
//  вибір (і передпоказ), подвійне — у зал. Поки показ у залі, гортання міняє
//  й те, що бачать люди. Ширини колонок тягнуться й пам'ятаються.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Platform.Storage;
using Slovo.Core;

namespace Slovo.App;

public sealed class ShowWorkspace : LayoutPanel, IRowSource
{
    static ShowWorkspace? _pictures, _presentation;
    /// Два робочі місця на всю програму — їх кличуть і вкладки, і пульт, і План.
    public static ShowWorkspace Pictures => _pictures ??= new ShowWorkspace(AppState.Shared, ShowModel.Kind.Pictures);
    public static ShowWorkspace Presentation => _presentation ??= new ShowWorkspace(AppState.Shared, ShowModel.Kind.Presentation);
    public static ShowWorkspace? For(WorkMode mode) => mode switch { WorkMode.Pictures => Pictures, WorkMode.Presentation => Presentation, _ => null };

    /// Пункт «Файл» із плану проповіді: презентація чи картинка — відкрити (уже відкритий
    /// не вдруге) і одразу показати сторінку файла. Звук і відео — не сюди (плеєр, MainWindow).
    public static bool OpenFromPlan(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        var isPresentation = ShowModel.Extensions(ShowModel.Kind.Presentation).Contains(ext);
        if (!isPresentation && !ShowModel.Extensions(ShowModel.Kind.Pictures).Contains(ext)) return false;
        var workspace = isPresentation ? Presentation : Pictures;
        var wanted = Path.GetFullPath(path);
        bool Same(ShowModel.Deck d) => string.Equals(Path.GetFullPath(d.Path), wanted, StringComparison.OrdinalIgnoreCase);
        if (!workspace.Model.Decks.Any(Same)) workspace.Open(new[] { path });
        var state = AppState.Shared;
        var mode = isPresentation ? WorkMode.Presentation : WorkMode.Pictures;
        if (state.Mode != mode) { state.Mode = mode; Signals.Shared.Send(Signals.Kind.Mode); }
        var deck = workspace.Model.Decks.FindIndex(Same);
        if (deck < 0) return true;
        workspace.SelectDeck(deck);
        workspace.SelectPage(workspace.Model.Decks[deck].Start);
        workspace.ShowCurrentPage();
        return true;
    }

    public readonly ShowModel Model;
    readonly AppState _state;
    readonly RowList _files, _list;
    readonly SlideFrameView _preview = new();
    readonly BottomCaption _caption = new() { FontSize = 11 };
    readonly List<PushButton> _tools = new();
    readonly PushButton _show, _hide, _slideshowButton;
    readonly FormField _seconds = new(13, true);
    readonly BottomCaption _secondsLabel = new() { FontSize = 13 };
    readonly WidthGrip _firstGrip = new(), _secondGrip = new();
    Avalonia.Threading.DispatcherTimer? _slideshow;
    int? _shownDeck;
    /// Що зараз у залі від показу — щоб наближення не скидалося на тій самій сторінці.
    static string? _shownPageMark;

    ShowWorkspace(AppState state, ShowModel.Kind kind)
    {
        _state = state;
        // Кадр сторінки вписується зі збереженням сторін (imageScaling .scaleProportionallyUpOrDown).
        _preview.Surface.FitsAspect = true;
        Model = new ShowModel(kind) { Remembers = !Program.Snapshotting || Environment.GetEnvironmentVariable("SLOVO_SHOW_MEMORY") == "1" };
        // Список, зібраний до служіння, переживає закриття програми.
        Model.Restore();
        var mode = kind == ShowModel.Kind.Pictures ? WorkMode.Pictures : WorkMode.Presentation;
        state.ShowTabs[mode] = this;

        _files = new RowList(new ListMetrics { LeadWidth = 0, DetailWidth = 36 }, 13) { Source = new DeckRows(this) };
        _files.SetUniformHeight(26);
        _list = new RowList(new ListMetrics { LeadWidth = 34 }, 13) { Source = this };
        _list.SetUniformHeight(26);
        // Рядок колонки сторінок — сторінка вибраної колоди, а не наскрізний номер.
        _list.OnSelect = (_, active, cause) => { if (cause == SelectCause.Code) return; Model.Select(Model.CurrentRange.Start + active); Refresh(); };
        // Подвійне клацання — у зал, як подвійне по вірші.
        _list.OnActivate = position => { Model.Select(Model.CurrentRange.Start + position); Show(); };
        _files.OnSelect = (_, active, cause) => { if (cause != SelectCause.Code) ChooseDeck(active); };
        _files.OnActivate = position => { ChooseDeck(position); Show(); };

        PushButton Tool(string symbol, Action action)
        {
            var b = new PushButton("", symbol) { Margin = 0.5, Pressed = action, SymbolSize = 14 };
            _tools.Add(b);
            return b;
        }
        Tool("plus", () => _ = OpenFiles());
        Tool("minus", RemoveCurrentEntry);
        Tool("xmark", CloseShow);
        Tool("chevron.left", () => Step(-1));
        Tool("chevron.right", () => Step(1));
        _show = new PushButton("") { Margin = 0.5, Pressed = Show };
        _hide = new PushButton("") { Margin = 0.5, Pressed = Hide };
        // Слайд-шоу: сторінки гортаються самі, з обраним кроком, по колу.
        _slideshowButton = new PushButton("") { Margin = 0.5, Pressed = ToggleSlideshow };
        _seconds.Text = SlideshowSeconds.ToString();
        _seconds.OnSubmit = text => SetSeconds(text);
        _seconds.OnChange = text => SetSeconds(text);
        foreach (Control c in _tools.Cast<Control>().Concat(new Control[] { _show, _hide, _slideshowButton, _seconds, _secondsLabel,
                                                                            _files, _list, _preview, _caption, _firstGrip, _secondGrip }))
            Children.Add(c);
        _firstGrip.OnDrag = delta =>
        {
            var column = kind == ShowModel.Kind.Presentation ? _files : _list;
            Widths.Set(FirstKey, column.Bounds.Width + delta, 120, Math.Max(120, Bounds.Width * 0.5));
            InvalidateArrange();
        };
        _firstGrip.OnReset = () => { Widths.Reset(FirstKey); InvalidateArrange(); };
        _secondGrip.OnDrag = delta => { Widths.Set(SecondKey, _list.Bounds.Width + delta, 120, Math.Max(120, Bounds.Width * 0.5)); InvalidateArrange(); };
        _secondGrip.OnReset = () => { Widths.Reset(SecondKey); InvalidateArrange(); };
        // Рядок стану збирає Refresh — після зміни мови його теж треба перекласти.
        Signals.Shared.Subscribe(Signals.Kind.Language, () => { ApplyCaptions(); Refresh(); });
        Signals.Shared.Subscribe(Signals.Kind.Live, Refresh);
        ApplyCaptions();
        ReloadLists();
        Refresh();
    }

    string FirstKey => Model.ShowKind == ShowModel.Kind.Presentation ? "presentationFilesWidth" : "picturesListWidth";
    const string SecondKey = "presentationPagesWidth";

    static int SlideshowSeconds => Defaults.Has("showSlideshowSeconds") ? Math.Clamp(Defaults.Int("showSlideshowSeconds"), 1, 600) : 6;

    void SetSeconds(string text)
    {
        if (!int.TryParse(text.Trim(), out var value)) return;
        Defaults.Set("showSlideshowSeconds", Math.Clamp(value, 1, 600));
        if (_slideshow != null) StartSlideshow();
    }

    // --- Підписи ------------------------------------------------------------------------

    void ApplyCaptions()
    {
        var pictures = Model.ShowKind == ShowModel.Kind.Pictures;
        _show.Title = Captions.Caption("SBShowOutScr", Captions.T("Показать"));
        _hide.Title = Captions.Caption("SBHideOutScr", Captions.T("Скрыть"));
        ToolTip.SetTip(_tools[0], Captions.T(pictures ? "Добавить картинки или папку с ними" : "Добавить презентацию или PDF"));
        ToolTip.SetTip(_tools[1], Captions.T(pictures ? "Убрать картинку из списка" : "Убрать презентацию из списка"));
        ToolTip.SetTip(_tools[2], Captions.T("Очистить список"));
        ToolTip.SetTip(_tools[3], Captions.T("Предыдущая страница"));
        ToolTip.SetTip(_tools[4], Captions.T("Следующая страница"));
        ToolTip.SetTip(_show, Captions.T("Показать слайд"));
        ToolTip.SetTip(_hide, Captions.T("Скрыть слайд"));
        _secondsLabel.Text = Captions.T("с");
        ApplySlideshowCaption();
        InvalidateArrange();
    }

    void ApplySlideshowCaption()
    {
        _slideshowButton.Title = _slideshow == null ? Captions.T("Слайд-шоу") : Captions.T("Остановить");
        ToolTip.SetTip(_slideshowButton, Captions.T("Показывать страницы одну за другой, по кругу"));
        _slideshowButton.InvalidateVisual();
    }

    // --- Розкладка (за NativeShowWorkspace.layout) ------------------------------------------

    protected override void Arrangement(Size size)
    {
        const double gap = 8, toolbarHeight = 28, bezel = 22;
        // Смуга кнопок: рамки впритул до видимих рамок, між ними 7 точок (знімок Mac).
        var x = gap;
        var y = gap + Math.Round((toolbarHeight - bezel) / 2);
        for (var i = 0; i < _tools.Count; i++)
        {
            // Шеврони вужчі за «+», «−», «×» — як рамки NSButton за шириною значка.
            var width = i >= 3 ? 26 : 29;
            Place(_tools[i], new Rect(x, y, width, bezel));
            x += width + 7;
        }
        foreach (var button in new[] { _show, _hide, _slideshowButton })
        {
            var width = Math.Max(52, Math.Ceiling(UiFont.Width(button.Title, 13) + 20));
            Place(button, new Rect(x, y, width, bezel));
            x += width + 7;
        }
        Place(_seconds, new Rect(x + 1, y, 51, bezel));
        x += 51 + 8;
        Place(_secondsLabel, new Rect(x, y + 3, 20, 16));

        var top = gap + toolbarHeight + gap;
        var height = Math.Max(0, size.Height - top - gap);
        const double grip = 7;
        double right;
        if (Model.ShowKind == ShowModel.Kind.Presentation)
        {
            // У презентацій дві колонки: файли й сторінки вибраного файла.
            var auto = Math.Max(150, Math.Min(260, size.Width * 0.2));
            var filesWidth = Widths.Value(FirstKey, auto, 120, Math.Max(120, size.Width * 0.5));
            var pagesWidth = Widths.Value(SecondKey, auto, 120, Math.Max(120, size.Width * 0.5));
            Place(_files, new Rect(gap, top, filesWidth, height));
            Place(_firstGrip, new Rect(gap + filesWidth, top, grip, height));
            Place(_list, new Rect(gap + filesWidth + grip, top, pagesWidth, height));
            Place(_secondGrip, new Rect(gap + filesWidth + grip + pagesWidth, top, grip, height));
            right = gap + filesWidth + grip + pagesWidth + grip + gap;
        }
        else
        {
            var listWidth = Math.Max(180, Math.Min(320, size.Width * 0.28));
            var width = Widths.Value(FirstKey, listWidth, 120, Math.Max(120, size.Width * 0.5));
            Place(_files, default);
            Place(_secondGrip, default);
            Place(_list, new Rect(gap, top, width, height));
            Place(_firstGrip, new Rect(gap + width, top, grip, height));
            right = gap + width + grip + gap;
        }
        const double captionHeight = 16;
        var previewHeight = Math.Max(0, height - captionHeight - 4);
        Place(_preview, new Rect(right, top, Math.Max(0, size.Width - right - gap), previewHeight));
        Place(_caption, new Rect(right, top + previewHeight + 4, Math.Max(0, size.Width - right - gap), captionHeight));
    }

    // --- Дії --------------------------------------------------------------------------------

    public void Open(IEnumerable<string> paths)
    {
        Model.Open(paths);
        ReloadLists();
        Refresh();
    }

    async Task OpenFiles()
    {
        if (TopLevel.GetTopLevel(this)?.StorageProvider is not { } storage) return;
        var pictures = Model.ShowKind == ShowModel.Kind.Pictures;
        var title = pictures
            ? Captions.T("Выберите картинки или папку с ними") + " (.jpg, .png, .heic, .gif, .webp, .bmp, .tif)"
            : Captions.T("Выберите презентацию или PDF") + " (.pdf, .pptx, .ppsx, .potx, .pptm, .ppsm)";
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = title,
            // Презентацій і PDF теж можна взяти кілька: список накопичується.
            AllowMultiple = true,
            FileTypeFilter = new[] { new FilePickerFileType(title) { Patterns = ShowModel.Extensions(Model.ShowKind).Select(e => "*." + e).ToList() } },
        });
        var paths = files.Select(f => f.TryGetLocalPath()).OfType<string>().ToList();
        if (paths.Count == 0) return;
        Open(paths);
    }

    void ReloadLists()
    {
        _files.Reload();
        _shownDeck = Model.ShowKind == ShowModel.Kind.Pictures ? 0 : Model.CurrentDeck ?? (Model.Decks.Count == 0 ? null : 0);
        _list.Reload();
        SyncLists();
    }

    void SyncLists()
    {
        var deck = Model.CurrentDeck ?? (Model.Decks.Count == 0 ? null : 0);
        var shownKey = Model.ShowKind == ShowModel.Kind.Pictures ? 0 : deck;
        if (shownKey != _shownDeck) { _shownDeck = shownKey; _list.Reload(); }
        _files.SetSelection(deck is { } d ? new[] { d } : Array.Empty<int>(), deck);
        var (start, count) = Model.CurrentRange;
        int? local = Model.Index is { } index && index - start >= 0 && index - start < count ? index - start : null;
        _list.SetSelection(local is { } l ? new[] { l } : Array.Empty<int>(), local);
        if (local is { } shown) _list.ScrollTo(shown);
    }

    public void ChooseDeck(int position)
    {
        Model.SelectDeck(position);
        SyncLists();
        Refresh();
    }

    public void SelectPage(int position)
    {
        Model.Select(position);
        SyncLists();
        Refresh();
    }

    public void SelectDeck(int position)
    {
        Model.SelectDeck(position);
        ReloadLists();
        Refresh();
    }

    public void ShowCurrentPage() => Show();

    public void HideCurrentPage() => Hide();

    /// «−»: у презентацій — увесь файл, у картинок — вибрана картинка.
    public void RemoveCurrentEntry()
    {
        if (Model.ShowKind == ShowModel.Kind.Presentation && (Model.CurrentDeck ?? (Model.Decks.Count == 0 ? null : 0)) is { } deck)
            Model.RemoveDeck(deck);
        else if (Model.Index is { } position) Model.Remove(position);
        else return;
        if (Model.IsEmpty) Hide();
        ReloadLists();
        Refresh();
        // Поки сторінка була в залі, її зняття міняє й зал.
        if (_state.StillShown && Model.CurrentImage != null) Show();
    }

    void CloseShow()
    {
        StopSlideshow();
        Model.Close();
        Hide();
        ReloadLists();
        Refresh();
    }

    /// Стрілки гортають показ — як вірші в Біблії; поки показ у залі, гортання міняє й зал.
    public bool Step(int delta, bool live = true)
    {
        if (!Model.Step(delta)) return false;
        SyncLists();
        Refresh();
        if (live && _state.StillShown) Show();
        return true;
    }

    /// «Показати» на вкладці показу: у зал іде сторінка, а не вірш.
    public bool ShowIfReady()
    {
        if (Model.CurrentImage == null) return false;
        Show();
        return true;
    }

    bool IsStillInHall(string? mark) => mark != null && mark == _shownPageMark && _state.IsLive && _state.LiveStill == mark;

    void Show()
    {
        if (Model.CurrentImage is not { } image || Model.CurrentPageMark is not { } mark) return;
        // Наближення — лише для сторінки, на якій його зробили.
        if (!IsStillInHall(mark)) SlideFocus.Shared.DropForNewPage();
        _shownPageMark = mark;
        // Картинка-файл іде в зал шляхом; сторінка документа — копією кадру під своїм знаком.
        if (Model.Pages[Model.Index!.Value].Source.Picture is { } path) _state.ShowStill(path, Model.CurrentTitle);
        else _state.ShowStill(mark, Copy(image), Model.CurrentTitle);
        Refresh();
    }

    void Hide()
    {
        _state.ClearStill();
        Refresh();
    }

    // --- Слайд-шоу ------------------------------------------------------------------------

    void ToggleSlideshow() { if (_slideshow == null) StartSlideshow(); else StopSlideshow(); }

    void StartSlideshow()
    {
        StopSlideshow(keepCaption: true);
        if (Model.IsEmpty) { ApplySlideshowCaption(); return; }
        // Перша сторінка — у зал одразу: чекати шість секунд незрозуміло.
        if (Model.Index == null) Model.Select(0);
        Show();
        _slideshow = new Avalonia.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(SlideshowSeconds) };
        _slideshow.Tick += (_, _) => Advance();
        _slideshow.Start();
        ApplySlideshowCaption();
    }

    void StopSlideshow(bool keepCaption = false)
    {
        _slideshow?.Stop();
        _slideshow = null;
        if (!keepCaption) ApplySlideshowCaption();
    }

    void Advance()
    {
        if (Model.IsEmpty) { StopSlideshow(); return; }
        if (Model.Index is { } current && current >= Model.Count - 1) Model.Select(0); else Model.Step(1);
        SyncLists();
        Show();
    }

    // --- Стан -------------------------------------------------------------------------------

    public void Refresh()
    {
        // Пульт стежить за сторінками показу: гортання мишею має доходити до телефона.
        RemoteControlServer.Shared.ScheduleCheck();
        var image = Model.CurrentImage;
        _preview.Surface.Show(image != null ? Copy(image) : null, false, "none", 0, "linear");
        var own = Model.ShowKind == ShowModel.Kind.Pictures ? WorkMode.Pictures : WorkMode.Presentation;
        if (_state.Mode == own) PublishPreview();
        var shown = _state.StillShown;
        var line = Model.Problem ?? "";
        if (line.Length == 0)
        {
            if (Model.IsEmpty) line = Captions.T(Model.ShowKind == ShowModel.Kind.Pictures ? "Картинки не выбраны" : "Презентация не открыта");
            else
            {
                // У презентацій лік — усередині файла: «Слайд 3 з 12».
                var (start, count) = Model.CurrentRange;
                var local = (Model.Index ?? start) - start + 1;
                line = Model.CurrentTitle + " — " + Captions.T("%s из %s", local.ToString(), count.ToString())
                       + (shown ? " · " + Captions.T("в зале") : "");
            }
        }
        _caption.Text = line;
        _caption.Color = Model.Problem == null ? () => Palette.SecondaryLabel : () => Palette.SystemOrange;
        _show.IsEnabled = image != null;
        _hide.IsEnabled = shown;
        InvalidateArrange();
    }

    /// Передпоказ своєї вкладки — вибрана сторінка.
    public void PublishPreview()
    {
        if (Model.CurrentImage is { } image && Model.CurrentPageMark is { } mark)
        {
            if (Model.Pages[Model.Index!.Value].Source.Picture is { } path) _state.SetPreviewStill(path);
            else { SlideImageStore.Shared.Pin(mark, Copy(image)); _state.SetPreviewStill(mark); }
        }
        else _state.SetPreviewStill(null);
    }

    /// Окремий примірник кадру (поверхні й сховище звільняють свої кадри самі).
    static SkiaSharp.SKImage Copy(SkiaSharp.SKImage image) => SkiaSharp.SKImage.FromBitmap(SkiaSharp.SKBitmap.FromImage(image));

    // --- Рядки ------------------------------------------------------------------------------

    public int RowCount => Model.CurrentRange.Count;

    public Row RowAt(int index)
    {
        var row = new Row { Lead = (index + 1).ToString() };
        var position = Model.CurrentRange.Start + index;
        if (position < 0 || position >= Model.Pages.Count) return row;
        row.Text = Model.Decks.Count == 0 ? Model.Pages[position].Title : Model.Pages[position].Short;
        return row;
    }

    sealed class DeckRows : IRowSource
    {
        readonly ShowWorkspace _owner;
        public DeckRows(ShowWorkspace owner) { _owner = owner; }
        public int RowCount => _owner.Model.Decks.Count;
        public Row RowAt(int index)
        {
            var decks = _owner.Model.Decks;
            if (index < 0 || index >= decks.Count) return new Row();
            return new Row(decks[index].Name, "", decks[index].Count.ToString()) { SingleLine = true };
        }
    }
}
