// =============================================================================
//  TranslationStrip.cs — смуга перекладів під робочою областю
// =============================================================================
//  Як NativeTranslationStripView на Mac: вкладки перекладів (основний —
//  «пігулка» акценту, напівжирний; другий — акцент 22 %), Ctrl+клацання —
//  другий переклад, права кнопка — меню вкладки. Праворуч: «Один переклад ⌄»
//  (вибір другого перекладу), «Пошук:» поле 140, кнопка результатів пошуку,
//  «Швидк. вибір:» поле 104, червоний підпис помилки адреси.
//  На вкладці «Пісні» замість вкладок перекладів стоять вкладки пісенників.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

/// Вкладки (перекладів чи пісенників): підпис, ідентифікатор, позначки.
public sealed class TabStrip : Control
{
    public readonly record struct Tab(string Title, string Id, bool IsPrimary, bool IsSecondary, string Tooltip);
    readonly List<(Tab Tab, Rect Box)> _tabs = new();
    public Action<string, bool>? OnPick;
    public Func<string, ContextMenu?>? OnMenu;
    public double FittingWidth { get; private set; }

    public TabStrip() { Palette.Changed += InvalidateVisual; }

    public int TabCount => _tabs.Count;

    public void Reload(IEnumerable<Tab> tabs)
    {
        _tabs.Clear();
        double x = 6;
        foreach (var tab in tabs)
        {
            var width = Math.Ceiling(UiFont.Width(tab.Title, 11, tab.IsPrimary ? FontWeight.Bold : FontWeight.Normal)) + 14;
            _tabs.Add((tab, new Rect(x, 3, width, 20)));
            x += width + 3;
        }
        FittingWidth = x;
        InvalidateMeasure();
        InvalidateVisual();
    }

    protected override Size MeasureOverride(Size available) => new(FittingWidth, 26);

    public override void Render(DrawingContext g)
    {
        g.FillRectangle(Brushes.Transparent, new Rect(Bounds.Size));
        var top = Math.Round((Bounds.Height - 20) / 2);
        foreach (var (tab, box0) in _tabs)
        {
            var box = box0.WithY(top);
            if (tab.IsPrimary) g.DrawRectangle(Palette.Brush(Palette.Selection), null, box, 4, 4);
            else if (tab.IsSecondary) g.DrawRectangle(Palette.Brush(Palette.Accent.WithAlpha(0.22)), null, box, 4, 4);
            var weight = tab.IsPrimary ? FontWeight.Bold : FontWeight.Normal;
            var lh = UiFont.LineHeight(11, weight);
            TextDraw.Draw(g, tab.Title, new Rect(box.X, box.Y + (box.Height - lh) / 2, box.Width, lh), 11,
                          tab.IsPrimary ? Colors.White : Palette.Label, weight, TextAlignment.Center, wrap: false);
        }
    }

    (Tab Tab, Rect Box)? At(Point p)
    {
        foreach (var t in _tabs) if (p.X >= t.Box.X && p.X < t.Box.Right) return t;
        return null;
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        var point = e.GetCurrentPoint(this);
        if (At(point.Position) is not { } hit) return;
        if (point.Properties.IsRightButtonPressed)
        {
            if (OnMenu?.Invoke(hit.Tab.Id) is { } menu) { menu.PlacementTarget = this; menu.Open(this); }
        }
        else OnPick?.Invoke(hit.Tab.Id, e.KeyModifiers.HasFlag(KeyModifiers.Control));
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        var tip = At(e.GetPosition(this))?.Tab.Tooltip;
        if (!Equals(ToolTip.GetTip(this), tip)) ToolTip.SetTip(this, tip);
    }
}

/// Підпис поруч із полем (11 пт).
public sealed class InlineCaption : Control
{
    string _text = "";
    public Func<Color> Color = () => Palette.SecondaryLabel;
    public FontWeight Weight = FontWeight.Normal;
    public InlineCaption() { Palette.Changed += InvalidateVisual; }
    public string Text { get => _text; set { _text = value; InvalidateVisual(); } }
    public double FittingWidth => _text.Length == 0 ? 0 : Math.Ceiling(UiFont.Width(_text, 11, Weight)) + 2;
    public override void Render(DrawingContext g)
    {
        if (_text.Length == 0) return;
        var lh = UiFont.LineHeight(11, Weight);
        TextDraw.Draw(g, _text, new Rect(0, (Bounds.Height - lh) / 2, Bounds.Width, lh), 11, Color(), Weight, wrap: false, trim: true);
    }
}

