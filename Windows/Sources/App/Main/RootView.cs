// =============================================================================
//  RootView.cs — каркас головного вікна: частини згори донизу
// =============================================================================
//  Як на Mac (NativeRootView): кожна частина — постійний вид, що живе весь час
//  роботи програми; натискання міняє вміст однієї частини, решта не
//  чіпається. Розкладка — арифметикою сімох прямокутників, без перерахунку
//  всього вікна. На Windows рядок меню видно у вікні (на Mac меню — у системному
//  рядку вгорі екрана).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public enum Slot { MenuBar, ModeTabs, Workspace, SearchResults, TranslationStrip, BottomRow }

/// Ящик під частину вікна: хазяїн частини кладе свій вид — розмір приходить сам.
public sealed class SlotBox : Panel
{
    public readonly Slot Slot;
    public Control? ContentView { get; private set; }
    public SlotBox(Slot slot) { Slot = slot; }

    /// Покласти вид. Попередні не знімаються, а ховаються: знову показати
    /// схований вид дешевше, ніж збудувати наново (на Mac — третина часу
    /// перемикання вкладки).
    public void Install(Control? view)
    {
        foreach (var child in Children) if (!ReferenceEquals(child, view)) child.IsVisible = false;
        ContentView = view;
        if (view == null) return;
        if (!Children.Contains(view)) Children.Add(view);
        view.IsVisible = true;
    }
}

public sealed class RootView : LayoutPanel
{
    public static class Metrics
    {
        /// Висота рядка меню на Windows (на Mac він у системному рядку — 0).
        public const double MenuBar = 26;
        public const double ModeTabs = 30;
        public const double SearchResults = 170;
        public const double TranslationStrip = 30;

        public static double Inset(Slot slot) => slot switch
        {
            Slot.MenuBar or Slot.ModeTabs => 8,
            Slot.Workspace => 0,
            _ => 6,
        };
    }

    public readonly Dictionary<Slot, SlotBox> Slots = new();
    readonly HashSet<Slot> _visible = new();
    readonly List<double> _separators = new();
    readonly HeightGrip _grip = new();
    readonly Backdrop _backdrop;

    public RootView()
    {
        // Тло вікна й розділові лінії малює окремий шар під усіма частинами
        // (у Panel власного малювання немає).
        _backdrop = new Backdrop(this);
        Children.Add(_backdrop);
        foreach (Slot slot in Enum.GetValues<Slot>())
        {
            var box = new SlotBox(slot);
            Slots[slot] = box;
            Children.Add(box);
            if (slot == Slot.SearchResults) box.IsVisible = false; else _visible.Add(slot);
        }
        // Нижній ряд тягнуть угору — щоб живому екрану було де розвернутися.
        _grip.OnDrag = delta =>
        {
            BottomMetrics.RowHeight -= delta;
            InvalidateArrange();
        };
        _grip.OnReset = () => { BottomMetrics.RowHeight = BottomMetrics.RowDefaultHeight; InvalidateArrange(); };
        Children.Add(_grip);
        Palette.Changed += () => _backdrop.InvalidateVisual();
    }

    static double Height(Slot slot) => slot switch
    {
        Slot.MenuBar => Metrics.MenuBar,
        Slot.ModeTabs => Metrics.ModeTabs,
        Slot.SearchResults => Metrics.SearchResults,
        Slot.TranslationStrip => Metrics.TranslationStrip,
        Slot.BottomRow => BottomMetrics.RowHeight,
        _ => 0,
    };

    public void SetVisible(bool shown, Slot slot)
    {
        if (slot == Slot.Workspace) return;
        if (_visible.Contains(slot) == shown) return;
        if (shown) _visible.Add(slot); else _visible.Remove(slot);
        Slots[slot].IsVisible = shown;
        InvalidateArrange();
        _backdrop.InvalidateVisual();
    }

    public bool IsSlotVisible(Slot slot) => _visible.Contains(slot);

    protected override void Arrangement(Size size)
    {
        _separators.Clear();
        var order = Enum.GetValues<Slot>().Where(_visible.Contains).ToList();
        var fixedHeight = order.Where(s => s != Slot.Workspace).Sum(Height);
        var lines = Math.Max(0, order.Count - 1);
        var workspace = Math.Max(80, size.Height - fixedHeight - lines);
        double y = 0;
        var hasBottom = false;
        for (var i = 0; i < order.Count; i++)
        {
            var slot = order[i];
            if (i > 0) { _separators.Add(y); y += 1; }
            var height = slot == Slot.Workspace ? workspace : Height(slot);
            var inset = Metrics.Inset(slot);
            var rect = new Rect(inset, y, Math.Max(0, size.Width - inset * 2), height);
            Place(Slots[slot], rect);
            if (slot == Slot.BottomRow)
            {
                // Смужка лягає на розділову лінію над рядом: чотири точки вгору й униз.
                Place(_grip, new Rect(0, y - 4, size.Width, 8));
                hasBottom = true;
            }
            y += height;
        }
        _grip.IsVisible = hasBottom;
        Place(_backdrop, new Rect(size));
        _backdrop.InvalidateVisual();
    }

    sealed class Backdrop : Control
    {
        readonly RootView _root;
        public Backdrop(RootView root) { _root = root; }
        public override void Render(DrawingContext g)
        {
            g.FillRectangle(Palette.Brush(Palette.WindowBackground), new Rect(Bounds.Size));
            var line = Palette.Brush(Palette.Separator);
            foreach (var y in _root._separators) g.FillRectangle(line, new Rect(0, y, Bounds.Width, 1));
        }
    }
}
