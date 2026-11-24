// =============================================================================
//  BasicTab.cs — вкладка «Основні» (як NativeSettingsBasicTab на Mac)
// =============================================================================
//  Реакція на кнопки · Монітор для показу слайда (список моніторів + «Ручна
//  настройка», Лівий/Верх/Ширина/Висота, розташування й розмір, карта
//  моніторів, «☀» — показати, де цей монітор) · Розміри за умовчанням · Що
//  виводити на передній план · Мінімальний відсоток заповнення сторінки й частота
//  анімації. Координати — як у первісного VisioBible: від лівого верхнього кута
//  головного монітора, у пікселях (на Windows так і є).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Platform;
using Slovo.Core;

namespace Slovo.App;

public sealed class BasicTab
{
    readonly SettingsStore _store;
    readonly TextBlock _connection = Form.Label(""), _placement = Form.Label("", false);
    readonly MonitorMap _map = new() { Width = 480, Height = 96 };
    readonly List<FormField> _manual = new();

    public BasicTab(SettingsStore store) { _store = store; }
    static string Vb(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback);
    ProgramOptions O => _store.Settings.Options;
    static IReadOnlyList<Screen> Screens => MainWindow.Shared?.Screens.All ?? Array.Empty<Screen>();

    public static string ScreenTitle(Screen screen, int index)
    {
        var name = screen.DisplayName is { Length: > 0 } n ? n : Captions.T("Монитор");
        return $"{index + 1}. {name} ({screen.Bounds.Width} x {screen.Bounds.Height})";
    }

    public Control Page()
    {
        var page = new Form.Page(new[] { ButtonAction(), Monitor(), Sizes(), Foreground(), PageAndAnimation() });
        Refresh();
        return page;
    }

    Form.Group ButtonAction() => new(Vb("RGButAction", "Реакция на кнопки:"), new Control[]
    {
        new Form.Row("", new[] { Form.Choice(new[] { Vb("RGButAction->Item0", "По нажатию"), Vb("RGButAction->Item1", "По отпусканию") },
            new Tie<int>(() => O.ButtonAction == Core.ButtonAction.OnPress ? 0 : 1, v => O.ButtonAction = v == 0 ? Core.ButtonAction.OnPress : Core.ButtonAction.OnRelease)) }),
    });

    Tie<int> Int(Func<int> get, Action<int> set) => new(get, v => { set(v); Refresh(); });

    Form.Group Monitor()
    {
        var titles = new[] { Vb("TextMessages25", "Ручная настройка") }.Concat(Screens.Select(ScreenTitle)).ToList();
        _manual.Clear();
        _manual.Add(Form.Number(Int(() => O.CustomLeft, v => O.CustomLeft = v), -20000, 20000, 70));
        _manual.Add(Form.Number(Int(() => O.CustomTop, v => O.CustomTop = v), -20000, 20000, 70));
        _manual.Add(Form.Number(Int(() => O.CustomWidth, v => O.CustomWidth = v), 1, 20000, 70));
        _manual.Add(Form.Number(Int(() => O.CustomHeight, v => O.CustomHeight = v), 1, 20000, 70));
        var flash = Form.Button("☀", Captions.FormHint("PSBMainSlideWin", "SettingsForm") ?? Captions.T("Показать позицию дисплея"), Flash);
        flash.Symbol = "sun.max"; flash.Title = ""; flash.Width = 30;
        return new Form.Group(Vb("GroupBox1", "Монитор для отображения слайда:"), new Control[]
        {
            new Form.Row(Vb("Label3", "Монитор:"), new Control[]
            {
                Form.Popup(titles, Int(() => O.MonitorIndex, v => O.MonitorIndex = v), 320), _connection, flash,
            }, 110),
            new Form.Row(Vb("Label40", "Левый:") + " / " + Vb("Label42", "Верх:") + " / " + Vb("Label41", "Ширина:") + " / " + Vb("Label43", "Высота:"),
                         _manual, 300),
            new Form.Row(Vb("Label4", Captions.T("Расположение:")) + " / " + Vb("Label5", Captions.T("Размер:")), new Control[] { _placement }, 300),
            new Form.Row("", new Control[] { _map }),
        });
    }

    Form.Group Sizes() => new(Vb("GroupBox2", Captions.T("Размеры по умолчанию")), new Control[]
    {
        new Form.Row(Vb("Label7", "Ширина:"), new[] { Form.Number(Int(() => O.DefaultWidth, v => O.DefaultWidth = v), 1, 20000) }, 110),
        new Form.Row(Vb("Label8", "Высота:"), new[] { Form.Number(Int(() => O.DefaultHeight, v => O.DefaultHeight = v), 1, 20000) }, 110),
    });

    Form.Group Foreground() => new(Vb("Label9", "При показе слайда") + " " + Vb("RGForeground", "на передний план"), new Control[]
    {
        new Form.Row("", new[] { Form.Choice(new[] { Vb("RGForeground->Item0", "Главное окно"), Vb("RGForeground->Item1", "Окно слайда") },
            new Tie<int>(() => O.Foreground == Core.Foreground.MainWindow ? 0 : 1, v => O.Foreground = v == 0 ? Core.Foreground.MainWindow : Core.Foreground.SlideWindow)) }),
    });

