// =============================================================================
//  MacSlider.cs — повзунок у вигляді «Слова» на Mac
// =============================================================================
//  Тонка сіра доріжка й біла кругла ручка з тінню (знімки Mac 1.3.9: кегль
//  списків угорі, указка й наближення під живим екраном).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public sealed class MacSlider : Control
{
    protected override void OnPropertyChanged(Avalonia.AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        // Свій малюнок: стан «доступна/ні» міняє вигляд — перемалювати.
        if (change.Property == IsEffectivelyEnabledProperty) InvalidateVisual();
    }

    public double Minimum { get; set; }
    public double Maximum { get; set; } = 1;
    double _value;
    public double Value
    {
        get => _value;
        set
        {
            var v = Math.Clamp(value, Minimum, Maximum);
            if (Math.Abs(v - _value) < 1e-9) return;
            _value = v;
            InvalidateVisual();
        }
    }
    /// Повідомляти під час протяжки, а не лише в кінці.
    public bool IsContinuous { get; set; } = true;
    /// Діаметр ручки: 20 — звичайний повзунок, 14 — малий.
    public double KnobSize { get; set; } = 20;
    public double Step { get; set; } = 1;
    /// Відступ доріжки від країв; null — до середини ручки в крайніх положеннях
    /// (повзунки «Слова»), 2 — на всю ширину, як звичайний NSSlider (гучність фонограми).
    public double? TrackInset { get; set; }
    public event Action<double>? ValueChanged;
    /// Протяжку почали й закінчили (перемотка плеєра тримається, поки тягнуть).
    public event Action? DragStarted, DragEnded;

    bool _dragging;

    public MacSlider()
    {
        Focusable = true;
        Cursor = new Cursor(StandardCursorType.Arrow);
        Palette.Changed += InvalidateVisual;
    }

    protected override Size MeasureOverride(Size available) => new(KnobSize * 4, KnobSize);

    double KnobX(double width)
    {
        var travel = Math.Max(1, width - KnobSize);
        var fraction = Maximum > Minimum ? (_value - Minimum) / (Maximum - Minimum) : 0;
        return KnobSize / 2 + travel * fraction;
    }

    public override void Render(DrawingContext g)
    {
        var b = Bounds;
        var mid = b.Height / 2;
        var dark = Palette.IsDark;
        var inset = TrackInset ?? KnobSize / 2 - 2;
        var track = new Rect(inset, mid - 2, Math.Max(0, b.Width - 2 * inset), 4);
        g.DrawRectangle(Palette.Brush(dark ? Color.FromArgb(56, 255, 255, 255) : Color.FromArgb(34, 0, 0, 0)), null, track, 2, 2);
        var x = KnobX(b.Width);
        var r = KnobSize / 2 - 0.5;
        var center = new Point(x, mid);
        // Тінь ручки — два напівпрозорі кола під нею.
        g.DrawEllipse(Palette.Brush(Color.FromArgb(28, 0, 0, 0)), null, center + new Point(0, 0.8), r + 0.6, r + 0.6);
        g.DrawEllipse(Palette.Brush(Color.FromArgb(dark ? (byte)230 : (byte)255, 255, 255, 255)),
                      new Pen(Palette.Brush(Color.FromArgb(40, 0, 0, 0)), 0.5), center, r, r);
    }

    void SetFrom(Point p)
    {
        var travel = Math.Max(1, Bounds.Width - KnobSize);
        var fraction = Math.Clamp((p.X - KnobSize / 2) / travel, 0, 1);
        var before = _value;
        Value = Minimum + fraction * (Maximum - Minimum);
        if (IsContinuous && Math.Abs(before - _value) > 1e-9) ValueChanged?.Invoke(_value);
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        _dragging = true;
        e.Pointer.Capture(this);
        DragStarted?.Invoke();
        SetFrom(e.GetPosition(this));
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        if (_dragging) SetFrom(e.GetPosition(this));
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        e.Pointer.Capture(null);
        if (!IsContinuous) ValueChanged?.Invoke(_value);
        DragEnded?.Invoke();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        var delta = e.Key switch { Key.Left or Key.Down => -Step, Key.Right or Key.Up => Step, _ => 0 };
        if (delta == 0) { base.OnKeyDown(e); return; }
        Value = _value + delta;
        ValueChanged?.Invoke(_value);
        e.Handled = true;
    }
}
