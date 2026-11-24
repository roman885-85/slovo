// =============================================================================
//  SearchResults.cs — вікно результатів пошуку (5), як NativeSearchResults на Mac
// =============================================================================
//  Шапка «Знайдено: (7 збігів)», смуга побудови пошукового ходу й хрестик;
//  нижче — список «Ін. 5:24 - Істинно, істинно кажу вам…», де знайдені слова
//  червоні. Рядок, на якому стоїть курсор (та сама книга, розділ і вірш),
//  підсвічено, і він увесь білий. Клацання готує вірш у передпоказі, подвійне —
//  виводить у зал. Видно вікно лише на вкладках зі смугою перекладів і лише
//  коли AppState.IsSearchResultsShown.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.TextFormatting;
using Avalonia.Utilities;
using Slovo.Core;

namespace Slovo.App;

/// Рядок із позначеними шматками (знайдене — червоним).
public readonly record struct MarkedLine(string Text, IReadOnlyList<(int Start, int Length)> Marks);

/// Віртуальний список різнокольорових рядків: малюються лише видимі, рядок
/// будується тієї миті, коли показався (як NativeAttributedList).
public sealed class MarkedList : Grid
{
    public Func<int> RowCount = () => 0;
    public Func<int, MarkedLine> Line = _ => new MarkedLine("", Array.Empty<(int, int)>());
    public Func<int, bool> IsSelected = _ => false;
    public Action<int>? OnSelect, OnActivate;
    public Func<int, ContextMenu?>? OnContextMenu;
    public double FontSize = 13;

    double _rowHeight = 20;
    public double RowHeight { get => _rowHeight; set { _rowHeight = value; Reload(); } }

    readonly ScrollViewer _scroll = new()
    {
        HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
        VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
    };
    readonly Canvas _canvas;

    public MarkedList()
    {
        ClipToBounds = true;
        _canvas = new Canvas(this);
        _scroll.Content = _canvas;
        _scroll.ClipToBounds = true;
        _scroll.ScrollChanged += (_, _) => _canvas.InvalidateVisual();
        Children.Add(_scroll);
        Palette.Changed += () => _canvas.InvalidateVisual();
    }

    /// Поля NSTableView стилю .inset, як у решти списків (RowList.DefaultInset).
    static readonly Thickness Inset = RowList.DefaultInset;
    double TotalHeight => RowCount() == 0 ? 0 : RowCount() * _rowHeight + Inset.Top + Inset.Bottom;

    public void Reload()
    {
        _canvas.InvalidateMeasure();
        _canvas.InvalidateVisual();
    }

    /// Перемалювати видимі рядки: змінився вибір, а не склад.
    public void RefreshVisible() => _canvas.InvalidateVisual();

    sealed class Canvas : Control
    {
        readonly MarkedList _list;
        public Canvas(MarkedList list) { _list = list; ClipToBounds = true; }

        protected override Size MeasureOverride(Size available) =>
            new(double.IsInfinity(available.Width) ? Math.Max(1, _list.Bounds.Width) : available.Width, _list.TotalHeight);

        protected override Size ArrangeOverride(Size finalSize) =>
            new(finalSize.Width, Math.Max(finalSize.Height, _list.TotalHeight));

        public override void Render(DrawingContext g)
        {
            var width = Bounds.Width;
            g.DrawRectangle(Palette.Brush(Palette.TextBackground), null, new Rect(Bounds.Size));
            var rh = _list._rowHeight;
            var count = _list.RowCount();
            if (count == 0 || rh <= 0) return;
            var top = _list._scroll.Offset.Y - Inset.Top;
            var viewport = _list._scroll.Viewport.Height;
            var first = Math.Max(0, (int)Math.Floor(top / rh));
            var end = Math.Min(count, (int)Math.Ceiling((top + Math.Max(viewport, rh)) / rh) + 1);
            var inner = Math.Max(1, width - Inset.Left - Inset.Right);
            for (var row = first; row < end; row++)
            {
                var rect = new Rect(Inset.Left, Inset.Top + row * rh, inner, rh);
                var selected = _list.IsSelected(row);
                if (selected) g.DrawRectangle(Palette.Brush(Palette.Accent.WithAlpha(0.85)), null, rect);
                DrawLine(g, _list.Line(row), rect, _list.FontSize, selected);
            }
        }

