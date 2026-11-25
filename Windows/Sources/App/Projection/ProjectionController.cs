// =============================================================================
//  ProjectionController.cs — вікно слайда для залу
// =============================================================================
//  Як ProjectionController на Mac:
//  • моніторів два й більше — без рамки на весь вибраний монітор (за умовчанням
//    — не той, де головне вікно), поверх усього, мишею не ловиться;
//  • монітор один — звичайне вікно «Вікно слайда» 16:9 праворуч угорі (ширина —
//    половина робочої області, не більше 960), поверх інших; хрестик НЕ закриває,
//    а ховає — вікно вертається само з наступним слайдом у залі;
//  • ручна настройка («Ліво, Верх, Ширина, Висота») — без рамки саме там і такого
//    розміру (координати — як у первісного VisioBible: від лівого верхнього кута);
//  • вибраного монітора немає — вікно розміром із «Параметрів».
//  Екрани змінилися (під'єднали проектор) — вікно перебудовується.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Platform;
using Avalonia.Threading;
using SkiaSharp;

namespace Slovo.App;

/// Де стоїть слайд: монітор за номером (і розмір вікна, якщо його немає) або вручну.
public abstract record SlidePlacementChoice
{
    public sealed record Monitor(int Number, int Width, int Height) : SlidePlacementChoice;
    public sealed record Manual(int Left, int Top, int Width, int Height) : SlidePlacementChoice;
}

public sealed class ProjectionController
{
    public static readonly ProjectionController Shared = new();

    Window? _window;
    SlideSurface? _surface;
    string _builtScreens = "";
    bool _hiddenByHand;
    readonly DispatcherTimer _screenWatch;

    public bool IsVisible { get; private set; }
    public SlidePlacementChoice? Placement { get; private set; }
    public event Action? Changed;

