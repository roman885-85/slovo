// =============================================================================
//  MainWindow.Bottom.cs — нижній ряд: План | Історія | Передпоказ і зал | Керування
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Slovo.Views;

public sealed partial class MainWindow
{
    readonly ListBox _planList = new();
    readonly TextBlock _planTitle = new() { FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly Button _sermonEnd = new() { IsVisible = false };
    readonly ListBox _historyList = new();
    readonly Image _preview = new() { Stretch = Stretch.Uniform };
    readonly Image _live = new() { Stretch = Stretch.Uniform };
    readonly TextBlock _previewReference = new() { FontSize = 11, Foreground = Ui.Muted, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock _liveReference = new() { FontSize = 11, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly CheckBox _activeBox = new();
    Button _showButton = null!, _hideButton = null!, _blackButton = null!, _blankButton = null!;
    readonly Image _templateThumb = new() { Width = 96, Height = 54, Stretch = Stretch.UniformToFill };
    readonly Image _slideBgThumb = new() { Width = 96, Height = 54, Stretch = Stretch.UniformToFill };
    readonly Image _commonBgThumb = new() { Width = 96, Height = 54, Stretch = Stretch.UniformToFill };
    readonly TextBlock _templateNote = new() { FontSize = 9, Foreground = Ui.Muted, TextTrimming = TextTrimming.CharacterEllipsis, Width = 96 };
    readonly TextBlock _slideBgNote = new() { FontSize = 9, Foreground = Ui.Muted, TextTrimming = TextTrimming.CharacterEllipsis, Width = 96 };
    readonly TextBlock _commonBgNote = new() { FontSize = 9, Foreground = Ui.Muted, TextTrimming = TextTrimming.CharacterEllipsis, Width = 96 };
    bool _fillingPlan, _fillingHistory;

    void BuildBottom()
    {
        _bottom.Children.Clear();
        _bottom.ColumnDefinitions = new ColumnDefinitions("3*,4,2*,4,3*,4,Auto");
        _bottom.Height = Math.Clamp(_state.Settings.BottomRowHeight, 160, 600);
        _bottom.Margin = new Thickness(6, 4);

        // Ручка висоти нижнього ряду — тягнуть угору (власник: «нижний блок можно растягивать вверх»).
        var grip = new Border { Height = 6, Background = Ui.Line, Cursor = new Cursor(StandardCursorType.SizeNorthSouth), Margin = new Thickness(0, 0, 0, 2) };
        double? dragStart = null; var startHeight = 0.0;
        grip.PointerPressed += (_, e) => { dragStart = e.GetPosition(this).Y; startHeight = _bottom.Height; e.Pointer.Capture(grip); };
        grip.PointerMoved += (_, e) => { if (dragStart is double y0) _bottom.Height = Math.Clamp(startHeight - (e.GetPosition(this).Y - y0), 160, 700); };
        grip.PointerReleased += (_, e) => { dragStart = null; e.Pointer.Capture(null); _state.Settings.BottomRowHeight = _bottom.Height; };
        _bottom.RowDefinitions = new RowDefinitions("Auto,*");
        Grid.SetColumnSpan(grip, 7);
        _bottom.Children.Add(grip);

        // План
        var plan = new DockPanel();
        var planHead = new DockPanel();
        var planMenu = Ui.Button("▼", () => { }, Lang.T("Плани: інший, новий, перейменувати", "Plans: another, new, rename"));
        planMenu.Click += (_, _) => OpenPlansFlyout(planMenu);
        DockPanel.SetDock(planMenu, Dock.Right);
        planHead.Children.Add(planMenu);
        var planLabel = Ui.Label(Lang.T("План", "Plan") + ": ", 12, true);
        DockPanel.SetDock(planLabel, Dock.Left);
        planHead.Children.Add(planLabel);
        planHead.Children.Add(_planTitle);
        DockPanel.SetDock(planHead, Dock.Top);
        plan.Children.Add(planHead);
        _sermonEnd.Content = Lang.T("Повернути план служіння", "Return the service plan");
        _sermonEnd.Background = Ui.Good; _sermonEnd.Foreground = Brushes.White;
        _sermonEnd.Click += (_, _) => _state.EndSermon();
        DockPanel.SetDock(_sermonEnd, Dock.Top);
        plan.Children.Add(_sermonEnd);
        var planButtons = Ui.Row(
            Ui.Button("+", _state.AddCurrentToPlan, Lang.T("Додати вибране в План", "Add the selection to the Plan")),
            Ui.Button("↑", () => { if (_planList.SelectedIndex >= 0) _state.MovePlanItem(_planList.SelectedIndex, -1); }, Lang.T("Вище", "Up")),
            Ui.Button("↓", () => { if (_planList.SelectedIndex >= 0) _state.MovePlanItem(_planList.SelectedIndex, 1); }, Lang.T("Нижче", "Down")),
            Ui.Button("×", () => { if (_planList.SelectedIndex >= 0) _state.RemovePlanItem(_planList.SelectedIndex); }, Lang.T("Прибрати пункт (Delete)", "Remove item (Delete)")),
            Ui.Button(Lang.T("Очистити", "Clear"), () => _ = ClearPlanAsked(), Lang.T("Очистити весь план", "Clear the whole plan")));
        planButtons.Margin = new Thickness(0, 2, 0, 0);
        DockPanel.SetDock(planButtons, Dock.Bottom);
        plan.Children.Add(planButtons);
        _planList.ItemTemplate = new FuncDataTemplate<PlanItem>((item, _) =>
        {
            if (item == null) return new TextBlock();
            var row = new DockPanel { Margin = new Thickness(2, 1) };
            var icon = new TextBlock { Text = item.Icon, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);
            var text = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis };
            text.Inlines!.Add(new Avalonia.Controls.Documents.Run(item.Title) { FontWeight = FontWeight.SemiBold });
            if (item.Subtitle.Length > 0) text.Inlines.Add(new Avalonia.Controls.Documents.Run(" — " + item.Subtitle) { Foreground = Ui.Muted });
            row.Children.Add(text);
            return row;
        });
        _planList.SelectionChanged += (_, _) =>
        {
            if (_fillingPlan || _planList.SelectedIndex < 0) return;
            _state.ActivatePlan(_planList.SelectedIndex, false);
        };
        _planList.DoubleTapped += (_, _) => { if (_planList.SelectedIndex >= 0) _state.ActivatePlan(_planList.SelectedIndex, true); };
        _planList.KeyDown += (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Enter && _planList.SelectedIndex >= 0) { _state.ActivatePlan(_planList.SelectedIndex, true); e.Handled = true; }
            if (e.Key == Avalonia.Input.Key.Delete && _planList.SelectedIndex >= 0) { _state.RemovePlanItem(_planList.SelectedIndex); e.Handled = true; }
        };
        _fontLists.Add(_planList);
        plan.Children.Add(_planList);
        Grid.SetRow(plan, 1);
        _bottom.Children.Add(plan);
        _bottom.Children.Add(BottomSplitter(1));

        // Історія
        var history = new DockPanel();
        var historyHead = new DockPanel();
        var clearHistory = Ui.Button(Lang.T("Очистити", "Clear"), () => _state.ClearHistory(), Lang.T("Очистити Історію", "Clear the History"));
        DockPanel.SetDock(clearHistory, Dock.Right);
        historyHead.Children.Add(clearHistory);
        historyHead.Children.Add(Ui.Label(Lang.T("Історія", "History"), 12, true));
        DockPanel.SetDock(historyHead, Dock.Top);
        history.Children.Add(historyHead);
        _historyList.ItemTemplate = new FuncDataTemplate<HistoryRecord>((record, _) => new TextBlock { Text = record?.Caption ?? "", TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(2, 1) });
        _historyList.SelectionChanged += (_, _) => { if (!_fillingHistory && _historyList.SelectedIndex >= 0) _state.ActivateHistory(_historyList.SelectedIndex, false); };
        _historyList.DoubleTapped += (_, _) => { if (_historyList.SelectedIndex >= 0) _state.ActivateHistory(_historyList.SelectedIndex, true); };
        _historyList.KeyDown += (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Delete && _historyList.SelectedIndex >= 0) { _state.RemoveHistory(_state.History.Records[_historyList.SelectedIndex].Id); e.Handled = true; }
        };
        _fontLists.Add(_historyList);
        history.Children.Add(_historyList);
        Grid.SetRow(history, 1); Grid.SetColumn(history, 2);
        _bottom.Children.Add(history);
        _bottom.Children.Add(BottomSplitter(3));

        // Передпоказ і зал
        var screens = new Grid { ColumnDefinitions = new ColumnDefinitions("*,6,*"), RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        var previewLabel = Ui.Label(Lang.T("Передпоказ", "Preview"), 12, true);
        var liveLabel = Ui.Label(Lang.T("Зал (живий екран)", "Hall (live screen)"), 12, true);
        Grid.SetColumn(liveLabel, 2);
        screens.Children.Add(previewLabel); screens.Children.Add(liveLabel);
        var previewBox = new Border { Background = Brushes.Black, Child = _preview, CornerRadius = new CornerRadius(4) };
        var liveBox = new Border { Background = Brushes.Black, Child = _live, CornerRadius = new CornerRadius(4), BorderBrush = Ui.Good, BorderThickness = new Thickness(2) };
        Grid.SetRow(previewBox, 1); Grid.SetRow(liveBox, 1); Grid.SetColumn(liveBox, 2);
        previewBox.DoubleTapped += (_, _) => _state.ShowCurrent();
        ToolTip.SetTip(previewBox, Lang.T("Подвійне клацання — показати в залі", "Double-click — show in the hall"));
        // Указка мишею по залу — як на планшеті.
        liveBox.PointerMoved += (_, e) =>
        {
            if (!e.GetCurrentPoint(liveBox).Properties.IsLeftButtonPressed) return;
            var p = e.GetPosition(liveBox);
            if (liveBox.Bounds.Width <= 0 || liveBox.Bounds.Height <= 0) return;
            _state.MovePointer(p.X / liveBox.Bounds.Width, p.Y / liveBox.Bounds.Height, "mouse");
        };
        liveBox.PointerReleased += (_, _) => _state.HidePointer();
        ToolTip.SetTip(liveBox, Lang.T("Ведіть мишею з натиснутою кнопкою — на стіні йде указка", "Drag with the button pressed — a pointer moves on the wall"));
        screens.Children.Add(previewBox); screens.Children.Add(liveBox);
        Grid.SetRow(_previewReference, 2); Grid.SetRow(_liveReference, 2); Grid.SetColumn(_liveReference, 2);
        screens.Children.Add(_previewReference); screens.Children.Add(_liveReference);
        Grid.SetRow(screens, 1); Grid.SetColumn(screens, 4);
        _bottom.Children.Add(screens);
        _bottom.Children.Add(BottomSplitter(5));

        // Керування
        var control = new StackPanel { Spacing = 6, Margin = new Thickness(4, 0, 0, 0) };
        var head = new DockPanel();
        _activeBox.Content = Lang.T("Активна", "Active");
        _activeBox.IsChecked = _state.Settings.ArrowsShowLive;
        ToolTip.SetTip(_activeBox, Lang.T("Увімкнено: стрілки й перегортання одразу виводять у зал. Вимкнено: лише готують передпоказ, у зал — «Показати» або Enter.", "On: arrows and paging go to the hall at once. Off: they only prepare the preview; the hall — Show or Enter."));
        _activeBox.IsCheckedChanged += (_, _) => { if (!_building) { _state.Settings.ArrowsShowLive = _activeBox.IsChecked == true; _state.SaveSettings(); } };
        DockPanel.SetDock(_activeBox, Dock.Right);
        head.Children.Add(_activeBox);
        head.Children.Add(Ui.Label(Lang.T("Керування", "Control"), 12, true));
        control.Children.Add(head);
        var arrows = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        arrows.Children.Add(Ui.Button("◀", () => _state.Step(-1, false), Lang.T("Попередній вірш / частина — у передпоказ", "Previous verse / part — preview")));
        arrows.Children.Add(Ui.Button("▶", () => _state.Step(1, false), Lang.T("Наступний вірш / частина — у передпоказ", "Next verse / part — preview")));
        arrows.Children.Add(Ui.Button("◀◀", () => _state.Step(-1, true), Lang.T("Попередній — одразу в зал", "Previous — straight to the hall")));
        arrows.Children.Add(Ui.Button("▶▶", () => _state.Step(1, true), Lang.T("Наступний — одразу в зал", "Next — straight to the hall")));
        control.Children.Add(arrows);
        var showRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        _showButton = Ui.Button(Lang.T("Показати", "Show"), _state.ShowCurrent, Lang.T("Передпоказ — у зал (F5)", "Preview — to the hall (F5)"), accent: true);
        _hideButton = Ui.Button(Lang.T("Сховати", "Hide"), _state.Hide, Lang.T("Погасити зал до фону (Esc)", "Fade the hall to the background (Esc)"));
        _blackButton = Ui.Button(Lang.T("Чорний", "Black"), _state.ToggleBlackScreen, Lang.T("Затемнення екрана (F12)", "Black screen (F12)"));
        _blankButton = Ui.Button(Lang.T("Порожній", "Blank"), _state.ToggleBlankSlide, Lang.T("Порожній слайд — лише фон (Ctrl+F5)", "Blank slide — background only (Ctrl+F5)"));
        showRow.Children.Add(_showButton); showRow.Children.Add(_hideButton); showRow.Children.Add(_blackButton); showRow.Children.Add(_blankButton);
        control.Children.Add(showRow);
        var thumbs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        thumbs.Children.Add(Thumb(Lang.T("Шаблон слайда", "Slide template"), _templateThumb, _templateNote, OpenTemplateFlyout, Lang.T("Клацання — вибрати шаблон .sch", "Click — choose a .sch template")));
        thumbs.Children.Add(Thumb(Lang.T("Фон слайда", "Slide background"), _slideBgThumb, _slideBgNote, b => OpenBackgroundFlyout(b, false), Lang.T("Клацання — вибрати фон; у меню — прибрати", "Click — choose a background; in the menu — remove")));
        thumbs.Children.Add(Thumb(Lang.T("Спільний фон", "Common background"), _commonBgThumb, _commonBgNote, b => OpenBackgroundFlyout(b, true), Lang.T("Спільний фон поверх шаблону; Ctrl+F9 вмикає й вимикає", "Common background over the template; Ctrl+F9 toggles")));
        control.Children.Add(thumbs);
        Grid.SetRow(control, 1); Grid.SetColumn(control, 6);
        _bottom.Children.Add(control);
    }

    static GridSplitter BottomSplitter(int column)
    {
        var splitter = new GridSplitter { Background = Brushes.Transparent, Width = 4 };
        Grid.SetColumn(splitter, column);
        Grid.SetRow(splitter, 1);
        return splitter;
    }

    static Control Thumb(string title, Image image, TextBlock note, Action<Button> click, string tip)
    {
        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(new TextBlock { Text = title, FontSize = 10 });
        var button = new Button { Padding = new Thickness(0), Background = Brushes.Black, Content = new Border { Child = image, Width = 96, Height = 54 } };
        button.Click += (_, _) => click(button);
        ToolTip.SetTip(button, tip);
        stack.Children.Add(button);
        stack.Children.Add(note);
        return stack;
    }

    void OpenTemplateFlyout(Button anchor)
    {
        var flyout = new MenuFlyout();
        var look = _state.Settings.Look(_state.Mode == "pictures" ? "bible" : _state.Mode);
        var none = new MenuItem { Header = (look.TemplateName.Length == 0 ? "● " : "   ") + Lang.T("Без шаблону (стиль із Параметрів)", "No template (style from Settings)") };
        none.Click += (_, _) => { look.TemplateName = ""; _state.ApplySettings(_state.Settings); };
        flyout.Items.Add(none);
        foreach (var template in _state.Templates.Templates)
        {
            var item = new MenuItem { Header = (template.Name.Equals(look.TemplateName, StringComparison.OrdinalIgnoreCase) ? "● " : "   ") + template.Name };
            var name = template.Name;
            item.Click += (_, _) => { look.TemplateName = name; _state.ApplySettings(_state.Settings); };
            flyout.Items.Add(item);
        }
        if (_state.Templates.Templates.Count == 0)
            flyout.Items.Add(new MenuItem { Header = Lang.T("Шаблонів немає — «Файл» → ресурси (Templates.zip) або тека VisioBible", "No templates — File → resources (Templates.zip) or a VisioBible folder"), IsEnabled = false });
        flyout.Items.Add(new Separator());
        var mode = new MenuItem { Header = Lang.F("Шаблон для режиму: {0}", "Template for the mode: {0}", AppState.ModeTitle(_state.Mode == "pictures" ? "bible" : _state.Mode)), IsEnabled = false };
        flyout.Items.Add(mode);
        flyout.ShowAt(anchor);
    }

    void OpenBackgroundFlyout(Button anchor, bool common)
    {
        var flyout = new MenuFlyout();
        var choose = new MenuItem { Header = Lang.T("Вибрати файл…", "Choose a file…") };
        choose.Click += (_, _) => _ = ChooseBackground(common);
        flyout.Items.Add(choose);
        var fromFolder = new MenuItem { Header = Lang.T("З теки фонів", "From the backgrounds folder") };
        foreach (var picture in _state.Pictures.Where(p => p.StartsWith(Paths.Backgrounds, StringComparison.OrdinalIgnoreCase)).Take(40))
        {
            var item = new MenuItem { Header = Path.GetFileNameWithoutExtension(picture) };
            var path = picture;
            item.Click += (_, _) =>
            {
                if (common) { _state.Settings.CommonBackground = path; _state.Settings.ShowCommonBackground = true; } else _state.Settings.SlideBackground = path;
                _state.ApplySettings(_state.Settings);
            };
            fromFolder.Items.Add(item);
        }
        if (fromFolder.Items.Count > 0) flyout.Items.Add(fromFolder);
        if (common)
        {
            var toggle = new MenuItem { Header = _state.Settings.ShowCommonBackground ? Lang.T("Вимкнути спільний фон (Ctrl+F9)", "Turn the common background off (Ctrl+F9)") : Lang.T("Увімкнути спільний фон (Ctrl+F9)", "Turn the common background on (Ctrl+F9)") };
            toggle.Click += (_, _) => _state.ToggleCommonBackground();
            flyout.Items.Add(toggle);
        }
        var clear = new MenuItem { Header = Lang.T("Прибрати (фон шаблону)", "Remove (template background)") };
        clear.Click += (_, _) =>
        {
            if (common) _state.Settings.CommonBackground = ""; else _state.Settings.SlideBackground = "";
            _state.ApplySettings(_state.Settings);
        };
        flyout.Items.Add(clear);
        flyout.ShowAt(anchor);
    }

    void OpenPlansFlyout(Button anchor)
    {
        var flyout = new MenuFlyout();
        foreach (var file in ServicePlan.SavedPlans())
        {
            var item = new MenuItem { Header = (file == _state.Plan.FilePath ? "● " : "   ") + Path.GetFileNameWithoutExtension(file) };
            var path = file;
            item.Click += (_, _) => { try { _state.LoadPlan(path); } catch (Exception error) { _ = Ui.Message(this, Lang.T("План", "Plan"), error.Message); } };
            flyout.Items.Add(item);
        }
        if (flyout.Items.Count > 0) flyout.Items.Add(new Separator());
        var fresh = new MenuItem { Header = "+ " + Lang.T("Новий план…", "New plan…") };
        fresh.Click += (_, _) => _ = NewPlan();
        flyout.Items.Add(fresh);
        var rename = new MenuItem { Header = Lang.T("Перейменувати…", "Rename…") };
        rename.Click += async (_, _) =>
        {
            var title = await Ui.Prompt(this, Lang.T("Назва плану", "Plan title"), Lang.T("Назва:", "Title:"), _state.Plan.Title);
            if (title != null) _state.RenamePlan(title);
        };
        flyout.Items.Add(rename);
        var open = new MenuItem { Header = Lang.T("Відкрити файл…", "Open a file…") };
        open.Click += (_, _) => _ = OpenPlanFile();
        flyout.Items.Add(open);
        var save = new MenuItem { Header = Lang.T("Зберегти як…", "Save as…") };
        save.Click += (_, _) => _ = SavePlanAs();
        flyout.Items.Add(save);
        var delete = new MenuItem { Header = Lang.T("Видалити цей план", "Delete this plan") };
        delete.Click += async (_, _) =>
        {
            if (!await Ui.Ask(this, Lang.T("Видалити план", "Delete plan"), Lang.F("Видалити план «{0}» разом із файлом?", "Delete the plan “{0}” with its file?", _state.Plan.Title), Lang.T("Видалити", "Delete"))) return;
            var path = _state.Plan.FilePath;
            _state.ClearPlan();
            _state.NewPlan(Lang.T("План служіння", "Service plan"));
            if (path != null && File.Exists(path) && path != _state.Plan.FilePath) { try { File.Delete(path); } catch { /* лишиться */ } }
        };
        flyout.Items.Add(delete);
        flyout.ShowAt(anchor);
    }

    async System.Threading.Tasks.Task ClearPlanAsked()
    {
        if (_state.Plan.Items.Count == 0) return;
        if (await Ui.Ask(this, Lang.T("Очистити план", "Clear plan"), Lang.F("Прибрати всі {0} пунктів з плану «{1}»?", "Remove all {0} items from the plan “{1}”?", _state.Plan.Items.Count, _state.Plan.Title), Lang.T("Очистити", "Clear")))
            _state.ClearPlan();
    }

    void RefreshPlan()
    {
        _fillingPlan = true;
        try
        {
            _planTitle.Text = _state.Plan.Title + (_state.Plan.Items.Count > 0 ? "  (" + _state.Plan.Items.Count + ")" : "");
            _sermonEnd.IsVisible = _state.IsSermon;
            _planList.ItemsSource = _state.Plan.Items.ToList();
            _planList.SelectedIndex = _state.PlanSelection;
            if (_state.PlanSelection >= 0) _planList.ScrollIntoView(_state.PlanSelection);
        }
        finally { _fillingPlan = false; }
    }

    void RefreshHistory()
    {
        _fillingHistory = true;
        try
        {
            _historyList.ItemsSource = _state.History.Records.ToList();
            _historyList.SelectedIndex = _state.HistorySelection is Guid id ? _state.History.Records.FindIndex(r => r.Id == id) : -1;
        }
        finally { _fillingHistory = false; }
    }

    void UpdateControlButtons()
    {
        _hideButton.Background = _state.IsLive || _state.IsBlackout || _state.IsTextHidden ? Ui.AccentSoft : Ui.Line;
        _blackButton.Background = _state.IsBlackout ? Ui.Bad : Ui.Line;
        _blackButton.Foreground = _state.IsBlackout ? Brushes.White : Brushes.Black;
        _blankButton.Background = _state.IsTextHidden ? Ui.Accent : Ui.Line;
        _blankButton.Foreground = _state.IsTextHidden ? Brushes.White : Brushes.Black;
        _activeBox.IsChecked = _state.Settings.ArrowsShowLive;
    }

    void RefreshThumbnails()
    {
        var look = _state.Settings.Look(_state.Mode == "pictures" ? "bible" : _state.Mode);
        var template = look.TemplateName.Length > 0 ? _state.Templates.Named(look.TemplateName) : null;
        _templateThumb.Source = template?.ThumbnailPath != null ? Thumbnail(template.ThumbnailPath) : null;
        _templateNote.Text = template?.Name ?? Lang.T("без шаблону", "no template");
        _slideBgThumb.Source = _state.Settings.SlideBackground.Length > 0 ? Thumbnail(_state.Settings.SlideBackground) : null;
        _slideBgNote.Text = _state.Settings.SlideBackground.Length > 0 ? Path.GetFileNameWithoutExtension(_state.Settings.SlideBackground) : Lang.T("фон шаблону", "template's");
        _commonBgThumb.Source = _state.Settings.CommonBackground.Length > 0 ? Thumbnail(_state.Settings.CommonBackground) : null;
        _commonBgThumb.Opacity = _state.Settings.ShowCommonBackground ? 1 : 0.35;
        _commonBgNote.Text = _state.Settings.CommonBackground.Length > 0
            ? (_state.Settings.ShowCommonBackground ? "" : Lang.T("вимкнено: ", "off: ")) + Path.GetFileNameWithoutExtension(_state.Settings.CommonBackground)
            : Lang.T("не вибрано", "none");
    }

    // MARK: Передпоказ і зал — малюються не частіше кількох разів на секунду.

    void SchedulePreview()
    {
        if (_previewTimer != null) return;
        _previewTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(60), DispatcherPriority.Background, (_, _) =>
        {
            _previewTimer?.Stop();
            _previewTimer = null;
            RenderPreviews();
        });
        _previewTimer.Start();
    }

