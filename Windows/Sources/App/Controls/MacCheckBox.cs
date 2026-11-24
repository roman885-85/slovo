// =============================================================================
//  MacCheckBox.cs — прапорець і перемикач-сегменти у вигляді «Слова» на Mac
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public sealed class MacCheckBox : Control
{
    protected override void OnPropertyChanged(Avalonia.AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        // Свій малюнок: стан «доступна/ні» міняє вигляд — перемалювати.
        if (change.Property == IsEffectivelyEnabledProperty) InvalidateVisual();
    }

    string _title;
    bool _on;
    public double FontSize { get; set; } = 13;
    /// Розмір квадратика: 14 — звичайний, 12 — малий, 10 — найменший.
    public double BoxSize { get; set; } = 14;
    public event Action<bool>? Toggled;

    public MacCheckBox(string title = "", double fontSize = 13, double boxSize = 14)
    {
        _title = title; FontSize = fontSize; BoxSize = boxSize;
        Focusable = true;
        Palette.Changed += InvalidateVisual;
    }

    public string Title { get => _title; set { _title = value; InvalidateMeasure(); InvalidateVisual(); } }
    public bool IsChecked { get => _on; set { if (_on == value) return; _on = value; InvalidateVisual(); } }

    public double FittingWidth => Math.Ceiling(BoxSize + 5 + UiFont.Width(_title, FontSize) + 2);
    protected override Size MeasureOverride(Size available) => new(FittingWidth, Math.Max(BoxSize + 2, UiFont.LineHeight(FontSize)));

    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size);
        g.FillRectangle(Brushes.Transparent, b);
        var dark = Palette.IsDark;
        var enabled = IsEffectivelyEnabled;
        var box = new Rect(0.5, Math.Round((b.Height - BoxSize) / 2) + 0.5, BoxSize - 1, BoxSize - 1);
        var radius = BoxSize * 0.22;
        if (_on)
        {
            g.DrawRectangle(Palette.Brush(enabled ? Palette.Accent : Palette.SystemGray), null, box, radius, radius);
            var pen = new Pen(Brushes.White, Math.Max(1.4, BoxSize / 8), lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
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
                            new Pen(Palette.Brush(dark ? Color.FromArgb(70, 255, 255, 255) : Color.FromArgb(70, 0, 0, 0)), 0.75),
                            box, radius, radius);
        }
        if (_title.Length > 0)
        {
            var lh = UiFont.LineHeight(FontSize);
            TextDraw.Draw(g, _title, new Rect(BoxSize + 5, Math.Round((b.Height - lh) / 2), Math.Max(0, b.Width - BoxSize - 5), lh),
                          FontSize, enabled ? Palette.Label : Palette.DisabledText, wrap: false, trim: true);
        }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed || !IsEffectivelyEnabled) return;
        IsChecked = !_on;
        Toggled?.Invoke(_on);
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.Space && IsEffectivelyEnabled) { IsChecked = !_on; Toggled?.Invoke(_on); e.Handled = true; return; }
        base.OnKeyDown(e);
    }
}

/// Кружок-перемикач (NSButton radio): вибраний — кольором акценту з білою цяткою.
/// Групу веде той, хто ставить перемикачі: Chosen приходить лише на вибір.
public sealed class MacRadio : Control
{
    protected override void OnPropertyChanged(Avalonia.AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        if (change.Property == IsEffectivelyEnabledProperty) InvalidateVisual();
    }

    string _title;
    bool _on;
    public double FontSize { get; set; } = 13;
    public double CircleSize { get; set; } = 14;
    public event Action? Chosen;

    public MacRadio(string title = "", double fontSize = 13, double circleSize = 14)
    {
        _title = title; FontSize = fontSize; CircleSize = circleSize;
        Focusable = true;
        Palette.Changed += InvalidateVisual;
    }

    public string Title { get => _title; set { _title = value; InvalidateMeasure(); InvalidateVisual(); } }
    public bool IsChecked { get => _on; set { if (_on == value) return; _on = value; InvalidateVisual(); } }

