// =============================================================================
//  MenuStrip.cs — рядок меню у вікні (Файл | Дії | Налаштування | Інтерфейс |
//  Мова | Довідка)
// =============================================================================
//  На Mac меню живе в системному рядку вгорі екрана, а цей рядок (NativeMenuBar)
//  захований. На Windows системного рядка немає — тож меню стоїть у вікні,
//  як у первісного VisioBible: значок і підпис, відкритий розділ — «пігулка»
//  кольору акценту. Склад пунктів — один список на все (MenuCatalog), той самий,
//  що в Mac-версії.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public enum MenuGroup { File, Actions, Settings, Interface, Language, Help }

/// Пункт меню: підпис, позначка, клавіша, межа групи, дія (немає — пункт сірий).
/// Пункт меню. `Picture` — мініатюра поруч (шаблони, фони), `IsHeader` — сірий заголовок.
public sealed record MenuEntry(string Title, Action? Run = null, bool IsOn = false, string? Key = null, bool StartsGroup = false,
                               string? Picture = null, bool IsHeader = false);

public static class MenuGroupInfo
{
    public static readonly MenuGroup[] All = Enum.GetValues<MenuGroup>();

    public static string CaptionKey(this MenuGroup g) => g switch
    {
        MenuGroup.File => "N1", MenuGroup.Actions => "N18", MenuGroup.Settings => "N13",
        MenuGroup.Interface => "N39", MenuGroup.Language => "N14", _ => "N4",
    };

    public static string Fallback(this MenuGroup g) => g switch
    {
        MenuGroup.File => Captions.T("Файл"), MenuGroup.Actions => Captions.T("Действия"),
        MenuGroup.Settings => Captions.T("Настройка"), MenuGroup.Interface => Captions.T("Интерфейс"),
        MenuGroup.Language => Captions.T("Language/Язык"), _ => Captions.T("Справка"),
    };

    public static string Symbol(this MenuGroup g) => g switch
    {
        MenuGroup.File => "folder", MenuGroup.Actions => "play.rectangle", MenuGroup.Settings => "gearshape",
        MenuGroup.Interface => "square.grid.2x2", MenuGroup.Language => "globe", _ => "questionmark.circle",
    };
}

public sealed class MenuStrip : LayoutPanel
{
    readonly Dictionary<MenuGroup, TitleButton> _buttons = new();
    /// Пункти розділу будуються в мить відкриття — завжди свіжі позначки.
    public Func<MenuGroup, IReadOnlyList<MenuEntry>> Entries = _ => Array.Empty<MenuEntry>();

