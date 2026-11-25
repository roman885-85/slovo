// =============================================================================
//  YouTubeEmbedPlayer.cs — вбудований програвач YouTube (YouTubeEmbedPlayer Mac)
// =============================================================================
//  Коли yt-dlp немає або він не зміг (YouTube змінив видачу) — ролик однаково
//  йде: офіційний IFrame Player API у браузерному виді (WebView2 — рушій Edge,
//  є в Windows 10/11). Сторінку-обгортку віддає свій сервер на 127.0.0.1
//  (YouTubeHostServer). Пуск, пауза, перемотка й гучність — через їхній
//  JavaScript-API, стан і час приходять назад повідомленнями.
//
//  Кадр для панелі плеєра, залу, NDI й «Відео по Wi-Fi» — знімки виду (на Mac
//  так само для панелі й трансляції: іншого шляху дістати картинку з чужого
//  iframe немає) у спільні буфери VideoFrames, близько 15 разів на секунду.
//  Вид живе у вікні-притулку за краєм екрана: WebView2 малює лише в справжньому
//  вікні. Звук грає процес рушія WebView2 — він дочірній для «Слова», тож
//  захоплення звуку програми (дерево процесу) бере й його.
// =============================================================================

using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Threading;
using SkiaSharp;

namespace Slovo.App;

public sealed class YouTubeEmbedPlayer : IDisposable
{
    /// Стани з YT.PlayerState — їхні числа.
    public enum State { Unstarted = -1, Ended = 0, Playing = 1, Paused = 2, Buffering = 3, Cued = 5 }

    public readonly string VideoId;
    public Action? OnReady;
    public Action<State>? OnState;
    public Action<int>? OnError;
    public Action<double, double>? OnTime;
    public bool IsReady { get; private set; }
    /// Що каже сам програвач YouTube (isMuted, getVolume 0–100) — перевірці звуку.
    public bool PlayerMuted { get; private set; }
    public double PlayerVolume { get; private set; } = -1;
    public int BrowserProcessId => _view.BrowserProcessId;

    /// Скільки знімків на секунду: більше — дорожче сторінці, панель і мікшер різниці не побачать.
    public const double SnapshotRate = 15;

    readonly Window _shelter;
    readonly WebPreviewHost _view = new();
    readonly DispatcherTimer _snapshots;
    bool _inFlight, _closed;

    public YouTubeEmbedPlayer(string videoId, bool autoplay)
    {
        VideoId = videoId;
        _view.Message += Received;
        _view.Failed += _ => OnError?.Invoke(-1);
        _shelter = new Window
        {
            Width = 1280, Height = 720, SystemDecorations = SystemDecorations.None, ShowInTaskbar = false,
            ShowActivated = false, CanResize = false, Background = Avalonia.Media.Brushes.Black,
            Position = new PixelPoint(-30000, -30000), WindowStartupLocation = WindowStartupLocation.Manual,
            Title = "Слово · YouTube", Content = _view,
        };
        // Перевірка у Windows 11 (25.11.2026): вікно, поставлене за край ще до показу, Avalonia
        // повертала на екран — притулок закривав робочий стіл. Тож місце — після показу, за всіма
        // моніторами разом (WebView2 малює й там: рушій запущено без стеження за затуленням вікон).
        _shelter.Opened += (_, _) => Dispatcher.UIThread.Post(Hide);
        _shelter.Show();
        _snapshots = new DispatcherTimer(TimeSpan.FromSeconds(1 / SnapshotRate), DispatcherPriority.Background, (_, _) => _ = Snapshot());
        var port = YouTubeHostServer.Shared.Ensure();
        if (port == 0) { Dispatcher.UIThread.Post(() => OnError?.Invoke(-1)); return; }
        _view.Navigate($"http://127.0.0.1:{port}/player?v={videoId}&autoplay={(autoplay ? 1 : 0)}");
    }

    // ── Керування ───────────────────────────────────────────────────────────