    void RenderPreviews()
    {
        try
        {
            var width = 480;
            var height = 270;
            if (_state.Settings.ManualPlacement && _state.Settings.CustomWidth > 0) height = (int)Math.Round((double)width * _state.Settings.CustomHeight / _state.Settings.CustomWidth);
            height = Math.Clamp(height, 120, 480);
            var preview = _preview.Source as Bitmap;
            _preview.Source = Bitmaps.Render(_state.PreviewOrder(), width, height);
            preview?.Dispose();
            var live = _live.Source as Bitmap;
            _live.Source = Bitmaps.Render(_state.HallOrder(), width, height);
            live?.Dispose();
            _previewReference.Text = _state.Slide.Reference.Length > 0 ? _state.Slide.Reference : _state.Mode == "pictures" && _state.CurrentPicture != null ? Path.GetFileName(_state.CurrentPicture) : "";
            _liveReference.Text = _state.IsBlackout ? Lang.T("Затемнення", "Black screen")
                : !_state.IsLive ? Lang.T("Зал порожній", "The hall is empty")
                : _state.IsTextHidden ? Lang.T("Порожній слайд", "Blank slide")
                : _state.LivePicture != null ? Path.GetFileName(_state.LivePicture)
                : _state.LiveSlide.Reference;
            RefreshThumbnails();
        }
        catch (Exception error)
        {
            Paths.Say("передпоказ: " + error.Message);
        }
    }
}
