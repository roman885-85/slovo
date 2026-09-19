// =============================================================================
//  MainWindow.cs — робоче місце: керування показом і вивід на проектор
// =============================================================================
//  Власник 19.09.2026: «клиентская программа для windows должна повторять и
//  дополнять функции версии планшета, то есть как минимум в ней должно быть
//  управление и отображение на проектор».
//
//  Тому вікно влаштовано, як планшет (TabletActivity.java): згори — вкладки
//  програми, ліворуч — вміст вкладки, посередині — зал і передпоказ із
//  кнопками показу, праворуч — План та Історія. Складання плану проповіді
//  лишилося окремим вікном (кнопка «📋 План проповіді»), як на планшеті.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;

namespace Propovidnyk.Views;

public sealed partial class MainWindow : Window
{
    readonly Settings _settings = Settings.Load();
    readonly CancellationTokenSource _closing = new();
    Api _api;
    JsonObject _state = new();
    long _seq;
    bool _online;
    /// Вкладка, яку показує це вікно; за програмою йде сама.
    string _tab = "bible";
    /// Люди тиснуть кнопки швидше, ніж приходить стан: поки чекаємо, не
    /// перемальовуємо списки під руками.
    DateTime _touched = DateTime.MinValue;
    /// Мишу тримають на залі — веде указку.
    bool _pointing;
    DateTime _pointerSent = DateTime.MinValue;

