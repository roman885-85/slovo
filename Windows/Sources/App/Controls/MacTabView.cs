// =============================================================================
//  MacTabView.cs — вкладки вікна (як NSTabView на Mac): сегменти по центру
//  зверху, під ними округла підкладка зі сторінкою
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public sealed class MacTabView : LayoutPanel
{
    readonly List<(string Title, Control Page)> _items = new();
    readonly Header _header;
    readonly Border _box = new() { CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1) };
    int _selected;
    public double FontSize { get; set; } = 12;
    public event Action<int>? SelectionChanged;

    public MacTabView()
    {
        _header = new Header(this);
        Children.Add(_box);
        Children.Add(_header);
        Apply();
        Palette.Changed += Apply;
    }

    void Apply()
    {
        _box.Background = Palette.Brush(Palette.IsDark ? Color.FromRgb(0x34, 0x34, 0x33) : Color.FromRgb(0xE6, 0xE7, 0xE6));
        _box.BorderBrush = Palette.Brush(Palette.IsDark ? Color.FromArgb(30, 255, 255, 255) : Color.FromArgb(24, 0, 0, 0));
        _header.InvalidateVisual();
    }

    public void Add(string title, Control page)
    {
        _items.Add((title, page));
        page.IsVisible = _items.Count - 1 == _selected;
        Children.Insert(Children.Count - 1, page);
        InvalidateArrange();
    }

    public int SelectedIndex
    {
        get => _selected;
        set
        {
            if (value < 0 || value >= _items.Count || value == _selected) return;
            _selected = value;
            for (var i = 0; i < _items.Count; i++) _items[i].Page.IsVisible = i == value;
            _header.InvalidateVisual();
            SelectionChanged?.Invoke(value);
        }
    }

    public int Count => _items.Count;
    public string TitleAt(int i) => _items[i].Title;
    public Control PageAt(int i) => _items[i].Page;

    double[] Widths() => _items.Select(i => Math.Ceiling(UiFont.Width(i.Title, FontSize)) + 26).ToArray();

    protected override void Arrangement(Size size)
    {
        var widths = Widths();
        var total = widths.Sum();
        const double headerHeight = 24;
        Place(_header, new Rect(Math.Max(0, (size.Width - total) / 2), 0, Math.Min(total, size.Width), headerHeight));
        var box = new Rect(0, headerHeight / 2, size.Width, Math.Max(0, size.Height - headerHeight / 2));
        Place(_box, box);
        var content = new Rect(0, headerHeight + 4, size.Width, Math.Max(0, size.Height - headerHeight - 6));
        foreach (var (_, page) in _items) Place(page, content);
    }

    sealed class Header : Control
    {
        readonly MacTabView _owner;
        public Header(MacTabView owner) { _owner = owner; }

        public override void Render(DrawingContext g)
        {
            var dark = Palette.IsDark;
            var b = new Rect(Bounds.Size);
            g.DrawRectangle(Palette.Brush(dark ? Color.FromRgb(0x46, 0x46, 0x45) : Color.FromRgb(0xDC, 0xDC, 0xDC)), null, b.Deflate(new Thickness(0, 1)), 6, 6);
            var widths = _owner.Widths();
            double x = 0;
            for (var i = 0; i < widths.Length; i++)
            {
                var cell = new Rect(x, 1, widths[i], b.Height - 2);
                if (i == _owner._selected)
                {
                    var pill = cell.Deflate(new Thickness(1.5, 1.5));
                    g.DrawRectangle(Palette.Brush(Color.FromArgb(30, 0, 0, 0)), null, pill.Translate(new Vector(0, 0.5)), 5, 5);
                    g.DrawRectangle(Palette.Brush(dark ? Color.FromRgb(0x69, 0x69, 0x68) : Colors.White), null, pill, 5, 5);
                }
                else if (i > 0 && i - 1 != _owner._selected)
                    g.FillRectangle(Palette.Brush(Palette.Separator), new Rect(x, 6, 1, b.Height - 12));
                var lh = UiFont.LineHeight(_owner.FontSize);
                TextDraw.Draw(g, _owner._items[i].Title, new Rect(cell.X, cell.Center.Y - lh / 2, cell.Width, lh), _owner.FontSize,
                              Palette.Label, align: TextAlignment.Center, wrap: false);
                x += widths[i];
            }
        }

        protected override void OnPointerPressed(PointerPressedEventArgs e)
        {
            var x = e.GetPosition(this).X;
            var widths = _owner.Widths();
            double left = 0;
            for (var i = 0; i < widths.Length; i++)
            {
                if (x >= left && x < left + widths[i]) { _owner.SelectedIndex = i; break; }
                left += widths[i];
            }
            e.Handled = true;
        }
    }
}
