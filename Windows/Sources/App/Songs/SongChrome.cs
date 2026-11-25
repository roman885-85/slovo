// =============================================================================
//  SongChrome.cs — оформлення вкладки «Пісні» (як NativeSongChrome і NativeSongQuickRow)
// =============================================================================
//  Кнопка-значок 22×18 (увімкнена — пігулка кольору виділення), смуга кнопок 22
//  точки з рисками-роздільниками, вкладки пісенників (поточна — пігулка, колесо
//  гортає), підпис колонки 19 точок, колонка зі шматків, рядок швидкого вибору
//  25 точок, шапка 30 точок (вкладки, бейдж «змінено», панель кнопок праворуч).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public sealed class SongButton : Control
{
    public static readonly Size Size = new(22, 18);
    readonly string _symbol;
    readonly Action _action;
    bool _on, _enabled = true;
    /// Кнопка-меню: замість дії — меню під кнопкою.
    public Func<ContextMenu>? MenuBuilder;

    public SongButton(string symbol, string hint, Action? action = null)
    {
        _symbol = symbol;
        _action = action ?? (() => { });
        ToolTip.SetTip(this, hint);
        Palette.Changed += InvalidateVisual;
    }

    public bool IsOn { get => _on; set { if (_on == value) return; _on = value; InvalidateVisual(); } }
    public bool IsActive { get => _enabled; set { if (_enabled == value) return; _enabled = value; InvalidateVisual(); } }
    public void SetHint(string hint) => ToolTip.SetTip(this, hint);

    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size);
        g.FillRectangle(Brushes.Transparent, b);
        if (_on) g.DrawRectangle(Palette.Brush(Palette.Selection), null, b.Deflate(1), 3, 3);
        var tint = _on ? Colors.White : _enabled ? Palette.Label : Palette.TertiaryLabel;
        const double side = 11;
        Icons.Draw(g, _symbol, new Rect((b.Width - side) / 2, (b.Height - side) / 2, side, side), tint, 1.15);
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (!_enabled || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        e.Handled = true;
        if (MenuBuilder != null)
        {
            var menu = MenuBuilder();
            menu.PlacementTarget = this;
            menu.Placement = PlacementMode.BottomEdgeAlignedLeft;
            menu.Open(this);
            return;
        }
        _action();
    }
}

/// Смуга кнопок над колонкою (22 точки), риски між групами кнопок.
public sealed class SongToolStrip : LayoutPanel
{
    public const double Height = 22;
    public abstract record Item
    {
        public sealed record Button(SongButton View) : Item;
        public sealed record Divider : Item;
    }
    List<Item> _items = new();
    readonly List<double> _dividers = new();
    readonly Backdrop _back;

    public SongToolStrip()
    {
        _back = new Backdrop(this);
        Children.Add(_back);
    }

    public void Install(IEnumerable<Item> items)
    {
        foreach (var item in _items) if (item is Item.Button b) Children.Remove(b.View);
        _items = items.ToList();
        foreach (var item in _items) if (item is Item.Button b) Children.Add(b.View);
        InvalidateArrange();
    }

    protected override void Arrangement(Size size)
    {
        _dividers.Clear();
        Place(_back, new Rect(size));
        double x = 4;
        foreach (var item in _items)
        {
            if (item is Item.Button b) { Place(b.View, new Rect(x, 2, SongButton.Size.Width, SongButton.Size.Height)); x += SongButton.Size.Width + 1; }
            else { _dividers.Add(x + 3); x += 8; }
        }
        _back.InvalidateVisual();
    }

    sealed class Backdrop : Control
    {
        readonly SongToolStrip _owner;
        public Backdrop(SongToolStrip owner) { _owner = owner; Palette.Changed += InvalidateVisual; }
        public override void Render(DrawingContext g)
        {
            g.FillRectangle(Palette.Brush(Palette.ControlBackground), new Rect(Bounds.Size));
            foreach (var x in _owner._dividers) g.FillRectangle(Palette.Brush(Palette.Separator), new Rect(x, 4, 1, Bounds.Height - 8));
        }
    }
}

