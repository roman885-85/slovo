// =============================================================================
//  WebSlideEditorWindow.cs — майстерня веб-слайдів (за NativeWebSlideEditor.swift
//  і WebSlideEditorWindow.swift)
// =============================================================================
//  Зліва сторінки (свої — олівцем, з комплекту — замком), посередині ручки
//  оформлення або розмітка, праворуч живий результат. Ползунки й правки руками
//  живуть мирно: і ті, й інші міняють той самий текст сторінки.
//  Розкладка — числами з layout() Mac: вікно 1240×760 (скільки дозволяє екран),
//  найменше 720×460; полоси кнопок угорі й під сценою переносять ряди.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Avalonia.Platform.Storage;
using Slovo.Core;

namespace Slovo.App;

public sealed class WebSlideEditorWindow : Window, ISnapshotWork, IRowSource
{
    static WebSlideEditorWindow? _shown;

    public static WebSlideEditorWindow Open(AppState state)
    {
        if (_shown is { } open) { open.Activate(); return open; }
        var window = _shown = new WebSlideEditorWindow(state);
        window.Closed += (_, _) => _shown = null;
        if (MainWindow.Shared is { } owner && ((Visual)owner).IsVisible) window.Show(owner); else window.Show();
        return window;
    }

    static string T(string text, params object[] args) => args.Length == 0 ? Captions.T(text) : Captions.T(text, args);

    readonly AppState _state;
    readonly WebSlideEditorModel _model = new();
    readonly LayoutPanel _panel = new();
    readonly FlowBar _toolbar = new();
    readonly RowList _pages;
    readonly Border _pagesFrame;
    readonly MiddleLabel _pageTitle = new(12, FontWeight.SemiBold) { Tint = () => Palette.Label };
    readonly Segmented _tabs;
    readonly WebSlideKnobsPanel _knobs = new();
    readonly TextBox _markup;
    readonly Border _markupFrame;
    readonly WebSlideStage _stage;
    readonly FlowBar _sampleBar = new();
    readonly MiddleLabel _status = new(11, FontWeight.Normal);
    readonly PopupButton _samplePopup;
    readonly PushButton _save, _browser;
    readonly MacCheckBox _blank;
    /// Що показано посередині: ручки чи розмітка.
    bool _showsMarkup;
    /// Яким був список сторінок минулого разу.
    string _listed = "";
    bool _settingMarkup;

