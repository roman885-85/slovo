// =============================================================================
//  BottomWidgets.cs — дрібні частини нижнього ряду
// =============================================================================
//  Підпис над панеллю (11 пт, другорядний колір), рамка панелі (кут 4, обідок
//  1, у фокусі — 2 кольору акценту), межа ширини з трьома крапками.
//  Як NativeBottomWidgets.swift і NativeWidthGrip.swift на Mac.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

/// Підпис над панеллю: «План:», «Історія:», «Попередній перегляд»…
public sealed class BottomCaption : Control
{
    string _text;
    public double FontSize { get; set; } = 11;
    public TextAlignment Align { get; set; } = TextAlignment.Left;
    public FontWeight Weight { get; set; } = FontWeight.Normal;
    public Func<Color> Color { get; set; } = () => Palette.SecondaryLabel;
    /// Текст «як є», без лігатур шрифту (ключі перекладу з «->»).
    public bool Plain { get; set; }
    /// Поле з боків тексту: мітка NSTextField відступає 2 точки від своєї рамки.
    public double Inset { get; set; }
    public BottomCaption(string text = "") { _text = text; Palette.Changed += InvalidateVisual; }
    public string Text { get => _text; set { if (_text == value) return; _text = value; InvalidateVisual(); } }
    public override void Render(DrawingContext g) =>
        TextDraw.Draw(g, _text, new Rect(Inset, 0, Math.Max(0, Bounds.Width - 2 * Inset), Bounds.Height), FontSize, Color(), Weight, Align, wrap: false, trim: true, plain: Plain);
}

/// Рамка панелі нижнього ряду.
public sealed class FramedBox : Border
{
    bool _highlighted;
    public FramedBox()
    {
        CornerRadius = new CornerRadius(BottomMetrics.Corner);
        ClipToBounds = true;
        Apply();
        Palette.Changed += Apply;
    }
    public bool IsHighlighted { get => _highlighted; set { if (_highlighted == value) return; _highlighted = value; Apply(); } }
    void Apply()
    {
        BorderThickness = new Thickness(_highlighted ? 2 : 1);
        BorderBrush = Palette.Brush(_highlighted ? Palette.Accent : Palette.Separator);
        Background = Palette.Brush(Palette.TextBackground);
    }
}

/// Межа ширини між панелями: три крапки, тягнеться вліво-вправо, подвійне клацання — як було.
public sealed class WidthGrip : Control
{
    public Action<double>? OnDrag;
    public Action? OnReset;
    double? _last;

    public WidthGrip() { Cursor = new Cursor(StandardCursorType.SizeWestEast); Palette.Changed += InvalidateVisual; }

    public override void Render(DrawingContext g)
    {
        g.FillRectangle(Brushes.Transparent, new Rect(Bounds.Size));
        var dot = 2.0;
        var y = Bounds.Height / 2 - dot * 4;
        var brush = Palette.Brush(Palette.Separator);
        for (var i = 0; i < 3; i++)
        {
            g.DrawEllipse(brush, null, new Rect(Bounds.Width / 2 - dot / 2, y, dot, dot));
            y += dot * 3;
        }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (e.ClickCount == 2) { OnReset?.Invoke(); _last = null; return; }
        // Як на Mac: точка натиску у власних координатах межі — межа їде разом
        // із панеллю, тож різниця від неї й є прирістом.
        _last = e.GetPosition(this).X;
        e.Pointer.Capture(this);
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        if (_last is not { } was) return;
        var delta = e.GetPosition(this).X - was;
        if (Math.Abs(delta) >= 1) OnDrag?.Invoke(delta);
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e) { _last = null; e.Pointer.Capture(null); }
}

/// Межа над нижньою панеллю: три крапки посередині, тягнеться вгору-вниз.
/// OnDrag дає ПРИРІСТ у координатах вікна (межа їде з панеллю, і зсув у власних
/// координатах рахував би той самий рух багато разів); OnBegin/OnEnd — щоб той,
/// хто слухає, вів свій рахунок від однієї точки (панель фонограм «прилипає»).
public sealed class HeightGrip : Control
{
    public Action<double>? OnDrag;
    public Action? OnReset, OnBegin, OnEnd;
    double? _last;

    public HeightGrip()
    {
        Cursor = new Cursor(StandardCursorType.SizeNorthSouth);
        Palette.Changed += InvalidateVisual;
    }

    public override void Render(DrawingContext g)
    {
        g.FillRectangle(Brushes.Transparent, new Rect(Bounds.Size));
        var dot = 2.0;
        var x = Bounds.Width / 2 - dot * 4;
        var brush = Palette.Brush(Palette.Separator);
        for (var i = 0; i < 3; i++)
        {
            g.DrawEllipse(brush, null, new Rect(x, Bounds.Height / 2 - dot / 2, dot, dot));
            x += dot * 3;
        }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (e.ClickCount == 2 && OnReset != null) { OnReset(); _last = null; e.Handled = true; return; }
        _last = e.GetPosition(TopLevel.GetTopLevel(this)).Y;
        e.Pointer.Capture(this);
        OnBegin?.Invoke();
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        if (_last is not { } was) return;
        var now = e.GetPosition(TopLevel.GetTopLevel(this)).Y;
        var delta = now - was;
        if (Math.Abs(delta) < 1) return;
        _last = now;
        OnDrag?.Invoke(delta);
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        if (_last == null) return;
        _last = null;
        e.Pointer.Capture(null);
        OnEnd?.Invoke();
    }
}