/// Вкладки пісенників: поточна — пігулка кольору виділення, решта — на тлі елементів.
public sealed class SongBookTabs : Control
{
    public const double Height = 22;
    public readonly record struct Tab(string Id, string Long, string Short, string Tooltip, string Url);
    public Action<string>? OnSelect;
    public Func<string, ContextMenu?>? OnMenu;
    public bool LongNames { get; private set; } = true;
    List<Tab> _tabs = new();
    List<double> _widths = new();
    double _offset;
    string _current = "", _placeholder = "";
    public int TabCount => _tabs.Count;

    public SongBookTabs() { ClipToBounds = true; Palette.Changed += InvalidateVisual; }

    public void SetTabs(IEnumerable<Tab> tabs, string current, bool longNames, string placeholder)
    {
        _tabs = tabs.ToList();
        _current = current;
        LongNames = longNames;
        _placeholder = placeholder;
        Measure();
        ScrollToCurrent();
        InvalidateVisual();
    }

    public void SetCurrent(string id)
    {
        if (id == _current) return;
        _current = id;
        Measure();
        ScrollToCurrent();
        InvalidateVisual();
    }

    void Measure() => _widths = _tabs.Select(t => Math.Ceiling(UiFont.Width(Label(t), 12, t.Id == _current ? FontWeight.SemiBold : FontWeight.Normal)) + 16).ToList();
    string Label(Tab t) => LongNames ? t.Long : t.Short.Length == 0 ? t.Long : t.Short;

    Rect RectAt(int index)
    {
        var x = 2 - _offset;
        for (var i = 0; i < index; i++) x += _widths[i] + 2;
        return new Rect(x, 2, _widths[index], Math.Max(0, Bounds.Height - 4));
    }

    double ContentWidth => _widths.Aggregate(4.0, (sum, w) => sum + w + 2);

    void ScrollToCurrent()
    {
        var index = _tabs.FindIndex(t => t.Id == _current);
        if (index < 0) return;
        var box = RectAt(index);
        if (box.X < 0) _offset += box.X - 4;
        else if (box.Right > Bounds.Width) _offset += box.Right - Bounds.Width + 4;
        Clamp();
    }

    void Clamp() => _offset = Math.Max(0, Math.Min(_offset, Math.Max(0, ContentWidth - Bounds.Width)));

    protected override void OnSizeChanged(SizeChangedEventArgs e) { base.OnSizeChanged(e); Clamp(); }

    public override void Render(DrawingContext g)
    {
        g.FillRectangle(Brushes.Transparent, new Rect(Bounds.Size));
        if (_tabs.Count == 0)
        {
            var lh = UiFont.LineHeight(12);
            TextDraw.Draw(g, _placeholder, new Rect(6, (Bounds.Height - lh) / 2, Bounds.Width - 6, lh), 12, Palette.SecondaryLabel, wrap: false, trim: true);
            return;
        }
        for (var i = 0; i < _tabs.Count; i++)
        {
            var box = RectAt(i);
            if (box.Right <= 0 || box.X >= Bounds.Width) continue;
            var current = _tabs[i].Id == _current;
            g.DrawRectangle(Palette.Brush(current ? Palette.Selection : Palette.ControlBackground), null, box, 4, 4);
            var weight = current ? FontWeight.SemiBold : FontWeight.Normal;
            var lh = UiFont.LineHeight(12, weight);
            TextDraw.Draw(g, Label(_tabs[i]), new Rect(box.X + 8, box.Y + (box.Height - lh) / 2, box.Width - 8, lh), 12,
                          current ? Colors.White : Palette.Label, weight, wrap: false);
        }
    }

    int? IndexAt(Point p)
    {
        for (var i = 0; i < _tabs.Count; i++) if (RectAt(i).Contains(p)) return i;
        return null;
    }

    bool _holdHooked;

