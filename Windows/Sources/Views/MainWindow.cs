// =============================================================================
//  MainWindow.cs — головне вікно «Слова»: каркас, меню, клавіші
// =============================================================================
//  Частини вікна згори вниз — як у «Слова» на Mac і в оригіналі: рядок меню,
//  вкладки режиму (Біблія | Пісні | Текст | Зображення) з повзунком кегля
//  списків, робоча область режиму, нижній ряд — План | Історія | Передпоказ і
//  зал | Керування. Вікно збирається кодом, а не розміткою: текст кожної
//  кнопки стоїть поруч із тим, що вона робить.
//
//  Гарячі клавіші — з hotkeys.ini (F5 показати, Esc сховати, F12 чорний…);
//  стрілки гортають вірші, частини пісні, сторінки й картинки.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Slovo.Views;

public sealed partial class MainWindow : Window
{
    readonly AppState _state;
    ProjectionController? _projection;
    bool _building;
    /// Службове вікно, відкрите командою пульта window-open (перевірки без екрана).
    Window? _serviceWindow;

    // Каркас
    readonly DockPanel _root = new();
    readonly Menu _menu = new();
    readonly StackPanel _modeTabs = new() { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(8, 4) };
    readonly Dictionary<string, Button> _modeButtons = new();
    readonly ContentControl _workspace = new();
    readonly Grid _bottom = new();
    readonly TextBlock _status = new() { Foreground = Ui.Muted, FontSize = 12, Margin = new Thickness(8, 2), TextTrimming = TextTrimming.CharacterEllipsis };
    readonly Slider _listFont = new() { Minimum = 10, Maximum = 24, Width = 110, VerticalAlignment = VerticalAlignment.Center };
    readonly Dictionary<string, Control> _workspaces = new();
    DispatcherTimer? _previewTimer;

    public AppState State => _state;