        static void DrawLine(DrawingContext g, MarkedLine line, Rect rect, double size, bool selected)
        {
            if (line.Text.Length == 0) return;
            var face = UiFont.Face(FontWeight.Normal);
            // Вибраний рядок цілком білий: червоне на підсвічуванні не читається.
            var plain = Palette.Brush(selected ? Colors.White : Palette.Label);
            List<ValueSpan<TextRunProperties>>? overrides = null;
            if (!selected && line.Marks.Count > 0)
            {
                var red = Palette.Brush(Palette.SystemRed);
                overrides = line.Marks
                    .Where(m => m.Length > 0 && m.Start >= 0 && m.Start + m.Length <= line.Text.Length)
                    .Select(m => new ValueSpan<TextRunProperties>(m.Start, m.Length,
                        new GenericTextRunProperties(face, fontRenderingEmSize: size, foregroundBrush: red)))
                    .ToList();
            }
            var width = Math.Max(0, rect.Width - 16);
            using var layout = new TextLayout(line.Text, face, size, plain, TextAlignment.Left, TextWrapping.NoWrap,
                TextTrimming.CharacterEllipsis, null, FlowDirection.LeftToRight, width, double.PositiveInfinity,
                double.NaN, 0, 1, overrides);
            var y = rect.Y + (rect.Height - layout.Height) / 2;
            using (g.PushClip(rect))
                layout.Draw(g, new Point(rect.X + 8, y));
        }

        protected override void OnPointerPressed(PointerPressedEventArgs e)
        {
            base.OnPointerPressed(e);
            var point = e.GetCurrentPoint(this);
            var y = point.Position.Y - Inset.Top;
            var x = point.Position.X;
            if (y < 0 || x < Inset.Left || x >= Bounds.Width - Inset.Right) return;
            var row = (int)Math.Floor(y / _list._rowHeight);
            if (row < 0 || row >= _list.RowCount()) return;
            if (point.Properties.IsRightButtonPressed)
            {
                if (_list.OnContextMenu?.Invoke(row) is { } menu) menu.Open(this);
                e.Handled = true;
                return;
            }
            if (!point.Properties.IsLeftButtonPressed) return;
            if (e.ClickCount >= 2) _list.OnActivate?.Invoke(row); else _list.OnSelect?.Invoke(row);
            e.Handled = true;
        }
    }
}

/// Вікно результатів пошуку (5) — розділ 5.1.5 посібника.
public sealed class SearchResultsPane : LayoutPanel
{
    const double HeaderHeight = 22;
    readonly AppState _state;
    readonly InlineCaption _caption = new(), _count = new(), _progressCaption = new();
    readonly ProgressStrip _progress = new();
    readonly IconButton _close = new("xmark", 11);
    readonly MarkedList _list = new();
    readonly Backdrop _backdrop = new();
    /// Рядки, приготовані до показу; перезбираються лише з новим набором знайденого.
    List<MarkedLine> _lines = new();

