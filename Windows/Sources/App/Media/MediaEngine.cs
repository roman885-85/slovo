// =============================================================================
//  MediaEngine.cs — програвач на LibVLC: файл чи потік, кадри, звук, доріжки
// =============================================================================
//  Оригінал грає через ffmpeg, Mac-«Слово» — через AVFoundation; тут LibVLC (той
//  самий ffmpeg усередині): усі формати зі списку автора, потоки (http/https,
//  HLS .m3u8, rtsp, udp, rtmp), вибір звукового виходу й доріжки, синхронність
//  звуку з кадром. Кадри — у VideoFrames (RV32 = BGRA), не в окреме вікно: зал,
//  «живий екран» і передпоказ малюють їх самі.
//  Події LibVLC приходять з його потоків — у головний їх переносить Dispatcher;
//  кликати LibVLC зсередини його ж події не можна (зависне), тож дії — з головного.
// =============================================================================

using System.Runtime.InteropServices;
using Avalonia.Threading;
using LibVLCSharp.Shared;

namespace Slovo.App;

public sealed class MediaEngine : IDisposable
{
    static LibVLC? _libVLC;
    static string? _unavailable;
    static bool _tried;

    /// Підняти LibVLC один раз на програму. Немає модулів (розробка на Mac) —
    /// програвач недоступний, решта програми працює.
    public static bool EnsureLoaded()
    {
        if (_tried) return _libVLC != null;
        _tried = true;
        try
        {
            var folder = Path.Combine(AppContext.BaseDirectory, "libvlc", OperatingSystem.IsWindows() ? "win-x64" : "osx-x64");
            if (Directory.Exists(folder)) LibVLCSharp.Shared.Core.Initialize(folder); else LibVLCSharp.Shared.Core.Initialize();
            _libVLC = new LibVLC("--no-video-title-show", "--no-osd", "--no-snapshot-preview", "--quiet", "--no-stats");
            return true;
        }
        catch (Exception error)
        {
            _unavailable = error.Message;
            Journal.Say($"плеєр: LibVLC не завантажився — {error.Message}");
            return false;
        }
    }

    /// Сам LibVLC — для перетворення фонограм чужих форматів (null — не завантажився).
    internal static LibVLC? Library => EnsureLoaded() ? _libVLC : null;

    /// Чому програвача немає (null — є).
    public static string? Unavailable => EnsureLoaded() ? null : _unavailable ?? "LibVLC";

    readonly MediaPlayer _player;
    readonly VideoFrames _frames;
    Media? _media;
    // Делегати, віддані LibVLC, мусять жити, поки живе програвач.
    readonly MediaPlayer.LibVLCVideoFormatCb _format;
    readonly MediaPlayer.LibVLCVideoCleanupCb _cleanup;
    readonly MediaPlayer.LibVLCVideoLockCb _lock;
    readonly MediaPlayer.LibVLCVideoUnlockCb _unlock;
    readonly MediaPlayer.LibVLCVideoDisplayCb _display;
    int _generation;

    /// Найбільший кадр: проектору більшого не треба, а 4K утричі дорожчий у копіюванні.
    const int MaxWidth = 1920, MaxHeight = 1080;

    public event Action? Playing, Paused, Stopped, EndReached, Failed, VideoStarted, TracksChanged;
    public event Action<double>? TimeChanged, LengthChanged;

    public MediaEngine(VideoFrames frames)
    {
        _frames = frames;
        _player = new MediaPlayer(_libVLC!);
        _format = Format;
        _cleanup = Cleanup;
        _lock = Lock;
        _unlock = Unlock;
        _display = Display;
        _player.SetVideoFormatCallbacks(_format, _cleanup);
        _player.SetVideoCallbacks(_lock, _unlock, _display);
        _player.Playing += (_, _) => Ui(() => Playing?.Invoke());
        _player.Paused += (_, _) => Ui(() => Paused?.Invoke());
        _player.Stopped += (_, _) => Ui(() => Stopped?.Invoke());
        _player.EndReached += (_, _) => Ui(() => EndReached?.Invoke());
        _player.EncounteredError += (_, _) => Ui(() => Failed?.Invoke());
        _player.TimeChanged += (_, e) => { var t = e.Time / 1000.0; Ui(() => TimeChanged?.Invoke(t)); };
        _player.LengthChanged += (_, e) => { var l = e.Length / 1000.0; Ui(() => LengthChanged?.Invoke(l)); };
        _player.Vout += (_, e) => { if (e.Count > 0) Ui(() => VideoStarted?.Invoke()); };
        _player.ESAdded += (_, e) => { if (e.Type == TrackType.Audio) Ui(() => TracksChanged?.Invoke()); };
    }

    /// Подію — на головний потік, лише якщо вона від поточного файла.
    void Ui(Action action)
    {
        var generation = _generation;
        Dispatcher.UIThread.Post(() => { if (generation == _generation) action(); });
    }

    // ── Відкриття й керування ───────────────────────────────────────────────

