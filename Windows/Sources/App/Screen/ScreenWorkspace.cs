// =============================================================================
//  ScreenWorkspace.cs — робоча область «Екран»: монітор чи вікно — в зал
// =============================================================================
//  За NativeScreenWorkspace Mac 1.3.9 (власник: «захват окна… или весь монитор…
//  и выводить его на проектор и ndi, с функцией указки и масштабирования»).
//  Зліва список того, що можна показати, справа — підказка й кнопки. Самої
//  картинки тут навмисно немає: її видно на живому екрані в нижньому ряду, і там
//  же по ній ведуть указкою й вибирають точку фокуса.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Slovo.App;

public sealed class ScreenWorkspace : LayoutPanel, IRowSource
{
    static ScreenWorkspace? _shared;
    public static ScreenWorkspace Shared => _shared ??= new ScreenWorkspace(AppState.Shared);

    const string ListWidthKey = "screenListWidth";
    const double Padding = 12, Gap = 10, ButtonHeight = 26, GripWidth = 7;
    static string T(string text, params object[] args) => Captions.T(text, args);

    readonly AppState _state;
    readonly BottomCaption _title = new() { FontSize = 13, Weight = FontWeight.SemiBold, Inset = 2, Color = () => Palette.Label };
    // У коді Mac — secondaryLabelColor, але на знімках 1.3.9 (обидві теми) підказка
    // виходить основним кольором тексту; повторюємо те, що видно.
    readonly WrapLabel _note = new("", 11);
    readonly RowList _list = new(ListMetrics.Settings(220), 13);
    readonly WidthGrip _grip = new();
    readonly PushButton _reload = new(), _show = new(), _hide = new();
    /// Що вибрано в списку — номер, а не саме джерело: список перечитується.
    int _chosen;

    ScreenWorkspace(AppState state)
    {
        _state = state;
        _list.SetUniformHeight(44);
        _list.Source = this;
        _list.OnSelect = (_, active, _) => _chosen = active;
        _list.OnActivate = row => { _chosen = row; Show(); };
        _reload.Pressed = Reload;
        _show.Pressed = Show;
        _hide.Pressed = Hide;
        _grip.OnDrag = delta =>
        {
            Widths.Set(ListWidthKey, _list.Bounds.Width + delta, 200, Bounds.Width * 0.7);
            InvalidateArrange();
        };
        _grip.OnReset = () => { Widths.Reset(ListWidthKey); InvalidateArrange(); };
        foreach (Control c in new Control[] { _title, _note, _reload, _show, _hide, _list, _grip }) Children.Add(c);
        state.ScreenCapture.Changed += () => { _list.Reload(); Refresh(); };
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyCaptions);
        ApplyCaptions();
    }

    /// Вкладку відкрили — перечитати джерела (як install на Mac).
    public void Attach()
    {
        Refresh();
        Reload();
    }

    void ApplyCaptions()
    {
        _title.Text = T("Что показать в зале");
        _reload.Title = T("Обновить список");
        ToolTip.SetTip(_reload, T("Обновить список мониторов и окон"));
        _show.Title = T("Показать");
        ToolTip.SetTip(_show, T("Показать слайд"));
        _hide.Title = T("Скрыть");
        ToolTip.SetTip(_hide, T("Скрыть слайд"));
        Refresh();
    }

    // --- Кнопки ---------------------------------------------------------------------

    void Reload()
    {
        _state.ScreenCapture.Reload();
        _list.Reload();
        Refresh();
    }

    void Show()
    {
        var capture = _state.ScreenCapture;
        if (_chosen < 0 || _chosen >= capture.Sources.Count) return;
        _state.ShowCapturedScreen(capture.Sources[_chosen]);
        _list.Reload();
        Refresh();
    }

    void Hide()
    {
        _state.StopCapturedScreen();
        _list.Reload();
        Refresh();
    }

    // --- Стан -------------------------------------------------------------------------

    void Refresh()
    {
        var hint = T("Выберите монитор или окно и нажмите «Показать». "
            + "Картинка пойдёт на проектор и в NDI. Указка и приближение работают "
            + "по живому экрану в нижнем ряду — там же выбирается участок, на "
            + "который надо смотреть.");
        var capture = _state.ScreenCapture;
        _show.IsEnabled = capture.Sources.Count > 0;
        _hide.IsEnabled = capture.IsRunning;
        _note.Text = capture.State.Length == 0 ? hint : capture.State + "\n\n" + hint;
        InvalidateArrange();
    }

    // --- Рядки списку -------------------------------------------------------------------

    public int RowCount => _state.ScreenCapture.Sources.Count;

    public Row RowAt(int index)
    {
        var capture = _state.ScreenCapture;
        if (index < 0 || index >= capture.Sources.Count) return new Row();
        var source = capture.Sources[index];
        return new Row(source.Title, "", source.Subtitle) { SingleLine = true, Bold = capture.Current?.Id == source.Id };
    }

    // --- Розкладка ----------------------------------------------------------------------

    protected override void Arrangement(Size size)
    {
        var width = size.Width;
        var height = size.Height;
        var listWidth = Widths.Value(ListWidthKey, Math.Max(240, Math.Min(520, width * 0.45)), 200, width * 0.7);
        Place(_title, new Rect(Padding, Padding, Math.Max(0, width - Padding * 2), 18));
        var top = Padding + 18 + Gap;
        var contentHeight = Math.Max(0, height - top - Padding - ButtonHeight - Gap);
        Place(_list, new Rect(Padding, top, listWidth, contentHeight));
        Place(_reload, new Rect(Padding, height - Padding - ButtonHeight, 170, ButtonHeight));
        Place(_grip, new Rect(Padding + listWidth, top, GripWidth, contentHeight));
        var rightX = Padding + listWidth + GripWidth + Gap;
        var rightWidth = Math.Max(0, width - rightX - Padding);
        Place(_note, new Rect(rightX, top, rightWidth, contentHeight));
        Place(_show, new Rect(rightX, height - Padding - ButtonHeight, 130, ButtonHeight));
        Place(_hide, new Rect(rightX + 140, height - Padding - ButtonHeight, 110, ButtonHeight));
    }
}
