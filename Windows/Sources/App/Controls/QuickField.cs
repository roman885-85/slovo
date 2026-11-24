// =============================================================================
//  QuickField.cs — поле швидкого вводу під колонками (як NativeQuickField)
// =============================================================================
//  Округлий прямокутник (кут 3), обідок другорядного кольору 35 % (у фокусі —
//  60 %), текст 11 пт; «не знайдено» — червоний обідок 2. Свій вигляд замість
//  поля Windows: те саме, що на знімках Mac.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;

namespace Slovo.App;

public class QuickField : LayoutPanel
{
    public static double FieldHeight = 19;
    public readonly TextBox Box;
    readonly Frame _frame;
    bool _setting;
    bool _rejected;

    public Action<string>? OnChange;
    public Action<string>? OnSubmit;
    public Action<bool>? OnFocus;
    public Func<Color>? ActiveFill;
    public Func<Color>? ActiveText;

    public QuickField(double fontSize = 11)
    {
        _frame = new Frame(this);
        Box = new TextBox
        {
            FontSize = fontSize,
            Padding = new Thickness(0),
            MinHeight = 0,
            // Тема Fluent ставить полю мінімум 64 точки: вузьке числове поле вилазило праворуч.
            MinWidth = 0,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            VerticalContentAlignment = Avalonia.Layout.VerticalAlignment.Center,
            AcceptsReturn = false,
            TextWrapping = TextWrapping.NoWrap,
            FontFamily = UiFont.Family,
        };
        Children.Add(_frame);
        Children.Add(Box);
        // TextChanging, а не TextChanged: TextChanged Avalonia шле через чергу, уже після
        // того, як `_setting` знято, — і текст, поставлений програмою (вибір рядка, очищення),
        // повертався в OnChange як набраний людиною (у «Перекладі» вибір рядка позначав
        // переклад зміненим, швидкий вибір пісні чи частини міг стрибнути). TextChanging
        // приходить одразу, коли Text уже новий.
        Box.TextChanging += (_, _) =>
        {
            if (_setting) return;
            IsRejected = false;
            OnChange?.Invoke(Box.Text ?? "");
        };
        Box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) { OnSubmit?.Invoke(Box.Text ?? ""); e.Handled = true; }
        };
        Box.GotFocus += (_, _) => { _frame.InvalidateVisual(); ApplyTextColor(); OnFocus?.Invoke(true); };
        Box.LostFocus += (_, _) => { _frame.InvalidateVisual(); ApplyTextColor(); OnFocus?.Invoke(false); };
        Palette.Changed += () => { _frame.InvalidateVisual(); ApplyTextColor(); };
        ApplyTextColor();
    }

    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        // Свій малюнок рамки: стан «доступне/ні» міняє вигляд — перемалювати.
        if (change.Property == IsEffectivelyEnabledProperty) _frame.InvalidateVisual();
    }

    public string Placeholder { get => Box.Watermark ?? ""; set => Box.Watermark = value; }

    public string Text
    {
        get => Box.Text ?? "";
        set
        {
            if ((Box.Text ?? "") == value) return;
            _setting = true;
            Box.Text = value;
            _setting = false;
        }
    }

    public bool IsRejected { get => _rejected; set { if (_rejected == value) return; _rejected = value; _frame.InvalidateVisual(); } }
    public bool IsFocusedField => Box.IsFocused;
    public void FocusField() { if (!Box.IsFocused && IsEffectivelyVisible) Box.Focus(); }

    void ApplyTextColor()
    {
        var focused = Box.IsFocused;
        Box.Foreground = Palette.Brush(focused && ActiveText != null ? ActiveText() : Palette.Label);
    }

    protected override Size Desired(Size available) => new(0, FieldHeight);

    protected override void Arrangement(Size size)
    {
        Place(_frame, new Rect(size));
        var h = Math.Ceiling(Box.FontSize) + 6;
        Place(Box, new Rect(4, (size.Height - h) / 2, Math.Max(0, size.Width - 8), h));
    }

    sealed class Frame : Control
    {
        readonly QuickField _field;
        public Frame(QuickField field) { _field = field; }
        public override void Render(DrawingContext g)
        {
            var focused = _field.Box.IsFocused;
            var b = new Rect(Bounds.Size).Deflate(0.5);
            var fill = focused && _field.ActiveFill != null ? _field.ActiveFill() : Palette.TextBackground;
            if (!_field.IsEffectivelyEnabled)
            {
                // Вимкнене поле Mac: бліда заливка й світлий обідок (#F6F6F6 / #E8E8E8 на знімку).
                g.DrawRectangle(Palette.Brush(Palette.IsDark ? Color.FromRgb(0x2A, 0x2A, 0x2A) : Color.FromRgb(0xF6, 0xF6, 0xF6)),
                                new Pen(Palette.Brush(Palette.IsDark ? Color.FromArgb(20, 255, 255, 255) : Color.FromRgb(0xE8, 0xE8, 0xE8)), 1), b, 3, 3);
                return;
            }
            var pen = _field._rejected
                ? new Pen(Palette.Brush(Palette.SystemRed), 2)
                : new Pen(Palette.Brush(Palette.SecondaryLabel.WithAlpha(focused ? 0.6 : 0.35)), 1);
            g.DrawRectangle(Palette.Brush(fill), pen, b, 3, 3);
        }
    }
}
