// =============================================================================
//  AppAudioCapture.cs — звук самої програми для NDI (AppAudioCapture + PlayerAudioTap Mac)
// =============================================================================
//  Власник (про Mac): «по NDI не передаётся звук». На Mac звук береться відводом
//  плеєра (файли) і системним захватом звуку процесу (потоки, YouTube) — останній
//  macOS дає лише після дозволу. У Windows є рівна річ без жодних дозволів —
//  захват звуку свого процесу (WASAPI process loopback, Windows 10 2004+ і 11):
//  усе, що грає «Слово» — фільм, потік, ролик, фонограма, — потрапляє в
//  трансляцію одним шляхом, як «весь звук програми» на Mac.
//
//  ActivateAudioInterfaceAsync("VAD\Process_Loopback", IAudioClient, параметри з
//  нашим PID) → IAudioClient у спільному режимі з LOOPBACK | EVENTCALLBACK і
//  форматом 48 кГц / 2 канали / float (GetMixFormat для такого клієнта не
//  працює — формат кажемо самі, AUTOCONVERTPCM перетворить). Потік захвату
//  чекає подію, забирає пакети й віддає їх площинними (канал за каналом) —
//  так їх і чекає NDI. Тиша (пакет із позначкою SILENT) — нулями.
// =============================================================================

using System.Runtime.InteropServices;

namespace Slovo.App;

public sealed class AppAudioCapture : IDisposable
{
    public const int SampleRate = 48000, Channels = 2;

    /// Площинні відліки: [канал 0 — n відліків][канал 1 — n відліків]; викликається з потоку захвату.
    public Action<float[], int, int, int>? OnSamples;
    /// Стан для «Параметрів» («звук: іде», «звук: потрібна Windows 10 2004…»).
    public Action<string>? OnState;
    public long Delivered => Interlocked.Read(ref _delivered);
    long _delivered;
    /// Чий звук: за замовчанням — «Слово» з усім деревом процесів (і рушієм WebView2).
    public int TargetProcessId { get; init; } = Environment.ProcessId;

    /// Перевірці: окреме захоплення на `milliseconds` — порції, відліки, пік (у фоні, не в головному потоці).
    public static (long Packets, long Samples, double Peak) Probe(int processId, int milliseconds)
    {
        long packets = 0, samples = 0; double peak = 0;
        using var capture = new AppAudioCapture { TargetProcessId = processId };
        capture.OnSamples = (planar, channels, count, rate) =>
        {
            Interlocked.Increment(ref packets);
            Interlocked.Add(ref samples, count);
            double p = 0; for (var i = 0; i < count * channels; i++) p = Math.Max(p, Math.Abs(planar[i]));
            lock (capture) peak = Math.Max(peak, p);
        };
        capture.Start();
        Thread.Sleep(milliseconds);
        capture.Stop();
        return (packets, samples, peak);
    }

    Thread? _thread;
    volatile bool _stopping;

    public void Start()
    {
        if (_thread != null) return;
        _stopping = false;
        _thread = new Thread(Run) { IsBackground = true, Name = "slovo-audio-capture", Priority = ThreadPriority.AboveNormal };
        _thread.Start();
    }

    public void Stop()
    {
        _stopping = true;
        _thread?.Join(2000);
        _thread = null;
    }

    public void Dispose() => Stop();

    /// Процес рушія WebView2 (браузерний; спільний для всіх видів WebView2 «Слова») — 0, поки
    /// рушія немає. Ставить WebPreviewHost. Перевірка у Windows 11 (25.11.2026): дерево процесу
    /// «Слова» звук WebView2 НЕ включає, хоч процес звуку рушія (audio.mojom.AudioService) —
    /// онук «Слова»: захоплення свого дерева дає тишу, а дерева рушія — звук ролика. Тож рушій
    /// береться окремим відводом і змішується зі своїм.
    public static volatile int WebViewProcessId;
    /// Чи грає щось у самому процесі (плеєр LibVLC, фонограми) — щоб помітити систему, де дерево
    /// «Слова» вже несе звук рушія (тоді рушій окремо не брати, інакше звук подвоїться).
    public static Func<bool>? InProcessPlaying;

    /// Один відвід: захоплення дерева процесу й черга відліків (почергово L,R).
    sealed class Tap : IDisposable
    {
        public readonly int ProcessId;
        public readonly IAudioClient Client;
        public readonly IAudioCaptureClient Capture;
        public readonly AutoResetEvent Ready = new(false);
        float[] _fifo = new float[SampleRate * Channels];
        int _start, _count;   // у числах float
        /// Коли прийшла остання порція (система шле їх і в тиші; замовкли — процесу вже нема).
        public long LastPacketAt = Environment.TickCount64;

