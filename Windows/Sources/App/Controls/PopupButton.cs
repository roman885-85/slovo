// =============================================================================
//  PopupButton.cs — список-кнопка вибору (як NSPopUpButton на Mac)
// =============================================================================
//  Біла (у темній темі #676766) округла кнопка з підписом вибраного й
//  подвійною стрілкою праворуч; клацання — меню з галочкою біля вибраного.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public sealed class PopupButton : Control
{
    protected override void OnPropertyChanged(Avalonia.AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        // Свій малюнок: стан «доступна/ні» міняє вигляд — перемалювати.
        if (change.Property == IsEffectivelyEnabledProperty) InvalidateVisual();
    }

    List<string> _items;
    int _selected;
    public double FontSize { get; set; } = 11;
    public event Action<int>? Selected;

    public PopupButton(IEnumerable<string> items, int selected = 0)
    {
        _items = items.ToList();
        _selected = selected;
        Focusable = true;
        Palette.Changed += InvalidateVisual;
    }

    public IReadOnlyList<string> Items => _items;
    public void SetItems(IEnumerable<string> items) { _items = items.ToList(); _selected = Math.Clamp(_selected, 0, Math.Max(0, _items.Count - 1)); InvalidateVisual(); }
    public int SelectedIndex { get => _selected; set { _selected = value; InvalidateVisual(); } }
    public string SelectedTitle => _selected >= 0 && _selected < _items.Count ? _items[_selected] : "";

    protected override Size MeasureOverride(Size available) =>
        new(Math.Ceiling(_items.Select(i => UiFont.Width(i, FontSize)).DefaultIfEmpty(0).Max()) + 34, 22);

    public override void Render(DrawingContext g)
    {
        var dark = Palette.IsDark;
        var b = new Rect(Bounds.Size);
        var bh = Math.Min(b.Height - 1, FontSize + 9);
        var bezel = new Rect(1, Math.Round((b.Height - bh) / 2), Math.Max(0, b.Width - 2), bh);
        g.DrawRectangle(Palette.Brush(Color.FromArgb(dark ? (byte)70 : (byte)38, 0, 0, 0)), null, bezel.Translate(new Vector(0, 0.5)), 5, 5);
        var face = dark ? Color.FromRgb(0x67, 0x67, 0x66) : Colors.White;
        if (!IsEffectivelyEnabled) face = dark ? Color.FromRgb(0x50, 0x50, 0x50) : Color.FromRgb(0xF6, 0xF6, 0xF6);
        g.DrawRectangle(Palette.Brush(face), new Pen(Palette.Brush(dark ? Color.FromArgb(25, 255, 255, 255) : Color.FromArgb(30, 0, 0, 0)), 0.5),
                        bezel.Deflate(0.25), 5, 5);
        var text = IsEffectivelyEnabled ? Palette.Label : Palette.DisabledText;
        var lh = UiFont.LineHeight(FontSize);
        TextDraw.Draw(g, SelectedTitle, new Rect(bezel.X + 8, bezel.Center.Y - lh / 2, Math.Max(0, bezel.Width - 30), lh), FontSize, text, wrap: false, trim: true);
        // Подвійна стрілка (вгору-вниз), як у NSPopUpButton.
        DrawArrows(g, bezel.Right - ArrowInset, bezel.Center.Y, text);
    }

    /// Де центр подвійної стрілки від правого краю рамки: 14 — малий список (11 пт),
    /// 10 — звичайний (13 пт, NSPopUpButton без зміни шрифту).
    public double ArrowInset { get; set; } = 14;

    /// Подвійна стрілка «вгору-вниз» списку, що випадає (і в комірці таблиці).
    public static void DrawArrows(DrawingContext g, double x, double cy, Color color)
    {
        var pen = new Pen(Palette.Brush(color), 1.3, lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
        var geo = new StreamGeometry();
        using (var c = geo.Open())
        {
            c.BeginFigure(new Point(x - 3, cy - 2), false); c.LineTo(new Point(x, cy - 5)); c.LineTo(new Point(x + 3, cy - 2));
            c.BeginFigure(new Point(x - 3, cy + 2), false); c.LineTo(new Point(x, cy + 5)); c.LineTo(new Point(x + 3, cy + 2));
        }
        g.DrawGeometry(null, pen, geo);
    }

    /// Ширина за вмістом для звичайного (13 пт) списку — як intrinsic NSPopUpButton:
    /// найширший пункт + 33 (виміряно: порожній — 33, «Slovo» — 64).
    public double FittingWidth => Math.Ceiling(_items.Select(i => UiFont.Width(i, FontSize)).DefaultIfEmpty(0).Max()) + 33;

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!IsEffectivelyEnabled || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        var entries = _items.Select((title, i) => new MenuEntry(title, () => { _selected = i; InvalidateVisual(); Selected?.Invoke(i); }, i == _selected)).ToList();
        var menu = MenuStrip.Build(entries);
        menu.PlacementTarget = this;
        menu.Placement = PlacementMode.BottomEdgeAlignedLeft;
        menu.Open(this);
        e.Handled = true;
    }
}

/// Поле вводу з рамкою (як NSTextField із бортиком): біле, тонкий обідок, синє
/// світіння навколо в фокусі.
public sealed class FormField : QuickField
{
    public FormField(double fontSize = 11, bool rightAligned = false) : base(fontSize)
    {
        if (rightAligned) Box.TextAlignment = TextAlignment.Right;
    }
}
