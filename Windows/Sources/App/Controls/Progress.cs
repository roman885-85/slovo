// =============================================================================
//  Progress.cs — смужка ходу й крутилка (як NSProgressIndicator .bar і .spinning)
// =============================================================================
//  Смужка: округла доріжка й заповнення кольору акценту, товщина 6 точок по
//  центру рамки (рамка буває вища — 12 у майстрі імпорту). Крутилка: дванадцять
//  рисок, що по черзі темнішають, — поки її крутять; зупинена не малюється.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using Avalonia.VisualTree;

namespace Slovo.App;

public sealed class ProgressLine : Control
{
    double _value;
    /// Частка зробленого, 0…1.
    public double Value
    {
        get => _value;
        set
        {
            var v = double.IsFinite(value) ? Math.Clamp(value, 0, 1) : 0;
            if (Math.Abs(v - _value) < 0.0005) return;
            _value = v;
            InvalidateVisual();
        }
    }

    /// Товщина доріжки.
    public double Thickness { get; set; } = 6;

    public ProgressLine() { Palette.Changed += InvalidateVisual; }

    public override void Render(DrawingContext g)
    {
        var t = Math.Min(Bounds.Height, Thickness);
        if (t <= 0 || Bounds.Width <= 0) return;
        var track = new Rect(0, Math.Round((Bounds.Height - t) / 2), Bounds.Width, t);
        var r = t / 2;
        g.DrawRectangle(Palette.Brush(Palette.QuaternaryLabel), null, track, r, r);
        if (_value > 0)
            g.DrawRectangle(Palette.Brush(Palette.Accent), null, new Rect(track.X, track.Y, Math.Max(t, track.Width * _value), t), r, r);
    }
}

public sealed class Spinner : Control
{
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(83) };
    int _step;
    bool _spinning;

    public Spinner()
    {
        _timer.Tick += (_, _) => { _step = (_step + 1) % 12; InvalidateVisual(); };
        Palette.Changed += InvalidateVisual;
    }

    /// Крутиться (startAnimation / stopAnimation).
    public bool IsSpinning
    {
        get => _spinning;
        set
        {
            if (_spinning == value) return;
            _spinning = value;
            if (value && IsAttachedToVisualTree) _timer.Start(); else _timer.Stop();
            InvalidateVisual();
        }
    }

    bool IsAttachedToVisualTree => this.GetVisualRoot() != null;

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        if (_spinning) _timer.Start();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        _timer.Stop();
        base.OnDetachedFromVisualTree(e);
    }

    public override void Render(DrawingContext g)
    {
        if (!_spinning) return;
        var c = new Rect(Bounds.Size).Center;
        var radius = Math.Min(Bounds.Width, Bounds.Height) / 2;
        if (radius <= 1) return;
        var width = Math.Max(1.2, radius * 0.2);
        for (var i = 0; i < 12; i++)
        {
            // Найтемніша — поточна, далі проти руху світлішають.
            var age = (_step - i + 12) % 12;
            var alpha = Math.Max(0.15, 1 - age / 12.0);
            var angle = i * Math.PI / 6 - Math.PI / 2;
            var (sin, cos) = Math.SinCos(angle);
            var pen = new Pen(Palette.Brush(Palette.SecondaryLabel.WithAlpha(alpha)), width, lineCap: PenLineCap.Round);
            g.DrawLine(pen, new Point(c.X + cos * radius * 0.5, c.Y + sin * radius * 0.5),
                       new Point(c.X + cos * (radius - width / 2), c.Y + sin * (radius - width / 2)));
        }
    }
}
