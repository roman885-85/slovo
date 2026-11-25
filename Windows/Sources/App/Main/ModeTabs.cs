// =============================================================================
//  ModeTabs.cs — вкладки режиму й повзунок кегля списків (верх вікна)
// =============================================================================
//  Як на Mac (NativeModeTabs): сім вкладок зліва — значок і підпис 12 пт;
//  вибрана — «пігулка» кольору акценту (85 %) з білим напівжирним текстом.
//  Справа: мала «A», повзунок 120 (кегль списків 9…22), велика «A», тека даних.
//  Натискання вкладки перефарбовує ДВІ вкладки — більше у вікні не міняється
//  нічого: робочу область переставляє її власний господар за приводом `Mode`.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public sealed class ModeTabs : LayoutPanel
{
    public const double FontMin = 9, FontMax = 22;

    readonly AppState _state;
    readonly Dictionary<WorkMode, TabButton> _tabs = new();
    readonly Glyph _smaller = new(11), _larger = new(16);
    readonly MacSlider _slider = new() { Minimum = FontMin, Maximum = FontMax, KnobSize = 20, Step = 1 };
    public readonly IconButton FolderButton = new("folder", 16);
    public readonly PushButton UpdateButton = new("", "arrow.down.circle.fill", ControlSize.Small) { Prominent = true, IsVisible = false };

    public Action? OpenDataFolder;
    public Action? UpdateTapped;

    public ModeTabs(AppState state)
    {
        _state = state;
        foreach (var mode in WorkModeInfo.All)
        {
            var tab = new TabButton(mode.Icon());
            tab.Pressed = () => Select(mode);
            _tabs[mode] = tab;
            Children.Add(tab);
        }
        Children.Add(_smaller);
        Children.Add(_slider);
        Children.Add(_larger);
        Children.Add(FolderButton);
        Children.Add(UpdateButton);
        FolderButton.Pressed = () => OpenDataFolder?.Invoke();
        ToolTip.SetTip(FolderButton, Captions.T("Папка с данными: переводы, песенники, фоны, шаблоны, планы и настройки"));
        UpdateButton.Pressed = () => UpdateTapped?.Invoke();
        UpdateButton.FontSize = 11;

        _slider.Value = state.ListFontSize;
        _slider.ValueChanged += size =>
        {
            if (Math.Abs(_state.ListFontSize - size) < 0.001) return;
            _state.ListFontSize = size;
            Signals.Shared.Send(Signals.Kind.ListFontSize);
        };
        ApplyTitles();
        state.ModeValue.Sink(ApplyMode);
        // Кегль списків міняють і колесом з Ctrl, і з «Параметрів»: повзунок
        // має стояти там, де величина насправді.
        state.ListFontSizeValue.Sink(size => _slider.Value = Math.Clamp(size, FontMin, FontMax));
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyTitles);
        Palette.Changed += () => { foreach (var t in _tabs.Values) t.InvalidateVisual(); };
    }

    public void ApplyTitles()
    {
        foreach (var mode in WorkModeInfo.All) _tabs[mode].Title = mode.TabTitle();
        ToolTip.SetTip(_slider, Captions.T("Размер шрифта списков (или Ctrl и колесо мыши)"));
        InvalidateArrange();
    }

    /// Показати пропозицію оновлення («Оновлення 1.4.1») або сховати.
    public void ShowUpdate(string? version)
    {
        UpdateButton.IsVisible = version != null;
        UpdateButton.Title = version != null ? Captions.T("Обновление %s", version) : "";
        ToolTip.SetTip(UpdateButton, Captions.T("Вышла новая версия «Слова» — нажмите, чтобы обновить"));
        InvalidateArrange();
    }

    void ApplyMode(WorkMode mode)
    {
        foreach (var (each, tab) in _tabs) tab.IsChosen = each == mode;
    }

    public void Select(WorkMode mode)
    {
        if (_state.Mode == mode) return;
        _state.Mode = mode;
        Signals.Shared.Send(Signals.Kind.Mode);
    }

    public WorkMode? ChosenMode => _tabs.FirstOrDefault(t => t.Value.IsChosen).Key;

    protected override Size Desired(Size available) => new(0, RootView.Metrics.ModeTabs);

    protected override void Arrangement(Size size)
    {
        double x = 0;
        foreach (var mode in WorkModeInfo.All)
        {
            var tab = _tabs[mode];
            Place(tab, new Rect(x, 0, tab.FittingWidth, size.Height));
            x += tab.FittingWidth + 4;
        }
        const double iconSide = 16, sliderWidth = 120;
        var middle = Math.Round(size.Height / 2);
        var right = size.Width;
        right -= 24;
        Place(FolderButton, new Rect(right, middle - 11, 22, 22));
        right -= iconSide + 6;
        Place(_larger, new Rect(right, middle - iconSide / 2, iconSide, iconSide));
        right -= sliderWidth + 4;
        Place(_slider, new Rect(right, middle - 10, sliderWidth, 20));
        right -= iconSide + 4;
        Place(_smaller, new Rect(right, middle - iconSide / 2, iconSide, iconSide));
        if (UpdateButton.IsVisible)
        {
            var width = Math.Ceiling(UpdateButton.FittingWidth) + 6;
            right -= width + 12;
            Place(UpdateButton, new Rect(right, middle - 11, width, 22));
        }
    }

    /// Вкладка режиму.
    sealed class TabButton : Control
    {
        const double IconSize = 12, Gap = 4, Padding = 10, Vertical = 3;
        readonly string _symbol;
        string _title = "";
        bool _chosen;
        public Action? Pressed;

        public TabButton(string symbol) { _symbol = symbol; }

        public string Title
        {
            get => _title;
            set { if (_title == value) return; _title = value; InvalidateVisual(); }
        }

        public bool IsChosen
        {
            get => _chosen;
            set { if (_chosen == value) return; _chosen = value; InvalidateVisual(); }
        }

        /// Ширину беремо за напівжирним підписом — інакше вкладки стрибали б.
        public double FittingWidth =>
            Math.Ceiling(Padding * 2 + IconSize + Gap + Math.Max(UiFont.Width(_title, 12), UiFont.Width(_title, 12, FontWeight.SemiBold)));

        public override void Render(DrawingContext g)
        {
            var b = new Rect(Bounds.Size);
            g.FillRectangle(Brushes.Transparent, b);
            var lineHeight = UiFont.LineHeight(12, FontWeight.SemiBold);
            var height = Math.Ceiling(lineHeight + Vertical * 2);
            var top = Math.Round((b.Height - height) / 2);
            if (_chosen) g.DrawRectangle(Palette.Brush(Palette.Selection), null, new Rect(0, top, b.Width, height), 5, 5);
            var color = _chosen ? Colors.White : Palette.Label;
            var x = Padding;
            Icons.Draw(g, _symbol, new Rect(x, Math.Round((b.Height - IconSize) / 2), IconSize, IconSize), color, _chosen ? 1.3 : 1);
            x += IconSize + Gap;
            TextDraw.Draw(g, _title, new Rect(x, Math.Round((b.Height - lineHeight) / 2), b.Width - x, lineHeight), 12, color,
                          _chosen ? FontWeight.SemiBold : FontWeight.Normal, wrap: false, trim: true);
        }

        protected override void OnPointerPressed(PointerPressedEventArgs e)
        {
            if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) { Pressed?.Invoke(); e.Handled = true; }
        }
    }

    /// «A» по боках повзунка (на Mac — значки textformat.size.smaller/larger).
    sealed class Glyph : Control
    {
        readonly double _size;
        public Glyph(double size) { _size = size; }
        public override void Render(DrawingContext g)
        {
            var lh = UiFont.LineHeight(_size);
            TextDraw.Draw(g, "A", new Rect(0, (Bounds.Height - lh) / 2, Bounds.Width, lh), _size,
                          Palette.SecondaryLabel, align: TextAlignment.Center, wrap: false);
        }
    }
}