    /// Відкрити файл (шлях) чи потік (адреса) і запустити.
    /// Відкрити файл чи потік. audio — окрема звукова доріжка (ролики YouTube: картинка й
    /// звук окремо, LibVLC грає їх разом, перемотка спільна); userAgent/referer — заголовки
    /// HTTP, з якими yt-dlp питав адресу (без них сервер YouTube відповідає 403).
    public void Open(string target, bool stream, string? audio = null, string? userAgent = null, string? referer = null)
    {
        _generation++;
        _media?.Dispose();
        _media = stream ? new Media(_libVLC!, new Uri(target)) : new Media(_libVLC!, target, FromType.FromPath);
        if (userAgent != null) _media.AddOption(":http-user-agent=" + userAgent);
        if (referer != null) _media.AddOption(":http-referrer=" + referer);
        if (audio != null) _media.AddSlave(MediaSlaveType.Audio, 4, audio);
        _player.Media = _media;
        _player.Play();
    }

    public void Close()
    {
        _generation++;
        // Stop у LibVLC чекає на свої потоки — не з головного, щоб вікно не завмирало.
        var player = _player;
        ThreadPool.QueueUserWorkItem(_ => { try { player.Stop(); } catch { } });
        _frames.Clear();
    }

    public void Play() => _player.SetPause(false);
    public void Pause() => _player.SetPause(true);

    /// Почати з початку після кінця файла (повтор): після EndReached LibVLC треба зупинити й пустити наново.
    public void Restart()
    {
        var player = _player;
        ThreadPool.QueueUserWorkItem(_ => { try { player.Stop(); player.Play(); } catch { } });
    }

    public void Seek(double seconds)
    {
        _player.Time = (long)Math.Max(0, seconds * 1000);
        // На паузі LibVLC кадр з нового місця не малює — у вікні лишився б старий
        // (на Mac — pullFrame(force:)). Крок на один кадр показує новий і лишає паузу.
        if (!_player.IsPlaying && _player.State == VLCState.Paused) _player.NextFrame();
    }

    public bool IsPlaying => _player.IsPlaying;

    /// Гучність 0…1 (уже як підсилення) і «Без звуку».
    public void SetVolume(float gain) => _player.Volume = (int)Math.Round(Math.Clamp(gain, 0, 1) * 100);
    public void SetMute(bool muted) => _player.Mute = muted;

    public sealed record Track(string Id, string Title);

    /// Звукові доріжки файла (без «вимкнено»).
    public List<Track> AudioTracks()
    {
        try
        {
            return _player.AudioTrackDescription.Where(t => t.Id >= 0)
                .Select(t => new Track(t.Id.ToString(), string.IsNullOrWhiteSpace(t.Name) ? $"#{t.Id}" : t.Name)).ToList();
        }
        catch { return new List<Track>(); }
    }

    public string? SelectedAudioTrack => _player.AudioTrack >= 0 ? _player.AudioTrack.ToString() : null;

    public void SelectAudioTrack(string id)
    {
        if (int.TryParse(id, out var number)) _player.SetAudioTrack(number);
    }

    public sealed record Device(string Id, string Name);

    /// Звукові виходи системи (як їх бачить LibVLC — WASAPI/MMDevice).
    public List<Device> AudioDevices()
    {
        try { return _player.AudioOutputDeviceEnum.Select(d => new Device(d.DeviceIdentifier, d.Description)).ToList(); }
        catch { return new List<Device>(); }
    }

    /// null — системний вихід.
    public void SetAudioDevice(string? id)
    {
        try { _player.SetOutputDevice(id ?? ""); } catch { /* вихід зник — лишається системний */ }
    }

    // ── Кадри ───────────────────────────────────────────────────────────────

    uint Format(ref IntPtr opaque, IntPtr chroma, ref uint width, ref uint height, ref uint pitches, ref uint lines)
    {
        // RV32 — 32 біти BGRX у пам'яті: те саме, що Bgra8888 у Skia (альфа ігнорується).
        Marshal.Copy(new[] { (byte)'R', (byte)'V', (byte)'3', (byte)'2' }, 0, chroma, 4);
        double w = width, h = height;
        var scale = Math.Min(1, Math.Min(MaxWidth / Math.Max(1, w), MaxHeight / Math.Max(1, h)));
        width = (uint)Math.Max(2, Math.Round(w * scale)) & ~1u;
        height = (uint)Math.Max(2, Math.Round(h * scale)) & ~1u;
        _frames.Configure((int)width, (int)height);
        _frames.BeginWrite(out _, out var pitch);
        pitches = (uint)pitch;
        lines = height;
        return 1;
    }

    void Cleanup(ref IntPtr opaque) { }

    IntPtr Lock(IntPtr opaque, IntPtr planes)
    {
        var pointer = _frames.BeginWrite(out var index, out _);
        Marshal.WriteIntPtr(planes, pointer);
        return new IntPtr(index);
    }

    void Unlock(IntPtr opaque, IntPtr picture, IntPtr planes) { }

    void Display(IntPtr opaque, IntPtr picture) => _frames.Publish(picture.ToInt32());

    public void Dispose()
    {
        _generation++;
        try { _player.Stop(); } catch { }
        _player.Dispose();
        _media?.Dispose();
    }
}
