// =============================================================================
//  MainWindow.cs — головне вікно «Слова»
// =============================================================================
//  Як NativeMainWindowController на Mac: 1600×1000 на першому запуску,
//  найменше 1120×720; закрили головне вікно — програма скінчилася.
//  Частини кладуть себе в ящики вікна самі (Install).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Slovo.Core;

namespace Slovo.App;

public sealed class MainWindow : Window
{
    public static MainWindow? Shared { get; private set; }

    public readonly RootView Root = new();
    public readonly AppState State;
    public readonly MenuStrip Menu = new();
    public readonly ModeTabs Tabs;
    public readonly BottomRow Bottom = new();
    public readonly TranslationStrip Strip = new();
    public BibleWorkspace? Bible { get; private set; }
    public SongsWorkspace? Songs { get; private set; }
    LookChooser? _looks;
    PointerDriver? _pointer;
    public OutputDriver? Output { get; private set; }
    TextWorkspace? _text;
    PlanDriver? _planDriver;

    public MainWindow(AppState state)
    {
        Shared = this;
        State = state;
        Title = Captions.T("Слово");
        Width = 1600;
        Height = 1000;
        MinWidth = 1120;
        MinHeight = 720;
        Content = Root;
        // Кинуті у вікно файли — у свою вкладку (презентація, картинки, плеєр).
        WindowDrop.Install(this);
        Tabs = new ModeTabs(state);
        Install(Menu, Slot.MenuBar);
        Install(Tabs, Slot.ModeTabs);
        Install(Bottom, Slot.BottomRow);
        Install(Strip, Slot.TranslationStrip);
        Bible = new BibleWorkspace(state);
        // Пісні живуть від старту (як NativeSongsWorkspace.attach): вкладки пісенників,
        // клавіші й пульт працюють і тоді, коли вкладка не відкрита.
        var songs = Songs = new SongsWorkspace(state);
        var bibleQuick = KeyHandling.FocusQuick;
        var bibleFocused = KeyHandling.FocusedQuick;
        KeyHandling.FocusQuick = kind => songs.FocusQuick(kind) || (bibleQuick?.Invoke(kind) ?? false);
        KeyHandling.FocusedQuick = () => songs.FocusedQuick ?? bibleFocused?.Invoke();
        KeyHandling.SongKey = songs.HandleKey;
        state.ToggleSongEditMode = songs.ToggleEditMode;
        ApplyMode();
        Signals.Shared.Subscribe(Signals.Kind.Mode, ApplyMode);
        // Смуга перекладів: вкладки з бібліотеки, основний — «пігулка», другий — підсвічено.
        Strip.Tabs.OnPick = (id, secondary) =>
        {
            if (secondary) state.ToggleSecondary(id); else state.PrimaryModuleID = id;
        };
        Signals.Shared.Subscribe(Signals.Kind.Translations, ApplyStrip);
        Strip.PairButton.Menu = () => MenuStrip.Build(new[] { new MenuEntry(state.SecondaryModuleIDs.Count == 0 ? Captions.T("Один перевод") : Captions.T("Два перевода")) }
            .Concat(state.OrderedModules.Select(m => new MenuEntry(m.Info.Name.Length > 0 ? m.Info.Name : m.Identifier, () => state.ToggleSecondary(m.Identifier),
                                                                    state.SecondaryModuleIDs.Contains(m.Identifier)))).ToList());
        ApplyStrip();
        Output = new OutputDriver(state, Bottom);
        _looks = new LookChooser(state, Bottom.Control);
        _pointer = new PointerDriver(Bottom);
        Install(new SearchResultsPane(state), Slot.SearchResults);
        Strip.SearchField.OnChange = state.SearchQueryChanged;
        Strip.SearchField.OnSubmit = state.RunSearch;
        Strip.SearchField.OnFocus = focused => { if (focused) state.PrepareSearch(); };
        Strip.SearchToggle.Pressed = state.ToggleSearchResults;
        state.SearchFieldFocusRequested += () => Strip.SearchField.FocusField();
        // Швидкий вибір місця (9): набір веде одразу; Enter — те саме, а адресу,
        // якої не впізнали, видно червоною рамкою й «Адресу не знайдено» на 2 с.
        var previousAddress = "";
        Strip.AddressField.OnChange = text =>
        {
            var deletion = text.Length < previousAddress.Length;
            previousAddress = text;
            Strip.AddressField.IsRejected = false;
            Strip.ErrorCaption.Text = "";
            if (text.Trim().Length == 0) return;
            // «Шукати по BackSpace у швидкому наборі» (6.1.2, елемент 14).
            if (deletion && !SettingsStore.Shared.Settings.Options.FastInputUseBackSpace) return;
            state.ApplyAddress(text);
        };
        Strip.AddressField.OnSubmit = text =>
        {
            if (state.ApplyAddress(text)) { Strip.AddressField.IsRejected = false; Strip.ErrorCaption.Text = ""; Strip.InvalidateArrange(); return; }
            Strip.AddressField.IsRejected = true;
            Strip.ErrorCaption.Text = Captions.Caption("ErrorMessages11", "Адрес не найден.").Replace("\\n", " ").Trim();
            Strip.InvalidateArrange();
            Avalonia.Threading.DispatcherTimer.RunOnce(() =>
            {
                Strip.AddressField.IsRejected = false;
                Strip.ErrorCaption.Text = "";
                Strip.InvalidateArrange();
            }, TimeSpan.FromSeconds(2));
        };
        // Меню правої кнопки по вкладці перекладу (5.1.7) — шість пунктів автора.
        Strip.Tabs.OnMenu = id =>
        {
            if (state.Module(id) is null) return null;
            var isSecond = state.SecondaryModuleIDs.Contains(id);
            var entries = new List<MenuEntry>
            {
                new(Captions.Caption("N_LongName", "Длинное название"), () => state.TabNamesLong = true, state.TabNamesLong),
                new(Captions.Caption("N_ShortName", "Короткое название"), () => state.TabNamesLong = false, !state.TabNamesLong),
                new(Captions.Caption("NReloadModule", "Перезагрузить модуль"), () => state.ReloadModule(id), StartsGroup: true),
                new(Captions.Caption("NOpenModuleFolder", "Открыть папку с модулем"), () => state.RevealModule(id)),
                new(Captions.Caption("NSelAsFirstTranslate", "Выбрать основным переводом"), () => state.PrimaryModuleID = id,
                    state.PrimaryModuleID == id, StartsGroup: true),
                new(Captions.Caption(isSecond ? "TextMessages63" : "TextMessages62", isSecond ? "Отменить второй перевод" : "Выбрать вторым переводом"),
                    () => state.ToggleSecondary(id), isSecond),
            };
            if (state.SecondaryModuleIDs.Count > 0)
                entries.Add(new MenuEntry(Captions.T("Показывать один перевод"), state.ShowSingleTranslation, StartsGroup: true));
            return MenuStrip.Build(entries);
        };
        KeyHandling.FocusAddress = () => Strip.AddressField.FocusField();
        _planDriver = new PlanDriver(state, Bottom.Plan);
        // Пункт «Файл» плану: показ чи картинка — у свою вкладку; звук чи відео — у плеєр
        // і одразу грати (openPlanFile на Mac).
        state.OpenPlanFile = (path, live) =>
        {
            if (ShowWorkspace.OpenFromPlan(path, live)) return true;
            if (!state.Media.Filters.Accepts(path)) return false;
            state.Media.Open(path);
            if (state.Mode != WorkMode.Media) { state.Mode = WorkMode.Media; Signals.Shared.Send(Signals.Kind.Mode); }
            if (live) state.Media.Play();
            return true;
        };
        // Del і Backspace в «Історії» — лише коли клавіатура в ній (сторож клавіш нижнього ряду на Mac).
        Bottom.History.List.AddHandler(KeyDownEvent, (_, e) =>
        {
            if (e.KeyModifiers != Avalonia.Input.KeyModifiers.None || e.Key is not (Avalonia.Input.Key.Delete or Avalonia.Input.Key.Back)) return;
            if (state.HistorySelection is { } chosen) state.RemoveHistory(chosen);
            e.Handled = true;
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        Signals.Shared.Subscribe(Signals.Kind.Layout, ApplyMode);
        Menu.Entries = group => MenuCatalog.Entries(group, state);
        KeyHandling.Install(this, state);
        var history = new HistoryRows(state);
        Bottom.History.List.Source = history;
        Bottom.History.List.OnActivate = i => { if (i < state.History.Records.Count) state.ActivateHistory(state.History.Records[i], true); };
        Bottom.History.List.OnSelect = (_, i, cause) => { if (cause != SelectCause.Code && i >= 0 && i < state.History.Records.Count) state.HistorySelection = state.History.Records[i].Id; };
        Signals.Shared.Subscribe(Signals.Kind.History, () =>
        {
            Bottom.History.List.Reload();
            var row = state.History.Records.ToList().FindIndex(r => r.Id == state.HistorySelection);
            Bottom.History.List.SetSelection(row >= 0 ? new[] { row } : Array.Empty<int>(), row >= 0 ? row : null);
        });
        Bottom.Control.ActiveBox.IsChecked = state.ArrowsShowLive;
        Bottom.Control.ActiveBox.Toggled += on => state.ArrowsShowLive = on;
        state.ReloadLibrary();
        // Бібліотека порожня — запропонувати ресурси з GitHub чи імпорт (ResourceOffer на Mac).
        if (!Program.QuietStart && !Program.Snapshotting) ResourceOffer.Watch(state);
        // Вікно слайда піднімається одразу й живе до закриття програми — як в оригіналі.
        // Тихий запуск (перевірки): без вікна залу і без фокусу клавіатури.
        ShowActivated = !Program.QuietStart;
        // Рамка вікна — як залишили; на малому екрані чи при масштабі 200 % — у межах робочої області.
        if (!Program.Snapshotting)
        {
            RestoreFrame();
            Opened += (_, _) => FitToScreen();
            Closing += (_, _) => RememberFrame();
        }
        if (!Program.QuietStart) Opened += (_, _) => StartProjection();
        SettingsStore.Shared.Changed += ApplyPlacement;
        Closing += (_, _) => { ProjectionController.Shared.SetVisible(false); state.FlushPlanAutosave(); Defaults.Flush(); };
    }

    /// Розміщення вікна слайда — з «Параметри → Основні» (монітор або ручна настройка).
    void ApplyPlacement()
    {
        var placement = SlideWindowPlacement.From(SettingsStore.Shared.Settings.Options);
        ProjectionController.Shared.SetPlacement(placement switch
        {
            SlideWindowPlacement.Manual m => new SlidePlacementChoice.Manual(m.Left, m.Top, m.Width, m.Height),
            SlideWindowPlacement.Monitor m => new SlidePlacementChoice.Monitor(m.Number, m.FallbackWidth, m.FallbackHeight),
            _ => null,
        });
    }

    void StartProjection()
    {
        if (Program.Snapshotting) return;
        ApplyPlacement();
        ProjectionController.Shared.SetVisible(true);
        Activate();
    }

    void ApplyStrip()
    {
        var state = State;
        Strip.Tabs.Reload(state.OrderedModules.Select(m => new TabStrip.Tab(state.TabTitle(m), m.Identifier,
            m.Identifier == state.PrimaryModuleID, state.SecondaryModuleIDs.Contains(m.Identifier),
            (m.Info.Name.Length > 0 ? m.Info.Name : m.Identifier) + " — " + m.Format.Title())));
        Strip.PairButton.Title = state.SecondaryModuleIDs.Count == 0 ? Captions.T("Один перевод") : Captions.T("Два перевода");
        Strip.InvalidateArrange();
    }

    /// Робоча область за режимом; смуга перекладів — лише на Біблії й Піснях.
    void ApplyMode()
    {
        var mode = State.Mode;
        SetVisible(mode is WorkMode.Bible or WorkMode.Songs, Slot.TranslationStrip);
        SetVisible(mode is WorkMode.Bible or WorkMode.Songs && State.IsSearchResultsShown, Slot.SearchResults);
        Strip.SearchToggle.IsOn = State.IsSearchResultsShown;
        Strip.SearchToggle.InvalidateVisual();
        if (mode == WorkMode.Bible && Bible != null) Install(Bible.View, Slot.Workspace);
        else if (mode == WorkMode.Songs && Songs != null) Install(Songs.View, Slot.Workspace);
        else if (mode == WorkMode.Text) Install(_text ??= new TextWorkspace(State), Slot.Workspace);
        else if (mode == WorkMode.Media) Install(MediaWorkspace.Shared, Slot.Workspace);
        else if (mode == WorkMode.Screen) { Install(ScreenWorkspace.Shared, Slot.Workspace); ScreenWorkspace.Shared.Attach(); }
        else if (ShowWorkspace.For(mode) is { } show) { Install(show, Slot.Workspace); show.Refresh(); }
        else Install(null, Slot.Workspace);
    }

    const string FrameKey = "mainWindowFrame", MaximizedKey = "mainWindowMaximized";

    void RestoreFrame()
    {
        if (Defaults.String(FrameKey) is { } saved && saved.Split(',') is { Length: 4 } parts
            && parts.Select(p => int.TryParse(p, out var v) ? v : int.MinValue).ToArray() is var n && n.All(v => v != int.MinValue))
        {
            Position = new PixelPoint(n[0], n[1]);
            Width = Math.Max(MinWidth, n[2]);
            Height = Math.Max(MinHeight, n[3]);
            WindowStartupLocation = WindowStartupLocation.Manual;
        }
        else WindowStartupLocation = WindowStartupLocation.CenterScreen;
        if (Defaults.Has(MaximizedKey) && Defaults.Bool(MaximizedKey)) WindowState = WindowState.Maximized;
    }

    void RememberFrame()
    {
        Defaults.Set(MaximizedKey, WindowState == WindowState.Maximized);
        if (WindowState == WindowState.Normal) Defaults.Set(FrameKey, $"{Position.X},{Position.Y},{(int)Width},{(int)Height}");
    }

    /// Вікно не вилазить за робочу область: на ноутбуці 1366×768 чи при масштабі 150–200 %
    /// типові 1600×1000 більші за екран. Зовсім малий екран — на весь екран.
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
        if (areaWidth < MinWidth || areaHeight < MinHeight) { WindowState = WindowState.Maximized; return; }
        if (Width > maxWidth) Width = maxWidth;
        if (Height > maxHeight) Height = maxHeight;
        var widthPx = (int)((Width + 16) * scale);
        var heightPx = (int)((Height + 40) * scale);
        var left = Position.X; var top = Position.Y;
        if (left < area.X || top < area.Y || left + widthPx > area.Right || top + heightPx > area.Bottom)
            Position = new PixelPoint(area.X + Math.Max(0, (area.Width - widthPx) / 2), area.Y + Math.Max(0, (area.Height - heightPx) / 2));
    }

    public void Install(Control? view, Slot slot) => Root.Slots[slot].Install(view);
    public SlotBox SlotView(Slot slot) => Root.Slots[slot];
    public void SetVisible(bool shown, Slot slot) => Root.SetVisible(shown, slot);
    public bool IsVisible(Slot slot) => Root.IsSlotVisible(slot);
}