    WebSlideEditorWindow(AppState state)
    {
        _state = state;
        Title = T("Редактор веб-слайдов");
        // Розмір — «скільки є екрана»: 1240×760 на ноутбуці не влазило, і полоси кнопок обрізалися.
        var free = Screens?.Primary?.WorkingArea is { } area && Screens.Primary.Scaling > 0
            ? new Size(area.Width / Screens.Primary.Scaling, area.Height / Screens.Primary.Scaling)
            : new Size(1240, 760);
        Width = Math.Min(1240, Math.Max(760, free.Width - 40));
        Height = Math.Min(760, Math.Max(520, free.Height - 40));
        MinWidth = 720;
        MinHeight = 460;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Palette.Brush(Palette.WindowBackground);
        Palette.Changed += () => Background = Palette.Brush(Palette.WindowBackground);

        // ── Полоса вгорі ──
        var create = Button(T("Новая из заготовки"), null, () => _ = CreatePage());
        var duplicate = Button(T("Взять за основу"), T("Сделать свою копию открытой страницы и править её"), () => _model.DuplicateCurrent());
        // «Зберегти» доступна завжди: авторську сторінку сама копіює у свої і зберігає копію.
        _save = Button(T("Сохранить"), null, SaveNow);
        _browser = Button(T("Открыть в браузере"), null, () => _model.OpenInBrowser(HttpPort));
        _toolbar.SetItems(new Control[] { create, duplicate, _save, _browser });

        // ── Сторінки ──
        _pages = new RowList(new ListMetrics
        {
            LeadWidth = 28, LeadAlign = TextAlignment.Center, Padding = new Thickness(3, 5, 3, 5), TextFontDelta = 0,
            Background = () => Palette.TextBackground,
        }, 13) { Source = this };
        _pages.ContentInset = new Thickness(0);
        _pages.SetUniformHeight(26);
        _pages.OnSelect = (_, active, cause) =>
        {
            if (cause == SelectCause.Code) return;
            var list = AllPages;
            if (active >= 0 && active < list.Count) _model.Open(list[active]);
        };
        _pagesFrame = new Border { Child = _pages, BorderThickness = new Thickness(1) };

        // ── Над ручками: ім'я сторінки з адресою і «Повзунки | Розмітка» ──
        _tabs = new Segmented(new[] { T("Ползунки"), T("Разметка") }, 13) { SelectedIndex = 0 };
        _tabs.Selected += index => TabChanged(index == 1);

        _knobs.Model = _model;
        _knobs.Owner = () => this;

        _markup = new TextBox
        {
            AcceptsReturn = true, AcceptsTab = false, TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily("Cascadia Mono,Consolas,Menlo,monospace"), FontSize = 12,
            BorderThickness = new Thickness(0), Padding = new Thickness(4), MinHeight = 0, MinWidth = 0,
        };
        // TextChanging, а не TextChanged: текст, поставлений програмою, не має повертатися як набраний.
        _markup.TextChanging += (_, _) =>
        {
            if (_settingMarkup || _model.Current?.IsEditable != true) return;
            _model.Source = _markup.Text ?? "";
        };
        _markupFrame = new Border { Child = _markup, BorderThickness = new Thickness(1), IsVisible = false };

        _stage = new WebSlideStage(_model) { SaveShortcut = SaveNow };

        // ── Під сценою: чим наповнити слайд ──
        _samplePopup = new PopupButton(WebSlideSample.All.Select(sample => sample.Title), 0) { FontSize = 13, ArrowInset = 10 };
        _samplePopup.Selected += index => { if (index >= 0 && index < WebSlideSample.All.Count) _model.Sample = WebSlideSample.All[index]; };
        var fromSlide = Button(T("Со слайда"), T("Взять текст, который программа показывает прямо сейчас"), () =>
        {
            var slide = _state.Slide;
            _model.TakeSample(slide.MainText, slide.SecondaryTexts.FirstOrDefault() ?? "", slide.Reference);
        });
        _blank = new MacCheckBox(T("Пустой экран в зале"), 11, 14) { IsChecked = _model.IsBlankScreen };
        ToolTip.SetTip(_blank, T("Так страница выглядит, когда показ выключен"));
        _blank.Toggled += on => _model.IsBlankScreen = on;
        var replay = Button(T("Показать заново"), null, _model.Replay);
        // Своя картинка під сторінку: видно, як титри стануть на кадр із залу.
        var backdrop = Button(T("Своя картинка…"), T("Подложить свой файл под предпросмотр — как будет выглядеть поверх кадра"), () => _ = ChooseBackdrop());
        var noBackdrop = Button(T("Убрать картинку"), null, () => _stage.SetBackdrop(null));
        _sampleBar.SetItems(new Control[] { _samplePopup, fromSlide, _blank, replay, backdrop, noBackdrop });

        _status.Tint = () => Palette.SecondaryLabel;

        foreach (Control control in new Control[] { _toolbar, _pagesFrame, _pageTitle, _tabs, _knobs, _markupFrame, _stage, _sampleBar, _status })
            _panel.Children.Add(control);
        _panel.Layout = Arrange;
        Content = _panel;
        ApplyFrames();
        Palette.Changed += ApplyFrames;

        _model.Changed += Refresh;
        _model.Broadcast = values => _state.Web.PublishStyle(values);
        _model.Reload(DataRoot);
        Refresh();
        // Закрили вікно — недописані правки мусять лягти на диск.
        Closing += (_, _) => _model.FlushSave();
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.S && e.KeyModifiers.HasFlag(KeyModifiers.Control)) { SaveNow(); e.Handled = true; }
        };
    }

    /// Порт сторінок: справжній, коли сервер працює (міг піти на запасний 8082), інакше — з налаштувань.
    /// На Mac тут завжди порт із налаштувань — і при запасному порті посилання вело в нікуди.
    int HttpPort => _state.Web.CurrentStatus.HttpPort ?? _state.WebSettings.HttpPort;

    string DataRoot => Path.GetDirectoryName(_state.ModulesFolder.TrimEnd(Path.DirectorySeparatorChar, '/')) is { Length: > 0 } root ? root : DataHome.Folder;

    void ApplyFrames()
    {
        _pagesFrame.BorderBrush = Palette.Brush(Palette.Separator);
        _markupFrame.BorderBrush = Palette.Brush(Palette.Separator);
        _markup.Background = Palette.Brush(Palette.TextBackground);
        _markup.Foreground = Palette.Brush(Palette.Label);
    }

    static PushButton Button(string title, string? hint, Action action)
    {
        var button = new PushButton(title) { FontSize = 11 };
        if (hint != null) ToolTip.SetTip(button, hint);
        button.Pressed = action;
        return button;
    }

    // ── Дії ───────────────────────────────────────────────────────────────────

    void SaveNow()
    {
        if (_model.Current is not { } page) return;
        if (!page.IsEditable && !_model.DuplicateCurrent()) return;
        _model.Save();
        Refresh();
    }

    void TabChanged(bool markup)
    {
        _showsMarkup = markup;
        _knobs.IsVisible = !markup;
        _markupFrame.IsVisible = markup;
        // Текст розмітки наливаємо тільки тоді, коли його показують.
        if (markup && _markup.Text != _model.Source) SetMarkup(_model.Source);
        _panel.InvalidateArrange();
    }

    void SetMarkup(string text)
    {
        _settingMarkup = true;
        _markup.Text = text;
        _settingMarkup = false;
    }

    /// Вибрати свій файл, який ляже під сторінку в передпоказі.
    async Task ChooseBackdrop()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = T("Картинка ляжет под страницу — только в предпросмотре"),
            AllowMultiple = false,
            FileTypeFilter = new[] { FilePickerFileTypes.ImageAll },
        });
        if (files.Count == 0 || files[0].TryGetLocalPath() is not { } path) return;
        _stage.SetBackdrop(path);
    }

    /// Нова сторінка із заготовки: ім'я і заготовка — одним вікном (як NSAlert на Mac).
    async Task CreatePage()
    {
        var done = new TaskCompletionSource<(string Name, int Template)?>();
        var window = new Window
        {
            Title = "", Width = 420, Height = 170, CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Palette.Brush(Palette.WindowBackground),
        };
        var name = new FormField(12) { Placeholder = T("Имя файла страницы") };
        var templates = new PopupButton(WebSlideTemplates.All.Select(template => OurWords.T(template.Title)), 0) { FontSize = 13, ArrowInset = 10 };
        (string, int)? result = null;
        var ok = new PushButton(Captions.FormCaption("BBOk", "SettingsForm", "Ок")) { Prominent = true };
        var cancel = new PushButton(Captions.FormCaption("BBCancel", "SettingsForm", "Отмена")) { Pressed = window.Close };
        void Accept() { result = (name.Text, templates.SelectedIndex); window.Close(); }
        ok.Pressed = Accept;
        name.OnSubmit = _ => Accept();
        var heading = new BottomCaption { Text = T("Новая из заготовки"), FontSize = 13, Weight = FontWeight.SemiBold, Color = () => Palette.Label };
        var panel = new LayoutPanel();
        foreach (Control c in new Control[] { heading, name, templates, ok, cancel }) panel.Children.Add(c);
        panel.Layout = size =>
        {
            panel.Place(heading, new Rect(20, 16, size.Width - 40, 18));
            // Допоміжний вигляд NSAlert — 380×56: поле вгорі, список під ним.
            var left = Math.Round((size.Width - 380) / 2);
            panel.Place(name, new Rect(left, 44, 380, 22));
            panel.Place(templates, new Rect(left, 74, 380, 24));
            var w = Math.Max(90, ok.FittingWidth + 24);
            panel.Place(ok, new Rect(size.Width - 20 - w, size.Height - 44, w, 24));
            var c = Math.Max(90, cancel.FittingWidth + 24);
            panel.Place(cancel, new Rect(size.Width - 20 - w - 8 - c, size.Height - 44, c, 24));
        };
        window.Content = panel;
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) window.Close(); else if (e.Key == Key.Enter) Accept(); };
        window.Closed += (_, _) => done.TrySetResult(result);
        await window.ShowDialog(this);
        if (await done.Task is not { } chosen) return;
        var title = chosen.Name.TrimWhitespaces();
        if (title.Length == 0 || chosen.Template < 0 || chosen.Template >= WebSlideTemplates.All.Count) return;
        _model.Create(WebSlideTemplates.All[chosen.Template], title);
        _pages.Reload();
    }

    void OfferCopy()
    {
        _model.OffersCopy = false;
        Alert.Ask(T("Это страница из комплекта программы"),
                  T("Чужие файлы редактор не трогает. Сделаем копию в ваших страницах — и настраивайте её сколько угодно."),
                  new[] { T("Сделать свою копию"), T("Отмена") },
                  answer => { if (answer == 0) _model.DuplicateCurrent(); }, this);
    }

    // ── Оновлення ─────────────────────────────────────────────────────────────

    List<WebSlideEditorModel.Page> AllPages => _model.MyPages.Concat(_model.AuthorPages).ToList();

    void Refresh()
    {
        // Поруч з іменем — адреса, за якою сторінку вбудовують в OBS чи відкривають у браузері.
        var address = "";
        if (_model.Current is { } page)
        {
            var host = _state.Web.CurrentStatus.Addresses.FirstOrDefault() ?? "127.0.0.1";
            address = "  —  " + WebPageAddress.Url(host, HttpPort, page.Name);
        }
        _pageTitle.Text = (_model.Current?.Name ?? T("Страница не выбрана")) + address
                          + (_model.IsModified ? "  • " + T("не сохранено") : "");
        _save.IsEnabled = _model.Current != null;
        var running = _state.Web.IsRunning;
        _browser.IsEnabled = running;
        ToolTip.SetTip(_browser, running ? T("Показать через работающий веб-сервер") : T("Сначала включите веб-слайды в настройках вывода"));
        _markup.IsReadOnly = _model.Current?.IsEditable != true;
        // Один крок повзунка переписує всю сторінку: наливати текст у сховану розмітку
        // сорок разів на секунду — робота на порожньому місці.
        if (_showsMarkup && _markup.Text != _model.Source && !_markup.IsFocused) SetMarkup(_model.Source);
        var sampleIndex = WebSlideSample.All.ToList().FindIndex(sample => sample.Id == _model.Sample.Id);
        if (sampleIndex >= 0) _samplePopup.SelectedIndex = sampleIndex;
        _blank.IsChecked = _model.IsBlankScreen;
        _status.Text = _model.Current?.IsEditable == false
            ? T("только чтение — чужие файлы редактор не трогает")
            : T("Правки руками и ползунки живут мирно: и те и другие меняют этот самый текст.");
        _knobs.Refresh();
        _stage.Refresh();
        // Список сторінок перебираємо лише тоді, коли він і справді змінився.
        var listing = string.Join("\u0001", AllPages.Select(item => item.Id + (item.IsEditable ? "✎" : "🔒")))
                      + "\u0002" + (_model.Current?.Id ?? "");
        if (listing != _listed)
        {
            _listed = listing;
            _pages.Reload();
        }
        if (_model.OffersCopy) OfferCopy();
        _panel.InvalidateArrange();
    }

    // ── Розкладка ─────────────────────────────────────────────────────────────

    void Arrange(Size size)
    {
        const double gap = 8;
        // Полоси міряємо самі: у вузькому вікні вони йдуть у два ряди.
        var toolbarHeight = _toolbar.HeightFor(size.Width - gap * 2);
        _panel.Place(_toolbar, new Rect(gap, gap, Math.Max(0, size.Width - gap * 2), toolbarHeight));
        var top = gap + toolbarHeight + gap;
        var bottom = size.Height - 30;

        const double listWidth = 210;
        _panel.Place(_pagesFrame, new Rect(gap, top, listWidth, Math.Max(0, bottom - top)));

        var middleLeft = listWidth + gap * 2;
        // Панель ручок не має з'їдати передпоказ: бере свою частку, але не більше трьох п'ятих.
        var free = size.Width - middleLeft - gap;
        var middleWidth = Math.Min(Math.Max(240, free * 0.42), Math.Max(240, free * 0.6));
        // Ім'я сторінки ужимається (трикрапкою посередині), перемикач стоїть цілим.
        var tabsWidth = Math.Ceiling(_tabs.FittingWidth);
        _panel.Place(_tabs, new Rect(middleLeft + middleWidth - tabsWidth, top + 1, tabsWidth, 24));
        _panel.Place(_pageTitle, new Rect(middleLeft, top + 5, Math.Max(0, middleWidth - tabsWidth - 8), 16));
        var middleTop = top + 26 + 4;
        var knobsRect = new Rect(middleLeft, middleTop, middleWidth, Math.Max(0, bottom - middleTop));
        _panel.Place(_knobs, knobsRect);
        _panel.Place(_markupFrame, knobsRect);

        var stageLeft = middleLeft + middleWidth + gap;
        var stageWidth = Math.Max(0, size.Width - stageLeft - gap);
        var sampleHeight = _sampleBar.HeightFor(stageWidth);
        var sampleTop = Math.Max(top, bottom - sampleHeight - 4);
        _panel.Place(_sampleBar, new Rect(stageLeft, sampleTop, stageWidth, sampleHeight));
        _panel.Place(_stage, new Rect(stageLeft, top, stageWidth, Math.Max(0, sampleTop - top - 6)));
        _panel.Place(_status, new Rect(gap, size.Height - 24, Math.Max(0, size.Width - gap * 2), 16));
    }

    // ── Список сторінок ───────────────────────────────────────────────────────

    public int RowCount => _model.MyPages.Count + _model.AuthorPages.Count;

    public Row RowAt(int index)
    {
        var page = AllPages[index];
        return new Row(page.Title)
        {
            LeadSymbol = page.IsEditable ? "pencil" : "lock.fill",
            SingleLine = true,
            TextColor = page.IsEditable ? null : Palette.SecondaryLabel,
        };
    }

    public ContextMenu? MenuAt(int index)
    {
        var list = AllPages;
        if (index < 0 || index >= list.Count || !list[index].IsEditable) return null;
        var page = list[index];
        return MenuStrip.Build(new[] { new MenuEntry(T("Удалить"), () => { _model.Delete(page); _pages.Reload(); }) });
    }

    // ── Знімки без екрана ─────────────────────────────────────────────────────

    public bool IsWorking => false;

    /// `--web-section N` — відкрити розділ ручок (0…4), `--web-page <ім'я>` — сторінку, `--web-markup` — розмітку;
    /// `--web-knob ім'я=значення` — через 6 с рухнути ручку так, як рука (перевірка трансляції значень
    /// сторінкам і запису у файл; веб-вивід піднімається, якщо дали `--web-slides-port`).
    public void Begin(string[] args)
    {
        string? Arg(string name) => Array.IndexOf(args, name) is var i and >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        if (AppState.WebPortOverride != null && !_state.Web.IsRunning) { _state.ApplyWebOutputNow(); Refresh(); }
        if (Arg("--web-knob") is { } knobArg && knobArg.IndexOf('=') is var eq and > 0)
        {
            var (name, value) = (knobArg[..eq], knobArg[(eq + 1)..]);
            // Таймери диспетчера без екрана не йдуть — чекаємо звичайною затримкою.
            _ = Task.Delay(TimeSpan.FromSeconds(6)).ContinueWith(_ => Avalonia.Threading.Dispatcher.UIThread.Post(() =>
            {
                if (_model.Sheet.Knobs.FirstOrDefault(knob => knob.Name == name) is { } knob)
                {
                    _model.Change(knob, value);
                    Console.WriteLine($"  веб-редактор: ручка {name} → {value} ({_model.Current?.Name})");
                }
                else Console.WriteLine($"  веб-редактор: ручки {name} у цій сторінці немає");
            }));
        }
        if (Arg("--web-page") is { } wanted && AllPages.FirstOrDefault(page => page.Name == wanted || page.Title == wanted) is { } page)
            _model.Open(page);
        if (Arg("--web-section") is { } raw && int.TryParse(raw, out var section) && section >= 0 && section < WebSlideSections.All.Count)
            _knobs.Show(WebSlideSections.All[section]);
        if (args.Contains("--web-markup")) { _tabs.SelectedIndex = 1; TabChanged(true); }
        Refresh();
        Snapshot.Pump(4);
    }

    /// Рядок в одну лінію з трикрапкою посередині (lineBreakMode .byTruncatingMiddle).
    sealed class MiddleLabel : Control
    {
        readonly double _size;
        readonly FontWeight _weight;
        string _text = "";
        public Func<Color> Tint { get; set; } = () => Palette.SecondaryLabel;

        public MiddleLabel(double size, FontWeight weight)
        {
            _size = size;
            _weight = weight;
            Palette.Changed += InvalidateVisual;
        }

        public string Text { get => _text; set { if (_text == value) return; _text = value; InvalidateVisual(); } }

        double Width(string text) => UiFont.Width(text, _size, _weight);

        string Fitted(double width)
        {
            if (_text.Length == 0 || Width(_text) <= width) return _text;
            int lo = 0, hi = _text.Length - 1;
            string Cut(int keep) => _text[..((keep + 1) / 2)] + "…" + _text[(_text.Length - keep / 2)..];
            while (lo < hi)
            {
                var mid = (lo + hi + 1) / 2;
                if (Width(Cut(mid)) <= width) lo = mid; else hi = mid - 1;
            }
            return Cut(lo);
        }

        public override void Render(DrawingContext g)
        {
            var text = Fitted(Math.Max(0, Bounds.Width - 4));
            if (text.Length == 0) return;
            TextDraw.Draw(g, text, new Rect(2, 0, Math.Max(0, Bounds.Width - 2), Bounds.Height), _size, Tint(), _weight, wrap: false, trim: false);
        }
    }
}