    /// Затримати палець на вкладці збірника — її меню (як права кнопка).
    void HookHold()
    {
        if (_holdHooked) return;
        _holdHooked = true;
        Holding += (_, e) =>
        {
            if (e.HoldingState != HoldingState.Started || e.PointerType != PointerType.Touch || IndexAt(e.Position) is not { } held) return;
            if (OnMenu?.Invoke(_tabs[held].Id) is { } menu) { menu.PlacementTarget = this; menu.Open(this); }
            e.Handled = true;
        };
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        HookHold();
        base.OnPointerPressed(e);
        var point = e.GetCurrentPoint(this);
        if (IndexAt(point.Position) is not { } index) return;
        e.Handled = true;
        if (point.Properties.IsRightButtonPressed)
        {
            if (OnMenu?.Invoke(_tabs[index].Id) is { } menu) { menu.PlacementTarget = this; menu.Open(this); }
            return;
        }
        OnSelect?.Invoke(_tabs[index].Id);
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        base.OnPointerMoved(e);
        var tip = IndexAt(e.GetPosition(this)) is { } i ? _tabs[i].Tooltip : null;
        if (!Equals(ToolTip.GetTip(this), tip)) ToolTip.SetTip(this, tip);
    }

    protected override void OnPointerWheelChanged(PointerWheelEventArgs e)
    {
        base.OnPointerWheelChanged(e);
        var step = e.Delta.Y != 0 ? e.Delta.Y : e.Delta.X;
        if (step == 0) return;
        _offset -= step * 20;
        Clamp();
        InvalidateVisual();
        e.Handled = true;
    }
}

/// Підпис колонки (19 точок): напівжирний 11 пт другорядного кольору.
public sealed class SongColumnTitle : Control
{
    public const double Height = 19;
    string _text = "";
    public string Text { get => _text; set { if (_text == value) return; _text = value; InvalidateVisual(); } }
    public SongColumnTitle() { Palette.Changed += InvalidateVisual; }
    public override void Render(DrawingContext g)
    {
        g.FillRectangle(Palette.Brush(Palette.WindowBackground), new Rect(Bounds.Size));
        if (_text.Length == 0) return;
        var lh = UiFont.LineHeight(11, FontWeight.SemiBold);
        TextDraw.Draw(g, _text, new Rect(8, (Bounds.Height - lh) / 2, Math.Max(0, Bounds.Width - 8), lh), 11,
                      Palette.SecondaryLabel, FontWeight.SemiBold, wrap: false, trim: true);
    }
}

/// Колонка зі шматків згори донизу (0 — забирає решту), між шматками риска.
public sealed class SongColumn : LayoutPanel
{
    public readonly record struct Piece(Control View, double Height);
    List<Piece> _pieces = new();
    readonly List<double> _separators = new();
    readonly Backdrop _back;

    public SongColumn() { _back = new Backdrop(this); Children.Add(_back); }

    public void Install(IEnumerable<Piece> pieces)
    {
        foreach (var p in _pieces) Children.Remove(p.View);
        _pieces = pieces.ToList();
        foreach (var p in _pieces) Children.Add(p.View);
        InvalidateArrange();
    }

    public void SetVisible(bool shown, int position)
    {
        if (position < 0 || position >= _pieces.Count || _pieces[position].View.IsVisible == shown) return;
        _pieces[position].View.IsVisible = shown;
        InvalidateMeasure();
        InvalidateArrange();
    }

    protected override void Arrangement(Size size)
    {
        _separators.Clear();
        Place(_back, new Rect(size));
        var live = _pieces.Where(p => p.View.IsVisible).ToList();
        var fixedHeight = live.Sum(p => p.Height);
        var lines = Math.Max(0, live.Count - 1);
        var rest = Math.Max(30, size.Height - fixedHeight - lines);
        double y = 0;
        for (var i = 0; i < live.Count; i++)
        {
            if (i > 0) { _separators.Add(y); y += 1; }
            var height = live[i].Height == 0 ? rest : live[i].Height;
            Place(live[i].View, new Rect(0, y, size.Width, height));
            y += height;
        }
        _back.InvalidateVisual();
    }

    sealed class Backdrop : Control
    {
        readonly SongColumn _owner;
        public Backdrop(SongColumn owner) { _owner = owner; Palette.Changed += InvalidateVisual; }
        public override void Render(DrawingContext g)
        {
            g.FillRectangle(Palette.Brush(Palette.TextBackground), new Rect(Bounds.Size));
            foreach (var y in _owner._separators) g.FillRectangle(Palette.Brush(Palette.Separator), new Rect(0, y, Bounds.Width, 1));
        }
    }
}

/// Рядок швидкого вибору (25 точок): поле і кнопки праворуч.
public sealed class SongQuickRow : LayoutPanel
{
    public const double Height = 25;
    public readonly QuickField Field = new();
    readonly List<SongButton> _buttons;
    readonly Border _back = new();

