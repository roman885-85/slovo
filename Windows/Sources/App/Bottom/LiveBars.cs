// =============================================================================
//  LiveBars.cs — смужки під живим екраном: указка й наближення
// =============================================================================
//  Як NativePointerBar / NativeFocusBar: зразок плями, колір, «розмір» і
//  «яскравість» повзунками, куди виводити указку (Усе | Зал | NDI); нижче —
//  «Наближення», у скільки разів, «У центр».
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Slovo.App;

/// Вигляд указки: колір, розмір (частка висоти кадру), яскравість, куди виводити.
public record struct PointerLook(Color Colour, double Size, double Opacity, bool ToProjector, bool ToNDI);

public sealed class PointerSample : Control
{
    PointerLook _look = new(Color.FromRgb(0xFF, 0xD9, 0x18), 0.14, 0.45, true, true);
    public PointerLook Look { get => _look; set { _look = value; InvalidateVisual(); } }
    public PointerSample() { Palette.Changed += InvalidateVisual; }
    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size);
        g.FillRectangle(Palette.Brush(Palette.ControlBackground), b);
        g.DrawRectangle(null, new Pen(Palette.Brush(Palette.Separator), 1), b.Deflate(0.5));
        var radius = Math.Max(1.5, Math.Min(b.Height, b.Width) * _look.Size / 2 * 3);
        var c = _look.Colour;
        g.DrawEllipse(Palette.Brush(Color.FromArgb((byte)(_look.Opacity * 255), c.R, c.G, c.B)),
                      new Pen(Palette.Brush(Color.FromArgb((byte)(Math.Min(1, _look.Opacity + 0.4) * 255), c.R, c.G, c.B)), 1),
                      b.Center, radius - 0.5, radius - 0.5);
    }
}

/// Поле кольору: заливка кольором; клацання — задати R, G, B.
public sealed class ColourSwatch : Control
{
    Color _colour;
    public Action<Color>? OnChange;
    public Action? OnClick;
    public ColourSwatch(Color colour) { _colour = colour; Palette.Changed += InvalidateVisual; }
    public Color Colour { get => _colour; set { _colour = value; InvalidateVisual(); } }
    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size).Deflate(0.5);
        g.DrawRectangle(Palette.Brush(_colour), new Pen(Palette.Brush(Palette.Separator), 1), b, 3, 3);
    }
    protected override void OnPointerPressed(Avalonia.Input.PointerPressedEventArgs e) { OnClick?.Invoke(); e.Handled = true; }
}

public sealed class PointerBar : LayoutPanel
{
    public readonly PointerSample Sample = new();
    public readonly ColourSwatch Colour = new(Color.FromRgb(0xFF, 0xD9, 0x18));
    public readonly MacSlider SizeSlider = new() { Minimum = 3, Maximum = 60, Value = 14, KnobSize = 14 };
    public readonly MacSlider Brightness = new() { Minimum = 5, Maximum = 100, Value = 45, KnobSize = 14 };
    public readonly Segmented Outputs = new(new[] { "", "", "NDI" }, 9);
    readonly BottomCaption _sizeLabel = new() { FontSize = 10 }, _brightLabel = new() { FontSize = 10 };

