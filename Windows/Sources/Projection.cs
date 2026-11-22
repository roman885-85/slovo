// =============================================================================
//  Projection.cs — вікно слайда: на проекторі або звичайним вікном
// =============================================================================
//  Як ProjectionController на Mac: без рамки на весь вибраний монітор, поверх
//  усього; коли монітор один — звичайне вікно «Вікно слайда» 16:9, щоб було
//  чим керувати програмою. Кадр малює SlideRenderer; зміна слайда й гасіння —
//  розчиненням між двома кадрами (власник: «при отключении слайда выполнять
//  плавное затухание, а не резкое отключение»).
// =============================================================================

using System;
using System.Linq;
using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using SkiaSharp;

namespace Slovo;

public static class Bitmaps
{
    /// SkiaSharp → Avalonia: копія пікселів у Bitmap.
    public static Bitmap ToAvalonia(SKBitmap bitmap) =>
        new(PixelFormat.Bgra8888, AlphaFormat.Premul, bitmap.GetPixels(), new PixelSize(bitmap.Width, bitmap.Height), new Vector(96, 96), bitmap.RowBytes);

    public static Bitmap Render(RenderOrder order, int width, int height)
    {
        using var skia = SlideRenderer.Render(order, width, height);
        return ToAvalonia(skia);
    }
}

public sealed class ProjectionWindow : Window
{
    readonly Image _back = new() { Stretch = Stretch.Fill };
    readonly Image _front = new() { Stretch = Stretch.Fill };
    readonly Ellipse _pointer = new() { IsVisible = false, IsHitTestVisible = false };
    readonly Canvas _overlay = new();
    public bool HiddenByHand { get; set; }
    public event Action? ClosedByHand;

    public ProjectionWindow(bool framed)
    {
        Background = Brushes.Black;
        ShowInTaskbar = framed;
        CanResize = framed;
        Topmost = true;
        ShowActivated = false;
        Title = Lang.T("Вікно слайда", "Slide window");
        if (!framed)
        {
            SystemDecorations = SystemDecorations.None;
            WindowStartupLocation = WindowStartupLocation.Manual;
        }
        _front.Transitions = new Transitions { new DoubleTransition { Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(350), Easing = new QuadraticEaseInOut() } };
        var grid = new Grid { Background = Brushes.Black };
        grid.Children.Add(_back);
        grid.Children.Add(_front);
        _overlay.Children.Add(_pointer);
        grid.Children.Add(_overlay);
        Content = grid;
        Closing += (_, e) =>
        {
            // Хрестик ховає вікно, а не закриває: показ у залі живе далі.
            if (framed && !_allowClose) { e.Cancel = true; HiddenByHand = true; Hide(); ClosedByHand?.Invoke(); }
        };
    }

    bool _allowClose;

    public void CloseForReal() { _allowClose = true; Close(); }

    /// Новий кадр — розчиненням за `seconds`; нуль — разом.
    public void Present(Bitmap frame, double seconds, string easing = "easeInOut")
    {
        var previous = _front.Source as Bitmap;
        _back.Source = previous;
        _front.Transitions![0] = new DoubleTransition
        {
            Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(Math.Max(0, seconds * 1000)),
            Easing = easing switch { "linear" => new LinearEasing(), "easeOut" => new QuadraticEaseOut(), "spring" => new BackEaseOut(), _ => new QuadraticEaseInOut() },
        };
        // Спершу прозорий новий кадр без переходу, потім — плавно до одиниці.
        _front.Transitions = null;
        _front.Opacity = 0;
        _front.Source = frame;
        Dispatcher.UIThread.Post(() =>
        {
            _front.Transitions = new Transitions
            {
                new DoubleTransition
                {
                    Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(Math.Max(0, seconds * 1000)),
                    Easing = easing switch { "linear" => new LinearEasing(), "easeOut" => new QuadraticEaseOut(), "spring" => new BackEaseOut(), _ => new QuadraticEaseInOut() },
                },
            };
            _front.Opacity = 1;
        }, DispatcherPriority.Render);
    }

