// =============================================================================
//  Splash.cs — заставка під час запуску (NativeSplash Mac 1.3.9)
// =============================================================================
//  Як у автора: поки читається бібліотека, людина бачить ім'я програми й те, чим
//  вона зараз зайнята, а не порожній екран. Вікно без рамки, поверх усіх, мишу
//  не ловить; гасне саме, коли бібліотеку прочитано, але не раніше ніж за 4 с
//  (власник просив, щоб її було видно, навіть якщо бібліотека прочиталась миттю).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace Slovo.App;

public static class Splash
{
    const double LeastSeconds = 4, Width = 460, Height = 260, Shadow = 24;
    static Window? _window;
    static Face? _face;
    static DateTime _shownAt;
    static DispatcherTimer? _animation;

    /// Показати заставку (у знімках і з --quiet-start — ні: вона поверх усіх вікон).
    public static void Show()
    {
        if (_window != null || Program.Snapshotting || Program.QuietStart) return;
        var face = _face = new Face();
        var window = _window = new Window
        {
            SystemDecorations = SystemDecorations.None,
            TransparencyLevelHint = new[] { WindowTransparencyLevel.Transparent },
            Background = Brushes.Transparent,
            Topmost = true,
            ShowInTaskbar = false,
            ShowActivated = false,
            CanResize = false,
            Width = Width + Shadow * 2,
            Height = Height + Shadow * 2,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            IsHitTestVisible = false,
            Title = Captions.T("Слово"),
            Content = new Border
            {
                Margin = new Thickness(Shadow),
                CornerRadius = new CornerRadius(18),
                ClipToBounds = true,
                // Темна підкладка — на ній ім'я читається і вдень, і ввечері.
                Background = new SolidColorBrush(Color.FromRgb(18, 26, 46)),
                BoxShadow = BoxShadows.Parse("0 10 30 0 #70000000"),
                Child = face,
            },
        };
        window.Show();
        _shownAt = DateTime.Now;
        _animation = new DispatcherTimer(TimeSpan.FromMilliseconds(33), DispatcherPriority.Render, (_, _) => face.Step());
        _animation.Start();
        // Бібліотеку прочитано — заставка йде (раніше 4 с — досидить).
        Signals.Shared.Subscribe(Signals.Kind.Library, () => { if (!AppState.Shared.IsLoadingLibrary) Hide(); });
    }

    /// Що програма робить зараз — той самий напис, що й у головному вікні.
    public static void Say(string text)
    {
        if (_face == null) return;
        _face.Caption = Captions.T(text);
    }

    public static void Hide()
    {
        if (_window is not { } window) return;
        var passed = (DateTime.Now - _shownAt).TotalSeconds;
        if (passed < LeastSeconds)
        {
            // Ще рано — досидимо решту й підемо самі (вдруге відкладати не треба).
            _shownAt = DateTime.MinValue;
            DispatcherTimer.RunOnce(Hide, TimeSpan.FromSeconds(LeastSeconds - passed));
            return;
        }
        _window = null;
        var fade = DateTime.Now;
        // Таймер без обробника в конструкторі (null там Avalonia не приймає — програма падала при запуску).
        var timer = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(16) };
        timer.Tick += (_, _) =>
        {
            var part = Math.Min(1, (DateTime.Now - fade).TotalSeconds / 0.25);
            window.Opacity = 1 - part;
            if (part < 1) return;
            timer.Stop();
            _animation?.Stop();
            _animation = null;
            _face = null;
            window.Close();
        };
        timer.Start();
    }

    /// Чи показана заставка — перевірці.
    public static bool IsShown => _window != null;

    /// Вікно з тим самим вмістом — для знімка перевірки (без «поверх усіх» і тіні).
    public static Window MakeForCheck(string caption)
    {
        var face = new Face { Caption = Captions.T(caption) };
        return new Window
        {
            SystemDecorations = SystemDecorations.None,
            Background = Brushes.White,
            Content = new Border { CornerRadius = new CornerRadius(18), ClipToBounds = true, Background = new SolidColorBrush(Color.FromRgb(18, 26, 46)), Child = face },
        };
    }

    /// Вміст плашки: значок, ім'я, опис, смужка ходу, напис, версія.
    sealed class Face : Control
    {
        readonly Bitmap? _icon;
        string _caption = Captions.T("Запускаю…");
        double _phase;
        readonly string _version;

        public Face()
        {
            try
            {
                using var asset = Avalonia.Platform.AssetLoader.Open(new Uri("avares://Slovo/Resources/AppIcon-256.png"));
                _icon = new Bitmap(asset);
            }
            catch { _icon = null; }
            var version = typeof(Splash).Assembly.GetName().Version;
            _version = version == null ? "" : $"v{version.Major}.{version.Minor}.{version.Build}";
        }

        public string Caption { get => _caption; set { _caption = value; InvalidateVisual(); } }

        public void Step()
        {
            _phase = (_phase + 0.033 / 1.4) % 1;
            InvalidateVisual();
        }

        public override void Render(DrawingContext g)
        {
            var w = Bounds.Width;
            if (_icon != null) g.DrawImage(_icon, new Rect(w / 2 - 36, 30, 72, 72));
            TextDraw.Draw(g, Captions.T("Слово"), new Rect(0, 106, w, 42), 34, Colors.White, FontWeight.SemiBold, TextAlignment.Center, wrap: false);
            TextDraw.Draw(g, Captions.T("Показ Библии, песен, медиа и презентаций на служении"), new Rect(16, 154, w - 32, 18), 12,
                          Color.FromArgb(158, 255, 255, 255), align: TextAlignment.Center, wrap: false, trim: true);
            // Смужка «щось робиться» без кінця: доріжка й біжучий відрізок кольору акценту.
            var track = new Rect(60, 192, w - 120, 6);
            g.DrawRectangle(new SolidColorBrush(Color.FromArgb(46, 255, 255, 255)), null, track, 3, 3);
            var run = track.Width * 0.3;
            var x = track.X - run + (track.Width + run) * _phase;
            using (g.PushClip(new RoundedRect(track, 3)))
                g.DrawRectangle(new SolidColorBrush(Palette.Accent), null, new Rect(x, track.Y, run, track.Height), 3, 3);
            TextDraw.Draw(g, _caption, new Rect(16, 210, w - 32, 16), 11, Color.FromArgb(191, 255, 255, 255),
                          align: TextAlignment.Center, wrap: false, trim: true);
            TextDraw.Draw(g, _version, new Rect(16, 232, w - 32, 14), 10, Color.FromArgb(89, 255, 255, 255),
                          align: TextAlignment.Center, wrap: false);
        }
    }
}