        public Tap(int processId)
        {
            ProcessId = processId;
            Client = Activate(processId);
            var format = new WaveFormatEx
            {
                FormatTag = 3, Channels = Channels, SamplesPerSec = SampleRate, AvgBytesPerSec = SampleRate * Channels * 4,
                BlockAlign = Channels * 4, BitsPerSample = 32, Size = 0,
            };
            const uint Loopback = 0x00020000, EventCallback = 0x00040000, AutoConvert = 0x80000000, SrcDefault = 0x08000000;
            Client.Initialize(0, Loopback | EventCallback | AutoConvert | SrcDefault, 2_000_000, 0, ref format, IntPtr.Zero);
            Client.SetEventHandle(Ready.SafeWaitHandle.DangerousGetHandle());
            var iid = typeof(IAudioCaptureClient).GUID;
            Client.GetService(ref iid, out var service);
            Capture = (IAudioCaptureClient)service;
            Client.Start();
        }

        public int Frames => _count / Channels;

        /// Забрати все, що накопичила система.
        public unsafe void Drain()
        {
            while (true)
            {
                Capture.GetNextPacketSize(out var packet);
                if (packet == 0) return;
                Capture.GetBuffer(out var data, out var frames, out var flags, out _, out _);
                LastPacketAt = Environment.TickCount64;
                var floats = (int)frames * Channels;
                if (floats > 0)
                {
                    // Не більше секунди в черзі: відвід, якого ніхто не забирає, не росте без краю.
                    if (_count + floats > _fifo.Length) Skip(Math.Min(_count, _count + floats - _fifo.Length) / Channels);
                    for (var i = 0; i < floats; i++)
                        _fifo[(_start + _count + i) % _fifo.Length] = (flags & 0x2) != 0 || data == IntPtr.Zero ? 0 : ((float*)data)[i];
                    _count += Math.Min(floats, _fifo.Length);
                }
                Capture.ReleaseBuffer(frames);
            }
        }

        /// Додати `frames` відліків у площинний буфер з вагою; бракує — тиша. Пік узятого.
        public float AddTo(float[] planar, int frames, float weight)
        {
            var peak = 0f;
            var available = Math.Min(frames, Frames);
            for (var i = 0; i < available; i++)
                for (var c = 0; c < Channels; c++)
                {
                    var v = _fifo[(_start + i * Channels + c) % _fifo.Length];
                    peak = Math.Max(peak, Math.Abs(v));
                    if (weight != 0) planar[c * frames + i] += v * weight;
                }
            Skip(available);
            return peak;
        }

        public void Skip(int frames)
        {
            var floats = Math.Min(_count, frames * Channels);
            _start = (_start + floats) % _fifo.Length;
            _count -= floats;
        }

        public void Dispose()
        {
            try { Client.Stop(); } catch { }
            Marshal.ReleaseComObject(Capture);
            Marshal.ReleaseComObject(Client);
            Ready.Dispose();
        }
    }

    void Run()
    {
        if (!OperatingSystem.IsWindows()) { OnState?.Invoke("звук: захват звука программы есть только в Windows"); return; }
        Tap? own = null, web = null;
        try
        {
            own = new Tap(TargetProcessId);
            OnState?.Invoke("звук: идёт");
            Journal.Say("звук програми: захоплення запущено (48 кГц, 2 канали)");
            var planar = Array.Empty<float>();
            var webWeight = 1f;
            var sameSound = 0;
            // Відвід рушія — лише коли захоплюємо своє дерево (перевірці Probe чужого PID він не потрібен).
            var mixesWeb = TargetProcessId == Environment.ProcessId;
            while (!_stopping)
            {
                var wanted = mixesWeb ? WebViewProcessId : 0;
                if ((web?.ProcessId ?? 0) != wanted)
                {
                    web?.Dispose();
                    web = null;
                    webWeight = 1f;
                    sameSound = 0;
                    if (wanted > 0)
                    {
                        try { web = new Tap(wanted); Journal.Say($"звук програми: і рушій WebView2 (процес {wanted})"); }
                        catch (Exception error) { Journal.Say($"звук програми: рушій WebView2 не взявся — {error.Message}"); WebViewProcessId = 0; }
                    }
                }
                if (web != null) WaitHandle.WaitAny(new WaitHandle[] { own.Ready, web.Ready }, 200);
                else own.Ready.WaitOne(200);
                own.Drain();
                web?.Drain();
                // Обидва відводи йдуть від одного годинника системи — віддаємо стільки, скільки є в обох;
                // відстав один більше ніж на 0,1 с (рушій ще не грав) — за нього тиша.
                var frames = own.Frames;
                if (web != null && web.Frames < frames && frames - web.Frames < SampleRate / 10 && Environment.TickCount64 - web.LastPacketAt < 300) frames = web.Frames;
                if (frames <= 0) continue;
                if (planar.Length != frames * Channels) planar = new float[frames * Channels];
                else Array.Clear(planar);
                var ownPeak = own.AddTo(planar, frames, 1f);
                if (web != null)
                {
                    var webPeak = web.AddTo(planar, frames, webWeight);
                    // Своє дерево грає те саме, що рушій, хоча в процесі нічого не грає, — значить, ця
                    // система вже включає рушій у дерево «Слова»: окремо його не додавати.
                    if (webWeight != 0 && webPeak > 0.02f && ownPeak > 0.02f && InProcessPlaying?.Invoke() != true && Math.Abs(ownPeak - webPeak) < 0.25f * webPeak)
                    {
                        if (++sameSound >= 50)
                        {
                            webWeight = 0;
                            Journal.Say("звук програми: дерево «Слова» вже несе звук WebView2 — рушій окремо не додаю");
                        }
                    }
                    else if (sameSound > 0 && webPeak > 0.02f) sameSound = 0;
                }
                if (webWeight != 0 && web != null)
                    for (var i = 0; i < planar.Length; i++) planar[i] = Math.Clamp(planar[i], -1f, 1f);
                Interlocked.Increment(ref _delivered);
                OnSamples?.Invoke(planar, Channels, frames, SampleRate);
            }
        }
        catch (Exception error)
        {
            var text = error is COMException { HResult: unchecked((int)0x80004002) or unchecked((int)0x80070032) or unchecked((int)0x80004001) }
                ? "звук: нужна Windows 10 версии 2004 или новее"
                : Captions.T("звук: захват не запустился (%s)", error.Message);
            OnState?.Invoke(text);
            Journal.Say("звук програми: захоплення не вдалося — " + error.Message);
        }
        finally
        {
            web?.Dispose();
            own?.Dispose();
        }
    }