    public SearchResultsPane(AppState state)
    {
        _state = state;
        _count.Weight = FontWeight.SemiBold;
        _count.Color = () => Palette.Label;
        _close.Tint = () => Palette.Label;
        _close.Pressed = () => _state.HideSearchResults();
        foreach (Control c in new Control[] { _backdrop, _caption, _count, _progress, _progressCaption, _close, _list })
            Children.Add(c);

        _list.RowCount = () => _lines.Count;
        _list.Line = i => i >= 0 && i < _lines.Count ? _lines[i] : default;
        _list.IsSelected = i => ShowsSongs
            ? i >= 0 && i < _state.SongHits.Count && (_state.IsCurrentSongHit?.Invoke(_state.SongHits[i]) ?? false)
            : i >= 0 && i < _state.Hits.Count && _state.IsCurrentHit(_state.Hits[i]);
        _list.OnSelect = i => Show(i, false);
        _list.OnActivate = i => Show(i, true);
        _list.OnContextMenu = Menu;

        ApplyCaptions();
        Rebuild();

        Signals.Shared.Subscribe(Signals.Kind.SearchResults, Rebuild);
        Signals.Shared.Subscribe(new[] { Signals.Kind.VerseSelection, Signals.Kind.Verses, Signals.Kind.BookSelection, Signals.Kind.SongSelection, Signals.Kind.SongPart },
                                 _ => _list.RefreshVisible());
        // Змінили вкладку — набране слово шукається заново, уже за нею.
        Signals.Shared.Subscribe(Signals.Kind.Mode, () => { _state.RerunSearch(); Rebuild(); });
        Signals.Shared.Subscribe(new[] { Signals.Kind.Language, Signals.Kind.ListFontSize },
                                 _ => { ApplyCaptions(); Rebuild(); });
    }

    void ApplyCaptions()
    {
        _caption.Text = Captions.Caption("Label2", "Найдено:");
        _progressCaption.Text = Captions.Caption("Label3D12", "Идет построение поискового  индекса...");
        ToolTip.SetTip(_close, Captions.MainHint("SBHideSearchResult", "Скрыть окно результатов поиска"));
        _list.FontSize = Math.Max(7, _state.ListFontSize);
        _list.RowHeight = Math.Ceiling(_state.ListFontSize) + 7;
    }

    /// На вкладці «Пісні» вікно показує знахідки по Пісеннику.
    bool ShowsSongs => _state.Mode == WorkMode.Songs;

    /// «(7 збігів)» — з дужками, як на знімку посібника.
    string CountText()
    {
        var count = _state.HitCount;
        if (count == 0)
            return _state.IsSearching ? "…" : Captions.Caption("TextMessages9", "Ничего не найдено");
        var word = Captions.Caption("TextMessages8", "совпадений");
        var number = _state.IsSearchTruncated ? $"{count}+" : $"{count}";
        return $"({number} {word})";
    }

    /// Скільки рядків стоїть у списку — для перевірок.
    public int LineCount => _lines.Count;

    void Rebuild()
    {
        static MarkedLine Line(string head, IEnumerable<TextSearch.Hit.Segment> segments)
        {
            var text = new System.Text.StringBuilder(head).Append(" - ");
            var marks = new List<(int, int)>();
            foreach (var segment in segments)
            {
                if (segment.IsMatch) marks.Add((text.Length, segment.Text.Length));
                text.Append(segment.Text);
            }
            return new MarkedLine(text.ToString(), marks);
        }
        _lines = ShowsSongs
            ? _state.SongHits.Select(h => Line(h.Title, h.Segments)).ToList()
            : _state.Hits.Select(h => Line(h.Reference, h.Segments)).ToList();
        _count.Text = CountText();
        if (_state.IndexProgress is { } value) { _progress.IsVisible = true; _progress.Value = value; }
        else _progress.IsVisible = false;
        InvalidateArrange();
        _list.Reload();
    }

    void Show(int index, bool live)
    {
        if (ShowsSongs)
        {
            if (index < 0 || index >= _state.SongHits.Count) return;
            var found = _state.SongHits[index];
            _state.RevealSong?.Invoke(found.SongIndex, found.PartIndex, live);
            _list.RefreshVisible();
            return;
        }
        if (index < 0 || index >= _state.Hits.Count) return;
        _state.ShowHit(_state.Hits[index], live);
        _list.RefreshVisible();
    }