    public MenuStrip()
    {
        foreach (var group in MenuGroupInfo.All)
        {
            var button = new TitleButton(group.Symbol());
            button.Pressed = () => Open(group);
            // Як у звичайному рядку меню: поки розділ відкритий, наведення на інший — відкриває його.
            button.Entered = () => { if (_menu != null && _menuGroup != group) Open(group); };
            _buttons[group] = button;
            Children.Add(button);
        }
        ApplyTitles();
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyTitles);
        Palette.Changed += () => { foreach (var b in _buttons.Values) b.InvalidateVisual(); };
    }

    public void ApplyTitles()
    {
        foreach (var group in MenuGroupInfo.All) _buttons[group].Title = Captions.Caption(group.CaptionKey(), group.Fallback());
        InvalidateArrange();
    }

    public string Caption(MenuGroup group) => _buttons[group].Title;

    protected override Size Desired(Size available) => new(0, RootView.Metrics.MenuBar);

    protected override void Arrangement(Size size)
    {
        double x = 0;
        foreach (var group in MenuGroupInfo.All)
        {
            var button = _buttons[group];
            Place(button, new Rect(x, 0, button.FittingWidth, size.Height));
            x += button.FittingWidth + 2;
        }
    }

    // Відкритий розділ. Власник (Windows 1.4.2): «при нажатиях на пункты меню в шапке предыдущее
    // меню не закрывается и происходит наложение» — кожне натискання відкривало нове меню поверх.
    ContextMenu? _menu;
    MenuGroup? _menuGroup, _closedGroup;
    long _closedAt;

    public bool IsMenuOpen => _menu != null;

    /// Відкрити розділ меню під його кнопкою. Інший розділ — попередній закривається; той самий
    /// ще раз — закривається (його могло вже закрити саме це натискання як клацання поза меню).
    public void Open(MenuGroup group)
    {
        if (_menu != null && _menuGroup == group) { _menu.Close(); return; }
        if (_menu == null && _closedGroup == group && Environment.TickCount64 - _closedAt < 300) { _closedGroup = null; return; }
        _menu?.Close();
        var button = _buttons[group];
        var menu = Build(Entries(group));
        _menu = menu;
        _menuGroup = group;
        button.IsOpen = true;
        menu.Closed += (_, _) =>
        {
            button.IsOpen = false;
            if (_menu != menu) return;
            _menu = null;
            _menuGroup = null;
            _closedGroup = group;
            _closedAt = Environment.TickCount64;
        };
        menu.PlacementTarget = button;
        menu.Placement = PlacementMode.BottomEdgeAlignedLeft;
        menu.Open(button);
    }

    /// Закрити відкритий розділ (Esc, перевірки).
    public void CloseMenu() => _menu?.Close();

    /// Підпис сполучення в меню. Назви клавіш «Слова» (як у hotkeys.ini VisioBible: «Esc», «Ins»,
    /// «Del», «PgUp», цифри) Avalonia не знає — без перекладу KeyGesture.Parse кидав виняток, і меню
    /// «Дії» (пункт «Сховати слайд» — Esc) не відкривалося (знайшов замір верху вікна 24.11).
    /// Незрозуміле сполучення — меню без підпису, а не виняток.
    public static KeyGesture? Gesture(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var parts = text.Split('+', StringSplitOptions.TrimEntries);
        // «Ctrl++» — плюс як клавіша: остання порожня частина.
        if (text.EndsWith("++")) parts = parts[..^2].Append("+").ToArray();
        var key = parts[^1] switch
        {
            "Esc" => "Escape", "Ins" => "Insert", "Del" => "Delete", "PgUp" => "PageUp", "PgDn" => "PageDown",
            "BackSpace" or "Backspace" => "Back",
            { Length: 1 } digit when char.IsDigit(digit[0]) => "D" + digit,
            var other => other,
        };
        var gesture = string.Join("+", parts[..^1].Append(key));
        try { return KeyGesture.Parse(gesture); }
        catch (Exception) { return null; }
    }

    public static ContextMenu Build(IReadOnlyList<MenuEntry> entries)
    {
        // Тема Fluent обмежує меню 456 точками — довгі пункти («Швидкий вибір книги/пісні введенням
        // її назви…») обрізалися посеред слова. На Mac меню ширшає під найдовший пункт.
        var menu = new ContextMenu { MaxWidth = 900 };
        var items = new List<Control>();
        foreach (var entry in entries)
        {
            if (entry.StartsGroup && items.Count > 0) items.Add(new Separator());
            Control? check = entry.IsOn ? new IconView("checkmark", 12) { Tint = () => Palette.Label } : null;
            Control? icon = check;
            if (entry.Picture != null && Thumbnails.Get(entry.Picture, 28) is { } picture)
            {
                // Як NSMenuItem.image поруч із позначкою стану: позначка, далі мініатюра 28 точок.
                var row = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 4 };
                row.Children.Add(check ?? new Control { Width = 12 });
                row.Children.Add(new Image { Source = picture, Height = 28, Width = Math.Round(28 * picture.Size.Width / Math.Max(1, picture.Size.Height)) });
                icon = row;
            }
            var item = new MenuItem
            {
                Header = entry.Title,
                InputGesture = Gesture(entry.Key),
                IsEnabled = entry.Run != null && !entry.IsHeader,
                Icon = icon,
            };
            var run = entry.Run;
            if (run != null) item.Click += (_, _) => run();
            items.Add(item);
        }
        menu.ItemsSource = items;
        return menu;
    }

    /// Кнопка розділу меню.
    sealed class TitleButton : Control
    {
        const double IconSize = 12, Gap = 4, Padding = 6;
        readonly string _symbol;
        string _title = "";
        bool _open;
        public Action? Pressed;
        public Action? Entered;

        public TitleButton(string symbol) { _symbol = symbol; }
        public string Title { get => _title; set { _title = value; InvalidateVisual(); } }
        public bool IsOpen { get => _open; set { _open = value; InvalidateVisual(); } }
        public double FittingWidth => Math.Ceiling(Padding * 2 + IconSize + Gap + UiFont.Width(_title, 12));

        public override void Render(DrawingContext g)
        {
            var b = new Rect(Bounds.Size);
            g.FillRectangle(Brushes.Transparent, b);
            if (_open) g.DrawRectangle(Palette.Brush(Palette.Selection), null, b.Deflate(new Thickness(0, 3)), 5, 5);
            var color = _open ? Colors.White : Palette.Label;
            var x = Padding;
            Icons.Draw(g, _symbol, new Rect(x, Math.Round((b.Height - IconSize) / 2), IconSize, IconSize), color);
            x += IconSize + Gap;
            var lh = UiFont.LineHeight(12);
            TextDraw.Draw(g, _title, new Rect(x, Math.Round((b.Height - lh) / 2), b.Width - x, lh), 12, color, wrap: false, trim: true);
        }

        protected override void OnPointerPressed(PointerPressedEventArgs e)
        {
            if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) { Pressed?.Invoke(); e.Handled = true; }
        }

        protected override void OnPointerEntered(PointerEventArgs e)
        {
            base.OnPointerEntered(e);
            // Пальцем «наведення» немає — лише миша й перо.
            if (e.Pointer.Type != PointerType.Touch) Entered?.Invoke();
        }
    }
}
