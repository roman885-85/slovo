// =============================================================================
//  RowList.cs — швидкий список головного вікна
// =============================================================================
//  Як на Mac (NativeList), але своїм кодом Avalonia: малюються лише рядки, що
//  видно (зазвичай два десятки), дані — у джерела за номером рядка, нічого не
//  копіюється. Натискання міняє один рядок — перемальовується саме він.
//  Той самий список уміє сітку плиток (вибір Книги «значками»).
//  Виділення список веде сам: відрізок — із Shift, урозбивку — з Ctrl.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Threading;

namespace Slovo.App;

public enum SelectCause { Click, DoubleClick, Keyboard, Code, Drag }
public enum ScrollPlace { Nearest, Center, Top }

public sealed class RowList : Grid
{
    // --- Налаштування -------------------------------------------------------------

    IRowSource? _source;
    /// Звідки брати рядки.
    public IRowSource? Source { get => _source; set { _source = value; Reload(); } }

    double _fontSize = 13;
    /// Кегль списку (повзунок угорі вікна, колесо з Ctrl).
    public double FontSize
    {
        get => _fontSize;
        set { if (Math.Abs(value - _fontSize) < 0.01) return; _fontSize = value; RebuildStyle(); }
    }

    ListMetrics _metrics;
    public ListMetrics Metrics { get => _metrics; set { _metrics = value; RebuildStyle(); } }

    bool _tiles;
    double _tileMinWidth, _tileHeight, _tileGap;
    /// Сітка плиток: плитка не вужча за `minItemWidth`, заввишки `itemHeight`.
    public void SetTiles(double minItemWidth, double itemHeight, double gap)
    {
        _tiles = true; _tileMinWidth = minItemWidth; _tileHeight = itemHeight; _tileGap = gap;
        RebuildStyle();
    }
    public void SetList() { _tiles = false; RebuildStyle(); }
    public bool IsTiles => _tiles;

    bool _measured;
    double _baseHeight = 22;
    /// Усі рядки однієї висоти — найшвидше (розділи, пісні, книги).
    public void SetUniformHeight(double height) { _measured = false; _baseHeight = height; ApplyHeights(); }
    /// Висота рядка — за текстом (вірші, частини пісні).
    public void SetMeasuredHeights(double estimate) { _measured = true; _baseHeight = estimate; ApplyHeights(); }
    public bool IsMeasured => _measured;

    public bool AllowsMultipleSelection { get; set; }
    /// Віддавати списку стрілки: за умовчанням ні — стрілки в програмі гортають вірш і розділ.
    public bool HandlesArrowKeys { get; set; }
    /// Enter відкриває виділене, як подвійне клацання (План).
    public bool ActivatesOnReturn { get; set; }

    IReadOnlyList<string>? _headerTitles;
    /// Заголовки колонок — для вигляду «Таблиця» вікна вибору Книги.
    public IReadOnlyList<string>? HeaderTitles
    {
        get => _headerTitles;
        set { _headerTitles = value; _header.IsVisible = value is { Count: > 0 }; _header.InvalidateVisual(); }
    }

    // --- Зворотні виклики ---------------------------------------------------------

    /// Виділення змінилося; `active` — рядок, по якому клацнули.
    public Action<IReadOnlyCollection<int>, int, SelectCause>? OnSelect;
    /// Подвійне клацання — у автора це «в зал».
    public Action<int>? OnActivate;
    /// Меню правої кнопки, якщо джерело його не дає.
    public Func<int, ContextMenu?>? OnContextMenu;
    /// Клацання по вузькій колонці зліва — по позначці (модулі: увімкнути/вимкнути).
    public Action<int>? OnLeadClick;
    /// Просте клацання без протяжки (відпущено на тому самому рядку).
    public Action<int>? OnClick;
    /// Ctrl з колесом — змінити кегль списків (на все вікно).
    public Action<double>? OnZoom;
    /// Перестановка протяжкою (як NativeListReorder): звідки й куди (місце «перед рядком»,
    /// count — у кінець). Поки задано, протяжка не виділяє діапазон, а переносить рядок.
    public Action<int, int>? OnMove;
    int? _reorderFrom, _reorderTo;
    /// Скільки разів мітка місця переходила — перевіркам.
    public int ReorderSteps { get; private set; }

    // --- Внутрішнє ----------------------------------------------------------------

    readonly ScrollViewer _scroll;
    readonly Canvas _canvas;
    readonly Header _header;
    ListStyle _style;
    int _count;
    int _columns = 1;
    Thickness _inset = DefaultInset;
    /// Відступи вмісту, як у NSTableView стилю .inset (так його ставить macOS 11+
    /// за замовчуванням): рядки відходять на 16 точок від боків, перший і
    /// останній — на 10 від країв. Виміряно на знімках Mac 1.3.9 («Клас»,
    /// «Розділ», «Вірш», плитки книг, «Історія»).
    public static readonly Thickness DefaultInset = new(16, 10, 16, 10);
    public Thickness ContentInset
    {
        get => _inset;
        set { _inset = value; _topsDirty = true; _measuredWidth = -1; _canvas.InvalidateMeasure(); _canvas.InvalidateVisual(); }
    }
    double[] _heights = Array.Empty<double>();   // висоти рядків таблиці (не пунктів у плитці)
    double[] _tops = Array.Empty<double>();      // початок кожного рядка; останній — уся висота
    bool _topsDirty = true;
    double _measuredWidth = -1;
    readonly SortedSet<int> _selection = new();
    int? _anchor;
    (int Index, ScrollPlace Place)? _pendingScroll;

