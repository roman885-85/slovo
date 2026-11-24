// =============================================================================
//  GridTable.cs — таблиця з колонками (як NSTableView у NSScrollView на Mac)
// =============================================================================
//  Заголовки колонок, рядки однакової висоти з чергуванням тла (і в порожньому
//  місці під рядками), вибір рядка, меню правої кнопки. Комірка може бути
//  списком, що випадає: клацання відкриває меню, вибір віддається власникові.
//  Розміри — зі знімка вікна «Переклад інтерфейсу» Mac 1.3.9 (світле й темне):
//  обідок 1, заголовок 27 + риска, підпис першої колонки за 9 від краю, між
//  колонками 17 (intercellSpacing), риска між заголовками за 12 до підпису,
//  висотою 16 з відступом 6 згори. Колонки — задані ширини; що не влізло
//  праворуч, обрізається (горизонтальної прокрутки на Mac немає). Віртуальна:
//  малює лише видимі рядки.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public interface IGridSource
{
    int RowCount { get; }
    string Cell(int row, int column);
    /// Колір тексту рядка (null — звичайний).
    Color? RowColor(int row) => null;
    /// Колір тексту комірки (за умовчанням — колір рядка).
    Color? CellColor(int row, int column) => RowColor(row);
    /// Рядок закреслено (видалений рядок, що ще показується).
    bool IsStruck(int row) => false;
    /// Список, що випадає, у комірці: пункти й вибраний (null — звичайний текст).
    (IReadOnlyList<string> Items, int Selected)? Choice(int row, int column) => null;
}

public sealed class GridTable : LayoutPanel
{
    public sealed record Column(string Title, double Width);

    /// Сірий рядок через один (alternatingContentBackgroundColors).
    public static Color Alternate => Palette.IsDark ? Color.FromArgb(13, 255, 255, 255) : Color.FromRgb(0xF4, 0xF5, 0xF5);
    /// Обідок прокрутки й лінія під заголовками.
    public static Color Border => Palette.IsDark ? Color.FromRgb(0x35, 0x35, 0x35) : Color.FromRgb(0xE5, 0xE5, 0xE5);
    /// Риски між заголовками колонок.
    public static Color HeaderRule => Palette.IsDark ? Color.FromRgb(0x47, 0x48, 0x47) : Color.FromRgb(0xE5, 0xE5, 0xE5);

    readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly Body _body;
    readonly HeaderView _header;
    readonly PaintLayer _frame;
    IReadOnlyList<Column> _columns = Array.Empty<Column>();
    public IGridSource? Source;
    public double RowHeight = 20;
    public double HeaderHeight = 27;
    public double FontSize = 11;
    public double HeaderFontSize = 11;
    /// Підпис першої колонки — від лівого краю; між колонками — проміжок; риска — за стільки до підпису.
    public double TextInset = 9, Gap = 17, RuleBack = 12;
    /// Комірки — текст «як є», без лігатур шрифту (ключі й тексти перекладу).
    public bool PlainText;
    /// Довгий текст комірки обрізається краєм колонки без «…» (мітка NSTextField
    /// за умовчанням); false — з трьома крапками (.byTruncatingTail).
    public bool ClipCells;
    /// Рядок тексту комірки — від верху рядка (як мітки в NSTableView без
    /// вирівнювання); null — посередині рядка.
    public double? CellTop;
    public int? Selected { get; private set; }
    public Action<int>? OnSelect;
    public Action<int>? OnActivate;
    public Func<int, ContextMenu?>? OnContextMenu;
    public Action<int, int, int>? OnChoice;

    public GridTable()
    {
        _header = new HeaderView(this);
        _body = new Body(this);
        _scroll.Content = _body;
        _frame = new PaintLayer((g, b) => g.DrawRectangle(null, new Pen(Palette.Brush(Border), 1), b.Deflate(0.5)));
        _frame.IsHitTestVisible = false;
        Children.Add(_header);
        Children.Add(_scroll);
        Children.Add(_frame);
        Focusable = true;
        _scroll.ScrollChanged += (_, _) => _body.InvalidateVisual();
        Palette.Changed += () => { _header.InvalidateVisual(); _body.InvalidateVisual(); _frame.InvalidateVisual(); };
    }

    protected override void Arrangement(Size size)
    {
        Place(_header, new Rect(1, 1, Math.Max(0, size.Width - 2), HeaderHeight + 1));
        Place(_scroll, new Rect(1, 2 + HeaderHeight, Math.Max(0, size.Width - 2), Math.Max(0, size.Height - 3 - HeaderHeight)));
        Place(_frame, new Rect(size));
    }