    public MainWindow(AppState state)
    {
        _state = state;
        Title = Lang.T("Слово", "Slovo");
        var s = state.Settings;
        Width = Math.Max(1000, s.WindowWidth);
        Height = Math.Max(640, s.WindowHeight);
        MinWidth = 900;
        MinHeight = 560;
        if (s.WindowX >= 0 && s.WindowY >= 0) { Position = new PixelPoint(s.WindowX, s.WindowY); WindowStartupLocation = WindowStartupLocation.Manual; }
        else WindowStartupLocation = WindowStartupLocation.CenterScreen;
        if (s.WindowMaximized) WindowState = WindowState.Maximized;
        try { Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://Slovo/Resources/AppIcon-256.png"))); }
        catch { /* без значка вікна — не біда */ }

        if (Program.QuietStart) ShowActivated = false;
        Build();
        state.Changed += OnStateChanged;
        state.FocusRequested += OnFocusRequested;
        state.WindowSnapshot = path =>
        {
            var target = _serviceWindow is { IsVisible: true } ? _serviceWindow : this;
            var scale = target.RenderScaling;
            var size = new PixelSize((int)Math.Max(1, target.Bounds.Width * scale), (int)Math.Max(1, target.Bounds.Height * scale));
            using var bitmap = new RenderTargetBitmap(size, new Vector(96 * scale, 96 * scale));
            bitmap.Render(target);
            bitmap.Save(path);
            return path;
        };
        state.WindowRequested = name =>
        {
            _serviceWindow?.Close();
            var tab = name.Contains(':') && int.TryParse(name[(name.IndexOf(':') + 1)..], out var t) ? t : -1;
            name = name.Split(':')[0];
            _serviceWindow = name switch
            {
                "settings" => new SettingsWindow(_state) { StartTab = tab },
                "resources" => new ResourcesWindow(_state, this),
                "editor" => _state.SongBook == null ? null : new SongEditorWindow(_state, _state.SongBookId, _state.SongIndex),
                _ => null,
            };
            _serviceWindow?.Show(this);
        };
        Lang.Changed += () => Dispatcher.UIThread.Post(Rebuild);
        AddHandler(KeyDownEvent, OnKeyDown, RoutingStrategies.Tunnel);
        Opened += (_, _) =>
        {
            FitToScreen();
            _projection = new ProjectionController(state, this);
            _projection.Changed += () => UpdateStatus();
            _projection.SetVisible(state.Settings.SlideWindowAtStart && !Program.QuietStart);
            state.StartServices();
            if (state.Pult != null) state.Pult.StatusChanged += () => Dispatcher.UIThread.Post(UpdateStatus);
            UpdateStatus();
            RefreshAll();
            _ = Updates.CheckQuietly(this, state);
            Screens.Changed += (_, _) => _projection?.RebuildIfScreensChanged();
            if (state.AllModules.Count == 0) Dispatcher.UIThread.Post(() => _ = OfferResources(), DispatcherPriority.Background);
        };
        Closing += (_, _) =>
        {
            RememberWindow();
            _projection?.SetVisible(false);
            state.Shutdown();
        };
    }

    /// Вікно не має вилазити за робочу область екрана: на ноутбуці 1366×768 і при
    /// масштабі 150–200 % типові 1420×860 більші за екран. Малий екран — на весь екран.
    void FitToScreen()
    {
        if (WindowState != WindowState.Normal) return;
        var screen = Screens.ScreenFromWindow(this) ?? Screens.Primary;
        if (screen == null) return;
        var scale = screen.Scaling <= 0 ? 1 : screen.Scaling;
        var area = screen.WorkingArea;
        double areaWidth = area.Width / scale, areaHeight = area.Height / scale;
        // Запас на рамку й заголовок вікна.
        double maxWidth = areaWidth - 16, maxHeight = areaHeight - 40;
        if (areaWidth < 1200 || areaHeight < 760 || Width > maxWidth || Height > maxHeight)
        {
            if (areaWidth < 1200 || areaHeight < 760) { WindowState = WindowState.Maximized; return; }
            Width = Math.Min(Width, maxWidth);
            Height = Math.Min(Height, maxHeight);
        }
        var frame = FrameSize ?? new Size(Width, Height + 32);
        var left = Position.X; var top = Position.Y;
        var widthPx = (int)(frame.Width * scale); var heightPx = (int)(frame.Height * scale);
        if (left < area.X || top < area.Y || left + widthPx > area.Right || top + heightPx > area.Bottom)
            Position = new PixelPoint(area.X + Math.Max(0, (area.Width - widthPx) / 2), area.Y + Math.Max(0, (area.Height - heightPx) / 2));
    }

    void RememberWindow()
    {
        var s = _state.Settings;
        s.WindowMaximized = WindowState == WindowState.Maximized;
        if (WindowState == WindowState.Normal)
        {
            s.WindowX = Position.X; s.WindowY = Position.Y;
            s.WindowWidth = (int)Width; s.WindowHeight = (int)Height;
        }
    }

    // MARK: Складання

    void Build()
    {
        _building = true;
        _root.Children.Clear();
        _modeTabs.Children.Clear();
        _modeButtons.Clear();
        _workspaces.Clear();
        _fontLists.Clear();

        BuildMenu();
        DockPanel.SetDock(_menu, Dock.Top);
        _root.Children.Add(_menu);

        // Вкладки режиму (18) і повзунок кегля списків (20).
        var tabsRow = new DockPanel { Margin = new Thickness(0, 0, 8, 0) };
        foreach (var mode in AppState.Modes)
        {
            var button = Ui.Button(AppState.ModeTitle(mode), () => _state.Mode = mode);
            button.Padding = new Thickness(16, 6);
            _modeButtons[mode] = button;
            _modeTabs.Children.Add(button);
        }
        DockPanel.SetDock(_modeTabs, Dock.Left);
        tabsRow.Children.Add(_modeTabs);
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        var slideWindow = Ui.Button(Lang.T("Вікно слайда", "Slide window"), () => _projection?.Toggle(), Lang.T("Показати чи сховати вікно слайда (проектор)", "Show or hide the slide window (projector)"));
        right.Children.Add(slideWindow);
        right.Children.Add(Ui.Label("A", 11));
        _listFont.Value = _state.Settings.ListFontSize;
        _listFont.PropertyChanged += (_, e) => { if (e.Property == RangeBase.ValueProperty && !_building) { _state.Settings.ListFontSize = Math.Round(_listFont.Value); ApplyListFont(); } };
        ToolTip.SetTip(_listFont, Lang.T("Розмір шрифту списків", "List font size"));
        right.Children.Add(_listFont);
        right.Children.Add(Ui.Label("A", 17, true));
        tabsRow.Children.Add(right);
        DockPanel.SetDock(tabsRow, Dock.Top);
        _root.Children.Add(tabsRow);

        DockPanel.SetDock(_status, Dock.Bottom);
        _root.Children.Add(_status);

        BuildBottom();
        DockPanel.SetDock(_bottom, Dock.Bottom);
        _root.Children.Add(_bottom);

        _workspaces["bible"] = BuildBible();
        _workspaces["songs"] = BuildSongs();
        _workspaces["text"] = BuildText();
        _workspaces["pictures"] = BuildPictures();
        _workspace.Margin = new Thickness(6, 0);
        _root.Children.Add(_workspace);

        Content = _root;
        _building = false;
        ApplyListFont();
        ShowMode();
    }

    void Rebuild()
    {
        Title = Lang.T("Слово", "Slovo");
        Build();
        RefreshAll();
        UpdateStatus();
    }

    void ApplyListFont()
    {
        var size = _state.Settings.ListFontSize;
        foreach (var control in _fontLists)
        {
            if (control is TemplatedControl templated) templated.FontSize = size;
            else if (control is TextBlock block) block.FontSize = size;
        }
    }

    readonly List<Control> _fontLists = new();

    void ShowMode()
    {
        foreach (var (mode, button) in _modeButtons)
        {
            var active = mode == _state.Mode;
            button.Background = active ? Ui.Accent : Ui.AccentSoft;
            button.Foreground = active ? Brushes.White : Brushes.Black;
            button.FontWeight = active ? FontWeight.SemiBold : FontWeight.Normal;
        }
        if (_workspaces.TryGetValue(_state.Mode, out var workspace)) _workspace.Content = workspace;
    }

    // MARK: Меню

    void BuildMenu()
    {
        _menu.Items.Clear();
        MenuItem Item(string title, Action click, string? gesture = null)
        {
            var item = new MenuItem { Header = title };
            if (!string.IsNullOrEmpty(gesture)) { try { item.InputGesture = KeyGesture.Parse(gesture); } catch { /* не розібралося */ } }
            item.Click += (_, _) => click();
            return item;
        }
        string Key(string action) => _state.Hotkey(action)?.Text.Replace("Esc", "Escape").Replace("Del", "Delete") ?? "";

        var file = new MenuItem { Header = Lang.T("Файл", "File") };
        file.Items.Add(Item(Lang.T("Переклади, пісенники, фони, шаблони…", "Translations, songbooks, backgrounds, templates…"), () => _ = OpenResources()));
        file.Items.Add(Item(Lang.T("Імпорт з теки VisioBible чи з файла…", "Import from a VisioBible folder or a file…"), () => _ = ImportFromDisk()));
        file.Items.Add(new Separator());
        file.Items.Add(Item(Lang.T("Відкрити план…", "Open plan…"), () => _ = OpenPlanFile()));
        file.Items.Add(Item(Lang.T("Зберегти план як…", "Save plan as…"), () => _ = SavePlanAs()));
        file.Items.Add(Item(Lang.T("Новий план…", "New plan…"), () => _ = NewPlan()));
        file.Items.Add(new Separator());
        file.Items.Add(Item(Lang.T("Знімок залу у файл", "Save a snapshot of the hall"), SaveScreenshot, Key("ScreenShot")));
        file.Items.Add(Item(Lang.T("Відкрити теку даних", "Open the data folder"), () => OpenFolder(Paths.Home)));
        file.Items.Add(new Separator());
        file.Items.Add(Item(Lang.T("Вихід", "Exit"), Close));
        _menu.Items.Add(file);

        var actions = new MenuItem { Header = Lang.T("Дії", "Actions") };
        actions.Items.Add(Item(Lang.T("Показати слайд", "Show slide"), _state.ShowCurrent, Key("ShowSlide")));
        actions.Items.Add(Item(Lang.T("Сховати слайд", "Hide slide"), _state.Hide, Key("HideSlide")));
        actions.Items.Add(Item(Lang.T("Затемнення екрана", "Black screen"), _state.ToggleBlackScreen, Key("ShowBlackScreen")));
        actions.Items.Add(Item(Lang.T("Порожній слайд (лише фон)", "Blank slide (background only)"), _state.ToggleBlankSlide, Key("ShowBlankSlide")));
        actions.Items.Add(Item(Lang.T("Спільний фон увімк./вимк.", "Common background on/off"), _state.ToggleCommonBackground, Key("ShowBackGrOnSlide")));
        actions.Items.Add(new Separator());
        actions.Items.Add(Item(Lang.T("Наступний вірш / частина", "Next verse / part"), () => _state.Step(1, _state.Settings.ArrowsShowLive)));
        actions.Items.Add(Item(Lang.T("Попередній вірш / частина", "Previous verse / part"), () => _state.Step(-1, _state.Settings.ArrowsShowLive)));
        actions.Items.Add(Item(Lang.T("Наступний розділ", "Next chapter"), () => _state.StepChapter(1, false)));
        actions.Items.Add(Item(Lang.T("Попередній розділ", "Previous chapter"), () => _state.StepChapter(-1, false)));
        actions.Items.Add(new Separator());
        actions.Items.Add(Item(Lang.T("Додати вибране в План", "Add selection to Plan"), _state.AddCurrentToPlan));
        actions.Items.Add(Item(Lang.T("Вікно слайда показати / сховати", "Slide window show / hide"), () => _projection?.Toggle()));
        _menu.Items.Add(actions);

        var songs = new MenuItem { Header = Lang.T("Пісні", "Songs") };
        songs.Items.Add(Item(Lang.T("Редактор пісень…", "Song editor…"), () => _ = OpenSongEditor(false)));
        songs.Items.Add(Item(Lang.T("Нова пісня в цьому пісеннику…", "New song in this songbook…"), () => _ = OpenSongEditor(true)));
        songs.Items.Add(Item(Lang.T("Новий пісенник…", "New songbook…"), () => _ = NewSongBook()));
        songs.Items.Add(Item(Lang.T("Експорт пісенника (.songbook / .vbm)…", "Export songbook (.songbook / .vbm)…"), () => _ = ExportSongBook()));
        _menu.Items.Add(songs);

        var settings = new MenuItem { Header = Lang.T("Налаштування", "Settings") };
        settings.Items.Add(Item(Lang.T("Параметри…", "Settings…"), () => _ = OpenSettings()));
        var language = new MenuItem { Header = Lang.T("Мова / Language", "Language") };
        foreach (var (code, name) in new[] { ("auto", Lang.T("Авто (мова Windows)", "Auto (Windows language)")), ("uk", "Українська"), ("en", "English") })
            language.Items.Add(Item((_state.Settings.Language == code ? "● " : "   ") + name, () => { _state.Settings.Language = code; _state.Settings.Save(); Lang.Apply(code); }));
        settings.Items.Add(language);
        _menu.Items.Add(settings);

        var help = new MenuItem { Header = Lang.T("Довідка", "Help") };
        help.Items.Add(Item(Lang.T("Гарячі клавіші…", "Hotkeys…"), () => _ = ShowHotkeys()));
        help.Items.Add(Item(Lang.T("Адреса пульта…", "Remote address…"), () => _ = ShowRemoteInfo()));
        help.Items.Add(Item(Lang.F("Перевірити оновлення… (зараз {0})", "Check for updates… (now {0})", Updates.Ours), () => _ = Updates.CheckNow(this, _state)));
        help.Items.Add(Item(Lang.T("Про програму", "About"), () => _ = Ui.Message(this, Lang.T("Слово для Windows", "Slovo for Windows"),
            Lang.F("«Слово» для Windows 10/11, версія {0}.\n\nПрограма для показу Біблії, пісень, оголошень і зображень на проекторі під час богослужіння. Повторює «Слово» для Mac: той самий порядок роботи, гарячі клавіші VisioBible, формати даних і пульт на телефоні, планшеті й у браузері.\n\nДані: {1}",
                   "Slovo for Windows 10/11, version {0}.\n\nA program to show the Bible, songs, announcements and pictures on a projector during worship. It mirrors Slovo for Mac: the same workflow, VisioBible hotkeys, data formats and the remote on a phone, tablet and in a browser.\n\nData: {1}", Updates.Ours, Paths.Home))));
        _menu.Items.Add(help);
    }

    // MARK: Клавіші

    void OnKeyDown(object? sender, KeyEventArgs e)
    {
        var focusedText = FocusManager?.GetFocusedElement() is TextBox;
        var action = _state.ActionFor(e.Key, e.KeyModifiers);
        var functional = e.Key is >= Avalonia.Input.Key.F1 and <= Avalonia.Input.Key.F24 || e.KeyModifiers.HasFlag(KeyModifiers.Control) || e.Key == Avalonia.Input.Key.Escape;
        if (action.Length > 0 && (functional || !focusedText))
        {
            if (action == "HideSlide" && focusedText && e.Key == Avalonia.Input.Key.Escape && !_state.IsLive && !_state.IsBlackout && !_state.IsTextHidden)
                return;   // Esc у полі вводу, коли зал і так порожній, — лишаємо полю
            if (_state.Perform(action)) { e.Handled = true; return; }
        }
        if (focusedText) return;
        var live = _state.Settings.ArrowsShowLive;
        switch (e.Key)
        {
            case Avalonia.Input.Key.Right:
            case Avalonia.Input.Key.PageDown:
                if (e.KeyModifiers.HasFlag(KeyModifiers.Shift) && _state.Mode == "bible") _state.StepChapter(1, false); else _state.Step(1, live);
                e.Handled = true; break;
            case Avalonia.Input.Key.Left:
            case Avalonia.Input.Key.PageUp:
                if (e.KeyModifiers.HasFlag(KeyModifiers.Shift) && _state.Mode == "bible") _state.StepChapter(-1, false); else _state.Step(-1, live);
                e.Handled = true; break;
            case Avalonia.Input.Key.Enter:
                if (FocusManager?.GetFocusedElement() is ListBoxItem or ListBox or Button or ComboBox) break;
                _state.ShowCurrent();
                e.Handled = true; break;
        }
    }

    void OnFocusRequested(string action)
    {
        switch (action)
        {
            case "Search": _state.Mode = "bible"; _searchBox.Focus(); _searchBox.SelectAll(); break;
            case "FastInput": case "FastInputBook": case "FastInputChapter": case "FastInputVers":
                _state.Mode = "bible"; _quickBox.Focus(); _quickBox.SelectAll(); break;
            case "FastSearchWindow": _state.IsSearchShown = !_state.IsSearchShown; RefreshSearch(); break;
            case "Plan": _planList.Focus(); break;
            case "MainWin": if (_state.Mode == "bible") _versesList.Focus(); else if (_state.Mode == "songs") _partsList.Focus(); else _textBody.Focus(); break;
            case "ScreenShot": SaveScreenshot(); break;
            case "OpenCommonBG": _ = ChooseBackground(common: true); break;
            case "OpenSlideBG": _ = ChooseBackground(common: false); break;
        }
    }

    // MARK: Зміни стану

    void OnStateChanged(Change change)
    {
        if (!Dispatcher.UIThread.CheckAccess()) { Dispatcher.UIThread.Post(() => OnStateChanged(change)); return; }
        // Збій у вікні не має зупиняти ні пульт, ні вікно слайда: вони слухають той самий потік змін.
        try { Reflect(change); }
        catch (Exception error) { Paths.Say("вікно: " + change + " — " + error); }
    }

    void Reflect(Change change)
    {
        switch (change)
        {
            case Change.Mode: ShowMode(); SchedulePreview(); RefreshThumbnails(); break;
            case Change.Library: RefreshTranslations(); RefreshBooks(); RefreshSongBooks(); RefreshSongList(); RefreshParts(); SchedulePreview(); UpdateStatus(); break;
            case Change.Bible: RefreshTranslations(); RefreshBooks(); SchedulePreview(); UpdateStatus(); break;
            case Change.Verses: RefreshVerseSelection(); SchedulePreview(); break;
            case Change.Songs: RefreshSongBooks(); RefreshSongList(); RefreshParts(); SchedulePreview(); break;
            case Change.SongParts: RefreshSongList(); RefreshParts(); SchedulePreview(); break;
            case Change.Text: RefreshText(); SchedulePreview(); break;
            case Change.Pictures: RefreshPictures(); SchedulePreview(); break;
            case Change.Slide: SchedulePreview(); break;
            case Change.Live: SchedulePreview(); UpdateControlButtons(); break;
            case Change.Plan: RefreshPlan(); break;
            case Change.History: RefreshHistory(); break;
            case Change.Search: RefreshSearch(); break;
            case Change.Settings: RefreshThumbnails(); RefreshTranslations(); SchedulePreview(); UpdateStatus(); UpdateControlButtons(); break;
            case Change.Pointer: break;
        }
    }

    void RefreshAll()
    {
        RefreshTranslations(); RefreshBooks();
        RefreshSongBooks(); RefreshSongList(); RefreshParts();
        RefreshText(); RefreshPictures();
        RefreshPlan(); RefreshHistory(); RefreshSearch(); RefreshThumbnails();
        UpdateControlButtons();
        SchedulePreview();
    }

    void UpdateStatus()
    {
        var pult = _state.Pult;
        var parts = new List<string>();
        if (pult != null)
        {
            var addresses = Remote.Names.Addresses().Select(a => a.Address.ToString()).ToList();
            var ip = addresses.FirstOrDefault() ?? "—";
            if (pult.IsRunning) parts.Add(Lang.F("Пульт: {0}:{1}", "Remote: {0}:{1}", ip, pult.Port) + (pult.MdnsName != null ? " · " + pult.MdnsName : ""));
            else if (_state.Settings.RemoteEnabled) parts.Add(Lang.T("Пульт: ", "Remote: ") + (pult.Error ?? Lang.T("не піднявся", "not running")));
            if (pult.WebRunning) parts.Add(Lang.T("Браузер: ", "Browser: ") + "http://" + (pult.MdnsName ?? ip) + (pult.PlainReady ? "" : ":" + pult.WebPort));
            else if (_state.Settings.WebEnabled && pult.WebError != null) parts.Add(Lang.T("Браузер: ", "Browser: ") + pult.WebError);
        }
        if (_projection != null)
            parts.Add(_projection.IsVisible ? (_projection.IsFramed ? Lang.T("Слайд: вікном (один монітор)", "Slide: windowed (one monitor)") : Lang.T("Слайд: на проекторі", "Slide: on the projector")) : Lang.T("Вікно слайда сховано", "Slide window hidden"));
        parts.Add(Lang.F("Переклад: {0}", "Translation: {0}", _state.PrimaryModule?.Name ?? Lang.T("немає", "none")));
        _status.Text = string.Join("   ·   ", parts);
    }

    // MARK: Дії меню

    void SaveScreenshot()
    {
        try { var file = _state.SaveScreenshot(); _status.Text = Lang.F("Знімок збережено: {0}", "Snapshot saved: {0}", file); }
        catch (Exception error) { _ = Ui.Message(this, Lang.T("Знімок", "Snapshot"), error.Message); }
    }

    static void OpenFolder(string path)
    {
        try
        {
            if (OperatingSystem.IsWindows()) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", "\"" + path + "\"") { UseShellExecute = true });
            else System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("open", path) { UseShellExecute = false });
        }
        catch { /* не відкрилося */ }
    }

    async Task OpenSettings()
    {
        var dialog = new SettingsWindow(_state);
        await dialog.ShowDialog(this);
    }

    async Task OpenResources()
    {
        var dialog = new ResourcesWindow(_state, this);
        await dialog.ShowDialog(this);
    }

    async Task OfferResources()
    {
        var yes = await Ui.Ask(this, Lang.T("Бібліотека порожня", "The library is empty"),
            Lang.T("У програмі ще немає перекладів і пісенників. Завантажити їх із ресурсів «Слова» на GitHub або взяти з теки VisioBible чи з файла?",
                   "The program has no translations or songbooks yet. Download them from Slovo's resources on GitHub, or take them from a VisioBible folder or a file?"),
            Lang.T("Відкрити ресурси", "Open resources"));
        if (yes) await OpenResources();
    }

    async Task ImportFromDisk()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = Lang.T("Файл модуля, пісенника, шаблону чи картинки — або bibleqt.ini теки модуля; «Скасувати» — вибрати теку", "A module, songbook, template or picture file — or bibleqt.ini of a module folder; Cancel — choose a folder"),
            AllowMultiple = true,
        });
        var paths = files.Select(f => f.TryGetLocalPath()).Where(p => p != null).Select(p => p!).ToList();
        if (paths.Count == 0)
        {
            var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = Lang.T("Тека VisioBible або тека з модулями", "A VisioBible folder or a folder with modules") });
            var folder = folders.FirstOrDefault()?.TryGetLocalPath();
            if (folder == null) return;
            var result = await Task.Run(() => ResourceStore.ImportFolder(_state.Library, folder));
            AdoptImport(result);
            await Ui.Message(this, Lang.T("Імпорт", "Import"), result.Summary() + (result.Failures.Count > 0 ? "\n\n" + string.Join("\n", result.Failures) : ""));
            return;
        }
        var total = new ImportResult();
        foreach (var path in paths)
        {
            var one = await Task.Run(() => ResourceStore.ImportFile(_state.Library, path));
            total.Modules.AddRange(one.Modules); total.Names.AddRange(one.Names); total.Failures.AddRange(one.Failures);
            total.Templates += one.Templates; total.Backgrounds += one.Backgrounds; total.Fonts += one.Fonts;
        }
        AdoptImport(total);
        await Ui.Message(this, Lang.T("Імпорт", "Import"), total.Summary() + (total.Failures.Count > 0 ? "\n\n" + string.Join("\n", total.Failures) : ""));
    }

    /// Нові модулі одразу вмикаються; шаблони й фони перечитуються.
    public void AdoptImport(ImportResult result)
    {
        foreach (var id in result.Modules) if (!_state.Settings.ModuleOrder.Contains(id)) _state.Settings.ModuleOrder.Add(id);
        _state.ReloadModules();
        _state.ReloadTemplates();
        _state.ReloadPictures();
        _state.SaveSettings();
    }

    async Task ShowHotkeys()
    {
        var lines = HotkeyAction.All.Select(a => a.Title + ": " + (_state.Hotkey(a.IniKey)?.Text ?? "—"));
        await Ui.Message(this, Lang.T("Гарячі клавіші", "Hotkeys"),
            string.Join("\n", lines) + "\n\n" + Lang.T("Стрілки ← → — попередній / наступний вірш, частина пісні, сторінка чи картинка; Shift+стрілка — розділ; Enter — показати. Набір клавіш міняється в Параметрах.",
                                                           "Arrows ← → — previous / next verse, song part, page or picture; Shift+arrow — chapter; Enter — show. The key set is changed in Settings."));
    }

    async Task ShowRemoteInfo()
    {
        var pult = _state.Pult;
        var addresses = Remote.Names.Addresses().Select(a => a.Address.ToString()).ToList();
        var text = pult == null || !pult.IsRunning
            ? Lang.T("Пульт вимкнено або порт зайнятий — див. Параметри → Пульт.", "The remote is off or the port is busy — see Settings → Remote.")
            : Lang.F("Телефон, планшет і «Проповідник» знаходять програму самі (розсилка SLOVO? на порт 8104). Якщо не знайшли — адреса вручну:\n{0}, порт {1}{2}\n\nПульт у браузері: {3}\n\nБрандмауер Windows при першому запуску спитає дозвіл — дозвольте для приватних мереж.",
                     "The phone, tablet and Propovidnyk find the program themselves (SLOVO? broadcast on port 8104). If not — the address by hand:\n{0}, port {1}{2}\n\nRemote in a browser: {3}\n\nWindows Firewall asks for permission at the first start — allow it for private networks.",
                     string.Join(" / ", addresses), pult.Port, _state.Settings.RemotePin.Length > 0 ? Lang.T(", PIN задано", ", PIN set") : "",
                     pult.WebRunning ? "http://" + (pult.MdnsName ?? addresses.FirstOrDefault() ?? "…") + (pult.PlainReady ? "" : ":" + pult.WebPort) : Lang.T("вимкнено", "off"));
        await Ui.Message(this, Lang.T("Адреса пульта", "Remote address"), text);
    }

    // MARK: Плани

    async Task OpenPlanFile()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = Lang.T("Відкрити план", "Open plan"),
            SuggestedStartLocation = await StorageProvider.TryGetFolderFromPathAsync(Paths.Plans),
            FileTypeFilter = new[] { new FilePickerFileType(Lang.T("План «Слова»", "Slovo plan")) { Patterns = new[] { "*.json" } } },
        });
        var path = files.FirstOrDefault()?.TryGetLocalPath();
        if (path == null) return;
        try { _state.LoadPlan(path); }
        catch (Exception error) { await Ui.Message(this, Lang.T("План", "Plan"), error.Message); }
    }

    async Task SavePlanAs()
    {
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = Lang.T("Зберегти план як", "Save plan as"),
            SuggestedFileName = ServicePlan.FileName(_state.Plan.Title),
            SuggestedStartLocation = await StorageProvider.TryGetFolderFromPathAsync(Paths.Plans),
            FileTypeChoices = new[] { new FilePickerFileType(Lang.T("План «Слова»", "Slovo plan")) { Patterns = new[] { "*.json" } } },
        });
        var path = file?.TryGetLocalPath();
        if (path == null) return;
        try { _state.SavePlanAs(path); }
        catch (Exception error) { await Ui.Message(this, Lang.T("План", "Plan"), error.Message); }
    }

    async Task NewPlan()
    {
        var title = await Ui.Prompt(this, Lang.T("Новий план", "New plan"), Lang.T("Назва плану:", "Plan title:"), Lang.T("План служіння", "Service plan"));
        if (title == null) return;
        _state.NewPlan(title);
    }

    // MARK: Пісенники

    async Task OpenSongEditor(bool newSong)
    {
        if (_state.SongBook == null) { await Ui.Message(this, Lang.T("Пісні", "Songs"), Lang.T("Спершу створіть або завантажте пісенник (меню «Пісні» → «Новий пісенник…» або «Файл» → ресурси).", "First create or load a songbook (Songs → New songbook… or File → resources).")); return; }
        var dialog = new SongEditorWindow(_state, _state.SongBookId, newSong ? null : _state.SongIndex);
        await dialog.ShowDialog(this);
    }

    async Task NewSongBook()
    {
        var title = await Ui.Prompt(this, Lang.T("Новий пісенник", "New songbook"), Lang.T("Назва пісенника:", "Songbook title:"), "");
        if (string.IsNullOrWhiteSpace(title)) return;
        var shortName = await Ui.Prompt(this, Lang.T("Новий пісенник", "New songbook"), Lang.T("Коротке ім'я (для адреси слайда):", "Short name (for the slide address):"), title.Trim().Length > 8 ? title.Trim()[..8] : title.Trim());
        if (shortName == null) return;
        var fileName = ResourceStore.SafeName(title.Trim()) + "." + SongBookWriter.Extension;
        var book = new SongBookData { Title = title.Trim(), ShortName = shortName.Trim() };
        var path = Path.Combine(Paths.Modules, fileName);
        SongBookWriter.WriteSongbook(book, path);
        var id = ModuleReaders.ImportSongBookData(_state.Library, book, fileName, "file", path);
        _state.SongBookChanged(id);
        _state.SelectSongBook(id);
        _state.Mode = "songs";
        await OpenSongEditor(true);
    }

    async Task ExportSongBook()
    {
        var book = _state.SongBook;
        if (book == null) return;
        var file = await StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = Lang.T("Експорт пісенника", "Export songbook"),
            SuggestedFileName = Path.GetFileNameWithoutExtension(AppState.SongBookFileName(book.Id)) + ".songbook",
            FileTypeChoices = new[]
            {
                new FilePickerFileType(Lang.T("Пісенник «Слова» (.songbook)", "Slovo songbook (.songbook)")) { Patterns = new[] { "*.songbook" } },
                new FilePickerFileType("VisioBible (.vbm)") { Patterns = new[] { "*.vbm" } },
            },
        });
        var path = file?.TryGetLocalPath();
        if (path == null) return;
        try
        {
            var data = _state.Library.SongBook(book.Id);
            if (path.EndsWith(".vbm", StringComparison.OrdinalIgnoreCase)) await File.WriteAllBytesAsync(path, SongBookWriter.Vbm(data));
            else SongBookWriter.WriteSongbook(data, path);
            _status.Text = Lang.F("Пісенник записано: {0}", "Songbook written: {0}", path);
        }
        catch (Exception error) { await Ui.Message(this, Lang.T("Експорт", "Export"), error.Message); }
    }

    // MARK: Фони

    async Task ChooseBackground(bool common)
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = common ? Lang.T("Спільний фон", "Common background") : Lang.T("Фон слайда", "Slide background"),
            SuggestedStartLocation = await StorageProvider.TryGetFolderFromPathAsync(Paths.Backgrounds),
            FileTypeFilter = new[] { new FilePickerFileType(Lang.T("Картинки", "Pictures")) { Patterns = new[] { "*.jpg", "*.jpeg", "*.png", "*.bmp", "*.gif", "*.webp" } } },
        });
        var path = files.FirstOrDefault()?.TryGetLocalPath();
        if (path == null) return;
        if (common) { _state.Settings.CommonBackground = path; _state.Settings.ShowCommonBackground = true; }
        else _state.Settings.SlideBackground = path;
        _state.ApplySettings(_state.Settings);
    }
}
