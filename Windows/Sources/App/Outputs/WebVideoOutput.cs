// =============================================================================
//  WebVideoOutput.cs — «Відео по Wi-Fi»: кадр залу й звук потоком HLS (WebVideoOutput Mac)
// =============================================================================
//  Навіщо (власник, про Mac): клієнт підключений по Wi-Fi, а повна смуга NDI по
//  Wi-Fi не проходить; NDI|HX — шлях Advanced SDK з обмеженням без ліцензії.
//  Тож окремий канал: H.264/AAC, шматки HLS, наш HTTP-сервер віддає їх за адресою
//  /wifi/. Затримка 2–4 с — ціна протоколу зі шматками; власник її допустив.
//
//  Кадр — той самий, що в NDI (OutputDriver.NdiFrame, правила виводу NDI), з
//  плавною зміною й кадром плеєра поверх; власний потік кодування, тож канал іде
//  й без NDI. Звук — захоплення звуку свого процесу (AppAudioCapture), у паузах —
//  тиша (потік HLS не може обриватися на звуковій доріжці). Кодери — Media
//  Foundation (MfEncoders.cs), мультиплексор — свій MPEG-TS (HlsTsSegmenter).
// =============================================================================

using System.Diagnostics;
using Avalonia.Threading;
using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public sealed class WebVideoOutput
{
    public static WebVideoOutput Shared { get; } = new();
    public const int Fps = 25;
    static string T(string text, params object[] args) => Captions.T(text, args);

    public string Status { get; private set; } = "";
    public event Action? StatusChanged;
    public int Segments => _segmenter?.SegmentCount ?? 0;
    public bool IsEnabled => _enabled;
    /// Для перевірок: канал іде й у режимі знімків.
    public static bool ForceEnabled;

    bool _enabled, _hooked, _renderPosted;
    int _frameGeneration;
    int _height = 720, _kbps = 3000, _width;
    Thread? _thread;
    volatile bool _stopping;
    volatile string? _failure;
    HlsTsSegmenter? _segmenter;
    DispatcherTimer? _timer;
    int _encodedWidth, _encodedHeight;

    readonly object _gate = new();
    SKImage? _current, _previous;
    long _fadeStart;
    double _fadeSeconds;

    AppAudioCapture? _audio;
    readonly object _audioGate = new();
    readonly Queue<short> _pcm = new();
    long _bytesAtLastTick;
    readonly Queue<(DateTime At, long Bytes)> _rate = new();

    public void Apply(bool enabled, int height, int kbps)
    {
        height = height is 720 or 540 or 360 ? height : 720;
        kbps = Math.Clamp(kbps, 300, 20000);
        var changed = enabled != _enabled || height != _height || kbps != _kbps;
        _height = height;
        _kbps = kbps;
        if (!changed) return;
        Stop();
        _enabled = enabled;
        if (!enabled)
        {
            HLSStreamRegistry.Provider = null;
            SetStatus("");
            return;
        }
        Start();
    }

    void HookOnce()
    {
        if (_hooked) return;
        _hooked = true;
        AppState.Shared.LiveChanged += ContentChanged;
        Signals.Shared.Subscribe(Signals.Kind.Live, ContentChanged);
    }

    void Start()
    {
        HookOnce();
        _height &= ~1;
        _width = (int)Math.Round(_height * 16.0 / 9) & ~1;
        _failure = null;
        _segmenter = new HlsTsSegmenter(hasAudio: true, targetSeconds: 1, keep: 6);
        HLSStreamRegistry.Provider = _segmenter;
        lock (_audioGate) _pcm.Clear();
        var audio = _audio = new AppAudioCapture();
        audio.OnSamples = TakeAudio;
        audio.Start();
        _stopping = false;
        _thread = new Thread(Run) { IsBackground = true, Name = "slovo-wifi-video", Priority = ThreadPriority.AboveNormal };
        _thread.Start();
        SetStatus(T("поток заводится…"));
        _timer ??= new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => RefreshStatus());
        _timer.Start();
        Journal.Say($"Відео по Wi-Fi: увімкнено, {_width}×{_height}, {_kbps} кбіт/с, {Fps} кадр/с");
        ContentChanged();
    }

    public void Stop()
    {
        _timer?.Stop();
        _stopping = true;
        _thread?.Join(3000);
        _thread = null;
        _audio?.Stop();
        _audio = null;
        if (_segmenter != null) Journal.Say("Відео по Wi-Fi: вимкнено");
        _segmenter = null;
        lock (_gate) { _current?.Dispose(); _current = null; _previous?.Dispose(); _previous = null; }
    }

    void SetStatus(string text)
    {
        if (Status == text) return;
        Status = text;
        StatusChanged?.Invoke();
    }

    internal void RefreshStatus()
    {
        if (!_enabled) return;
        if (_failure is { } failure) { SetStatus(T("ошибка кодера: ") + failure); return; }
        var segmenter = _segmenter;
        if (segmenter == null || segmenter.SegmentCount == 0) { SetStatus(T("поток заводится…")); return; }
        var now = DateTime.Now;
        var bytes = segmenter.BytesWritten;
        _rate.Enqueue((now, bytes));
        while (_rate.Count > 0 && (now - _rate.Peek().At).TotalSeconds > 5) _rate.Dequeue();
        var (at, first) = _rate.Peek();
        var seconds = Math.Max(1, (now - at).TotalSeconds);
        var mbps = (bytes - first) * 8 / seconds / 1_000_000;
        SetStatus(T("идёт: кусков ") + $"{segmenter.SegmentCount}, {_encodedWidth}×{_encodedHeight}, " + mbps.ToString("0.0") + T(" Мбит/с"));
        _bytesAtLastTick = bytes;
    }

    /// Кадр залу змінився — намалювати його заново (головний потік, як NdiOutput).
    public void ContentChanged()
    {
        if (!_enabled || _renderPosted) return;
        _renderPosted = true;
        Dispatcher.UIThread.Post(() =>
        {
            _renderPosted = false;
            if (!_enabled || MainWindow.Shared?.Output is not { } driver) return;
            var generation = ++_frameGeneration;
            var fade = Math.Clamp(AppState.Shared.Style.TransitionDuration, 0, 2);
            driver.RenderOutputFrame("wifi-video", generation, _width, _height, transparent: false, (image, done) =>
            {
                if (image == null) return;
                if (done != _frameGeneration || !_enabled) { image.Dispose(); return; }
                lock (_gate)
                {
                    _previous?.Dispose();
                    _previous = _current;
                    _current = image;
                    _fadeStart = Environment.TickCount64;
                    _fadeSeconds = fade;
                }
            });
        }, DispatcherPriority.Background);
    }

    // ── Звук ────────────────────────────────────────────────────────────────

    /// Скільки відліків звуку прийшло й найгучніший за останню порцію — перевірці.
    public long AudioSamplesIn => Interlocked.Read(ref _audioSamplesIn);
    public double AudioPeak { get; private set; }
    long _audioSamplesIn;

    void TakeAudio(float[] planar, int channels, int samples, int rate)
    {
        Interlocked.Add(ref _audioSamplesIn, samples);
        var peak = 0f;
        for (var i = 0; i < samples * Math.Min(2, channels); i++) peak = Math.Max(peak, Math.Abs(planar[i]));
        AudioPeak = peak;
        lock (_audioGate)
        {
            for (var i = 0; i < samples; i++)
                for (var c = 0; c < 2; c++)
                {
                    var v = planar[Math.Min(c, channels - 1) * samples + i];
                    _pcm.Enqueue((short)Math.Clamp(v * 32767f, -32768f, 32767f));
                }
            // Не більше пів секунди наперед: інакше звук відставатиме від кадру.
            while (_pcm.Count > MfAacEncoder.Rate) _pcm.Dequeue();
        }
    }

    byte[] PopAudio(int samples)
    {
        var bytes = new byte[samples * 4];
        lock (_audioGate)
            for (var i = 0; i < samples * 2; i++)
            {
                var v = _pcm.Count > 0 ? _pcm.Dequeue() : (short)0;
                bytes[i * 2] = (byte)v;
                bytes[i * 2 + 1] = (byte)(v >> 8);
            }
        return bytes;
    }

    // ── Кодування ───────────────────────────────────────────────────────────

    void Run()
    {
        var segmenter = _segmenter!;
        int width = _width, height = _height;
        try
        {
            using var video = new MfH264Encoder(width, height, Fps, _kbps * 1000);
            using var aac = new MfAacEncoder();
            _encodedWidth = width; _encodedHeight = height;
            using var surface = SKSurface.Create(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul));
            var bgra = new byte[width * height * 4];
            var nv12 = new byte[width * height * 3 / 2];
            var whole = new SKRect(0, 0, width, height);
            var clock = Stopwatch.StartNew();
            long frame = 0, audioSamples = 0;
            while (!_stopping)
            {
                var ahead = frame * 1000.0 / Fps - clock.Elapsed.TotalMilliseconds;
                if (ahead > 1) Thread.Sleep((int)ahead);
                // Відстали більше ніж на секунду (машина зайнята) — наздогнати годинник, а не кодувати чергу.
                if (-ahead > 1000) { frame = (long)(clock.Elapsed.TotalSeconds * Fps); audioSamples = frame * MfAacEncoder.Rate / Fps; }
                var canvas = surface.Canvas;
                canvas.Clear(SKColors.Black);
                lock (_gate)
                {
                    var fade = _fadeSeconds <= 0 ? 1 : Math.Clamp((Environment.TickCount64 - _fadeStart) / 1000.0 / _fadeSeconds, 0, 1);
                    if (_previous != null && fade < 1)
                    {
                        using var old = new SKPaint { Color = SKColors.White.WithAlpha((byte)Math.Round(255 * (1 - fade))), FilterQuality = SKFilterQuality.Medium };
                        canvas.DrawImage(_previous, whole, old);
                    }
                    if (_current != null)
                    {
                        using var paint = new SKPaint { Color = SKColors.White.WithAlpha((byte)Math.Round(255 * fade)), FilterQuality = SKFilterQuality.Medium };
                        canvas.DrawImage(_current, whole, paint);
                    }
                }
                if (AppState.Shared.Media.IsVideoOnScreen) VideoFrames.Shared.DrawLatest(canvas, whole);
                canvas.Flush();
                unsafe
                {
                    fixed (byte* pointer = bgra)
                        surface.ReadPixels(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Opaque), (IntPtr)pointer, width * 4, 0, 0);
                }
                Nv12.FromBgra(bgra, width, height, nv12);
                var time = frame * 10_000_000L / Fps;
                foreach (var unit in video.Encode(nv12, time)) segmenter.AddVideo(unit.Data, unit.Time * 9 / 1000);
                var wanted = (frame + 1) * MfAacEncoder.Rate / Fps;
                var count = (int)(wanted - audioSamples);
                if (count > 0)
                {
                    var pcm = PopAudio(count);
                    foreach (var unit in aac.Encode(pcm, pcm.Length, audioSamples * 10_000_000L / MfAacEncoder.Rate))
                        segmenter.AddAudio(unit.Data, unit.Time * 9 / 1000);
                    audioSamples = wanted;
                }
                frame++;
            }
        }
        catch (Exception error)
        {
            _failure = error is TypeLoadException or PlatformNotSupportedException or DllNotFoundException or EntryPointNotFoundException
                ? T("кодеры Media Foundation есть только в Windows")
                : error.Message;
            Journal.Say("Відео по Wi-Fi: кодер — " + error.Message);
            Dispatcher.UIThread.Post(RefreshStatus);
        }
    }
}