    public PointerBar()
    {
        foreach (Control c in new Control[] { Sample, Colour, SizeSlider, Brightness, Outputs, _sizeLabel, _brightLabel }) Children.Add(c);
        Layout = Arrange;
        ApplyCaptions();
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyCaptions);
    }

    public void ApplyCaptions()
    {
        ToolTip.SetTip(SizeSlider, Captions.T("Размер пятна — доля высоты кадра"));
        ToolTip.SetTip(Brightness, Captions.T("Яркость пятна"));
        ToolTip.SetTip(Colour, Captions.T("Цвет: нажмите, чтобы задать R, G, B"));
        _sizeLabel.Text = Captions.T("Размер");
        _brightLabel.Text = Captions.T("Яркость");
        Outputs.SetLabel(0, Captions.T("Все"));
        Outputs.SetLabel(1, Captions.T("Зал"));
        ToolTip.SetTip(Outputs, Captions.T("Куда выводить указку: везде, только в зал (проектор) или только в NDI"));
        ToolTip.SetTip(this, Captions.T("Указка: нажмите левой кнопкой по живому экрану и ведите не отпуская"));
        InvalidateArrange();
    }

    void Arrange(Size size)
    {
        const double gap = 4;
        var height = size.Height;
        double x = 0;
        Place(Sample, new Rect(x, 0, height, height));
        x += height + gap;
        Place(Colour, new Rect(x, 1, 34, height - 2));
        x += 34 + gap;
        var outputsWidth = Math.Min(160, Math.Max(112, size.Width * 0.34));
        var outputs = new Rect(Math.Max(x, size.Width - outputsWidth), 0, outputsWidth, height);
        Place(Outputs, outputs);
        var free = Math.Max(0, outputs.X - x - gap);
        var showLabels = free > 190;
        _sizeLabel.IsVisible = _brightLabel.IsVisible = showLabels;
        var labelWidth = showLabels ? 48 : 0;
        var sliderWidth = Math.Max(0, (free - labelWidth * 2 - gap * 3) / 2);
        if (showLabels) { Place(_sizeLabel, new Rect(x, 2, labelWidth, height - 4)); x += labelWidth; }
        Place(SizeSlider, new Rect(x, 1, sliderWidth, height - 2));
        x += sliderWidth + gap;
        if (showLabels) { Place(_brightLabel, new Rect(x, 2, labelWidth, height - 4)); x += labelWidth; }
        Place(Brightness, new Rect(x, 1, sliderWidth, height - 2));
    }
}

public sealed class FocusBar : LayoutPanel
{
    public readonly MacCheckBox Toggle = new("", 10, 10);
    public readonly MacSlider Zoom = new() { Minimum = 110, Maximum = 600, Value = 200, KnobSize = 14 };
    readonly BottomCaption _zoomLabel = new() { FontSize = 10 };
    public readonly PushButton CenterButton = new("", null, ControlSize.Mini) { FontSize = 10 };

    public FocusBar()
    {
        foreach (Control c in new Control[] { Toggle, Zoom, _zoomLabel, CenterButton }) Children.Add(c);
        Layout = Arrange;
        ApplyCaptions();
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyCaptions);
    }

    public void ApplyCaptions()
    {
        Toggle.Title = Captions.T("Приближение");
        ToolTip.SetTip(Toggle, Captions.T("Нажмите по живому экрану — этот кусок страницы станет во весь экран"));
        CenterButton.Title = Captions.T("В центр");
        ToolTip.SetTip(CenterButton, Captions.T("Вернуть взгляд на середину страницы"));
        ToolTip.SetTip(Zoom, Captions.T("Во сколько раз приблизить"));
        InvalidateArrange();
    }

    /// Показати стан наближення: увімкнено, у скільки разів.
    public void Show(bool on, double zoom)
    {
        Toggle.IsChecked = on;
        Zoom.IsEnabled = on;
        CenterButton.IsEnabled = on;
        if (Math.Abs(Zoom.Value - zoom * 100) > 0.5) Zoom.Value = zoom * 100;
        // Як String(format: "×%.1f") на Mac — з крапкою.
        _zoomLabel.Text = "×" + zoom.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture);
    }

    void Arrange(Size size)
    {
        const double gap = 4;
        var height = size.Height;
        double x = 0;
        var toggleWidth = Math.Min(120, Math.Max(70, size.Width * 0.3));
        Place(Toggle, new Rect(x, 0, toggleWidth, height));
        x += toggleWidth + gap;
        const double buttonWidth = 62;
        var button = new Rect(Math.Max(x, size.Width - buttonWidth), 0, buttonWidth, height);
        Place(CenterButton, button);
        const double labelWidth = 30;
        var free = Math.Max(0, button.X - x - gap - labelWidth);
        Place(Zoom, new Rect(x, 1, free, height - 2));
        x += free + 2;
        Place(_zoomLabel, new Rect(x, 4, labelWidth, height - 6));
    }
}