    public IReadOnlyCollection<int> Selection => _selection;
    public int? Anchor => _anchor;
    public int ItemCount => _count;

    public RowList(ListMetrics? metrics = null, double fontSize = 13)
    {
        _metrics = metrics ?? new ListMetrics();
        _fontSize = fontSize;
        _style = new ListStyle(fontSize, _metrics);
        Focusable = true;
        ClipToBounds = true;
        RowDefinitions = new RowDefinitions("Auto,*");
        _header = new Header(this) { IsVisible = false, Height = 20 };
        _canvas = new Canvas(this);
        _scroll = new ScrollViewer
        {
            Content = _canvas,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            AllowAutoHide = true,
            ClipToBounds = true,
        };
        _scroll.ScrollChanged += (_, _) => _canvas.InvalidateVisual();
        SetRow(_header, 0);
        SetRow(_scroll, 1);
        Children.Add(_header);
        Children.Add(_scroll);
        AddHandler(PointerWheelChangedEvent, OnWheel, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        Palette.Changed += () => _canvas.InvalidateVisual();
    }

    // --- Оновлення ----------------------------------------------------------------

    /// Перечитати ВЕСЬ список (переклади Біблії мають однакове число книг — короткий
    /// шлях лишав частину списку від попереднього перекладу).
    public void Reload()
    {
        _count = _source?.RowCount ?? 0;
        _selection.RemoveWhere(i => i >= _count);
        if (_anchor is { } a && a >= _count) _anchor = null;
        _measuredWidth = -1;
        ApplyHeights();
    }

    /// Рядки з висотою за текстом, які треба переміряти (лише вони, а не весь список: на 3400
    /// рядках повне переміряння коштувало 150 мс на Mac і 335 мс у Windows — замір «основа», 24.11).
    readonly HashSet<int> _remeasure = new();

    public void ReloadRow(int index)
    {
        if (index < 0 || index >= _count) return;
        if (_measured && !_tiles) { _remeasure.Add(index); _canvas.InvalidateMeasure(); }
        _canvas.InvalidateVisual();
    }

    public void ReloadRows(IEnumerable<int> indexes)
    {
        foreach (var i in indexes) ReloadRow(i);
    }

    void RebuildStyle()
    {
        _style = new ListStyle(_fontSize, _metrics);
        _measuredWidth = -1;
        ApplyHeights();
    }

    /// Найменша висота, за якої в рядок ще влазить рядок тексту.
    public double MinimumRowHeight => Math.Ceiling(_style.TextLineHeight) + 2;
    double Grown(double baseHeight) => Math.Max(baseHeight, MinimumRowHeight);

    void ApplyHeights()
    {
        _topsDirty = true;
        _canvas.InvalidateMeasure();
        _canvas.InvalidateVisual();
        _header.InvalidateVisual();
    }

    int TableRows => _columns > 1 ? (_count + _columns - 1) / _columns : _count;

    /// Перерахувати колонки плитки й висоти рядків під ширину.
    void Prepare(double outer)
    {
        // Рядки малюються й міряються шириною всередині відступів (на Mac —
        // ширина стовпця таблиці, на 32 точки вужча за видиму область).
        var width = Math.Max(1, outer - _inset.Left - _inset.Right);
        var columns = 1;
        if (_tiles && width > 0) columns = Math.Max(1, (int)((width + _tileGap) / (_tileMinWidth + _tileGap)));
        if (columns != _columns) { _columns = columns; _topsDirty = true; }
        var rows = TableRows;
        if (_heights.Length != rows) { _heights = new double[rows]; _topsDirty = true; _measuredWidth = -1; }
        if (_tiles)
        {
            var h = Grown(_tileHeight) + _tileGap;
            for (var i = 0; i < rows; i++) _heights[i] = h;
        }
        else if (!_measured)
        {
            var h = Grown(_baseHeight);
            for (var i = 0; i < rows; i++) _heights[i] = h;
        }
        else if (Math.Abs(width - _measuredWidth) > 0.5)
        {
            // Висоти міряються тією самою шириною, якою потім малюється рядок, —
            // на Mac саме розбіжність цих ширин обрізала останній рядок куплета.
            _measuredWidth = width;
            for (var i = 0; i < rows; i++)
            {
                if (_source == null || i >= _source.RowCount) { _heights[i] = Grown(_baseHeight); continue; }
                var row = _source.RowAt(i);
                _heights[i] = Math.Max(1, new RowLayout(row, width, _style, !row.SingleLine).Height);
            }
            _topsDirty = true;
        }
        else if (_measured && _remeasure.Count > 0)
        {
            foreach (var i in _remeasure)
            {
                if (i < 0 || i >= rows || _source == null || i >= _source.RowCount) continue;
                var row = _source.RowAt(i);
                var height = Math.Max(1, new RowLayout(row, width, _style, !row.SingleLine).Height);
                if (Math.Abs(height - _heights[i]) > 0.01) { _heights[i] = height; _topsDirty = true; }
            }
        }
        _remeasure.Clear();
        if (_topsDirty)
        {
            if (_tops.Length != rows + 1) _tops = new double[rows + 1];
            var y = _inset.Top;
            for (var i = 0; i < rows; i++) { _tops[i] = y; y += _heights[i]; }
            _tops[rows] = y + _inset.Bottom;
            _topsDirty = false;
        }
    }

    double TotalHeight => _tops.Length > 0 ? _tops[^1] : 0;

    int TableRowAt(double y)
    {
        var rows = TableRows;
        if (rows == 0 || _tops.Length < rows + 1) return -1;
        if (y < 0) return 0;
        if (y >= _tops[rows]) return rows - 1;
        int lo = 0, hi = rows - 1;
        while (lo < hi)
        {
            var mid = (lo + hi + 1) / 2;
            if (_tops[mid] <= y) lo = mid; else hi = mid - 1;
        }
        return lo;
    }

    double TileStep(double width) => _columns > 1 ? (width + _tileGap) / _columns : width;
    /// Ширина рядка всередині відступів.
    double InnerWidth(double outer) => Math.Max(1, outer - _inset.Left - _inset.Right);

    // --- Виділення ----------------------------------------------------------------

    public void SetSelection(IEnumerable<int> items, int? active = null, bool notify = false,
                             SelectCause cause = SelectCause.Code)
    {
        _selection.Clear();
        foreach (var i in items) if (i >= 0 && i < _count) _selection.Add(i);
        if (active != null) _anchor = active;
        _canvas.InvalidateVisual();
        if (notify) OnSelect?.Invoke(_selection, active ?? (_selection.Count > 0 ? _selection.Min : -1), cause);
    }

    public void SelectAll()
    {
        if (!AllowsMultipleSelection || _count == 0) return;
        SetSelection(Enumerable.Range(0, _count), notify: true, cause: SelectCause.Keyboard);
    }

    /// Те саме, що клацання людини (для пульта, клавіш і перевірок).
    /// Модифікатори останнього клацання — рішення про вибір приймає стан
    /// (як NSEvent.modifierFlags у NativeVerseColumn).
    public KeyModifiers LastModifiers { get; private set; }

    public void Click(int index, KeyModifiers modifiers = KeyModifiers.None, int clickCount = 1)
    {
        LastModifiers = modifiers;
        if (index < 0 || index >= _count) return;
        if (clickCount >= 2) { OnActivate?.Invoke(index); return; }
        if (AllowsMultipleSelection && modifiers.HasFlag(KeyModifiers.Shift) && _anchor is { } from)
        {
            SetSelection(Range(from, index));
            OnSelect?.Invoke(_selection, index, SelectCause.Click);
            return;
        }
        if (AllowsMultipleSelection && (modifiers.HasFlag(KeyModifiers.Control) || modifiers.HasFlag(KeyModifiers.Meta)))
        {
            var set = new SortedSet<int>(_selection);
            if (!set.Remove(index)) set.Add(index);
            SetSelection(set, active: index);
            OnSelect?.Invoke(_selection, index, SelectCause.Click);
            return;
        }
        SetSelection(new[] { index }, active: index);
        OnSelect?.Invoke(_selection, index, SelectCause.Click);
    }

    static IEnumerable<int> Range(int a, int b) => Enumerable.Range(Math.Min(a, b), Math.Abs(a - b) + 1);

    // --- Прокрутка ----------------------------------------------------------------

    /// Довести рядок до видимого: без плавності — зал не чекає чверть секунди.
    public void ScrollTo(int index, ScrollPlace place = ScrollPlace.Nearest)
    {
        _pendingScroll = null;
        if (index < 0 || index >= _count) return;
        var view = _scroll.Viewport.Height;
        if (_topsDirty || _canvas.IsMeasureValid == false || view <= 1)
        {
            // Список ще не має висоти (вкладку будують раніше, ніж вона отримує
            // місце) — прокрутимо після розкладки.
            _pendingScroll = (index, place);
            return;
        }
        var row = _columns > 1 ? index / _columns : index;
        if (row >= _heights.Length) return;
        var top = _tops[row];
        var height = _heights[row];
        var offset = _scroll.Offset.Y;
        var max = Math.Max(0, TotalHeight - view);
        double y = offset;
        switch (place)
        {
            case ScrollPlace.Nearest:
                if (top < offset) y = top;
                else if (top + height > offset + view) y = top + height - view;
                break;
            case ScrollPlace.Center: y = top + height / 2 - view / 2; break;
            case ScrollPlace.Top: y = top; break;
        }
        y = Math.Clamp(y, 0, max);
        if (Math.Abs(y - offset) > 0.5) _scroll.Offset = new Vector(0, y);
    }

    internal void AfterLayout()
    {
        if (_pendingScroll is { } p && _scroll.Viewport.Height > 1)
        {
            _pendingScroll = null;
            Dispatcher.UIThread.Post(() => ScrollTo(p.Index, p.Place), DispatcherPriority.Render);
        }
    }

    /// Видимі пункти (у плитці — усі клітинки видимих рядів).
    public (int First, int End) VisibleItems
    {
        get
        {
            var rows = TableRows;
            if (rows == 0) return (0, 0);
            var first = TableRowAt(_scroll.Offset.Y);
            var last = TableRowAt(_scroll.Offset.Y + Math.Max(1, _scroll.Viewport.Height) - 0.5);
            return (first * _columns, Math.Min(_count, (last + 1) * _columns));
        }
    }

    public double ScrollOffset => _scroll.Offset.Y;

    /// Рамка пункту в координатах списку (для підказок і перевірок).
    public Rect? FrameOfItem(int index)
    {
        if (index < 0 || index >= _count || _topsDirty) return null;
        var row = _columns > 1 ? index / _columns : index;
        var width = InnerWidth(_canvas.Bounds.Width);
        var rect = new Rect(_inset.Left, _tops[row] - _scroll.Offset.Y + _scroll.Bounds.Top, width, _heights[row]);
        if (_columns > 1)
        {
            var step = TileStep(width);
            var column = index - row * _columns;
            rect = new Rect(_inset.Left + column * step, rect.Top, Math.Max(1, step - _tileGap), rect.Height);
        }
        return rect;
    }

    int? ItemAtCanvas(Point p)
    {
        var row = TableRowAt(p.Y);
        if (row < 0 || p.Y > TotalHeight) return null;
        // Поля довкола рядків — не рядок (NSTableView.row(at:) дає там −1).
        if (p.Y < _tops[0] || p.Y >= _tops[row] + _heights[row]) return null;
        if (p.X < _inset.Left || p.X >= _canvas.Bounds.Width - _inset.Right) return null;
        if (_columns <= 1) return row < _count ? row : null;
        var step = TileStep(InnerWidth(_canvas.Bounds.Width));
        var column = Math.Min(_columns - 1, Math.Max(0, (int)((p.X - _inset.Left) / Math.Max(1, step))));
        var index = row * _columns + column;
        return index < _count ? index : null;
    }

    // --- Миша й клавіші -----------------------------------------------------------

    int? _pressedItem, _dragOrigin, _dragLast;
    Point _pressedAt;
    bool _pressedMoved;

    void OnWheel(object? sender, PointerWheelEventArgs e)
    {
        if (e.KeyModifiers.HasFlag(KeyModifiers.Control) && OnZoom != null)
        {
            OnZoom(e.Delta.Y);
            e.Handled = true;
        }
    }

    // --- Палець (сенсорний екран) -----------------------------------------------------
    // Власник (Windows 1.4.2): «добавить поддержку для устройств с сенсорным экраном». Палець — не
    // миша: провести — прокрутити (це робить сам ScrollViewer, з інерцією), тож рядок вибирається не
    // на дотик, а коли палець піднято на тому самому місці; двічі — як подвійне клацання; затримати —
    // меню рядка (як права кнопка). Прокрутка забирає палець собі — тоді це не дотик.
    int? _touchItem;
    Point _touchAt;
    bool _touchCancelled;
    long _touchDownAt, _lastTapAt;
    int? _lastTapItem;

    /// Час подвійного дотику — системний (як подвійне клацання у Windows), а не вгаданий.
    double DoubleTapMilliseconds =>
        TopLevel.GetTopLevel(this)?.PlatformSettings?.GetDoubleTapTime(PointerType.Touch).TotalMilliseconds is > 0 and var ms ? ms : 500;

    void TouchPressed(PointerPressedEventArgs e)
    {
        Focus();
        _touchAt = e.GetPosition(_canvas);
        _touchItem = ItemAtCanvas(_touchAt);
        _touchCancelled = false;
        _touchDownAt = Environment.TickCount64;
        // Не Handled: жест прокрутки ScrollViewer мусить побачити цей дотик.
    }

    void TouchMoved(PointerEventArgs e)
    {
        var p = e.GetPosition(_canvas);
        if (!_touchCancelled && Math.Abs(p.X - _touchAt.X) + Math.Abs(p.Y - _touchAt.Y) > 10) _touchCancelled = true;
    }

    void TouchReleased(PointerReleasedEventArgs e)
    {
        var item = _touchItem;
        _touchItem = null;
        if (_touchCancelled || item is not { } index || ItemAtCanvas(e.GetPosition(_canvas)) != index) return;
        // Від дотику до дотику (як подвійне клацання Windows), у межах системного часу.
        var count = _lastTapItem == index && _touchDownAt - _lastTapAt <= DoubleTapMilliseconds ? 2 : 1;
        _lastTapItem = count == 1 ? index : null;
        _lastTapAt = _touchDownAt;
        if (count == 1 && OnLeadClick != null && _columns == 1 && _metrics.LeadWidth > 0
            && _touchAt.X <= _inset.Left + _metrics.LeadWidth + _metrics.Padding.Left + 6)
        {
            OnLeadClick(index);
            return;
        }
        Click(index, KeyModifiers.None, count);
        if (count == 1) OnClick?.Invoke(index);
        e.Handled = true;
    }

    /// Затримати палець — меню рядка (як права кнопка миші).
    internal void TouchHeld(HoldingRoutedEventArgs e)
    {
        if (e.HoldingState != HoldingState.Started || _touchCancelled || _touchItem is not { } r) return;
        _touchCancelled = true;
        if (!_selection.Contains(r)) SetSelection(new[] { r }, active: r, notify: true, cause: SelectCause.Click);
        var menu = _source?.MenuAt(r) ?? OnContextMenu?.Invoke(r);
        if (menu != null) { menu.PlacementTarget = this; menu.Open(this); }
        e.Handled = true;
    }

    /// Жест прокрутки забрав палець — це вже не дотик до рядка.
    internal void TouchLost() => _touchCancelled = true;

    internal void Pressed(PointerPressedEventArgs e)
    {
        if (e.Pointer.Type == PointerType.Touch) { TouchPressed(e); return; }
        Focus();
        _dragOrigin = null; _dragLast = null; _pressedItem = null; _pressedMoved = false;
        _reorderFrom = null; _reorderTo = null;
        var point = e.GetCurrentPoint(_canvas);
        var hit = ItemAtCanvas(point.Position);
        if (point.Properties.IsRightButtonPressed)
        {
            if (hit is not { } r) return;
            if (!_selection.Contains(r)) SetSelection(new[] { r }, active: r, notify: true, cause: SelectCause.Click);
            var menu = _source?.MenuAt(r) ?? OnContextMenu?.Invoke(r);
            if (menu != null) { menu.PlacementTarget = this; menu.Open(this); }
            e.Handled = true;
            return;
        }
        if (hit is not { } index) return;
        var mods = e.KeyModifiers & (KeyModifiers.Shift | KeyModifiers.Control | KeyModifiers.Alt | KeyModifiers.Meta);
        if (mods == KeyModifiers.None && e.ClickCount == 1) { _pressedItem = index; _pressedAt = point.Position; }
        if (OnLeadClick != null && _columns == 1 && _metrics.LeadWidth > 0
            && point.Position.X <= _inset.Left + _metrics.LeadWidth + _metrics.Padding.Left + 6)
        {
            OnLeadClick(index);
            e.Handled = true;
            return;
        }
        Click(index, e.KeyModifiers, e.ClickCount);
        if (OnMove != null && e.ClickCount == 1 && mods == KeyModifiers.None && _columns <= 1) { _reorderFrom = index; _reorderTo = null; ReorderSteps = 0; }
        else if (AllowsMultipleSelection && e.ClickCount == 1 && mods == KeyModifiers.None) _dragOrigin = index;
        e.Handled = true;
    }

    internal void Moved(PointerEventArgs e)
    {
        if (e.Pointer.Type == PointerType.Touch) { TouchMoved(e); return; }
        var p = e.GetPosition(_canvas);
        UpdateTip(p);
        if (!e.GetCurrentPoint(_canvas).Properties.IsLeftButtonPressed) return;
        if (_pressedItem != null && !_pressedMoved && Math.Abs(p.X - _pressedAt.X) + Math.Abs(p.Y - _pressedAt.Y) > 4)
            _pressedMoved = true;
        if (_reorderFrom != null)
        {
            if (!_pressedMoved) return;
            AutoScroll(e);
            TrackReorder(p);
            return;
        }
        if (_dragOrigin is not { } origin) return;
        // Протяжка за край — список їде сам.
        var local = e.GetPosition(_scroll);
        if (local.Y < 0) _scroll.Offset = new Vector(0, Math.Max(0, _scroll.Offset.Y - 12));
        else if (local.Y > _scroll.Viewport.Height) _scroll.Offset = new Vector(0, _scroll.Offset.Y + 12);
        if (ItemAtCanvas(p) is not { } index || index == _dragLast) return;
        _dragLast = index;
        SetSelection(Range(origin, index), active: origin);
        OnSelect?.Invoke(_selection, index, SelectCause.Drag);
    }

    void AutoScroll(PointerEventArgs e)
    {
        var local = e.GetPosition(_scroll);
        if (local.Y < 0) _scroll.Offset = new Vector(0, Math.Max(0, _scroll.Offset.Y - 12));
        else if (local.Y > _scroll.Viewport.Height) _scroll.Offset = new Vector(0, _scroll.Offset.Y + 12);
    }

    /// Верхня половина рядка — «перед ним», нижня — «після»; над першим — 0, нижче останнього — у кінець.
    void TrackReorder(Point p)
    {
        if (_count == 0 || _tops.Length < _count + 1) return;
        int place;
        var row = ItemAtCanvas(p);
        if (row is { } r) place = p.Y < _tops[r] + _heights[r] / 2 ? r : r + 1;
        else place = p.Y <= _tops[0] ? 0 : _count;
        if (place == _reorderTo) return;
        _reorderTo = place;
        ReorderSteps++;
        _canvas.InvalidateVisual();
    }

    /// Ставити туди ж, звідки взяли, — не перестановка.
    void DropReorder()
    {
        var from = _reorderFrom; var to = _reorderTo;
        _reorderFrom = null; _reorderTo = null;
        _canvas.InvalidateVisual();
        if (from is not { } f || to is not { } t || t == f || t == f + 1) return;
        OnMove?.Invoke(f, t);
    }

    internal void Released(PointerReleasedEventArgs e)
    {
        if (e.Pointer.Type == PointerType.Touch) { TouchReleased(e); return; }
        if (_reorderFrom != null) { var moved = _pressedMoved; DropReorder(); if (moved) { _pressedItem = null; _dragOrigin = null; _dragLast = null; return; } }
        _dragOrigin = null; _dragLast = null;
        var pressed = _pressedItem;
        _pressedItem = null;
        if (pressed is not { } item || _pressedMoved || e.InitialPressMouseButton != MouseButton.Left) return;
        if (ItemAtCanvas(e.GetPosition(_canvas)) == item) OnClick?.Invoke(item);
    }

    string? _tip;
    void UpdateTip(Point p)
    {
        string? tip = null;
        if (ItemAtCanvas(p) is { } i && _source != null && i < _source.RowCount)
        {
            var t = _source.RowAt(i).Tooltip;
            if (t.Length > 0) tip = t;
        }
        if (tip == _tip) return;
        _tip = tip;
        ToolTip.SetTip(_canvas, tip);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (HandleKey(e.Key, e.KeyModifiers)) { e.Handled = true; return; }
        base.OnKeyDown(e);
    }

    /// Клавіші списку — та сама логіка, що на Mac (стрілки, Home/End, сторінки).
    public bool HandleKey(Key key, KeyModifiers modifiers)
    {
        if ((modifiers.HasFlag(KeyModifiers.Control) || modifiers.HasFlag(KeyModifiers.Meta)) && key == Key.A)
        {
            SelectAll();
            return AllowsMultipleSelection;
        }
        if (ActivatesOnReturn && key == Key.Enter && (_anchor ?? (_selection.Count > 0 ? _selection.Min : (int?)null)) is { } row && row < _count)
        {
            OnActivate?.Invoke(row);
            return true;
        }
        if (!HandlesArrowKeys || _count == 0) return false;
        var current = _anchor ?? (_selection.Count > 0 ? _selection.Min : 0);
        var visible = VisibleItems;
        var page = Math.Max(1, visible.End - visible.First - 1);
        int target;
        switch (key)
        {
            case Key.Up: target = current - (_columns > 1 ? _columns : 1); break;
            case Key.Down: target = current + (_columns > 1 ? _columns : 1); break;
            case Key.Home: target = 0; break;
            case Key.End: target = _count - 1; break;
            case Key.PageUp: target = current - page; break;
            case Key.PageDown: target = current + page; break;
            default: return false;
        }
        target = Math.Clamp(target, 0, _count - 1);
        if (AllowsMultipleSelection && modifiers.HasFlag(KeyModifiers.Shift) && _anchor is { } from)
        {
            SetSelection(Range(from, target));
            OnSelect?.Invoke(_selection, target, SelectCause.Keyboard);
        }
        else
        {
            SetSelection(new[] { target }, active: target);
            OnSelect?.Invoke(_selection, target, SelectCause.Keyboard);
        }
        ScrollTo(target);
        return true;
    }

    // --- Малювання ----------------------------------------------------------------

    void DrawRow(DrawingContext g, Row row, bool selected, Rect rect)
    {
        var m = _metrics;
        using var clip = g.PushClip(rect);
        if (selected) g.FillRectangle(Palette.Brush(m.SelectionColor()), rect);
        else if (row.Fill is { } fill) g.FillRectangle(Palette.Brush(fill), rect);

        var layout = new RowLayout(row, rect.Width, _style, !row.SingleLine);
        var singleLine = row.SingleLine;
        Rect leadRect = layout.Lead, textRect = layout.Text, detailRect = layout.Detail;
        // Висоту рядку задано ззовні, а текст просить більше: малюємо один рядок
        // тексту; не влазить і він із відступами — той самий рядок по центру.
        // Інакше великий кегль наповзав на сусідні рядки (зауваження власника).
        if (!_measured && layout.Height > rect.Height + 0.5)
        {
            singleLine = true;
            var one = new RowLayout(row, rect.Width, _style, false);
            leadRect = one.Lead; textRect = one.Text; detailRect = one.Detail;
            if (one.Height > rect.Height + 0.5)
            {
                textRect = textRect.WithY(Math.Max(0, Math.Round((rect.Height - textRect.Height) / 2)));
                leadRect = leadRect.WithY(Math.Max(0, Math.Round((rect.Height - leadRect.Height) / 2)));
                detailRect = m.DetailWidth > 0
                    ? detailRect.WithY(Math.Max(0, Math.Round((rect.Height - detailRect.Height) / 2)))
                    : default;
            }
        }

        if (row.LeadSymbol is { } symbol)
        {
            // Значок першої колонки (NSImageView 16×16 у NativeTable): по центру, кольору номера.
            var area = leadRect.Translate(rect.Position);
            var side = Math.Min(14, Math.Min(area.Width, rect.Height - 4));
            var box = new Rect(Math.Round(area.Center.X - side / 2), Math.Round(rect.Y + (rect.Height - side) / 2), side, side);
            Icons.Draw(g, symbol, box, selected ? m.SelectedTextColor().WithAlpha(0.9) : row.LeadColor ?? m.LeadColor());
        }
        else if (row.Lead is "●" or "○" or "☑" or "☐" or "✓")
        {
            // Галочка в першій колонці (як NativeTable): сіра, коли клацати по ній нічого.
            DrawLeadCheck(g, leadRect.Translate(rect.Position), row.Lead is "●" or "☑" or "✓", OnLeadClick != null);
        }
        else if (row.Lead.Length > 0)
        {
            var color = selected ? m.SelectedTextColor().WithAlpha(0.9) : row.LeadColor ?? m.LeadColor();
            var size = TextDraw.Fitted(row.Lead, _style.LeadSize, leadRect.Width, 0.72, FontWeight.SemiBold);
            TextDraw.Draw(g, row.Lead, leadRect.Translate(rect.Position), size, color, FontWeight.SemiBold,
                          m.LeadAlign, wrap: false, trim: false);
        }

        var textColor = selected ? m.SelectedTextColor() : row.TextColor ?? m.TextColor();
        var fitsOneLine = textRect.Height < _style.TextLineHeight * 1.8;
        var oneLine = singleLine && fitsOneLine;
        // Позначка після тексту лишається видимою: місце під неї відкладаємо, текст ріжеться раніше.
        var badge = row.Badge.Length > 0 && oneLine ? Math.Ceiling(UiFont.Width(" " + row.Badge + " ", 9, FontWeight.SemiBold)) : 0;
        var titleRect = badge > 0 ? textRect.WithWidth(Math.Max(1, textRect.Width - badge - 4)) : textRect;
        var weight = row.Bold ? FontWeight.SemiBold : FontWeight.Normal;
        TextDraw.Draw(g, row.Text, titleRect.Translate(rect.Position), _style.TextSize, textColor,
                      weight, m.Align, wrap: !oneLine, trim: oneLine);
        if (badge > 0)
        {
            var tint = row.BadgeColor ?? Palette.SystemOrange;
            var used = Math.Min(Math.Ceiling(UiFont.Width(row.Text, _style.TextSize, weight)), titleRect.Width);
            var lh = UiFont.LineHeight(9, FontWeight.SemiBold);
            var pill = new Rect(rect.X + titleRect.X + used + 4, rect.Y + titleRect.Y + Math.Round((titleRect.Height - lh) / 2), badge, lh);
            g.FillRectangle(Palette.Brush(tint.WithAlpha(0.16)), pill);
            TextDraw.Draw(g, row.Badge, pill, 9, tint, FontWeight.SemiBold, TextAlignment.Center, wrap: false, trim: false);
        }

        if (row.Detail.Length > 0 && detailRect.Height > 0)
        {
            var color = selected ? m.SelectedTextColor().WithAlpha(0.8) : m.DetailColor();
            var size = TextDraw.Fitted(row.Detail, _style.DetailSize, detailRect.Width);
            TextDraw.Draw(g, row.Detail, detailRect.Translate(rect.Position), size, color,
                          FontWeight.Normal, m.Align, wrap: false, trim: true);
        }

        if (row.Rule is { } rule)
            g.FillRectangle(Palette.Brush(rule), new Rect(rect.X, rect.Bottom - 1, rect.Width, 1));
    }

    /// Клітинка сітки книг: скорочення крупно, під ним повна назва дрібно.
    void DrawTile(DrawingContext g, Row row, bool selected, Rect rect)
    {
        var m = _metrics;
        var fill = selected ? Palette.TileSelection : row.Fill ?? Palette.ControlBackground;
        g.DrawRectangle(Palette.Brush(fill), null, rect.Deflate(0.5), 4, 4);
        var title = row.Lead.Length == 0 ? row.Text : row.Lead;
        var titleColor = selected ? m.SelectedTextColor() : row.TextColor ?? m.TextColor();
        var hasCaption = row.Lead.Length > 0 && row.Text.Length > 0;
        var titleHeight = _style.LeadLineHeight;
        var captionHeight = hasCaption ? _style.DetailLineHeight : 0;
        var block = titleHeight + (hasCaption ? captionHeight + 1 : 0);
        var top = rect.Top + Math.Max(2, (rect.Height - block) / 2);
        var inner = rect.Width - 6;
        TextDraw.Draw(g, title, new Rect(rect.X + 3, top, inner, titleHeight),
                      TextDraw.Fitted(title, _style.LeadSize, inner, 0.72, FontWeight.SemiBold), titleColor,
                      FontWeight.SemiBold, TextAlignment.Center, wrap: false, trim: true);
        if (hasCaption)
        {
            var color = selected ? m.SelectedTextColor().WithAlpha(0.85) : titleColor.WithAlpha(0.75);
            // Підпис під клітинкою може зменшитися сильніше за рядок списку —
            // аби не різатися трьома крапками («Книга Ісуса Навина»).
            TextDraw.Draw(g, row.Text, new Rect(rect.X + 3, top + titleHeight + 1, inner, captionHeight),
                          TextDraw.Fitted(row.Text, _style.DetailSize, inner, 0.55), color,
                          FontWeight.Normal, TextAlignment.Center, wrap: false, trim: true);
        }
    }

    internal void Paint(DrawingContext g, Size size)
    {
        var view = new Rect(0, _scroll.Offset.Y, size.Width, Math.Max(1, _scroll.Viewport.Height));
        g.FillRectangle(Palette.Brush(_metrics.Background()), view);
        if (_source == null || _count == 0) return;
        var rows = TableRows;
        if (_heights.Length != rows || _topsDirty) return;
        var first = TableRowAt(view.Top);
        var last = TableRowAt(view.Bottom);
        if (first < 0) return;
        var width = InnerWidth(size.Width);
        for (var r = first; r <= last && r < rows; r++)
        {
            var rect = new Rect(_inset.Left, _tops[r], width, _heights[r]);
            if (_columns > 1)
            {
                var step = TileStep(width);
                var tileWidth = Math.Max(1, step - _tileGap);
                for (var c = 0; c < _columns; c++)
                {
                    var index = r * _columns + c;
                    if (index >= _count || index >= _source.RowCount) break;
                    DrawTile(g, _source.RowAt(index), _selection.Contains(index),
                             new Rect(_inset.Left + c * step, rect.Top, tileWidth, rect.Height - _tileGap));
                }
            }
            else if (r < _source.RowCount)
            {
                DrawRow(g, _source.RowAt(r), _selection.Contains(r), rect);
            }
        }
    }

    static void DrawLeadCheck(DrawingContext g, Rect area, bool on, bool enabled)
    {
        const double side = 14;
        var box = new Rect(Math.Round(area.Center.X - side / 2) + 0.5, Math.Round(area.Center.Y - side / 2) + 0.5, side - 1, side - 1);
        var dark = Palette.IsDark;
        if (on)
        {
            g.DrawRectangle(Palette.Brush(enabled ? Palette.Accent : Palette.SystemGray.WithAlpha(0.55)), null, box, 3, 3);
            var pen = new Pen(Brushes.White, 1.6, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
            var s = box.Width;
            var path = new StreamGeometry();
            using (var c = path.Open())
            {
                c.BeginFigure(new Point(box.X + s * 0.24, box.Y + s * 0.52), false);
                c.LineTo(new Point(box.X + s * 0.42, box.Y + s * 0.72));
                c.LineTo(new Point(box.X + s * 0.77, box.Y + s * 0.3));
            }
            g.DrawGeometry(null, pen, path);
        }
        else
        {
            g.DrawRectangle(Palette.Brush(dark ? Color.FromArgb(40, 255, 255, 255) : Colors.White),
                            new Pen(Palette.Brush(Color.FromArgb(70, 0, 0, 0)), 0.75), box, 3, 3);
        }
    }

    /// Мітка місця під час перестановки: риска 2 точки кольору акценту.
    internal void PaintReorderMark(DrawingContext g, Size size)
    {
        if (_reorderTo is not { } place || _count == 0 || _tops.Length < _count + 1) return;
        var y = place < _count ? _tops[place] : _tops[_count - 1] + _heights[_count - 1];
        g.DrawRectangle(Palette.Brush(Palette.Accent), null, new Rect(_inset.Left + 2, Math.Max(0, y - 1), Math.Max(0, InnerWidth(size.Width) - 4), 2), 1, 1);
    }

    // --- Полотно рядків -------------------------------------------------------------

    sealed class Canvas : Control
    {
        readonly RowList _list;
        public Canvas(RowList list)
        {
            _list = list;
            ClipToBounds = true;
            // Затримати палець на рядку — його меню (Holding Avalonia: лише дотик і перо).
            Holding += (_, e) => { if (e.PointerType == PointerType.Touch) _list.TouchHeld(e); };
        }

        protected override Size MeasureOverride(Size available)
        {
            var width = double.IsInfinity(available.Width) ? Math.Max(1, _list.Bounds.Width) : available.Width;
            _list.Prepare(width);
            return new Size(width, _list.TotalHeight);
        }

        protected override Size ArrangeOverride(Size finalSize)
        {
            _list.Prepare(finalSize.Width);
            Dispatcher.UIThread.Post(_list.AfterLayout, DispatcherPriority.Loaded);
            return new Size(finalSize.Width, Math.Max(finalSize.Height, _list.TotalHeight));
        }

        public override void Render(DrawingContext context) { _list.Paint(context, Bounds.Size); _list.PaintReorderMark(context, Bounds.Size); }

        protected override void OnPointerPressed(PointerPressedEventArgs e) => _list.Pressed(e);
        protected override void OnPointerMoved(PointerEventArgs e) => _list.Moved(e);
        protected override void OnPointerReleased(PointerReleasedEventArgs e) => _list.Released(e);
        protected override void OnPointerCaptureLost(PointerCaptureLostEventArgs e)
        {
            base.OnPointerCaptureLost(e);
            if (e.Pointer.Type == PointerType.Touch) _list.TouchLost();
        }
    }

    /// Заголовки колонок (вигляд «Таблиця»).
    sealed class Header : Control
    {
        readonly RowList _list;
        public Header(RowList list) { _list = list; }

        public override void Render(DrawingContext g)
        {
            var titles = _list._headerTitles;
            var b = new Rect(Bounds.Size);
            g.FillRectangle(Palette.Brush(Palette.WindowBackground), b);
            g.FillRectangle(Palette.Brush(Palette.Separator), new Rect(0, b.Height - 1, b.Width, 1));
            if (titles == null || titles.Count == 0) return;
            var m = _list._metrics;
            var x = m.Padding.Left;
            var size = 11.0;
            if (titles.Count > 0 && m.LeadWidth > 0)
            {
                TextDraw.Draw(g, titles[0], new Rect(x, 3, m.LeadWidth, 14), size, Palette.SecondaryLabel, wrap: false, trim: true);
                x += m.LeadWidth + 4;
            }
            if (titles.Count > 1)
            {
                var right = m.DetailWidth > 0 ? b.Width - m.Padding.Right - m.DetailWidth - 4 : b.Width - m.Padding.Right;
                TextDraw.Draw(g, titles[1], new Rect(x, 3, Math.Max(1, right - x), 14), size, Palette.SecondaryLabel, wrap: false, trim: true);
            }
            if (titles.Count > 2 && m.DetailWidth > 0)
                TextDraw.Draw(g, titles[2], new Rect(b.Width - m.Padding.Right - m.DetailWidth, 3, m.DetailWidth, 14), size,
                              Palette.SecondaryLabel, wrap: false, trim: true);
        }
    }
}