    ProjectionController()
    {
        // Сповіщення про зміну екранів у Windows приходять не завжди —
        // звіряємо підпис екранів раз на дві секунди.
        _screenWatch = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) => RebuildIfScreensChanged());
    }

    static Screens? AllScreens => MainWindow.Shared?.Screens;

    public static string ScreenSignature()
    {
        var screens = AllScreens?.All;
        if (screens == null) return "";
        return string.Join(";", screens.Select(s => $"{s.Bounds.X},{s.Bounds.Y},{s.Bounds.Width}x{s.Bounds.Height}×{s.Scaling}"));
    }

    public void SetPlacement(SlidePlacementChoice? placement)
    {
        if (Equals(Placement, placement)) return;
        Placement = placement;
        if (IsVisible) Rebuild();
    }

    public void SetVisible(bool visible)
    {
        if (visible == IsVisible && (_window != null || !visible)) return;
        IsVisible = visible;
        if (visible) { Rebuild(); _screenWatch.Start(); }
        else { CloseWindow(); _screenWatch.Stop(); }
        Changed?.Invoke();
    }

    public void Toggle() => SetVisible(!IsVisible);

    public bool IsFramed => _window?.SystemDecorations == SystemDecorations.Full;
    public bool IsSlideWindowVisible => _window?.IsVisible == true;
    public SlideSurface? Surface => _surface;
    public SKImage? HallImage => _surface?.CurrentImage;

    void RebuildIfScreensChanged()
    {
        var now = ScreenSignature();
        if (now == _builtScreens || !IsVisible) return;
        Journal.Say($"проектор: екранів {AllScreens?.ScreenCount}, вікно слайда перебудовую");
        Rebuild();
    }

    Screen? PreferredScreen()
    {
        var screens = AllScreens;
        if (screens == null || screens.ScreenCount == 0) return null;
        var all = screens.All;
        if (Placement is SlidePlacementChoice.Monitor m)
        {
            var i = m.Number - 1;
            return i >= 0 && i < all.Count ? all[i] : all[0];
        }
        var mine = MainWindow.Shared != null ? screens.ScreenFromWindow(MainWindow.Shared) : screens.Primary;
        return all.FirstOrDefault(s => s.Bounds != mine?.Bounds) ?? mine ?? all[0];
    }

    void Rebuild()
    {
        CloseWindow();
        _builtScreens = ScreenSignature();
        var screen = PreferredScreen();
        if (screen == null) return;
        var count = AllScreens?.ScreenCount ?? 1;
        var surface = new SlideSurface();
        var window = new Window
        {
            Background = Brushes.Black,
            Content = surface,
            Title = Captions.T("Окно слайда"),
            ShowActivated = false,
            Topmost = true,
        };
        var scale = screen.Scaling;
        if (Placement is SlidePlacementChoice.Manual manual)
        {
            window.SystemDecorations = SystemDecorations.None;
            window.ShowInTaskbar = false;
            window.WindowStartupLocation = WindowStartupLocation.Manual;
            window.Position = new PixelPoint(manual.Left, manual.Top);
            window.Width = Math.Max(160, manual.Width / scale);
            window.Height = Math.Max(90, manual.Height / scale);
            surface.IsHitTestVisible = false;
        }
        else if (Placement is SlidePlacementChoice.Monitor missing && missing.Number - 1 >= count)
        {
            Windowed(window, screen, new Size(missing.Width / scale, missing.Height / scale));
        }
        else if (count < 2)
        {
            Windowed(window, screen, null);
        }
        else
        {
            window.SystemDecorations = SystemDecorations.None;
            window.ShowInTaskbar = false;
            window.WindowStartupLocation = WindowStartupLocation.Manual;
            window.Position = screen.Bounds.Position;
            window.Width = screen.Bounds.Width / scale;
            window.Height = screen.Bounds.Height / scale;
            surface.IsHitTestVisible = false;
        }
        _window = window;
        _surface = surface;
        // Розмір вікна залу змінився (і коли воно щойно стало справжнього розміру) — вид програвача YouTube за ним.
        window.SizeChanged += (_, _) => { if (_hostedEmbed != null || _embedShown) Avalonia.Threading.Dispatcher.UIThread.Post(ResyncEmbed); };
        window.Show();
        if (window.SystemDecorations == SystemDecorations.None && Placement is not SlidePlacementChoice.Manual)
            window.WindowState = WindowState.FullScreen;
        Journal.Say(window.SystemDecorations == SystemDecorations.Full
            ? "проектор: вікно слайда — звичайним вікном" : "проектор: вікно слайда — без рамки на весь монітор");
        Redraw?.Invoke(false);
        Avalonia.Threading.Dispatcher.UIThread.Post(ResyncEmbed);
    }

    void Windowed(Window window, Screen screen, Size? requested)
    {
        var work = screen.WorkingArea;
        var scale = screen.Scaling;
        var width = requested?.Width ?? Math.Min(work.Width / scale * 0.5, 960);
        var height = requested?.Height ?? Math.Round(width / 16 * 9);
        window.Width = width;
        window.Height = height;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Position = new PixelPoint((int)(work.Right - width * scale - 40 * scale), (int)(work.Y + 40 * scale));
        window.SystemDecorations = SystemDecorations.Full;
        window.CanResize = true;
        window.ShowInTaskbar = true;
        window.Closing += (_, e) =>
        {
            if (_allowClose) return;
            e.Cancel = true;
            _hiddenByHand = true;
            if (_hostedEmbed != null) { _hostedEmbed.HideFromHall(); _hostedEmbed = null; }
            window.Hide();
            Journal.Say("проектор: вікно слайда сховано хрестиком — вернеться з наступним слайдом");
            Changed?.Invoke();
        };
    }

    bool _allowClose;

    // ── Вбудований YouTube у залі (hostWeb Mac) ─────────────────────────────

    YouTubeEmbedPlayer? _hostedEmbed, _wantedEmbed;
    bool _embedShown;

    /// Кадр ролика YouTube не дістати буфером, як у фільму (його малює чужий iframe), тож
    /// у зал, поки ролик на екрані, стає сам вид програвача — поверх кадру, на весь зал,
    /// плавно, як на Mac. Не на екрані — вертається в притулок за краєм екрана й малює далі
    /// (знімки для панелі, NDI й «Відео по Wi-Fi»).
    public void SyncEmbed(YouTubeEmbedPlayer? embed, bool shown)
    {
        _wantedEmbed = embed;
        _embedShown = shown;
        if (_hostedEmbed != null && (_hostedEmbed != embed || !shown || _window is not { IsVisible: true }))
        {
            _hostedEmbed.HideFromHall();
            _hostedEmbed = null;
        }
        if (embed == null || !shown) { Note(embed == null ? "немає програвача" : "ролик не на екрані"); return; }
        if (_window is not { IsVisible: true } window) { Note(_window == null ? "вікна залу немає" : "вікно залу сховане"); return; }
        if (window.TryGetPlatformHandle()?.Handle is not { } handle || handle == IntPtr.Zero) { Note("у вікна залу немає HWND"); return; }
        var scale = window.RenderScaling;
        var (w, h) = ((int)Math.Round(window.ClientSize.Width * scale), (int)Math.Round(window.ClientSize.Height * scale));
        if (embed.ShowIn(handle, w, h))
        {
            if (_hostedEmbed != embed) Journal.Say("проектор: ролик YouTube — сам програвач у вікні залу");
            _hostedEmbed = embed;
            Note("у залі " + embed.HallSize);
        }
        else Note(embed.IsReady ? "програвач не перейшов у вікно залу" : "програвач ще не готовий");
    }

    /// Чому програвач YouTube (не) у залі — перевірці (пульт, /api/media).
    public string EmbedNote { get; private set; } = "";
    void Note(string text)
    {
        if (EmbedNote == text) return;
        EmbedNote = text;
        if (_wantedEmbed != null) Journal.Say("проектор: програвач YouTube — " + text);
    }

    void ResyncEmbed() => SyncEmbed(_wantedEmbed, _embedShown);

    void CloseWindow()
    {
        _hiddenByHand = false;
        if (_hostedEmbed != null) { _hostedEmbed.HideFromHall(); _hostedEmbed = null; }
        if (_window == null) return;
        Journal.Say("проектор: вікно слайда прибрано");
        _allowClose = true;
        _window.Close();
        _allowClose = false;
        _window = null;
        _surface = null;
    }

    /// Хтось (стан програми) малює кадр під розмір вікна: false — без переходу.
    public Action<bool>? Redraw;

    /// Розмір кадру в пікселях: як вікно, але не ширше за 1920 (як на Mac — проектор
    /// усе одно покаже 1920×1080, а зайві мілісекунди віднімаються у вікна керування).
    public (int Width, int Height) FrameSize()
    {
        if (_surface == null || _window == null) return (1920, 1080);
        var scale = Math.Min(_window.RenderScaling, 2);
        var w = Math.Max(16, _surface.Bounds.Width) * scale;
        var h = Math.Max(9, _surface.Bounds.Height) * scale;
        var shrink = Math.Min(1, 1920 / Math.Max(1, w));
        return ((int)Math.Max(1, Math.Round(w * shrink)), (int)Math.Max(1, Math.Round(h * shrink)));
    }

    /// Показати готовий кадр у залі. Сховане хрестиком вікно вертається, коли в зал іде слайд.
    public void Present(SKImage? frame, bool animated, string kind, double seconds, string easing, bool blank)
    {
        _surface?.Show(frame, animated, kind, seconds, easing);
        if (_hiddenByHand && !blank && _window != null)
        {
            _hiddenByHand = false;
            _window.Show();
            Avalonia.Threading.Dispatcher.UIThread.Post(ResyncEmbed);
            Journal.Say("проектор: у зал пішов слайд — вікно слайда повернуто");
            Changed?.Invoke();
        }
    }
}
