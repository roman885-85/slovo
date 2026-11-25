// =============================================================================
//  ControlPanel.cs — «Керування:» (нижній ряд, праворуч)
// =============================================================================
//  Як NativeControlPanel: два ряди по три малі кнопки (« Розділ, ‹ Вірш,
//  ↻ Поточний / » Розділ, › Вірш, Знімок), праворуч «Показати» (кольору
//  акценту) і «Сховати»; риска на висоті 48; під нею мініатюри «Шаблон»,
//  «Фон слайда», «Загальний фон» (96×54, підпис 10 пт, примітка 9 пт).
//  Прапорець «Активна» ставить нижній ряд у рядок підпису.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;

namespace Slovo.App;

/// Мініатюра: підпис, картинка 96×54 у рамці, примітка під нею.
public sealed class BottomThumbnail : Control
{
    public static readonly Size PictureSize = new(96, 54);
    public static double FullHeight => 12 + PictureSize.Height + 12;

    string _title = "", _note = "";
    Bitmap? _image;
    bool _dimmed;
    public Action? OnClick;
    public Func<ContextMenu?>? OnMenu;

    public BottomThumbnail() { Palette.Changed += InvalidateVisual; }

    public void Apply(string title, Bitmap? image, string note, string hint, bool dimmed)
    {
        _title = title; _image = image; _note = note; _dimmed = dimmed;
        ToolTip.SetTip(this, hint);
        InvalidateVisual();
    }

    public override void Render(DrawingContext g)
    {
        g.FillRectangle(Brushes.Transparent, new Rect(Bounds.Size));
        TextDraw.Draw(g, _title, new Rect(0, 0, Bounds.Width, 12), 10, Palette.SecondaryLabel, wrap: false, trim: true);
        var frame = new Rect(0, 12, PictureSize.Width, PictureSize.Height);
        g.DrawRectangle(Palette.Brush(Palette.ControlBackground), new Pen(Palette.Brush(Palette.Separator), 1), frame.Deflate(0.5), 3, 3);
        using (g.PushClip(new RoundedRect(frame.Deflate(1), 2)))
        {
            if (_image != null)
            {
                // Пропорційно в рамку, як imageScaling .scaleProportionallyUpOrDown.
                var s = Math.Min(frame.Width / _image.Size.Width, frame.Height / _image.Size.Height);
                var w = _image.Size.Width * s; var h = _image.Size.Height * s;
                using (g.PushOpacity(_dimmed ? 0.4 : 1))
                    g.DrawImage(_image, new Rect(frame.X + (frame.Width - w) / 2, frame.Y + (frame.Height - h) / 2, w, h));
            }
            else
            {
                Icons.Draw(g, "photo", new Rect(frame.Center.X - 22, frame.Center.Y - 20, 44, 40), Palette.TertiaryLabel, 1.2);
            }
        }
        // Примітка обрізається посередині (lineBreakMode .byTruncatingMiddle).
        TextDraw.Draw(g, MiddleEllipsis(_note, 9, PictureSize.Width), new Rect(0, 12 + PictureSize.Height, PictureSize.Width, 12),
                      9, Palette.TertiaryLabel, wrap: false, trim: true);
    }

    static string MiddleEllipsis(string text, double size, double width)
    {
        if (UiFont.Width(text, size) <= width || text.Length < 5) return text;
        var keep = text.Length - 1;
        while (keep > 2)
        {
            var head = (keep + 1) / 2; var tail = keep / 2;
            var s = text[..head] + "…" + text[^tail..];
            if (UiFont.Width(s, size) <= width) return s;
            keep--;
        }
        return text;
    }

    bool _holdHooked;

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!_holdHooked)
        {
            // Затримати палець — меню (як права кнопка).
            _holdHooked = true;
            Holding += (_, h) =>
            {
                if (h.HoldingState != HoldingState.Started || h.PointerType != PointerType.Touch) return;
                if (OnMenu?.Invoke() is { } held) { held.PlacementTarget = this; held.Open(this); }
                h.Handled = true;
            };
        }
        var p = e.GetCurrentPoint(this).Properties;
        if (p.IsRightButtonPressed)
        {
            if (OnMenu?.Invoke() is { } menu) { menu.PlacementTarget = this; menu.Open(this); }
        }
        else if (p.IsLeftButtonPressed) OnClick?.Invoke();
        e.Handled = true;
    }
}