    public double FittingWidth => Math.Ceiling(CircleSize + 5 + UiFont.Width(_title, FontSize) + 2);
    protected override Size MeasureOverride(Size available) => new(FittingWidth, Math.Max(CircleSize + 2, UiFont.LineHeight(FontSize)));

    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size);
        g.FillRectangle(Brushes.Transparent, b);
        var dark = Palette.IsDark;
        var enabled = IsEffectivelyEnabled;
        var circle = new Rect(0.5, Math.Round((b.Height - CircleSize) / 2) + 0.5, CircleSize - 1, CircleSize - 1);
        if (_on)
        {
            g.DrawEllipse(Palette.Brush(enabled ? Palette.Accent : Palette.SystemGray), null, circle);
            var dot = CircleSize * 0.4;
            g.DrawEllipse(Brushes.White, null, new Rect(circle.Center.X - dot / 2, circle.Center.Y - dot / 2, dot, dot));
        }
        else
        {
            g.DrawEllipse(Palette.Brush(dark ? Color.FromArgb(40, 255, 255, 255) : Colors.White),
                          new Pen(Palette.Brush(dark ? Color.FromArgb(70, 255, 255, 255) : Color.FromArgb(70, 0, 0, 0)), 0.75), circle);
        }
        if (_title.Length > 0)
        {
            var lh = UiFont.LineHeight(FontSize);
            TextDraw.Draw(g, _title, new Rect(CircleSize + 5, Math.Round((b.Height - lh) / 2), Math.Max(0, b.Width - CircleSize - 5), lh),
                          FontSize, enabled ? Palette.Label : Palette.DisabledText, wrap: false, trim: true);
        }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed || !IsEffectivelyEnabled) return;
        if (!_on) { IsChecked = true; Chosen?.Invoke(); }
        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key == Key.Space && IsEffectivelyEnabled && !_on) { IsChecked = true; Chosen?.Invoke(); e.Handled = true; return; }
        base.OnKeyDown(e);
    }
}

/// Сегменти-перемикач («Усе | Зал | NDI») — як NSSegmentedControl, стиль rounded.
public sealed class Segmented : Control
{
    readonly List<string> _labels;
    int _selected;
    public double FontSize { get; set; } = 13;
    public event Action<int>? Selected;

    public Segmented(IEnumerable<string> labels, double fontSize = 13)
    {
        _labels = labels.ToList(); FontSize = fontSize;
        Palette.Changed += InvalidateVisual;
    }

    public int SelectedIndex { get => _selected; set { _selected = value; InvalidateVisual(); } }
    public void SetLabel(int index, string label) { _labels[index] = label; InvalidateVisual(); }
    /// Ширина за вмістом, як fittingSize NSSegmentedControl: кожен сегмент — підпис і поля по 7.
    public double FittingWidth => Math.Ceiling(_labels.Sum(label => UiFont.Width(label, FontSize) + 14) + 2);

    public override void Render(DrawingContext g)
    {
        var dark = Palette.IsDark;
        var bh = Math.Min(Bounds.Height, FontSize + 8);
        var track = new Rect(0, Math.Round((Bounds.Height - bh) / 2), Bounds.Width, bh);
        g.DrawRectangle(Palette.Brush(dark ? Color.FromRgb(0x3C, 0x3C, 0x3C) : Color.FromRgb(0xE0, 0xE0, 0xE0)), null, track, 5, 5);
        if (_labels.Count == 0) return;
        var w = track.Width / _labels.Count;
        for (var i = 0; i < _labels.Count; i++)
        {
            var cell = new Rect(track.X + i * w, track.Y, w, track.Height);
            if (i == _selected)
            {
                var pill = cell.Deflate(1.5);
                g.DrawRectangle(Palette.Brush(Color.FromArgb(30, 0, 0, 0)), null, pill.Translate(new Vector(0, 0.5)), 4, 4);
                g.DrawRectangle(Palette.Brush(dark ? Color.FromRgb(0x72, 0x72, 0x72) : Colors.White), null, pill, 4, 4);
            }
            else if (i > 0 && i - 1 != _selected)
            {
                g.FillRectangle(Palette.Brush(Palette.Separator), new Rect(cell.X, cell.Y + 4, 1, cell.Height - 8));
            }
            var lh = UiFont.LineHeight(FontSize);
            TextDraw.Draw(g, _labels[i], new Rect(cell.X + 2, Math.Round(cell.Center.Y - lh / 2), cell.Width - 4, lh), FontSize,
                          Palette.Label, i == _selected ? FontWeight.Medium : FontWeight.Normal, TextAlignment.Center, wrap: false, trim: true);
        }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (_labels.Count == 0 || !e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        var i = Math.Clamp((int)(e.GetPosition(this).X / (Bounds.Width / _labels.Count)), 0, _labels.Count - 1);
        _selected = i;
        InvalidateVisual();
        Selected?.Invoke(i);
        e.Handled = true;
    }
}