    Form.Group PageAndAnimation() => new("", new Control[]
    {
        new Form.Row(Vb("Label6", Captions.T("Минимальный процент заполнения для создания новой страницы:")), new Control[]
        {
            Form.Number(Int(() => O.PercentFillingPage, v => O.PercentFillingPage = v), 0, 100, 56), Form.Label(Vb("Label10", "%")),
        }, 340),
        new Form.Row(Vb("Label11", "Частота обновления анимации:"), new Control[]
        {
            Form.Number(Int(() => O.AnimationFrequency, v => O.AnimationFrequency = v), 1, 240, 56), Form.Label(Vb("Label12", "Герц")),
        }, 340),
    });

    Screen? Selected
    {
        get
        {
            var i = O.MonitorIndex - 1;
            return i >= 0 && i < Screens.Count ? Screens[i] : null;
        }
    }

    void Refresh()
    {
        var manual = O.MonitorIndex == 0;
        foreach (var f in _manual) f.IsEnabled = manual;
        _connection.Foreground = Palette.Brush(Palette.SecondaryLabel);
        if (manual) _connection.Text = Vb("TextMessages25", "Ручная настройка");
        else if (Selected is { } screen)
            _connection.Text = screen.IsPrimary ? Vb("TextMessages2", "Основной") : Vb("TextMessages3", "Не основной");
        else
        {
            _connection.Text = Vb("TextMessages26", "Не подключен");
            _connection.Foreground = Palette.Brush(Palette.SystemOrange);
        }
        _placement.Text = Selected is { } s
            ? $"{s.Bounds.X}, {s.Bounds.Y}   {s.Bounds.Width} x {s.Bounds.Height}"
            : $"{O.CustomLeft}, {O.CustomTop}   {O.DefaultWidth} x {O.DefaultHeight}";
        _map.Selected = O.MonitorIndex - 1;
        _map.InvalidateVisual();
    }

    void Flash()
    {
        if (Selected is { } s) MonitorFlash.Show(s.Bounds.X, s.Bounds.Y, s.Bounds.Width, s.Bounds.Height);
        else MonitorFlash.Show(O.CustomLeft, O.CustomTop, O.CustomWidth, O.CustomHeight);
    }

    /// Карта моніторів: прямокутники в масштабі, вибраний — кольором акценту.
    sealed class MonitorMap : Control
    {
        public int Selected = -1;
        public override void Render(DrawingContext g)
        {
            var screens = Screens;
            if (screens.Count == 0) return;
            var x0 = screens.Min(s => s.Bounds.X); var y0 = screens.Min(s => s.Bounds.Y);
            var x1 = screens.Max(s => s.Bounds.Right); var y1 = screens.Max(s => s.Bounds.Bottom);
            double uw = x1 - x0, uh = y1 - y0;
            if (uw <= 0 || uh <= 0) return;
            var scale = Math.Min(Bounds.Width / uw, Bounds.Height / uh) * 0.92;
            var ox = (Bounds.Width - uw * scale) / 2; var oy = (Bounds.Height - uh * scale) / 2;
            for (var i = 0; i < screens.Count; i++)
            {
                var f = screens[i].Bounds;
                var rect = new Rect((f.X - x0) * scale + ox, (f.Y - y0) * scale + oy, Math.Max(f.Width * scale, 1), Math.Max(f.Height * scale, 1));
                g.DrawRectangle(Palette.Brush(i == Selected ? Palette.Accent.WithAlpha(0.3) : Color.FromArgb(38, 128, 128, 128)),
                                new Pen(Palette.Brush(Palette.Separator), 1), rect, 3, 3);
                var lines = new[] { (i + 1).ToString(), $"{f.X}, {f.Y}", $"{f.Width} x {f.Height}" };
                var sizes = new[] { 11.0, 8.0, 8.0 };
                var top = rect.Center.Y - 20;
                for (var k = 0; k < 3; k++)
                {
                    TextDraw.Draw(g, lines[k], new Rect(rect.X, top, rect.Width, sizes[k] + 4), sizes[k], Palette.SecondaryLabel,
                                  k == 0 ? FontWeight.Bold : FontWeight.Normal, TextAlignment.Center, wrap: false);
                    top += sizes[k] + 3;
                }
            }
        }
    }
}

/// Показати, де монітор: напівпрозоре вікно з рамкою на 1,5 с (як SettingsMonitorFlash).
public static class MonitorFlash
{
    public static void Show(int left, int top, int width, int height)
    {
        var window = new Window
        {
            SystemDecorations = SystemDecorations.None, Topmost = true, ShowInTaskbar = false, ShowActivated = false,
            Background = new SolidColorBrush(Color.FromArgb(110, 0, 122, 255)),
            WindowStartupLocation = WindowStartupLocation.Manual, Position = new PixelPoint(left, top),
            TransparencyLevelHint = new[] { WindowTransparencyLevel.Transparent },
        };
        var scale = MainWindow.Shared?.Screens.ScreenFromPoint(new PixelPoint(left + 1, top + 1))?.Scaling ?? 1;
        window.Width = Math.Max(40, width / scale);
        window.Height = Math.Max(40, height / scale);
        window.Content = new Border { BorderBrush = Brushes.White, BorderThickness = new Thickness(6) };
        window.Show();
        Avalonia.Threading.DispatcherTimer.RunOnce(window.Close, TimeSpan.FromSeconds(1.5));
    }
}