    ContextMenu? Menu(int index)
    {
        if (ShowsSongs)
        {
            if (index < 0 || index >= _state.SongHits.Count) return null;
            var found = _state.SongHits[index];
            if (_state.OpenSongs?.Invoke() is not { } songs || found.SongIndex < 0 || found.SongIndex >= songs.Count) return null;
            var song = songs[found.SongIndex];
            var plan = new MenuItem { Header = Captions.Caption("MIAddToPlan", "Добавить в План") };
            plan.Click += (_, _) =>
            {
                SongPart? part = found.PartIndex is { } p && p >= 0 && p < song.Parts.Count ? song.Parts[p] : null;
                _state.AddSongToPlan?.Invoke(song, part);
            };
            var copySong = new MenuItem { Header = Captions.Caption("MICopyToClipboard", "Скопировать в буфер обмена (Ctrl + C)") };
            copySong.Click += async (_, _) =>
            {
                if (TopLevel.GetTopLevel(this)?.Clipboard is { } board) await board.SetTextAsync($"{found.Title}\n{found.Text}");
            };
            return new ContextMenu { ItemsSource = new object[] { plan, copySong } };
        }
        if (index < 0 || index >= _state.Hits.Count) return null;
        var hit = _state.Hits[index];
        var toPlan = new MenuItem { Header = Captions.Caption("MIAddToPlan", "Добавить в План") };
        toPlan.Click += (_, _) => { _state.ShowHit(hit, false); _state.AddCurrentToPlan(); };
        var copy = new MenuItem { Header = Captions.Caption("MICopyToClipboard", "Скопировать в буфер обмена (Ctrl + C)") };
        copy.Click += async (_, _) =>
        {
            if (TopLevel.GetTopLevel(this)?.Clipboard is { } board)
                await board.SetTextAsync($"{hit.Reference} {hit.Text}");
        };
        return new ContextMenu { ItemsSource = new object[] { toPlan, copy } };
    }

    protected override void Arrangement(Size size)
    {
        var w = size.Width;
        Place(_backdrop, new Rect(size));
        double x = 8;
        var captionWidth = _caption.FittingWidth;
        Place(_caption, new Rect(x, 0, captionWidth, HeaderHeight));
        x += captionWidth + 6;
        var countWidth = _count.FittingWidth;
        Place(_count, new Rect(x, 0, countWidth, HeaderHeight));
        x += countWidth + 6;
        Place(_progress, new Rect(x, 7, 110, 8));
        if (_progress.IsVisible)
        {
            x += 116;
            Place(_progressCaption, new Rect(x, 0, _progressCaption.FittingWidth, HeaderHeight));
        }
        else Place(_progressCaption, default);
        Place(_close, new Rect(w - 26, 3, 20, 16));
        Place(_list, new Rect(0, HeaderHeight + 1, w, Math.Max(0, size.Height - HeaderHeight - 1)));
    }

    /// Тло шапки й риска під нею.
    sealed class Backdrop : Control
    {
        public Backdrop() { Palette.Changed += InvalidateVisual; }
        public override void Render(DrawingContext g)
        {
            g.DrawRectangle(Palette.Brush(Palette.TextBackground), null, new Rect(Bounds.Size));
            g.DrawRectangle(Palette.Brush(Palette.ControlBackground), null, new Rect(0, 0, Bounds.Width, HeaderHeight));
            g.DrawRectangle(Palette.Brush(Palette.Separator), null, new Rect(0, HeaderHeight, Bounds.Width, 1));
        }
    }

    /// Смуга «будується пошуковий хід» (NSProgressIndicator .bar).
    sealed class ProgressStrip : Control
    {
        double _value;
        public double Value { get => _value; set { _value = Math.Clamp(value, 0, 1); InvalidateVisual(); } }
        public ProgressStrip() { Palette.Changed += InvalidateVisual; }
        public override void Render(DrawingContext g)
        {
            var b = new Rect(Bounds.Size);
            g.DrawRectangle(Palette.Brush(Palette.QuaternaryLabel), null, b, 4, 4);
            g.DrawRectangle(Palette.Brush(Palette.Accent), null, new Rect(0, 0, b.Width * _value, b.Height), 4, 4);
        }
    }
}