    public void SetColumns(IReadOnlyList<Column> columns)
    {
        _columns = columns;
        _header.InvalidateVisual();
        _body.InvalidateVisual();
    }

    public void Reload()
    {
        var count = Source?.RowCount ?? 0;
        if (Selected is { } s && s >= count) Selected = null;
        _body.InvalidateMeasure();
        _body.InvalidateVisual();
    }

    public void Select(int? row, bool scroll = true)
    {
        Selected = row;
        _body.InvalidateVisual();
        if (!scroll || row is not { } r) return;
        var top = r * RowHeight;
        var viewport = _scroll.Viewport.Height;
        if (viewport <= 0) return;
        if (top < _scroll.Offset.Y) _scroll.Offset = new Vector(0, top);
        else if (top + RowHeight > _scroll.Offset.Y + viewport) _scroll.Offset = new Vector(0, top + RowHeight - viewport);
    }

    /// Де стоїть підпис кожної колонки (від лівого краю вмісту) і скільки йому місця.
    List<(double Text, double Width)> Layout(double width)
    {
        var result = new List<(double, double)>();
        var x = TextInset;
        for (var i = 0; i < _columns.Count; i++)
        {
            var w = i == _columns.Count - 1 ? Math.Max(_columns[i].Width, width - x - 4) : _columns[i].Width;
            result.Add((x, w));
            x += _columns[i].Width + Gap;
        }
        return result;
    }

    sealed class HeaderView : Control
    {
        readonly GridTable _t;
        public HeaderView(GridTable table) { _t = table; ClipToBounds = true; }
        public override void Render(DrawingContext g)
        {
            var b = new Rect(Bounds.Size);
            g.FillRectangle(Palette.Brush(Palette.TextBackground), b);
            g.FillRectangle(Palette.Brush(Border), new Rect(0, b.Height - 1, b.Width, 1));
            var columns = _t.Layout(b.Width);
            var lh = UiFont.LineHeight(_t.HeaderFontSize);
            var y = Math.Round((_t.HeaderHeight - lh) / 2);
            for (var i = 0; i < columns.Count; i++)
            {
                var (x, w) = columns[i];
                if (i > 0) g.FillRectangle(Palette.Brush(HeaderRule), new Rect(Math.Round(x - _t.RuleBack), 6, 1, Math.Max(0, _t.HeaderHeight - 11)));
                TextDraw.Draw(g, _t._columns[i].Title, new Rect(x, y, Math.Max(0, w), lh), _t.HeaderFontSize, Palette.Label, wrap: false, trim: true);
            }
        }
    }

    sealed class Body : Control
    {
        readonly GridTable _t;
        public Body(GridTable table) { _t = table; ClipToBounds = true; }

        protected override Size MeasureOverride(Size available)
        {
            var count = _t.Source?.RowCount ?? 0;
            var width = double.IsInfinity(available.Width) ? 400 : available.Width;
            return new Size(width, Math.Max(count * _t.RowHeight, _t._scroll.Viewport.Height));
        }

        public override void Render(DrawingContext g)
        {
            var b = new Rect(Bounds.Size);
            var count = _t.Source?.RowCount ?? 0;
            var top = _t._scroll.Offset.Y;
            var bottom = top + Math.Max(_t._scroll.Viewport.Height, 1);
            // Своя межа видимого: частково видний нижній рядок не має вилазити за рамку.
            using var clip = g.PushClip(new Rect(0, top, b.Width, bottom - top));
            g.FillRectangle(Palette.Brush(Palette.TextBackground), new Rect(0, top, b.Width, bottom - top));
            var columns = _t.Layout(b.Width);
            var lh = UiFont.LineHeight(_t.FontSize);
            // Чергування тла — і нижче останнього рядка, як у NSTableView.
            var last = (int)Math.Ceiling(bottom / _t.RowHeight);
            for (var r = Math.Max(0, (int)(top / _t.RowHeight)); r <= last; r++)
            {
                var rect = new Rect(0, r * _t.RowHeight, b.Width, _t.RowHeight);
                var selected = r == _t.Selected && r < count;
                if (selected) g.FillRectangle(Palette.Brush(Palette.Selection), rect);
                else if (r % 2 == 1) g.FillRectangle(Palette.Brush(Alternate), rect);
                if (r >= count || _t.Source is not { } source) continue;
                var struck = source.IsStruck(r);
                var lineTop = rect.Y + (_t.CellTop ?? Math.Round((rect.Height - lh) / 2));
                for (var c = 0; c < columns.Count; c++)
                {
                    var (x, w) = columns[c];
                    if (source.Choice(r, c) is { } choice)
                    {
                        var title = choice.Selected >= 0 && choice.Selected < choice.Items.Count ? choice.Items[choice.Selected] : "";
                        DrawChoice(g, ChoiceRect(x, w, rect.Y), title);
                        continue;
                    }
                    var color = selected ? Palette.SelectedText : struck ? Palette.SecondaryLabel : source.CellColor(r, c) ?? Palette.Label;
                    var text = source.Cell(r, c);
                    TextDraw.Draw(g, text, new Rect(x, lineTop, Math.Max(0, w), lh), _t.FontSize, color, wrap: false, trim: true, plain: _t.PlainText, clip: _t.ClipCells);
                    if (struck && text.Length > 0)
                    {
                        // Закреслення — по ширині тексту (не далі за колонку).
                        var length = Math.Min(UiFont.Width(text, _t.FontSize), w);
                        g.FillRectangle(Palette.Brush(color), new Rect(x, Math.Round(lineTop + lh * 0.55), length, 1));
                    }
                }
            }
        }