public sealed class ControlPanel : LayoutPanel
{
    /// Кнопки кроків — значок, ключ підпису й підказки (переклад — наш словник).
    public static readonly (string Symbol, string Title, string Hint)[] Steps =
    {
        ("chevron.left.2", "Глава", "Предыдущая глава"),
        ("chevron.left", "Стих", "Предыдущий стих"),
        ("arrow.counterclockwise", "Текущий", "К текущему стиху"),
        ("chevron.right.2", "Глава", "Следующая глава"),
        ("chevron.right", "Стих", "Следующий стих"),
        ("camera", "Снимок", "Сделать снимок экрана слайда"),
    };

    public readonly PushButton[] StepButtons;
    public readonly PushButton ShowButton = new("", "eye") { Prominent = true };
    public readonly PushButton HideButton = new("", "eye.slash");
    public readonly MacCheckBox ActiveBox = new("", 11, 12);
    readonly Border _separator = new();
    public readonly BottomThumbnail Template = new(), SlideBackground = new(), CommonBackground = new();

    public ControlPanel()
    {
        StepButtons = Steps.Select(s => new PushButton("", s.Symbol, ControlSize.Small) { FontSize = 10, SymbolSize = 9 }).ToArray();
        foreach (var b in StepButtons) Children.Add(b);
        Children.Add(ShowButton);
        Children.Add(HideButton);
        Children.Add(_separator);
        Children.Add(Template);
        Children.Add(SlideBackground);
        Children.Add(CommonBackground);
        Layout = Arrange;
        _separator.Background = Palette.Brush(Palette.Separator);
        Palette.Changed += () => _separator.Background = Palette.Brush(Palette.Separator);
        ApplyCaptions();
    }

    public void ApplyCaptions()
    {
        for (var i = 0; i < StepButtons.Length; i++)
        {
            StepButtons[i].Title = Captions.T(Steps[i].Title);
            ToolTip.SetTip(StepButtons[i], Captions.T(Steps[i].Hint));
        }
        ShowButton.Title = Captions.Caption("SBShowOutScr", "Показать");
        ToolTip.SetTip(ShowButton, Captions.MainHint("SBShowOutScr", "Показать слайд"));
        HideButton.Title = Captions.Caption("SBHideOutScr", "Скрыть");
        ToolTip.SetTip(HideButton, Captions.MainHint("SBHideOutScr", "Скрыть слайд"));
        ActiveBox.Title = Captions.T("Активная");
        ToolTip.SetTip(ActiveBox, Captions.T("Включено — стрелки и перелистывание сразу выводят слайд в зал. Выключено — стрелки только готовят слайд в предпросмотре, а в зал его выводят «Показать» или Enter."));
        _measuredKey = "";
        InvalidateArrange();
    }

    string _measuredKey = "";
    double[] _columns = { 68, 68, 68 };
    double _show = 108;

    (double[] Columns, double Show) Measured()
    {
        var key = string.Join("|", StepButtons.Select(b => b.Title).Append(ShowButton.Title).Append(HideButton.Title));
        if (key == _measuredKey) return (_columns, _show);
        var columns = new double[] { 56, 56, 56 };
        for (var i = 0; i < StepButtons.Length; i++)
            columns[i % 3] = Math.Max(columns[i % 3], Math.Ceiling(StepButtons[i].FittingWidth) + 2);
        double show = 96;
        foreach (var b in new[] { ShowButton, HideButton }) show = Math.Max(show, Math.Ceiling(b.FittingWidth) + 2);
        _columns = columns; _show = show; _measuredKey = key;
        return (columns, show);
    }

    /// Найменша ширина «Керування» — щоб кнопки й мініатюри не різалися.
    public double PreferredWidth
    {
        get
        {
            var (columns, show) = Measured();
            return Math.Max(BottomMetrics.ControlMinWidth, columns.Sum() + 3 * 2 + 8 + show);
        }
    }

    void Arrange(Size size)
    {
        var (columns, show) = Measured();
        const double gap = 3;
        for (var i = 0; i < StepButtons.Length; i++)
        {
            var column = i % 3;
            var line = i / 3;
            var x = columns.Take(column).Sum() + column * gap;
            Place(StepButtons[i], new Rect(x, line * (21 + gap), columns[column], 21));
        }
        var navWidth = columns.Sum() + gap * 2;
        Place(ShowButton, new Rect(navWidth + 8, 0, show, 21));
        Place(HideButton, new Rect(navWidth + 8, 24, show, 21));
        const double barY = 48;
        Place(_separator, new Rect(0, barY, size.Width, 1));
        var thumbY = barY + 6;
        var thumbs = new[] { Template, SlideBackground, CommonBackground };
        for (var i = 0; i < thumbs.Length; i++)
            Place(thumbs[i], new Rect(i * (BottomThumbnail.PictureSize.Width + 8), thumbY, BottomThumbnail.PictureSize.Width, BottomThumbnail.FullHeight));
    }
}