    public SongQuickRow(IEnumerable<SongButton>? buttons = null)
    {
        _buttons = buttons?.ToList() ?? new List<SongButton>();
        Children.Add(_back);
        Children.Add(Field);
        foreach (var b in _buttons) Children.Add(b);
        _back.Background = Palette.Brush(Palette.WindowBackground);
        Palette.Changed += () => _back.Background = Palette.Brush(Palette.WindowBackground);
    }

    protected override void Arrangement(Size size)
    {
        Place(_back, new Rect(size));
        var tail = _buttons.Count * (SongButton.Size.Width + 2);
        var field = new Rect(6, (size.Height - QuickField.FieldHeight) / 2, Math.Max(20, size.Width - 12 - tail), QuickField.FieldHeight);
        Place(Field, field);
        var x = field.Right + 2;
        foreach (var b in _buttons)
        {
            Place(b, new Rect(x, (size.Height - SongButton.Size.Height) / 2, SongButton.Size.Width, SongButton.Size.Height));
            x += SongButton.Size.Width + 2;
        }
    }
}

/// Шапка вкладки (30 точок): вкладки пісенників (на вкладці «Пісні» вони стоять на
/// смузі перекладів), бейдж «змінено», кнопки праворуч.
public sealed class SongHeader : LayoutPanel
{
    public const double Height = 30;
    public readonly SongBookTabs Tabs = new();
    public readonly SongToolStrip Toolbar = new();
    readonly Badge _badge;
    double _toolbarWidth = 120;
    bool _modified, _keepsTabs = true;
    public string ModifiedTitle = Captions.T("изменён");

    public SongHeader()
    {
        _badge = new Badge(this);
        Children.Add(_badge);
        Children.Add(Tabs);
        Children.Add(Toolbar);
    }

    public double ToolbarWidth { get => _toolbarWidth; set { _toolbarWidth = value; InvalidateArrange(); } }
    public bool IsModified { get => _modified; set { if (_modified == value) return; _modified = value; InvalidateArrange(); _badge.InvalidateVisual(); } }
    public bool KeepsTabs { get => _keepsTabs; set { _keepsTabs = value; InvalidateArrange(); } }

    double BadgeWidth => _modified ? Math.Ceiling(UiFont.Width(ModifiedTitle, 10, FontWeight.SemiBold)) + 14 : 0;

    protected override void Arrangement(Size size)
    {
        Place(_badge, new Rect(size));
        var toolbar = new Rect(size.Width - _toolbarWidth - 4, (size.Height - SongToolStrip.Height) / 2, _toolbarWidth, SongToolStrip.Height);
        Place(Toolbar, toolbar);
        if (_keepsTabs && Tabs.Parent == this)
            Place(Tabs, new Rect(4, (size.Height - SongBookTabs.Height) / 2, Math.Max(40, toolbar.X - BadgeWidth - 12), SongBookTabs.Height));
        _badge.InvalidateVisual();
    }

    sealed class Badge : Control
    {
        readonly SongHeader _owner;
        public Badge(SongHeader owner) { _owner = owner; IsHitTestVisible = false; Palette.Changed += InvalidateVisual; }
        public override void Render(DrawingContext g)
        {
            g.FillRectangle(Palette.Brush(Palette.WindowBackground), new Rect(Bounds.Size));
            if (!_owner._modified) return;
            var w = Math.Ceiling(UiFont.Width(_owner.ModifiedTitle, 10, FontWeight.SemiBold)) + 10;
            var x = _owner._keepsTabs && _owner.Tabs.Parent == _owner ? _owner.Tabs.Bounds.Right + 4 : 6;
            var box = new Rect(x, (Bounds.Height - 16) / 2, w, 16);
            g.DrawRectangle(Palette.Brush(Palette.SystemOrange.WithAlpha(0.25)), null, box, 8, 8);
            var lh = UiFont.LineHeight(10, FontWeight.SemiBold);
            TextDraw.Draw(g, _owner.ModifiedTitle, new Rect(box.X + 5, box.Y + (box.Height - lh) / 2, w, lh), 10, Palette.Label, FontWeight.SemiBold, wrap: false);
        }
    }
}
