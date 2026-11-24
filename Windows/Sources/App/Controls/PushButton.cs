// =============================================================================
//  PushButton.cs — кнопка у вигляді «Слова» на Mac
// =============================================================================
//  Округла кнопка: біла (у темній темі сіра #656565) з тонким обідком і тінню;
//  «головна» (Показати) — кольору акценту з білим текстом. Розміри як у
//  AppKit: звичайна — обідок 20 у рамці 21, мала — 16, найменша — 13.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;

namespace Slovo.App;

public enum ControlSize { Regular, Small, Mini }

public sealed class PushButton : Control
{
    protected override void OnPropertyChanged(Avalonia.AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        // Свій малюнок: стан «доступна/ні» міняє вигляд — перемалювати.
        if (change.Property == IsEffectivelyEnabledProperty) InvalidateVisual();
    }

    string _title = "";
    public string Title { get => _title; set { if (_title == value) return; _title = value; InvalidateMeasure(); InvalidateVisual(); } }
    public string? Symbol { get; set; }
    /// Розмір значка (на Mac — кегль символу).
    public double SymbolSize { get; set; }
    public ControlSize Size { get; set; } = ControlSize.Regular;
    /// Кегль підпису; 0 — за розміром кнопки (13 / 11 / 9).
    public double FontSize { get; set; }
    /// Насиченість підпису (тон фонограми на Mac — medium і semibold).
    public FontWeight Weight { get; set; } = FontWeight.Normal;
    /// Головна кнопка — колір акценту, білий текст.
    public bool Prominent { get; set; }
    public bool Bordered { get; set; } = true;
    public bool IsOn { get; set; }
    /// Колір підпису й значка (як `contentTintColor` у NSButton); null — звичайний.
    public Func<Color>? TitleTint { get; set; }
    /// Вимкнена кнопка лишає свій колір, лише блідіший — як кольорові знаки (🌐, 🔑)
    /// на вимкнених кнопках Mac: емодзі не сіріють.
    public bool TintsWhenDisabled { get; set; }
    /// Зсув вмісту від середини (значок кнопки, що випадає, — лівіше, праворуч шеврон).
    public double ContentOffset { get; set; }
    public Action? Pressed;

    bool _down, _inside;

    public PushButton(string title = "", string? symbol = null, ControlSize size = ControlSize.Regular)
    {
        _title = title;
        Symbol = symbol;
        Size = size;
        Focusable = true;
        Palette.Changed += InvalidateVisual;
    }

    double TextSize => FontSize > 0 ? FontSize : Size switch { ControlSize.Small => 11, ControlSize.Mini => 9, _ => 13 };
    double IconSize => SymbolSize > 0 ? SymbolSize : Size switch { ControlSize.Small => 9, ControlSize.Mini => 8, _ => 12 };
    double BezelHeight => Size switch { ControlSize.Small => 16, ControlSize.Mini => 13, _ => 20 };
    double Radius => Size switch { ControlSize.Small => 4, ControlSize.Mini => 3, _ => 5 };
    double Pad => Size switch { ControlSize.Small => 8, ControlSize.Mini => 6, _ => 12 };
    /// Прозоре поле між краєм кнопки AppKit і її рамкою (виміряно: між сусідніми
    /// кнопками з кроком 3 видно 15 точок). Розкладки Mac рахують рамки кнопок
    /// разом із цим полем — тому й ми малюємо рамку всередині нього.
    public double Margin { get => _margin ?? (Size == ControlSize.Mini ? 5 : 6); set => _margin = value; }
    double? _margin;

    /// Ширина за вмістом — як `fittingSize` кнопки AppKit.
    public double FittingWidth
    {
        get
        {
            var text = _title.Length > 0 ? UiFont.Width(_title, TextSize, Weight) : 0;
            var icon = Symbol != null ? IconSize + (text > 0 ? 4 : 0) : 0;
            // NSButton.fittingSize включає прозорі поля довкола рамки (Margin з кожного боку).
            return Math.Ceiling(Pad * 2 + icon + text + 2 * Margin);
        }
    }