        /// Список у комірці (знімок «Нумерації» Mac): рамка від підпису колонки мінус
        /// пів точки, на 6 вужча за колонку, 20 заввишки від верху рядка.
        Rect ChoiceRect(double x, double width, double rowTop) =>
            new(x - 0.5, rowTop + 0.5, Math.Max(0, width - 6), Math.Min(20, _t.RowHeight - 1));

        void DrawChoice(DrawingContext g, Rect r, string title)
        {
            var dark = Palette.IsDark;
            g.DrawRectangle(Palette.Brush(Color.FromArgb(dark ? (byte)70 : (byte)38, 0, 0, 0)), null, r.Translate(new Vector(0, 0.5)), 5, 5);
            g.DrawRectangle(Palette.Brush(dark ? Color.FromRgb(0x67, 0x67, 0x66) : Colors.White),
                            new Pen(Palette.Brush(dark ? Color.FromArgb(25, 255, 255, 255) : Color.FromArgb(30, 0, 0, 0)), 0.5), r.Deflate(0.25), 5, 5);
            var lh = UiFont.LineHeight(_t.FontSize);
            TextDraw.Draw(g, title, new Rect(r.X + 9, r.Y + Math.Round((r.Height - lh) / 2), Math.Max(0, r.Width - 30), lh), _t.FontSize, Palette.Label, wrap: false, trim: true);
            PopupButton.DrawArrows(g, r.Right - 10.5, r.Center.Y, Palette.Label);
        }

        protected override void OnPointerPressed(PointerPressedEventArgs e)
        {
            var point = e.GetCurrentPoint(this);
            var row = (int)(point.Position.Y / _t.RowHeight);
            var count = _t.Source?.RowCount ?? 0;
            _t.Focus();
            if (row < 0 || row >= count) return;
            _t.Selected = row;
            InvalidateVisual();
            _t.OnSelect?.Invoke(row);
            if (point.Properties.IsRightButtonPressed)
            {
                if (_t.OnContextMenu?.Invoke(row) is { } menu) { menu.PlacementTarget = this; menu.Open(this); }
                e.Handled = true;
                return;
            }
            if (e.ClickCount == 2) { _t.OnActivate?.Invoke(row); e.Handled = true; return; }
            // Клацання по списку в комірці — меню з його пунктами.
            var columns = _t.Layout(Bounds.Width);
            for (var c = 0; c < columns.Count; c++)
            {
                var (x, w) = columns[c];
                if (point.Position.X < x - 0.5 || point.Position.X >= x - 0.5 + Math.Max(0, w - 6)) continue;
                if (_t.Source?.Choice(row, c) is not { } choice) break;
                var column = c;
                var entries = choice.Items.Select((title, i) => new MenuEntry(title, () => _t.OnChoice?.Invoke(row, column, i), i == choice.Selected)).ToList();
                var menu = MenuStrip.Build(entries);
                menu.PlacementTarget = this;
                menu.Placement = PlacementMode.Pointer;
                menu.Open(this);
                break;
            }
            e.Handled = true;
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        var count = Source?.RowCount ?? 0;
        if (count > 0)
        {
            int? next = e.Key switch
            {
                Key.Down => Math.Min(count - 1, (Selected ?? -1) + 1),
                Key.Up => Math.Max(0, (Selected ?? count) - 1),
                Key.Home => 0,
                Key.End => count - 1,
                _ => null,
            };
            if (next is { } row) { Select(row); OnSelect?.Invoke(row); e.Handled = true; return; }
            if (e.Key == Key.Enter && Selected is { } s) { OnActivate?.Invoke(s); e.Handled = true; return; }
        }
        base.OnKeyDown(e);
    }
}