    // Вкладки
    readonly Dictionary<string, Button> _tabButtons = new();
    readonly ContentControl _panel = new();
    // Зал
    readonly Image _hall = new() { Stretch = Stretch.Uniform };
    readonly TextBlock _hallNote = new() { Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _liveReference = new() { FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock _liveText = new() { TextWrapping = TextWrapping.Wrap, MaxLines = 4 };
    readonly TextBlock _previewReference = new() { FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap, Foreground = Ui.Muted };
    readonly TextBlock _previewText = new() { TextWrapping = TextWrapping.Wrap, MaxLines = 4, Foreground = Ui.Muted };
    readonly TextBlock _status = new() { Foreground = Ui.Muted, FontSize = 12, TextWrapping = TextWrapping.Wrap };
    readonly TextBlock _connection = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
    Button _showButton = null!, _hideButton = null!, _blackButton = null!, _blankButton = null!;
    // План та Історія
    readonly ListBox _side = new();
    readonly TextBlock _sideTitle = new() { FontWeight = FontWeight.SemiBold };
    Button _planTab = null!, _historyTab = null!, _sermonEnd = null!;
    bool _sideHistory;
    bool _fillingSide;
    int _sideSelected = -1;

    public MainWindow()
    {
        Width = 1460;
        Height = 880;
        MinWidth = 1040;
        MinHeight = 660;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        try { Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://Propovidnyk/Resources/AppIcon-256.png"))); }
        catch { /* без значка вікна — не біда */ }
        _api = Api.From(_settings);
        Build();
        Closing += (_, _) => _closing.Cancel();
        // Нова версія програми: питаємо GitHub раз на добу, мовчки.
        Opened += (_, _) => _ = Updates.CheckQuietly(this, _settings);
        _ = Follow();
        _ = RefreshHallLoop();
    }

    // MARK: Складання вікна

    void Build()
    {
        Title = Lang.T("Проповідник Слова", "Slovo Preacher");

        var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        _tabButtons.Clear();
        foreach (var (key, title) in new[]
                 {
                     ("bible", Lang.T("Біблія", "Bible")),
                     ("songs", Lang.T("Пісні", "Songs")),
                     ("presentation", Lang.T("Презентація", "Presentation")),
                     ("media", Lang.T("Медіа", "Media")),
                     ("pictures", Lang.T("Зображення", "Pictures")),
                     ("screen", Lang.T("Екран", "Screen")),
                     ("text", Lang.T("Текст", "Text")),
                 })
        {
            var button = Ui.Button(title, () => ChooseTab(key));
            _tabButtons[key] = button;
            tabs.Children.Add(button);
        }

        var language = new MenuFlyout();
        foreach (var (code, name) in new[] { ("auto", Lang.T("Авто (мова Windows)", "Auto (Windows language)")), ("uk", "Українська"), ("en", "English") })
        {
            var item = new MenuItem { Header = (_settings.Language == code ? "● " : "   ") + name };
            item.Click += (_, _) => ChangeLanguage(code);
            language.Items.Add(item);
        }
        language.Items.Add(new Separator());
        var check = new MenuItem { Header = Lang.F("Перевірити оновлення… (зараз {0})", "Check for updates… (now {0})", Updates.Ours) };
        check.Click += (_, _) => _ = Updates.CheckNow(this, _settings);
        language.Items.Add(check);
        var languageButton = Ui.Button("Мова / Language", () => { });
        languageButton.Flyout = language;

        var right = Ui.Row(
            Ui.Button("📋 " + Lang.T("План проповіді", "Sermon plan"), OpenPlan,
                      Lang.T("Скласти план проповіді заздалегідь і завантажити його в «Слово»", "Build a sermon plan in advance and upload it to Slovo"), accent: true),
            Ui.Button(Lang.T("Підключення…", "Connection…"), OpenConnection),
            languageButton);

        var top = new DockPanel { LastChildFill = false, Margin = new Thickness(10, 8, 10, 6) };
        DockPanel.SetDock(tabs, Dock.Left);
        DockPanel.SetDock(right, Dock.Right);
        top.Children.Add(tabs);
        top.Children.Add(right);

        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("7*,8,8*,8,5*"), Margin = new Thickness(10, 0, 10, 6) };
        var panelCard = Ui.Card(_panel, 8);
        // Кожній колонці — своя найменша ширина: інакше довгий список пісень
        // розпихав сусідів, і кнопки Плану виїжджали за край вікна.
        panelCard.MinWidth = 420;
        body.Children.Add(panelCard);
        var hallCard = HallColumn();
        hallCard.MinWidth = 360;
        Grid.SetColumn(hallCard, 2);
        body.Children.Add(hallCard);
        var sideCard = Ui.Card(SideColumn());
        sideCard.MinWidth = 250;
        Grid.SetColumn(sideCard, 4);
        body.Children.Add(sideCard);

        var bottom = new DockPanel { Margin = new Thickness(12, 0, 12, 8), LastChildFill = false };
        DockPanel.SetDock(_connection, Dock.Left);
        DockPanel.SetDock(_status, Dock.Right);
        bottom.Children.Add(_connection);
        bottom.Children.Add(_status);

        var root = new DockPanel { Background = Ui.Paper };
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(top);
        root.Children.Add(bottom);
        root.Children.Add(body);
        Content = root;

        ShowTab(_tab);
        MarkTabs();
        ShowConnection();
        FillSide();
    }

    Control HallColumn()
    {
        var hall = new Border
        {
            Background = Brushes.Black,
            CornerRadius = new CornerRadius(8),
            ClipToBounds = true,
            MinHeight = 200,
            Child = new Grid { Children = { _hall, _hallNote } },
        };
        // Указка й наближення — як на планшеті: ведіть пальцем по залу, і на
        // стіні йде пляма; подвійне клацання знімає наближення.
        hall.PointerPressed += (_, e) => { _pointing = true; Pointer(hall, e.GetPosition(hall)); };
        hall.PointerMoved += (_, e) => { if (_pointing) Pointer(hall, e.GetPosition(hall)); };
        hall.PointerReleased += (_, _) => { _pointing = false; Send("pointer-off"); };
        hall.PointerExited += (_, _) => { if (_pointing) { _pointing = false; Send("pointer-off"); } };
        hall.DoubleTapped += (_, _) => Send("zoom", new JsonObject { ["zoom"] = 1, ["x"] = 0.5, ["y"] = 0.5 });
        ToolTip.SetTip(hall, Lang.T("Ведіть мишею — указка на стіні; подвійне клацання знімає наближення",
                                    "Drag with the mouse — a pointer on the wall; a double click removes the zoom"));
        var texts = new StackPanel { Spacing = 3, Margin = new Thickness(2, 8, 2, 0) };
        texts.Children.Add(Ui.Label(Lang.T("У залі:", "In the hall:"), 12, true));
        texts.Children.Add(_liveReference);
        texts.Children.Add(_liveText);
        texts.Children.Add(Ui.Label(Lang.T("Передпоказ:", "Preview:"), 12, true));
        texts.Children.Add(_previewReference);
        texts.Children.Add(_previewText);

        _showButton = Ui.Button(Lang.T("Показати", "Show"), () => Send("show"),
                                Lang.T("Вивести в зал те, що в передпоказі", "Show what is in the preview in the hall"), accent: true);
        _hideButton = Ui.Button(Lang.T("Сховати", "Hide"), () => Send("hide"));
        _blackButton = Ui.Button(Lang.T("Чорний", "Black"), () => Send("black"),
                                 Lang.T("Чорний екран у залі", "A black screen in the hall"));
        _blankButton = Ui.Button(Lang.T("Порожній", "Blank"), () => Send("blank"),
                                 Lang.T("Порожній слайд: фон без тексту", "A blank slide: background without text"));
        var buttons = new WrapPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        foreach (var button in new[]
                 {
                     Ui.Button("◀ " + Lang.T("Назад", "Back"), () => Send("prev")),
                     Ui.Button(Lang.T("Далі", "Next") + " ▶", () => Send("next"), accent: true),
                     _showButton, _hideButton, _blackButton, _blankButton,
                 })
        {
            button.Margin = new Thickness(0, 0, 6, 6);
            buttons.Children.Add(button);
        }

        var column = new DockPanel();
        DockPanel.SetDock(texts, Dock.Bottom);
        DockPanel.SetDock(buttons, Dock.Bottom);
        column.Children.Add(buttons);
        column.Children.Add(texts);
        column.Children.Add(hall);
        return Ui.Card(column, 8);
    }

    Control SideColumn()
    {
        _planTab = Ui.Button(Lang.T("План", "Plan"), () => { _sideHistory = false; FillSide(); });
        _historyTab = Ui.Button(Lang.T("Історія", "History"), () => { _sideHistory = true; FillSide(); });
        _sermonEnd = Ui.Button(Lang.T("Повернути план служіння", "Restore the service plan"), () => Send("sermon-end"),
                               Lang.T("План служіння лише відкладено на час проповіді", "The service plan is only set aside for the sermon"));
        _sermonEnd.IsVisible = false;
        _sermonEnd.Foreground = Ui.Accent;

        _side.ItemTemplate = new FuncDataTemplate<SideRow>((row, _) =>
        {
            var panel = new StackPanel { Spacing = 2, Margin = new Thickness(2, 3) };
            panel.Children.Add(new TextBlock
            {
                Text = row?.Title ?? "",
                FontWeight = row?.Current == true ? FontWeight.Bold : FontWeight.Normal,
                Foreground = row?.Current == true ? Ui.Accent : Brushes.Black,
                TextWrapping = TextWrapping.Wrap,
            });
            if (!string.IsNullOrEmpty(row?.Subtitle))
                panel.Children.Add(new TextBlock { Text = row.Subtitle, Foreground = Ui.Muted, FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxLines = 2 });
            return panel;
        });
        ScrollViewer.SetHorizontalScrollBarVisibility(_side, ScrollBarVisibility.Disabled);
        _side.SelectionChanged += (_, _) =>
        {
            if (_fillingSide || _side.SelectedItem is not SideRow row) return;
            _sideSelected = row.Index;
            Send(_sideHistory ? "history" : "plan", row.Index);
        };

        var buttons = new WrapPanel();
        foreach (var button in new[]
                 {
                     Ui.Button("＋ " + Lang.T("У План", "To Plan"), () => Send("plan-add"),
                               Lang.T("Покласти в План те, що зараз вибрано в програмі", "Put what is selected in the program into the Plan")),
                     Ui.Button("↑", () => Move(-1), Lang.T("Пересунути пункт вище", "Move the item up")),
                     Ui.Button("↓", () => Move(1), Lang.T("Пересунути пункт нижче", "Move the item down")),
                     Ui.Button("✕", Remove, Lang.T("Прибрати пункт", "Remove the item")),
                 })
        {
            button.Margin = new Thickness(0, 0, 6, 6);
            buttons.Children.Add(button);
        }

        var head = new StackPanel { Spacing = 6, Margin = new Thickness(0, 0, 0, 6) };
        head.Children.Add(Ui.Row(_planTab, _historyTab));
        head.Children.Add(_sideTitle);
        head.Children.Add(Ui.Hint(Lang.T("Клацніть пункт — він у залі.", "Click an item — it goes to the hall.")));
        var bottom = new StackPanel { Spacing = 4 };
        bottom.Children.Add(buttons);
        bottom.Children.Add(_sermonEnd);

        var column = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        column.Children.Add(head);
        column.Children.Add(bottom);
        column.Children.Add(new Border { Child = _side, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) });
        return column;
    }

    /// Рядок плану чи історії. ToString — те, що читає озвучка Windows.
    sealed record SideRow(int Index, string Title, string Subtitle, bool Current)
    {
        public override string ToString() => Subtitle.Length > 0 ? Title + " — " + Subtitle : Title;
    }

    // MARK: Вкладки

    void ChooseTab(string key)
    {
        _tab = key;
        ShowTab(key);
        MarkTabs();
        Send("mode", key, byText: true);
    }

    void MarkTabs()
    {
        var program = (string?)_state["mode"] ?? "";
        foreach (var (key, button) in _tabButtons)
        {
            var mine = key == _tab;
            button.Background = mine ? Ui.AccentSoft : Brushes.Transparent;
            button.FontWeight = mine ? FontWeight.SemiBold : FontWeight.Normal;
            // Крапка — вкладка, на якій стоїть сама програма.
            var title = button.Content as string ?? "";
            var clean = title.TrimEnd(' ', '●');
            button.Content = key == program ? clean + " ●" : clean;
        }
    }

    /// Указка: частки ширини й висоти картинки залу, вісь Y униз.
    void Pointer(Control hall, Point at)
    {
        // Картинка вписана в чорне поле: рахуємо частку від самої картинки,
        // інакше пляма з'їжджала б на широкому екрані.
        var width = hall.Bounds.Width;
        var height = hall.Bounds.Height;
        if (_hall.Source is Bitmap bitmap && bitmap.Size.Width > 0 && bitmap.Size.Height > 0)
        {
            var scale = Math.Min(width / bitmap.Size.Width, height / bitmap.Size.Height);
            var shownWidth = bitmap.Size.Width * scale;
            var shownHeight = bitmap.Size.Height * scale;
            var left = (width - shownWidth) / 2;
            var top = (height - shownHeight) / 2;
            width = shownWidth;
            height = shownHeight;
            at = new Point(at.X - left, at.Y - top);
        }
        if (width <= 1 || height <= 1) return;
        var x = Math.Min(1, Math.Max(0, at.X / width));
        var y = Math.Min(1, Math.Max(0, at.Y / height));
        // Двадцять разів на секунду досить: більше — зайвий шум у мережі.
        if (DateTime.UtcNow - _pointerSent < TimeSpan.FromMilliseconds(50)) return;
        _pointerSent = DateTime.UtcNow;
        Send("pointer", new JsonObject
        {
            ["x"] = x, ["y"] = y, ["colour"] = "#FFD400", ["size"] = 0.05, ["opacity"] = 0.85,
        });
    }

    void ShowTab(string key)
    {
        _panel.Content = key switch
        {
            "songs" => SongsPanel(),
            "presentation" => PagesPanel(presentation: true),
            "media" => MediaPanel(),
            "pictures" => PagesPanel(presentation: false),
            "screen" => ScreenPanel(),
            "text" => TextPanel(),
            _ => BiblePanel(),
        };
    }
}