/// «Один переклад ⌄» — кнопка-меню без рамки.
public sealed class PullDown : Control
{
    string _title = "";
    public Func<ContextMenu?>? Menu;
    public PullDown() { Palette.Changed += InvalidateVisual; }
    public string Title { get => _title; set { _title = value; InvalidateMeasure(); InvalidateVisual(); } }
    public double FittingWidth => Math.Ceiling(UiFont.Width(_title, 11)) + 18;
    public override void Render(DrawingContext g)
    {
        g.FillRectangle(Brushes.Transparent, new Rect(Bounds.Size));
        var lh = UiFont.LineHeight(11);
        var y = (Bounds.Height - lh) / 2;
        TextDraw.Draw(g, _title, new Rect(0, y, Bounds.Width - 14, lh), 11, Palette.Label, wrap: false, trim: true);
        Icons.Draw(g, "chevron.down", new Rect(Bounds.Width - 12, Bounds.Height / 2 - 4.5, 9, 9), Palette.Label, 1.4);
    }
    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (Menu?.Invoke() is { } menu) { menu.PlacementTarget = this; menu.Placement = PlacementMode.BottomEdgeAlignedLeft; menu.Open(this); }
        e.Handled = true;
    }
}

public sealed class TranslationStrip : LayoutPanel
{
    readonly ScrollViewer _scroll;
    public readonly TabStrip Tabs = new();
    readonly InlineCaption _searchCaption = new(), _addressCaption = new();
    public readonly InlineCaption ErrorCaption = new() { Color = () => Palette.SystemRed };
    public readonly QuickField SearchField = new(), AddressField = new();
    public readonly IconButton SearchToggle = new("list.bullet.rectangle", 13);
    public readonly PullDown PairButton = new();
    Control? _guest;

    public TranslationStrip()
    {
        _scroll = new ScrollViewer
        {
            Content = Tabs,
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
        };
        SearchToggle.Tint = () => Palette.Label;
        foreach (Control c in new Control[] { _scroll, _searchCaption, SearchField, SearchToggle, _addressCaption, AddressField, ErrorCaption, PairButton })
            Children.Add(c);
        Layout = Arrange;
        SearchField.Placeholder = Captions.T("Слова для поиска…");
        AddressField.Placeholder = Captions.T("Адрес: Ин 3:16");
        ApplyCaptions();
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyCaptions);
    }

    public void ApplyCaptions()
    {
        _searchCaption.Text = Captions.Caption("Label3D11", "Поиск:");
        _addressCaption.Text = Captions.Caption("Label3D14", "Быстр. выбор:");
        ToolTip.SetTip(PairButton, Captions.T("Второй перевод на слайде: он же выбирается правой кнопкой по вкладке"));
        ToolTip.SetTip(SearchToggle, Captions.MainHint("SBSearchToggle", "Показать/скрыть результаты поиска"));
        ToolTip.SetTip(SearchField, Captions.MainHint("ESearch", "Поиск"));
        ToolTip.SetTip(AddressField, Captions.MainHint("EFastInput",
            "Быстрый выбор вводом в формате:\n[номер Книги] Книга Глава Стих [Стих_по] (имя книги можно сокращать)").Replace("\\n", "\n"));
        SearchField.Placeholder = Captions.T("Слова для поиска…");
        AddressField.Placeholder = Captions.T("Адрес: Ин 3:16");
        InvalidateArrange();
    }

    /// Чужі вкладки замість перекладів (пісенники на вкладці «Пісні»).
    public void ShowGuestTabs(Control? view)
    {
        if (ReferenceEquals(_guest, view)) return;
        if (_guest != null) Children.Remove(_guest);
        _guest = view;
        _scroll.IsVisible = view == null;
        PairButton.IsVisible = view == null;
        if (view != null) Children.Add(view);
        InvalidateArrange();
    }

    void Arrange(Size size)
    {
        var height = QuickField.FieldHeight;
        var y = (size.Height - height) / 2;
        var right = size.Width;
        if (ErrorCaption.Text.Length > 0)
        {
            var w = ErrorCaption.FittingWidth;
            Place(ErrorCaption, new Rect(right - w, 0, w, size.Height));
            right -= w + 6;
        }
        else Place(ErrorCaption, default);
        Place(AddressField, new Rect(right - 104, y, 104, height));
        right -= 104 + 4;
        var aw = _addressCaption.FittingWidth;
        Place(_addressCaption, new Rect(right - aw, 0, aw, size.Height));
        right -= aw + 6;
        Place(SearchToggle, new Rect(right - 20, (size.Height - 16) / 2, 20, 16));
        right -= 20 + 4;
        Place(SearchField, new Rect(right - 140, y, 140, height));
        right -= 140 + 4;
        var sw = _searchCaption.FittingWidth;
        Place(_searchCaption, new Rect(right - sw, 0, sw, size.Height));
        right -= sw + 6;
        if (_guest == null)
        {
            var pw = PairButton.FittingWidth + 6;
            Place(PairButton, new Rect(right - pw, y, pw, height));
            right -= pw + 8;
            Place(_scroll, new Rect(0, 0, Math.Max(0, right), size.Height));
        }
        else
        {
            Place(PairButton, default);
            Place(_scroll, default);
            Place(_guest, new Rect(4, (size.Height - 22) / 2, Math.Max(40, right - 8), 22));
        }
    }
}