    protected override Size MeasureOverride(Size available) => new(FittingWidth, Size switch { ControlSize.Small => 19, ControlSize.Mini => 16, _ => 21 });

    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size);
        var dark = Palette.IsDark;
        var enabled = IsEffectivelyEnabled;
        var bh = Math.Min(b.Height - 1, BezelHeight);
        var bezel = new Rect(Margin, Math.Round((b.Height - bh) / 2), Math.Max(0, b.Width - 2 * Margin), bh);
        Color face, text;
        if (Prominent && enabled)
        {
            face = _down && _inside ? Palette.Accent.WithAlpha(0.8) : Palette.Accent;
            text = Colors.White;
        }
        else
        {
            face = dark ? Color.FromRgb(0x65, 0x65, 0x65) : Colors.White;
            if (!enabled) face = dark ? Color.FromRgb(0x5A, 0x5A, 0x5A) : Color.FromRgb(0xF6, 0xF6, 0xF6);
            if (_down && _inside) face = dark ? Color.FromRgb(0x7A, 0x7A, 0x7A) : Color.FromRgb(0xE3, 0xE3, 0xE3);
            if (IsOn) face = dark ? Color.FromRgb(0x80, 0x80, 0x80) : Color.FromRgb(0xDC, 0xDC, 0xDC);
            text = enabled ? TitleTint?.Invoke() ?? Palette.Label
                 : TintsWhenDisabled && TitleTint != null ? TitleTint().WithAlpha(0.45) : Palette.DisabledText;
        }
        if (Bordered)
        {
            // Тінь знизу й тонкий обідок — як у кнопки macOS 11+.
            g.DrawRectangle(Palette.Brush(Color.FromArgb(dark ? (byte)70 : (byte)38, 0, 0, 0)), null,
                            bezel.Translate(new Vector(0, 0.5)), Radius, Radius);
            g.DrawRectangle(Palette.Brush(face),
                            new Pen(Palette.Brush(dark ? Color.FromArgb(25, 255, 255, 255) : Color.FromArgb(30, 0, 0, 0)), 0.5),
                            bezel.Deflate(0.25), Radius, Radius);
        }
        else if (_down && _inside)
        {
            g.DrawRectangle(Palette.Brush(Palette.QuaternaryLabel), null, bezel, Radius, Radius);
        }
        // Вміст: значок і підпис по центру.
        var textWidth = _title.Length > 0 ? UiFont.Width(_title, TextSize, Weight) : 0;
        var iconWidth = Symbol != null ? IconSize : 0;
        var gap = Symbol != null && textWidth > 0 ? 4 : 0;
        var total = iconWidth + gap + textWidth;
        var x = bezel.X + Math.Max(0, (bezel.Width - total) / 2) + ContentOffset;
        if (Symbol != null)
        {
            Icons.Draw(g, Symbol, new Rect(x, bezel.Center.Y - IconSize / 2, IconSize, IconSize), text, 1.1);
            x += iconWidth + gap;
        }
        if (textWidth > 0)
        {
            var lh = UiFont.LineHeight(TextSize);
            TextDraw.Draw(g, _title, new Rect(x, Math.Round(bezel.Center.Y - lh / 2), Math.Min(textWidth + 1, bezel.Right - x), lh),
                          TextSize, text, Weight, wrap: false, trim: true);
        }
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        _down = _inside = true;
        e.Pointer.Capture(this);
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        if (!_down) return;
        var inside = new Rect(Bounds.Size).Contains(e.GetPosition(this));
        if (inside != _inside) { _inside = inside; InvalidateVisual(); }
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        if (!_down) return;
        var fire = _inside;
        _down = _inside = false;
        e.Pointer.Capture(null);
        InvalidateVisual();
        if (fire && IsEffectivelyEnabled) Pressed?.Invoke();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (e.Key is Key.Space or Key.Enter && IsEffectivelyEnabled) { Pressed?.Invoke(); e.Handled = true; return; }
        base.OnKeyDown(e);
    }

    /// Натиснути кодом (пульт, перевірки).
    public void PerformClick() { if (IsEffectivelyEnabled) Pressed?.Invoke(); }
}

/// Кнопка-значок без рамки (тека даних, кнопки над колонками).
public sealed class IconButton : Control
{
    protected override void OnPropertyChanged(Avalonia.AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);
        // Свій малюнок: стан «доступна/ні» міняє вигляд — перемалювати.
        if (change.Property == IsEffectivelyEnabledProperty) InvalidateVisual();
    }

    public string Symbol { get; set; }
    public double SymbolSize { get; set; } = 14;
    public Func<Color> Tint { get; set; } = () => Palette.SecondaryLabel;
    /// Увімкнений перемикач — підкладка кольору акценту, значок білий.
    public bool IsOn { get; set; }
    public Action? Pressed;
    bool _down;

    public IconButton(string symbol, double symbolSize = 14)
    {
        Symbol = symbol;
        SymbolSize = symbolSize;
        Palette.Changed += InvalidateVisual;
    }

    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size);
        g.FillRectangle(Brushes.Transparent, b);
        if (IsOn) g.DrawRectangle(Palette.Brush(Palette.Selection), null, b, 4, 4);
        else if (_down) g.DrawRectangle(Palette.Brush(Palette.QuaternaryLabel), null, b, 4, 4);
        var color = IsOn ? Colors.White : (IsEffectivelyEnabled ? Tint() : Palette.DisabledText);
        Icons.Draw(g, Symbol, new Rect(b.Center.X - SymbolSize / 2, b.Center.Y - SymbolSize / 2, SymbolSize, SymbolSize), color);
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        _down = true; e.Pointer.Capture(this); InvalidateVisual(); e.Handled = true;
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        if (!_down) return;
        _down = false; e.Pointer.Capture(null); InvalidateVisual();
        if (new Rect(Bounds.Size).Contains(e.GetPosition(this)) && IsEffectivelyEnabled) Pressed?.Invoke();
    }
}