/// BGRA → NV12 (BT.601, обмежений діапазон), рядки парами — паралельно.
static class Nv12
{
    public static void FromBgra(byte[] bgra, int width, int height, byte[] nv12)
    {
        Parallel.For(0, height / 2, pair =>
        {
            for (var dy = 0; dy < 2; dy++)
            {
                var y = pair * 2 + dy;
                var source = y * width * 4;
                var target = y * width;
                for (var x = 0; x < width; x++)
                {
                    var i = source + x * 4;
                    int b = bgra[i], g = bgra[i + 1], r = bgra[i + 2];
                    nv12[target + x] = (byte)(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
                }
            }
            var uv = width * height + pair * width;
            var top = pair * 2 * width * 4;
            var bottom = top + width * 4;
            for (var x = 0; x < width; x += 2)
            {
                var a = top + x * 4; var c = bottom + x * 4;
                var b = (bgra[a] + bgra[a + 4] + bgra[c] + bgra[c + 4]) >> 2;
                var g = (bgra[a + 1] + bgra[a + 5] + bgra[c + 1] + bgra[c + 5]) >> 2;
                var r = (bgra[a + 2] + bgra[a + 6] + bgra[c + 2] + bgra[c + 6]) >> 2;
                nv12[uv + x] = (byte)Math.Clamp(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128, 0, 255);
                nv12[uv + x + 1] = (byte)Math.Clamp(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128, 0, 255);
            }
        });
    }
}