    public void Play() => Run("player.playVideo()");
    public void Pause() => Run("player.pauseVideo()");
    public void Seek(double seconds) => Run($"player.seekTo({Math.Max(0, seconds).ToString(System.Globalization.CultureInfo.InvariantCulture)}, true)");
    public void SetVolume(double value) => Run($"player.setVolume({(int)Math.Round(Math.Clamp(value, 0, 1) * 100)})");
    public void SetMuted(bool muted) => Run(muted ? "player.mute()" : "player.unMute()");

    void Run(string script)
    {
        if (!IsReady || _closed) return;
        _view.Run("try{" + script + "}catch(e){}");
    }

    /// Притулок — правіше за всі монітори (там його не видно й нічого він не закриває).
    void Hide()
    {
        if (_closed) return;
        var right = 0;
        var screens = _shelter.Screens?.All;
        if (screens != null) foreach (var screen in screens) right = Math.Max(right, screen.Bounds.Right);
        _shelter.Position = new PixelPoint(right + 4000, 0);
    }

    /// Сам вид програвача — у вікно залу (як hostWeb на Mac); назад — у притулок, де він малює далі.
    public bool ShowIn(IntPtr window, int width, int height) => !_closed && _view.MoveTo(window, width, height);
    public void HideFromHall() => _view.ReturnHome();
    public bool InHall => _view.IsAway;
    /// Розмір виду в залі (пікселі) — перевірці.
    public string HallSize => _view.GuestSize;

    public void StartSnapshots() => _snapshots.Start();
    public void StopSnapshots() => _snapshots.Stop();

    /// Один знімок у VideoFrames; поки попередній не повернувся — новий не просимо.
    public async Task Snapshot()
    {
        if (_inFlight || _closed || !_view.IsReady) return;
        _inFlight = true;
        try
        {
            var jpeg = await _view.Capture();
            if (jpeg == null || _closed) return;
            using var decoded = SKBitmap.Decode(jpeg);
            if (decoded == null) return;
            var frames = VideoFrames.Shared;
            if (frames.Width != decoded.Width || frames.Height != decoded.Height) frames.Configure(decoded.Width, decoded.Height);
            var target = frames.BeginWrite(out var index, out var pitch);
            if (target == IntPtr.Zero) return;
            using (var converted = decoded.ColorType == SKColorType.Bgra8888 ? null : decoded.Copy(SKColorType.Bgra8888))
            {
                var source = converted ?? decoded;
                for (var row = 0; row < source.Height; row++)
                    unsafe { Buffer.MemoryCopy((byte*)source.GetPixels() + (long)row * source.RowBytes, (byte*)target + (long)row * pitch, pitch, Math.Min(pitch, source.RowBytes)); }
            }
            frames.Publish(index);
        }
        catch { }
        finally { _inFlight = false; }
    }

    // ── Повідомлення сторінки ───────────────────────────────────────────────

    void Received(string text)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            var kind = root.GetProperty("kind").GetString();
            switch (kind)
            {
                case "ready":
                    IsReady = true;
                    OnReady?.Invoke();
                    break;
                case "state":
                    OnState?.Invoke((State)root.GetProperty("value").GetInt32());
                    break;
                case "time":
                    if (root.TryGetProperty("m", out var muted)) PlayerMuted = muted.GetInt32() == 1;
                    if (root.TryGetProperty("v", out var volume)) PlayerVolume = volume.GetDouble();
                    OnTime?.Invoke(root.GetProperty("cur").GetDouble(), root.GetProperty("dur").GetDouble());
                    break;
                case "error":
                    OnError?.Invoke(root.GetProperty("value").GetInt32());
                    break;
            }
        }
        catch { }
    }

    /// Зняти все: зупинити ролик, порожня сторінка глушить звук одразу, закрити притулок.
    public void Dispose()
    {
        if (_closed) return;
        StopSnapshots();
        Run("player.stopVideo()");
        _closed = true;
        OnReady = null; OnState = null; OnError = null; OnTime = null;
        _view.Navigate("about:blank");
        // Із залу — додому: контролер має закритися разом зі своїм вікном, а не з вікном залу.
        _view.ReturnHome();
        _shelter.Close();
    }
}
