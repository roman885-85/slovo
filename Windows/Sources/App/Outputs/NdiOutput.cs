// =============================================================================
//  NdiOutput.cs — трансляція залу в мережу джерелом NDI (NDIOutput Mac 1.3.9)
// =============================================================================
//  Устроєно як справжнє джерело відео, а не «збережи картинку за кнопкою»: у
//  трансляції своя частота кадрів, і мікшер чекає кадри й тоді, коли на екрані
//  нічого не міняється. Звідси поділ праці: вміст приходить подіями (змінився
//  вірш — малюємо кадр NDI у головному потоці), а темп задає свій потік, що
//  складає кадр (плавна зміна, кадр плеєра поверх) і віддає його бібліотеці NDI.
//  «Прозорий фон» — текст без фону, для титрів поверх картинки трансляції.
// =============================================================================

using Avalonia.Threading;
using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public sealed unsafe class NdiOutput
{
    public static NdiOutput Shared { get; } = new();
    static string T(string text, params object[] args) => Captions.T(text, args);

    /// Ім'я джерела для перевірок (щоб не плутати з робочим «Слово» в мережі церкви).
    public static string? SourceNameOverride { get; set; }
    public static bool ForceEnabled { get; set; }
    public string SourceName => SourceNameOverride ?? "Слово";

    /// Повне ім'я в мережі, як його бачать приймачі: «МАШИНА (Слово)» (null — джерела немає).
    public unsafe string? NetworkName
    {
        get
        {
            var sender = _sender;
            if (sender == IntPtr.Zero || NdiRuntime.SendSourceName == null) return null;
            try { var source = NdiRuntime.SendSourceName(sender); return source == null ? null : System.Runtime.InteropServices.Marshal.PtrToStringUTF8(source->Name); }
            catch { return null; }
        }
    }

    /// Що сказати в «Параметрах»: «В ефірі: Слово (2 приймачі)», «Зупинена», чому немає.
    public string Status { get; private set; } = "";
    public int Connections { get; private set; }
    public long FramesSent => Interlocked.Read(ref _sent);
    public event Action? StatusChanged;

    readonly object _gate = new();
    IntPtr _sender;
    Thread? _pump;
    volatile bool _stopping;
    long _sent;
    int _width = 1920, _height = 1080;
    double _fps = 30;
    bool _transparent, _sendVideo;
    volatile bool _videoOnScreen;
    SKImage? _current, _previous;
    long _fadeStartTicks;
    double _fadeSeconds;
    bool _renderPosted;
    bool _hooked;
    // Друге джерело «Слово Wi-Fi» (NDIWiFiOutput): той самий кадр, зменшений і рідше.
    // Відправник створюється й закривається в потоці трансляції — там же, де ним користуються.
    volatile bool _wifiWanted;
    int _wifiHeight = 360, _wifiFps = 15;
    public static bool ForceWiFi { get; set; }
    public string WiFiStatus { get; private set; } = "";
    public long WiFiFramesSent => Interlocked.Read(ref _wifiSent);
    long _wifiSent;

    public bool IsRunning => _sender != IntPtr.Zero;

    // ── Звук (syncAudio / submitAudio Mac) ─────────────────────────────────
    //  Звук програми (AppAudioCapture) іде в те саме джерело, що й картинка, — коли
    //  трансляція йде, звук дозволено «Параметрами» (NdiSendAudio) і щось грає
    //  (плеєр або фонограма; audioWanted на Mac). Порції відправляються одразу з
    //  потоку захвату: NDI дозволяє слати звук і картинку з різних потоків.

    int _frameGeneration;
    AppAudioCapture? _audio;
    bool _sendsAudio = true, _audioWanted;
    readonly object _sendGate = new();
    long _audioIn, _audioSent, _audioNoSender;
    /// Для перевірок: звук іде й без того, щоб щось грало.
    public static bool ForceAudio;
    public string AudioState { get; private set; } = "";
    public long AudioIn => Interlocked.Read(ref _audioIn);
    public long AudioSent => Interlocked.Read(ref _audioSent);
    public long AudioNoSender => Interlocked.Read(ref _audioNoSender);
    public long AudioCaptured => _audio?.Delivered ?? 0;

    void SetAudioState(string text)
    {
        if (AudioState == text) return;
        AudioState = text;
        StatusChanged?.Invoke();
    }

    public void SetAudioWanted(bool wanted)
    {
        if (_audioWanted == wanted) return;
        _audioWanted = wanted;
        SyncAudio();
    }

    void SyncAudio()
    {
        var wanted = IsRunning && _sendsAudio && (_audioWanted || ForceAudio);
        if (wanted)
        {
            if (_audio != null) return;
            var capture = new AppAudioCapture();
            capture.OnState = text => Dispatcher.UIThread.Post(() => SetAudioState(text.StartsWith("звук: ") && text.Contains('(') ? text : T(text)));
            capture.OnSamples = SubmitAudio;
            _audio = capture;
            SetAudioState(T("звук: запускается…"));
            capture.Start();
        }
        else
        {
            _audio?.Stop();
            _audio = null;
            SetAudioState(!_sendsAudio ? T("звук: выключен настройкой") : "");
        }
    }

    /// Порція звуку, площинна (канал за каналом). Будь-який потік.
    public void SubmitAudio(float[] planar, int channels, int samples, int sampleRate)
    {
        Interlocked.Increment(ref _audioIn);
        lock (_sendGate)
        {
            if (_sender == IntPtr.Zero) { Interlocked.Increment(ref _audioNoSender); return; }
            fixed (float* data = planar)
            {
                var frame = new NdiRuntime.AudioFrame
                {
                    SampleRate = sampleRate, Channels = channels, Samples = samples, Timecode = NdiRuntime.TimecodeSynthesize,
                    Data = (IntPtr)data, ChannelStride = samples * sizeof(float),
                };
                NdiRuntime.SendAudio(_sender, &frame);
            }
        }
        Interlocked.Increment(ref _audioSent);
    }

    /// Застосувати «Параметри → Медіа → NDI»: увімкнути, вимкнути, змінити кадр.
    public void Apply(ProgramOptions options)
    {
        HookOnce();
        var enabled = options.NdiEnabled || ForceEnabled;
        if (!enabled)
        {
            Stop();
            SetStatus(T("Остановлена"));
            return;
        }
        var (hallWidth, hallHeight) = ProjectionController.Shared.FrameSize();
        var height = options.NdiFrameHeight is > 0 and var wanted ? wanted : (hallHeight > 0 ? hallHeight : 1080);
        var width = options.NdiFrameHeight is > 0 ? (int)Math.Round(height * 16.0 / 9) : (hallWidth > 0 ? hallWidth : 1920);
        var index = options.NdiFrameRateIndex;
        var fps = index >= 0 && index < OutputConfiguration.NdiFrameRates.Count ? OutputConfiguration.NdiFrameRates[index] : 30;
        lock (_gate)
        {
            var changed = width != _width || height != _height || Math.Abs(fps - _fps) > 0.01 || _transparent != options.NdiTransparentBackground;
            _width = width & ~1;
            _height = height & ~1;
            _fps = Math.Clamp(fps, 1, 60);
            _transparent = options.NdiTransparentBackground;
            _sendVideo = options.NdiSendVideo;
            _sendsAudio = options.NdiSendAudio ?? true;
            if (changed) { _previous?.Dispose(); _previous = null; }
            _wifiHeight = options.NdiWiFiHeight is 540 or 360 or 270 ? options.NdiWiFiHeight.Value : 360;
            _wifiFps = Math.Clamp(options.NdiWiFiFrameRate ?? 15, 1, 30);
        }
        _wifiWanted = (options.NdiWiFiEnabled ?? false) || ForceWiFi;
        if (!IsRunning) Start();
        SyncAudio();
        ContentChanged();
    }

    void HookOnce()
    {
        if (_hooked) return;
        _hooked = true;
        var state = AppState.Shared;
        state.MediaScreenChanged += () => _videoOnScreen = state.Media.IsVideoOnScreen;
        // Звук потрібен, поки щось грає — плеєр або фонограма (audioWanted Mac).
        void Playing() => Dispatcher.UIThread.Post(() => SetAudioWanted(state.Media.IsPlaying || (state.Backing?.IsPlaying ?? false)));
        state.Media.Changed += Playing;
        if (state.Backing is { } backing) backing.Changed += Playing;
        state.LiveChanged += ContentChanged;
        Signals.Shared.Subscribe(Signals.Kind.Live, ContentChanged);
    }

    void Start()
    {
        if (!NdiRuntime.IsAvailable)
        {
            SetStatus(NdiRuntime.Problem ?? T("NDI не установлен"));
            return;
        }
        var name = System.Runtime.InteropServices.Marshal.StringToCoTaskMemUTF8(SourceName);
        try
        {
            var create = new NdiRuntime.SendCreate { Name = name, Groups = IntPtr.Zero, ClockVideo = true, ClockAudio = false };
            _sender = NdiRuntime.SendCreateFn(&create);
        }
        finally { System.Runtime.InteropServices.Marshal.FreeCoTaskMem(name); }
        if (_sender == IntPtr.Zero)
        {
            SetStatus(T("NDI не дал создать источник"));
            Journal.Say($"NDI: не вдалося створити джерело «{SourceName}»");
            return;
        }
        Journal.Say($"NDI: джерело «{SourceName}» створено, {_width}×{_height}, {_fps:0.##} кадр/с");
        _stopping = false;
        _videoOnScreen = AppState.Shared.Media.IsVideoOnScreen;
        var pump = _pump = new Thread(Pump) { IsBackground = true, Name = "slovo-ndi", Priority = ThreadPriority.AboveNormal };
        pump.Start();
        SetStatus(T("В эфире: %s", SourceName));
    }

    public void Stop()
    {
        // Звук — першим: потік захвату шле в те саме джерело.
        _audio?.Stop();
        _audio = null;
        if (_pump is { } pump)
        {
            _stopping = true;
            pump.Join(2000);
            _pump = null;
        }
        lock (_sendGate)
        {
            if (_sender != IntPtr.Zero)
            {
                NdiRuntime.SendDestroy(_sender);
                _sender = IntPtr.Zero;
                Journal.Say($"NDI: джерело «{SourceName}» закрито");
            }
        }
        lock (_gate)
        {
            _current?.Dispose(); _current = null;
            _previous?.Dispose(); _previous = null;
        }
        Connections = 0;
        WiFiStatus = "";
    }

    void SetStatus(string text)
    {
        if (Status == text) return;
        Status = text;
        StatusChanged?.Invoke();
    }

    /// Змінився вміст залу — намалювати кадр NDI (кілька подій поспіль — один кадр).
    public void ContentChanged()
    {
        if (!IsRunning || _renderPosted) return;
        _renderPosted = true;
        Dispatcher.UIThread.Post(() =>
        {
            _renderPosted = false;
            if (!IsRunning || MainWindow.Shared?.Output is not { } driver) return;
            int width, height; bool transparent;
            lock (_gate) { width = _width; height = _height; transparent = _transparent; }
            var generation = ++_frameGeneration;
            var fade = Math.Clamp(AppState.Shared.Style.TransitionDuration, 0, 2);
            // Малюється у фоні (OutputDriver.RenderOutputFrame): головний потік не стоїть.
            driver.RenderOutputFrame("ndi", generation, width, height, transparent, (image, done) =>
            {
                if (image == null) return;
                if (done != _frameGeneration || !IsRunning) { image.Dispose(); return; }
                lock (_gate)
                {
                    _previous?.Dispose();
                    _previous = _current;
                    _current = image;
                    _fadeStartTicks = Environment.TickCount64;
                    // Плавна зміна, як у залі (на Mac — змішування кадрів SlideFrameRenderer+Blend).
                    _fadeSeconds = fade;
                }
            });
        }, DispatcherPriority.Background);
    }

    /// Потік трансляції: скласти кадр і віддати; бібліотека сама тримає темп (clock_video).
    void Pump()
    {
        byte[]? pixels = null, smallPixels = null;
        SKSurface? surface = null, small = null;
        int surfaceWidth = 0, surfaceHeight = 0;
        var lastCount = Environment.TickCount64;
        var wifi = IntPtr.Zero;
        long wifiLast = 0;
        try
        {
            while (!_stopping)
            {
                int width, height; double fps; bool transparent, sendVideo;
                lock (_gate) { width = _width; height = _height; fps = _fps; transparent = _transparent; sendVideo = _sendVideo; }
                if (surface == null || surfaceWidth != width || surfaceHeight != height)
                {
                    surface?.Dispose();
                    surface = SKSurface.Create(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul));
                    surfaceWidth = width; surfaceHeight = height;
                    pixels = new byte[width * height * 4];
                }
                var canvas = surface.Canvas;
                canvas.Clear(transparent ? SKColors.Transparent : SKColors.Black);
                var whole = new SKRect(0, 0, width, height);
                lock (_gate)
                {
                    var fade = _fadeSeconds <= 0 ? 1 : Math.Clamp((Environment.TickCount64 - _fadeStartTicks) / 1000.0 / _fadeSeconds, 0, 1);
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
                // Кадр плеєра (і захопленого екрана) — поверх, як у залі.
                if (sendVideo && _videoOnScreen) VideoFrames.Shared.DrawLatest(canvas, whole);
                canvas.Flush();
                fixed (byte* buffer = pixels)
                {
                    // NDI чекає прозорість «як є» (не помножену): Skia перераховує при читанні.
                    var info = new SKImageInfo(width, height, SKColorType.Bgra8888, transparent ? SKAlphaType.Unpremul : SKAlphaType.Opaque);
                    surface.ReadPixels(info, (IntPtr)buffer, width * 4, 0, 0);
                    var frame = new NdiRuntime.VideoFrame
                    {
                        XRes = width, YRes = height, FourCC = transparent ? NdiRuntime.FourCC_BGRA : NdiRuntime.FourCC_BGRX,
                        FrameRateN = (int)Math.Round(fps * 1000), FrameRateD = 1000, AspectRatio = (float)width / height,
                        FrameFormat = NdiRuntime.FrameProgressive, Timecode = NdiRuntime.TimecodeSynthesize,
                        Data = (IntPtr)buffer, LineStride = width * 4,
                    };
                    NdiRuntime.SendVideo(_sender, &frame);
                }
                Interlocked.Increment(ref _sent);
                // «Слово Wi-Fi»: не частіше за свою частоту, той самий кадр меншим.
                if (_wifiWanted && wifi == IntPtr.Zero) wifi = CreateWiFi();
                else if (!_wifiWanted && wifi != IntPtr.Zero) { NdiRuntime.SendDestroy(wifi); wifi = IntPtr.Zero; PostWiFiStatus(""); }
                int wifiHeight, wifiFps;
                lock (_gate) { wifiHeight = _wifiHeight; wifiFps = _wifiFps; }
                if (wifi != IntPtr.Zero && Environment.TickCount64 - wifiLast >= 1000.0 / wifiFps)
                {
                    wifiLast = Environment.TickCount64;
                    var wifiWidth = (int)Math.Round(wifiHeight * (double)width / height) & ~1;
                    if (small == null || small.Canvas.DeviceClipBounds.Width != wifiWidth || small.Canvas.DeviceClipBounds.Height != wifiHeight)
                    {
                        small?.Dispose();
                        small = SKSurface.Create(new SKImageInfo(wifiWidth, wifiHeight, SKColorType.Bgra8888, SKAlphaType.Premul));
                        smallPixels = new byte[wifiWidth * wifiHeight * 4];
                    }
                    using (var whole2 = surface.Snapshot())
                    {
                        small.Canvas.Clear(SKColors.Transparent);
                        using var scale = new SKPaint { FilterQuality = SKFilterQuality.Medium };
                        small.Canvas.DrawImage(whole2, new SKRect(0, 0, wifiWidth, wifiHeight), scale);
                        small.Canvas.Flush();
                    }
                    fixed (byte* buffer = smallPixels)
                    {
                        var info = new SKImageInfo(wifiWidth, wifiHeight, SKColorType.Bgra8888, transparent ? SKAlphaType.Unpremul : SKAlphaType.Opaque);
                        small.ReadPixels(info, (IntPtr)buffer, wifiWidth * 4, 0, 0);
                        var frame = new NdiRuntime.VideoFrame
                        {
                            XRes = wifiWidth, YRes = wifiHeight, FourCC = transparent ? NdiRuntime.FourCC_BGRA : NdiRuntime.FourCC_BGRX,
                            FrameRateN = wifiFps * 1000, FrameRateD = 1000, AspectRatio = (float)wifiWidth / wifiHeight,
                            FrameFormat = NdiRuntime.FrameProgressive, Timecode = NdiRuntime.TimecodeSynthesize,
                            Data = (IntPtr)buffer, LineStride = wifiWidth * 4,
                        };
                        NdiRuntime.SendVideo(wifi, &frame);
                    }
                    Interlocked.Increment(ref _wifiSent);
                }
                if (Environment.TickCount64 - lastCount > 1000)
                {
                    lastCount = Environment.TickCount64;
                    var connections = NdiRuntime.SendConnections(_sender, 0);
                    if (connections != Connections)
                    {
                        Connections = connections;
                        Dispatcher.UIThread.Post(() => SetStatus(connections > 0
                            ? T("В эфире: %s", SourceName) + " · " + T("приёмников: %s", connections.ToString())
                            : T("В эфире: %s", SourceName)));
                    }
                }
            }
        }
        catch (Exception error) { Journal.Say($"NDI: потік трансляції впав — {error.Message}"); }
        finally
        {
            surface?.Dispose();
            small?.Dispose();
            if (wifi != IntPtr.Zero) { NdiRuntime.SendDestroy(wifi); PostWiFiStatus(""); }
        }
    }

    /// Друге джерело — без власного годинника: темп тримає основне.
    IntPtr CreateWiFi()
    {
        var wifiName = SourceName + " Wi-Fi";
        var name = System.Runtime.InteropServices.Marshal.StringToCoTaskMemUTF8(wifiName);
        try
        {
            var create = new NdiRuntime.SendCreate { Name = name, ClockVideo = false, ClockAudio = false };
            var sender = NdiRuntime.SendCreateFn(&create);
            Journal.Say(sender == IntPtr.Zero ? $"NDI: не вдалося створити «{wifiName}»" : $"NDI: джерело «{wifiName}» створено, {_wifiHeight} рядків, {_wifiFps} кадр/с");
            PostWiFiStatus(sender == IntPtr.Zero ? T("NDI не дал создать источник") : T("В эфире: %s", wifiName));
            return sender;
        }
        finally { System.Runtime.InteropServices.Marshal.FreeCoTaskMem(name); }
    }

    void PostWiFiStatus(string text) => Dispatcher.UIThread.Post(() =>
    {
        if (WiFiStatus == text) return;
        WiFiStatus = text;
        StatusChanged?.Invoke();
    });

    // --- Перевірка: прийняти власне джерело на цьому ж комп'ютері --------------------

    /// Знайти своє джерело й прийняти звук: скільки порцій і відліків дійшло, який рівень
    /// (середньоквадратичний, дБ відносно повної шкали) — щоб відрізнити звук від тиші.
    public static string ReceiveAudioCheck(string name, int seconds = 8)
    {
        if (!NdiRuntime.IsAvailable) return NdiRuntime.Problem ?? "NDI";
        var find = new NdiRuntime.FindCreate { ShowLocalSources = true };
        var finder = NdiRuntime.FindCreateFn(&find);
        if (finder == IntPtr.Zero) return "find_create";
        try
        {
            var until = DateTime.Now.AddSeconds(seconds);
            NdiRuntime.Source? mine = null;
            uint count = 0;
            while (DateTime.Now < until && mine == null)
            {
                NdiRuntime.FindWait(finder, 1000);
                var sources = NdiRuntime.FindSources(finder, &count);
                for (var i = 0; i < count; i++)
                    if ((System.Runtime.InteropServices.Marshal.PtrToStringUTF8(sources[i].Name) ?? "").EndsWith("(" + name + ")")) mine = sources[i];
            }
            if (mine is not { } source) return $"джерела «{name}» не знайдено (джерел у мережі: {count})";
            var create = new NdiRuntime.RecvCreate { Source = source, ColorFormat = 0, Bandwidth = 100, AllowFields = false };
            var receiver = NdiRuntime.RecvCreateFn(&create);
            if (receiver == IntPtr.Zero) return "recv_create";
            try
            {
                long frames = 0, samples = 0; double sum = 0; int rate = 0, channels = 0;
                var deadline = DateTime.Now.AddSeconds(seconds);
                while (DateTime.Now < deadline)
                {
                    NdiRuntime.VideoFrame video;
                    NdiRuntime.AudioFrame audio;
                    var kind = NdiRuntime.RecvCaptureAudio(receiver, &video, &audio, IntPtr.Zero, 500);
                    if (kind == 1) { NdiRuntime.RecvFreeVideo(receiver, &video); continue; }
                    if (kind != 2) continue;
                    frames++; rate = audio.SampleRate; channels = audio.Channels;
                    var data = (float*)audio.Data;
                    for (var i = 0; i < audio.Samples; i++) { var v = data[i]; sum += v * v; }
                    samples += audio.Samples;
                    NdiRuntime.RecvFreeAudio(receiver, &audio);
                    if (frames >= 150) break;
                }
                if (frames == 0) return "звуку не дочекалися";
                var rms = Math.Sqrt(sum / Math.Max(1, samples));
                var db = rms > 0 ? 20 * Math.Log10(rms) : double.NegativeInfinity;
                return $"порцій {frames}, відліків {samples} ({rate} Гц, каналів {channels}), рівень {(double.IsInfinity(db) ? "тиша" : db.ToString("0.0") + " дБFS")}";
            }
            finally { NdiRuntime.RecvDestroy(receiver); }
        }
        finally { NdiRuntime.FindDestroy(finder); }
    }

    /// Знайти своє джерело й прийняти кадр (як самоперевірка Mac). Опис того, що дійшло.
    /// Перевірці: які джерела NDI видно звідси за `seconds` секунд (повні імена «МАШИНА (джерело)»).
    public static string ListSources(int seconds)
    {
        if (!NdiRuntime.IsAvailable) return NdiRuntime.Problem ?? "NDI";
        var find = new NdiRuntime.FindCreate { ShowLocalSources = true };
        var finder = NdiRuntime.FindCreateFn(&find);
        if (finder == IntPtr.Zero) return "find_create";
        try
        {
            var until = DateTime.Now.AddSeconds(seconds);
            var names = new SortedSet<string>();
            while (DateTime.Now < until)
            {
                NdiRuntime.FindWait(finder, 1000);
                uint count = 0;
                var sources = NdiRuntime.FindSources(finder, &count);
                for (var i = 0; i < count; i++)
                {
                    var full = System.Runtime.InteropServices.Marshal.PtrToStringUTF8(sources[i].Name) ?? "";
                    var url = System.Runtime.InteropServices.Marshal.PtrToStringUTF8(sources[i].Address) ?? "";
                    names.Add(full + (url.Length > 0 ? " @ " + url : ""));
                }
            }
            return names.Count == 0 ? "жодного" : string.Join(" | ", names);
        }
        finally { NdiRuntime.FindDestroy(finder); }
    }

    public static string ReceiveCheck(string name, int seconds = 8, string? savePath = null)
    {
        if (!NdiRuntime.IsAvailable) return NdiRuntime.Problem ?? "NDI";
        var find = new NdiRuntime.FindCreate { ShowLocalSources = true };
        var finder = NdiRuntime.FindCreateFn(&find);
        if (finder == IntPtr.Zero) return "find_create";
        try
        {
            var until = DateTime.Now.AddSeconds(seconds);
            NdiRuntime.Source* sources = null;
            uint count = 0;
            NdiRuntime.Source? mine = null;
            while (DateTime.Now < until && mine == null)
            {
                NdiRuntime.FindWait(finder, 1000);
                sources = NdiRuntime.FindSources(finder, &count);
                for (var i = 0; i < count; i++)
                {
                    var full = System.Runtime.InteropServices.Marshal.PtrToStringUTF8(sources[i].Name) ?? "";
                    if (full.EndsWith("(" + name + ")")) mine = sources[i];
                }
            }
            if (mine is not { } source) return $"джерела «{name}» не знайдено (джерел у мережі: {count})";
            var create = new NdiRuntime.RecvCreate { Source = source, ColorFormat = 0, Bandwidth = 100, AllowFields = false };
            var receiver = NdiRuntime.RecvCreateFn(&create);
            if (receiver == IntPtr.Zero) return "recv_create";
            try
            {
                var deadline = DateTime.Now.AddSeconds(seconds);
                while (DateTime.Now < deadline)
                {
                    NdiRuntime.VideoFrame frame;
                    var kind = NdiRuntime.RecvCapture(receiver, &frame, IntPtr.Zero, IntPtr.Zero, 1000);
                    if (kind != 1) continue;
                    // Середній колір кадру — щоб бачити, що прийшла саме картинка залу.
                    long r = 0, g = 0, b = 0, n = 0;
                    var data = (byte*)frame.Data;
                    for (var y = 0; y < frame.YRes; y += 8)
                        for (var x = 0; x < frame.XRes; x += 8)
                        {
                            var p = data + (long)y * frame.LineStride + x * 4;
                            b += p[0]; g += p[1]; r += p[2]; n++;
                        }
                    var fourcc = new string(new[] { (char)(frame.FourCC & 0xFF), (char)((frame.FourCC >> 8) & 0xFF), (char)((frame.FourCC >> 16) & 0xFF), (char)(frame.FourCC >> 24) });
                    var text = $"кадр {frame.XRes}×{frame.YRes} {fourcc} {frame.FrameRateN}/{frame.FrameRateD}, середній колір {r / Math.Max(1, n)},{g / Math.Max(1, n)},{b / Math.Max(1, n)}";
                    if (savePath != null)
                    {
                        using var bitmap = new SKBitmap(new SKImageInfo(frame.XRes, frame.YRes, SKColorType.Bgra8888, SKAlphaType.Unpremul));
                        for (var row = 0; row < frame.YRes; row++)
                            Buffer.MemoryCopy(data + (long)row * frame.LineStride, (byte*)bitmap.GetPixels() + (long)row * bitmap.RowBytes, bitmap.RowBytes, frame.XRes * 4);
                        using var file = File.Create(savePath);
                        bitmap.Encode(file, SKEncodedImageFormat.Png, 90);
                    }
                    NdiRuntime.RecvFreeVideo(receiver, &frame);
                    return text;
                }
                return "кадру не дочекалися";
            }
            finally { NdiRuntime.RecvDestroy(receiver); }
        }
        finally { NdiRuntime.FindDestroy(finder); }
    }
}
