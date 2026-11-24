// =============================================================================
//  Columns.cs — колонки робочої області з підписами й межами, що тягнуться
// =============================================================================
//  Як NativeColumnsView / NativeLabelledPane / NativeIconButtonRow на Mac:
//  ширини колонок — від «ідеальної» в межах [найменша, найбільша], колонка
//  без найбільшої забирає решту; межа 1 точка, тягнеться за ±4 точки від неї.
//  Підпис колонки (11 пт, другорядний колір) — у смужці 19 точок згори.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public sealed class ColumnsView : LayoutPanel
{
    public readonly record struct Column(Control View, double MinWidth, double IdealWidth, double MaxWidth);

    readonly List<Column> _columns = new();
    double[] _widths = Array.Empty<double>();
    readonly List<double> _dividers = new();
    readonly Lines _lines;
    int? _dragging;
    double _dragStart, _dragWidth;

    public ColumnsView()
    {
        _lines = new Lines(this);
        Children.Add(_lines);
        Palette.Changed += _lines.InvalidateVisual;
    }

    public void Install(IEnumerable<Column> columns)
    {
        foreach (var c in _columns) Children.Remove(c.View);
        _columns.Clear();
        _columns.AddRange(columns);
        _widths = _columns.Select(c => c.IdealWidth).ToArray();
        foreach (var c in _columns) Children.Insert(Children.Count - 1, c.View);
        InvalidateArrange();
    }

    protected override void Arrangement(Size size)
    {
        _dividers.Clear();
        Place(_lines, new Rect(size));
        if (_columns.Count == 0) return;
        var gaps = _columns.Count - 1;
        double fixedWidth = 0;
        var flexible = new List<int>();
        for (var i = 0; i < _columns.Count; i++)
        {
            var c = _columns[i];
            if (c.MaxWidth == 0) flexible.Add(i);
            else { _widths[i] = Math.Min(c.MaxWidth, Math.Max(c.MinWidth, _widths[i])); fixedWidth += _widths[i]; }
        }
        var rest = Math.Max(0, size.Width - gaps - fixedWidth);
        foreach (var i in flexible) _widths[i] = Math.Max(_columns[i].MinWidth, rest / flexible.Count);
        double x = 0;
        for (var i = 0; i < _columns.Count; i++)
        {
            Place(_columns[i].View, new Rect(x, 0, _widths[i], size.Height));
            x += _widths[i];
            if (i < _columns.Count - 1) { _dividers.Add(x); x += 1; }
        }
        _lines.InvalidateVisual();
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        var p = e.GetPosition(this);
        if (_dragging is { } index)
        {
            var c = _columns[index];
            if (c.MaxWidth <= 0) return;
            var wanted = Math.Min(c.MaxWidth, Math.Max(c.MinWidth, _dragWidth + (p.X - _dragStart)));
            if (Math.Abs(wanted - _widths[index]) > 0.1) { _widths[index] = wanted; InvalidateArrange(); }
            return;
        }
        Cursor = _dividers.Any(d => Math.Abs(d - p.X) < 4) ? new Cursor(StandardCursorType.SizeWestEast) : null;
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        var p = e.GetPosition(this);
        var index = _dividers.FindIndex(d => Math.Abs(d - p.X) < 4);
        if (index < 0) return;
        _dragging = index; _dragStart = p.X; _dragWidth = _widths[index];
        e.Pointer.Capture(this);
        e.Handled = true;
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        if (_dragging == null) return;
        _dragging = null;
        e.Pointer.Capture(null);
    }

    /// Межі між колонками ловляться за ±4 точки — ширше, ніж сама лінія.
    sealed class Lines : Control
    {
        readonly ColumnsView _owner;
        public Lines(ColumnsView owner) { _owner = owner; IsHitTestVisible = true; }
        public override void Render(DrawingContext g)
        {
            var brush = Palette.Brush(Palette.Separator);
            foreach (var x in _owner._dividers) g.FillRectangle(brush, new Rect(x, 0, 1, Bounds.Height));
            // Прозорі смужки ±4 біля ліній, щоб межу можна було вхопити поверх колонок.
            foreach (var x in _owner._dividers) g.FillRectangle(Brushes.Transparent, new Rect(x - 4, 0, 9, Bounds.Height));
        }
    }
}

/// Колонка з підписом угорі («Клас:», «Книга:», «Розділ:», «Вірш:»).
public sealed class LabelledPane : LayoutPanel
{
    public const double CaptionHeight = 19;
    readonly BottomCaption _caption = new();
    Control? _content;

    public LabelledPane() { Children.Add(_caption); }

    public string Caption { get => _caption.Text; set => _caption.Text = value; }

    public void Install(Control view)
    {
        if (_content != null) Children.Remove(_content);
        _content = view;
        Children.Add(view);
        InvalidateArrange();
    }

    protected override void Arrangement(Size size)
    {
        Place(_caption, new Rect(6, 3, Math.Max(0, size.Width - 8), 14));
        if (_content != null) Place(_content, new Rect(0, CaptionHeight, size.Width, Math.Max(0, size.Height - CaptionHeight)));
    }
}

/// Ряд кнопок-значків над колонкою (20×16 через 22).
public sealed class IconButtonRow : LayoutPanel
{
    public const double RowHeight = 20;
    public readonly List<IconButton> Buttons = new();

    public void Install(IEnumerable<IconButton> buttons)
    {
        foreach (var b in Buttons) Children.Remove(b);
        Buttons.Clear();
        Buttons.AddRange(buttons);
        foreach (var b in Buttons) { b.SymbolSize = 13; b.Tint = () => Palette.Label; Children.Add(b); }
        InvalidateArrange();
    }

    protected override Size Desired(Size available) => new(0, RowHeight);

    protected override void Arrangement(Size size)
    {
        double x = 4;
        foreach (var b in Buttons) { Place(b, new Rect(x, 2, 20, 16)); x += 22; }
    }
}