    // ── Активація клієнта захвату свого процесу ─────────────────────────────

    static IAudioClient Activate(int processId)
    {
        var parameters = new ActivationParams { ActivationType = 1, TargetProcessId = (uint)processId, LoopbackMode = 0 };
        var size = Marshal.SizeOf<ActivationParams>();
        var blob = Marshal.AllocHGlobal(size);
        var variant = Marshal.AllocHGlobal(Marshal.SizeOf<PropVariantBlob>());
        try
        {
            Marshal.StructureToPtr(parameters, blob, false);
            Marshal.StructureToPtr(new PropVariantBlob { Type = 65 /* VT_BLOB */, Size = (uint)size, Data = blob }, variant, false);
            var done = new Completion();
            var iid = typeof(IAudioClient).GUID;
            ActivateAudioInterfaceAsync("VAD\\Process_Loopback", ref iid, variant, done, out _);
            if (!done.Signal.WaitOne(5000)) throw new TimeoutException("ActivateAudioInterfaceAsync");
            if (done.Result < 0) Marshal.ThrowExceptionForHR(done.Result);
            return (IAudioClient)done.Interface!;
        }
        finally
        {
            Marshal.FreeHGlobal(variant);
            Marshal.FreeHGlobal(blob);
        }
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    sealed class Completion : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        public readonly ManualResetEvent Signal = new(false);
        public int Result;
        public object? Interface;

        public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation)
        {
            try
            {
                operation.GetActivateResult(out Result, out var activated);
                Interface = activated;
            }
            catch (Exception error) { Result = error.HResult; }
            finally { Signal.Set(); }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ActivationParams { public int ActivationType; public uint TargetProcessId; public int LoopbackMode; }

    [StructLayout(LayoutKind.Sequential)]
    struct PropVariantBlob { public ushort Type, Reserved1, Reserved2, Reserved3; public uint Size; public IntPtr Data; }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    struct WaveFormatEx { public ushort FormatTag, Channels; public int SamplesPerSec, AvgBytesPerSec; public ushort BlockAlign, BitsPerSample, Size; }

    [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = false)]
    static extern void ActivateAudioInterfaceAsync([MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath, ref Guid riid, IntPtr activationParams,
                                                   IActivateAudioInterfaceCompletionHandler completionHandler, out IActivateAudioInterfaceAsyncOperation operation);

    [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IActivateAudioInterfaceAsyncOperation
    {
        void GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
    }

    [ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IActivateAudioInterfaceCompletionHandler
    {
        void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation);
    }

    [ComImport, Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAgileObject { }

    [ComImport, Guid("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        void Initialize(int shareMode, uint streamFlags, long bufferDuration, long periodicity, ref WaveFormatEx format, IntPtr sessionGuid);
        void GetBufferSize(out uint frames);
        void GetStreamLatency(out long latency);
        void GetCurrentPadding(out uint frames);
        [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, IntPtr closest);
        void GetMixFormat(out IntPtr format);
        void GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        void Start();
        void Stop();
        void Reset();
        void SetEventHandle(IntPtr handle);
        void GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48A0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        void GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        void ReleaseBuffer(uint frames);
        void GetNextPacketSize(out uint frames);
    }
}