    public void ShowPointer(bool on, double x, double y, RGBA colour, double size, double opacity)
    {
        _pointer.IsVisible = on;
        if (!on) return;
        var w = _overlay.Bounds.Width;
        var h = _overlay.Bounds.Height;
        if (w <= 0 || h <= 0) return;
        var radius = Math.Max(2, size * h / 2);
        _pointer.Width = radius * 2;
        _pointer.Height = radius * 2;
        var color = Color.FromArgb((byte)Math.Round(Math.Clamp(opacity, 0, 1) * 255), (byte)Math.Round(colour.R * 255), (byte)Math.Round(colour.G * 255), (byte)Math.Round(colour.B * 255));
        _pointer.Fill = new SolidColorBrush(color);
        _pointer.Stroke = new SolidColorBrush(Color.FromArgb((byte)Math.Round(Math.Clamp(opacity + 0.4, 0, 1) * 255), color.R, color.G, color.B));
        _pointer.StrokeThickness = Math.Max(1.5, radius * 0.08);
        Canvas.SetLeft(_pointer, x * w - radius);
        Canvas.SetTop(_pointer, y * h - radius);
    }
}

/// Господар вікна слайда: будує його за налаштуваннями й подає кадри.
public sealed class ProjectionController
{
    readonly AppState _state;
    readonly Window _owner;
    ProjectionWindow? _window;
    bool _framed;
    string _screensSignature = "";
    public bool IsVisible { get; private set; }
    public event Action? Changed;

    public ProjectionController(AppState state, Window owner)
    {
        _state = state;
        _owner = owner;
        state.Changed += change =>
        {
            if (change is Change.Live or Change.Settings) Refresh(change == Change.Live);
            if (change == Change.Pointer) ApplyPointer();
        };
    }

    public ProjectionWindow? Window => _window;
    public bool IsFramed => _framed;

    public void SetVisible(bool visible)
    {
        if (visible == IsVisible && (_window != null || !visible)) return;
        IsVisible = visible;
        if (visible) Rebuild(); else CloseWindow();
        Changed?.Invoke();
    }

    public void Toggle() => SetVisible(!IsVisible);

    /// Екрани, як їх бачить програма.
    public string ScreenSignature()
    {
        var screens = _owner.Screens.All;
        return string.Join(";", screens.Select(s => s.Bounds.X + "," + s.Bounds.Y + "," + s.Bounds.Width + "x" + s.Bounds.Height + "×" + s.Scaling));
    }

    /// Перебудувати, якщо екрани справді змінилися.
    public void RebuildIfScreensChanged()
    {
        var now = ScreenSignature();
        if (now == _screensSignature || !IsVisible) return;
        Paths.Say("проектор: екрани змінилися — перебудовую вікно слайда");
        Rebuild();
    }

    Screen? PreferredScreen()
    {
        var screens = _owner.Screens.All;
        if (screens.Count == 0) return null;
        var index = _state.Settings.MonitorIndex - 1;
        if (_state.Settings.MonitorIndex > 0 && index < screens.Count) return screens[index];
        var mine = _owner.Screens.ScreenFromWindow(_owner) ?? _owner.Screens.Primary;
        return screens.FirstOrDefault(s => !ReferenceEquals(s, mine) && !s.Bounds.Equals(mine?.Bounds ?? default)) ?? mine ?? screens[0];
    }

    void Rebuild()
    {
        CloseWindow();
        _screensSignature = ScreenSignature();
        var settings = _state.Settings;
        var screens = _owner.Screens.All;
        var screen = PreferredScreen();
        if (screen == null) return;
        var monitorMissing = settings.MonitorIndex > 0 && settings.MonitorIndex - 1 >= screens.Count;
        _framed = !settings.ManualPlacement && (screens.Count < 2 || monitorMissing);
        // Перевірка повноекранного вікна на машині з одним монітором (ВМ): змінна середовища
        // SLOVO_SLIDE_FULLSCREEN=1 ставить слайд без рамки на весь єдиний екран.
        if (_framed && !monitorMissing && Environment.GetEnvironmentVariable("SLOVO_SLIDE_FULLSCREEN") == "1") _framed = false;
        var window = new ProjectionWindow(_framed);
        window.ClosedByHand += () => { Changed?.Invoke(); };
        if (settings.ManualPlacement)
        {
            window.Position = new PixelPoint(settings.CustomLeft, settings.CustomTop);
            var scale = screen.Scaling;
            window.Width = Math.Max(160, settings.CustomWidth / scale);
            window.Height = Math.Max(90, settings.CustomHeight / scale);
        }
        else if (_framed)
        {
            var work = screen.WorkingArea;
            var scale = screen.Scaling;
            double width = monitorMissing ? settings.DefaultWidth / scale : Math.Min(work.Width / scale * 0.5, 960);
            double height = monitorMissing ? settings.DefaultHeight / scale : Math.Round(width / 16 * 9);
            window.Width = width;
            window.Height = height;
            window.Position = new PixelPoint((int)(work.Right - width * scale - 40 * scale), (int)(work.Y + 40 * scale));
            window.Topmost = true;
        }
        else
        {
            var bounds = screen.Bounds;
            window.Position = new PixelPoint(bounds.X, bounds.Y);
            window.Width = bounds.Width / screen.Scaling;
            window.Height = bounds.Height / screen.Scaling;
        }
        _window = window;
        window.Show();
        if (!_framed && !settings.ManualPlacement)
        {
            // Повний екран саме на тому моніторі, де стоїть вікно. Ручна настройка
            // лишається вікном без рамки за своїми координатами й розміром.
            window.WindowState = WindowState.FullScreen;
        }
        Dispatcher.UIThread.Post(() => { Refresh(false); ApplyPointer(); }, DispatcherPriority.Background);
    }

    void CloseWindow()
    {
        if (_window == null) return;
        Paths.Say("проектор: вікно слайда прибрано");
        _window.CloseForReal();
        _window = null;
    }

    (int Width, int Height) FrameSize()
    {
        if (_window == null) return (1920, 1080);
        var scale = _window.RenderScaling;
        var width = (int)Math.Round(Math.Max(16, _window.ClientSize.Width) * scale);
        var height = (int)Math.Round(Math.Max(9, _window.ClientSize.Height) * scale);
        if (width <= 0 || height <= 0) return (1920, 1080);
        return (width, height);
    }

    bool _wasLive;

    /// Намалювати зал і подати в вікно.
    public void Refresh(bool animated)
    {
        var window = _window;
        if (window == null) return;
        var (width, height) = FrameSize();
        var order = _state.HallOrder();
        var frame = Bitmaps.Render(order, width, height);
        var settings = _state.Settings;
        var seconds = 0.0;
        var easing = "easeInOut";
        if (animated)
        {
            var live = _state.IsLive && !_state.IsBlackout && !_state.IsTextHidden;
            if (live) { seconds = settings.ShowTransition == "none" ? 0 : settings.ShowTransitionSeconds; }
            else { seconds = settings.HideFadeSeconds; easing = settings.HideFadeEasing; }
            _wasLive = live;
        }
        window.Present(frame, seconds, easing);
        // Сховане рукою вікно вертається саме: у зал пішов слайд.
        if (window.HiddenByHand && _state.IsLive && !_state.LiveSlide.IsBlank)
        {
            window.HiddenByHand = false;
            window.Show();
            Changed?.Invoke();
        }
    }

    void ApplyPointer()
    {
        var window = _window;
        if (window == null) return;
        var s = _state;
        window.ShowPointer(s.PointerOn, s.PointerX, s.PointerY, RGBA.FromHex(s.PointerColour ?? s.Settings.PointerColour) ?? RGBA.Gold,
                           s.PointerSizeOverride ?? s.Settings.PointerSize, s.PointerOpacityOverride ?? s.Settings.PointerOpacity);
    }
}
