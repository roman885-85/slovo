// =============================================================================
//  ScreenCapture.cs — захоплення монітора чи вікна чужої програми (вкладка «Екран»)
// =============================================================================
//  За ScreenCaptureModel Mac 1.3.9: список джерел (монітори, вікна інших програм),
//  «Показати» / «Сховати», 15 кадрів на секунду, курсор у кадрі, наближення точкою
//  фокуса з живого екрана. Кадр іде ТІЄЮ САМОЮ дорогою, що й кадр фільму (VideoFrames →
//  зал, «живий екран», NDI), — нічого свого, як і на Mac.
//
//  На Mac — ScreenCaptureKit; тут — GDI: монітор знімається BitBlt/StretchBlt з
//  екрана (наближення — тим самим викликом), вікно — PrintWindow із
//  PW_RENDERFULLCONTENT (так знімається й вікно, закрите іншими, і сторінки Chrome/Edge).
//  Вікна власної програми в списку немає: наведена сама на себе, картинка йде в
//  нескінченність і миготить у залі.
// =============================================================================

using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Threading;

namespace Slovo.App;

public sealed class ScreenCaptureModel
{
    static string T(string text, params object[] args) => Captions.T(text, args);

    /// Що можна показати: монітор цілком або одне вікно.
    public sealed record Source(string Id, SourceKind Kind, string Title, string Subtitle, int Width, int Height, IntPtr Handle, PixelRect Bounds)
    {
        public string KindName => Kind == SourceKind.Display ? "display" : "window";
    }

    public enum SourceKind { Display, Window }

    public List<Source> Sources { get; private set; } = new();
    public Source? Current { get; private set; }
    /// Що сказати людині: скільки джерел, чи йде показ, чому не пішов.
    public string State { get; private set; } = "";
    /// Скільки кадрів забрали — перевірці й підпису.
    public long FrameCount => Interlocked.Read(ref _frames);
    /// Дозволу на запис екрана Windows не питає.
    public bool NeedsPermission => false;
    /// Скільки кадрів на секунду брати (на Mac теж 15: більше на служінні не треба).
    public int FrameRate = 15;

    public event Action? Changed;
    void Notify() => Changed?.Invoke();

    Thread? _thread;
    volatile bool _stopping;
    long _frames;
    /// Показаний шматок кадру (частки 0…1) — з точки фокуса живого екрана.
    volatile StrongBox<Rect> _crop = new(new Rect(0, 0, 1, 1));

    public bool IsRunning => _thread != null;

    public ScreenCaptureModel()
    {
        SlideFocus.Shared.ShownChanged += () => _crop = new StrongBox<Rect>(SlideFocus.Shared.ShownRect);
    }

    // --- Список джерел --------------------------------------------------------------

    /// Перечитати, що зараз можна показати. Кличеться при відкритті вкладки.
    public void Reload()
    {
        if (!OperatingSystem.IsWindows())
        {
            Sources = new();
            State = T("Найдено источников: %s", "0");
            Notify();
            return;
        }
        var found = new List<Source>();
        foreach (var monitor in Native.Monitors())
        {
            var width = monitor.Right - monitor.Left;
            var height = monitor.Bottom - monitor.Top;
            found.Add(new Source($"display-{found.Count + 1}", SourceKind.Display, T("Монитор %s", (found.Count + 1).ToString()),
                                 $"{width}×{height}", width, height, IntPtr.Zero, new PixelRect(monitor.Left, monitor.Top, width, height)));
        }
        var own = Environment.ProcessId;
        var names = new Dictionary<uint, string>();
        foreach (var (handle, title, pid, bounds) in Native.Windows())
        {
            if (pid == own || title.Length == 0 || bounds.Width <= 120 || bounds.Height <= 90) continue;
            if (!names.TryGetValue(pid, out var app)) names[pid] = app = AppName(pid);
            found.Add(new Source($"window-{handle}", SourceKind.Window, title, app, bounds.Width, bounds.Height, handle, bounds));
        }
        Sources = found;
        State = T("Найдено источников: %s", found.Count.ToString());
        Notify();
    }

    /// Назва програми для другого рядка: опис із файла, а без доступу — ім'я процесу.
    static string AppName(uint pid)
    {
        try
        {
            using var process = Process.GetProcessById((int)pid);
            try
            {
                if (process.MainModule?.FileVersionInfo.FileDescription is { Length: > 0 } description) return description;
            }
            catch { }
            return process.ProcessName;
        }
        catch { return ""; }
    }

    /// Джерела для знімка перевірки (на Mac списку вікон Windows немає).
    internal void SetSourcesForCheck(List<Source> sources)
    {
        Sources = sources;
        State = T("Найдено источников: %s", sources.Count.ToString());
        Notify();
    }

    // --- Показ ------------------------------------------------------------------------

    /// Почати показ джерела. false — не вийшло (причина лишається в State).
    public bool Start(Source source)
    {
        Stop();
        if (!OperatingSystem.IsWindows())
        {
            State = T("Не удалось начать захват: %s", T("этой функции в Windows-версии ещё нет"));
            Notify();
            return false;
        }
        if (source.Kind == SourceKind.Window && !Native.IsWindow(source.Handle))
        {
            State = T("Источник больше не открыт — обновите список");
            Notify();
            return false;
        }
        _crop = new StrongBox<Rect>(SlideFocus.Shared.ShownRect);
        Interlocked.Exchange(ref _frames, 0);
        _stopping = false;
        Current = source;
        State = T("Показывается: %s", source.Title);
        var thread = new Thread(() => Run(source)) { IsBackground = true, Name = "slovo-capture", Priority = ThreadPriority.AboveNormal };
        _thread = thread;
        thread.Start();
        Notify();
        return true;
    }

    public void Stop()
    {
        if (_thread is not { } thread) return;
        _stopping = true;
        thread.Join(2000);
        _thread = null;
        Current = null;
        State = "";
        Notify();
    }

    /// Потік захоплення: кадр — пауза до наступного — кадр.
    void Run(Source source)
    {
        using var grabber = new Grabber();
        var interval = TimeSpan.FromSeconds(1.0 / Math.Max(1, FrameRate));
        var clock = Stopwatch.StartNew();
        var next = TimeSpan.Zero;
        var failures = 0;
        while (!_stopping)
        {
            bool ok;
            try { ok = grabber.Grab(source, _crop.Value); }
            catch (Exception error)
            {
                ok = false;
                if (failures == 0) Journal.Say($"екран: кадр «{source.Title}» не знято — {error.Message}");
            }
            if (ok) { failures = 0; Interlocked.Increment(ref _frames); }
            else if (++failures == 1 && source.Kind == SourceKind.Window && !Native.IsWindow(source.Handle))
            {
                // Вікно закрили — показ зупиняється сам, а людина бачить, чому.
                Dispatcher.UIThread.Post(() =>
                {
                    if (Current?.Id != source.Id) return;
                    LostSource?.Invoke();
                    State = T("Источник больше не открыт — обновите список");
                    Notify();
                });
                return;
            }
            next += interval;
            var wait = next - clock.Elapsed;
            if (wait > TimeSpan.Zero) Thread.Sleep(wait);
            else next = clock.Elapsed;
        }
    }

    /// Джерело зникло під час показу (вікно закрили) — AppState знімає показ.
    public Action? LostSource;

    // --- Кадр ---------------------------------------------------------------------------

    /// Знімач одного потоку: свої DC і бітмапи (GDI-об'єкти живуть у потоці, що їх створив).
    sealed class Grabber : IDisposable
    {
        IntPtr _outDC, _outBitmap, _outBits, _oldOut;
        int _outWidth, _outHeight;
        IntPtr _tmpDC, _tmpBitmap, _tmpBits, _oldTmp;
        int _tmpWidth, _tmpHeight;

        public bool Grab(Source source, Rect crop)
        {
            if (source.Kind == SourceKind.Display) return GrabDisplay(source, crop);
            return GrabWindow(source, crop);
        }

        bool _logged;

        bool GrabDisplay(Source source, Rect crop)
        {
            var b = source.Bounds;
            Prepare(ref _outDC, ref _outBitmap, ref _outBits, ref _oldOut, ref _outWidth, ref _outHeight, b.Width, b.Height);
            var (cx, cy, cw, ch) = Part(b.Width, b.Height, crop);
            if (!_logged)
            {
                _logged = true;
                Journal.Say($"екран: монітор {b.X},{b.Y} {b.Width}×{b.Height}, шматок {cx},{cy} {cw}×{ch} (фокус {crop.X:0.###},{crop.Y:0.###} {crop.Width:0.###}×{crop.Height:0.###})");
            }
            var screen = Native.GetDC(IntPtr.Zero);
            try
            {
                if (cw == b.Width && ch == b.Height)
                    Native.BitBlt(_outDC, 0, 0, b.Width, b.Height, screen, b.X, b.Y, Native.SRCCOPY | Native.CAPTUREBLT);
                else
                {
                    Native.SetStretchBltMode(_outDC, Native.HALFTONE);
                    Native.SetBrushOrgEx(_outDC, 0, 0, IntPtr.Zero);
                    Native.StretchBlt(_outDC, 0, 0, b.Width, b.Height, screen, b.X + cx, b.Y + cy, cw, ch, Native.SRCCOPY | Native.CAPTUREBLT);
                }
            }
            finally { Native.ReleaseDC(IntPtr.Zero, screen); }
            DrawCursor(_outDC, b.X + cx, b.Y + cy, cw, ch, b.Width, b.Height);
            Publish(b.Width, b.Height);
            return true;
        }

        bool GrabWindow(Source source, Rect crop)
        {
            var handle = source.Handle;
            if (!Native.IsWindow(handle)) return false;
            if (!Native.GetWindowRect(handle, out var window)) return false;
            var visible = Native.FrameBounds(handle) ?? window;
            var fullWidth = window.Right - window.Left;
            var fullHeight = window.Bottom - window.Top;
            var width = visible.Right - visible.Left;
            var height = visible.Bottom - visible.Top;
            if (fullWidth < 2 || fullHeight < 2 || width < 2 || height < 2) return false;
            Prepare(ref _tmpDC, ref _tmpBitmap, ref _tmpBits, ref _oldTmp, ref _tmpWidth, ref _tmpHeight, fullWidth, fullHeight);
            if (!Native.PrintWindow(handle, _tmpDC, Native.PW_RENDERFULLCONTENT)) return false;
            Prepare(ref _outDC, ref _outBitmap, ref _outBits, ref _oldOut, ref _outWidth, ref _outHeight, width, height);
            var offsetX = visible.Left - window.Left;
            var offsetY = visible.Top - window.Top;
            var (cx, cy, cw, ch) = Part(width, height, crop);
            if (cw == width && ch == height)
                Native.BitBlt(_outDC, 0, 0, width, height, _tmpDC, offsetX, offsetY, Native.SRCCOPY);
            else
            {
                Native.SetStretchBltMode(_outDC, Native.HALFTONE);
                Native.SetBrushOrgEx(_outDC, 0, 0, IntPtr.Zero);
                Native.StretchBlt(_outDC, 0, 0, width, height, _tmpDC, offsetX + cx, offsetY + cy, cw, ch, Native.SRCCOPY);
            }
            DrawCursor(_outDC, visible.Left + cx, visible.Top + cy, cw, ch, width, height);
            Publish(width, height);
            return true;
        }

        /// Шматок кадру за точкою фокуса (у пікселях джерела).
        static (int X, int Y, int W, int H) Part(int width, int height, Rect crop)
        {
            // Порожній шматок (ще не заданий фокус) — як увесь кадр.
            if (crop.Width <= 0 || crop.Height <= 0 || (crop.Width >= 0.999 && crop.Height >= 0.999)) return (0, 0, width, height);
            var w = Math.Clamp((int)Math.Round(crop.Width * width), 8, width);
            var h = Math.Clamp((int)Math.Round(crop.Height * height), 8, height);
            var x = Math.Clamp((int)Math.Round(crop.X * width), 0, width - w);
            var y = Math.Clamp((int)Math.Round(crop.Y * height), 0, height - h);
            return (x, y, w, h);
        }

        /// Курсор у кадрі (на Mac showsCursor): там, де він на екрані, і в масштабі наближення.
        static void DrawCursor(IntPtr dc, int left, int top, int partWidth, int partHeight, int outWidth, int outHeight)
        {
            var info = new Native.CURSORINFO { cbSize = Marshal.SizeOf<Native.CURSORINFO>() };
            if (!Native.GetCursorInfo(ref info) || (info.flags & Native.CURSOR_SHOWING) == 0 || info.hCursor == IntPtr.Zero) return;
            if (info.ptScreenPos.X < left || info.ptScreenPos.Y < top || info.ptScreenPos.X >= left + partWidth || info.ptScreenPos.Y >= top + partHeight) return;
            int hotX = 0, hotY = 0;
            if (Native.GetIconInfo(info.hCursor, out var icon))
            {
                hotX = icon.xHotspot; hotY = icon.yHotspot;
                if (icon.hbmMask != IntPtr.Zero) Native.DeleteObject(icon.hbmMask);
                if (icon.hbmColor != IntPtr.Zero) Native.DeleteObject(icon.hbmColor);
            }
            var scaleX = (double)outWidth / partWidth;
            var scaleY = (double)outHeight / partHeight;
            var size = Native.GetSystemMetrics(Native.SM_CXCURSOR);
            var drawn = Math.Abs(scaleX - 1) < 0.01 ? 0 : (int)Math.Round(size * scaleX);
            var x = (int)Math.Round((info.ptScreenPos.X - left - hotX) * scaleX);
            var y = (int)Math.Round((info.ptScreenPos.Y - top - hotY) * scaleY);
            Native.DrawIconEx(dc, x, y, info.hCursor, drawn, drawn, 0, IntPtr.Zero, Native.DI_NORMAL);
        }

        /// Кадр — у спільні буфери кадрів (зал, живий екран, NDI беруть звідти).
        void Publish(int width, int height)
        {
            Native.GdiFlush();
            var frames = VideoFrames.Shared;
            if (frames.Width != width || frames.Height != height) frames.Configure(width, height);
            var target = frames.BeginWrite(out var index, out var pitch);
            if (target == IntPtr.Zero) return;
            unsafe
            {
                var rowBytes = width * 4;
                var from = (byte*)_outBits;
                var to = (byte*)target;
                if (pitch == rowBytes) Buffer.MemoryCopy(from, to, (long)rowBytes * height, (long)rowBytes * height);
                else for (var row = 0; row < height; row++) Buffer.MemoryCopy(from + (long)row * rowBytes, to + (long)row * pitch, pitch, rowBytes);
            }
            frames.Publish(index);
        }

        /// DC з DIB-бітмапою потрібного розміру (32 біти, згори донизу); той самий розмір — та сама.
        static void Prepare(ref IntPtr dc, ref IntPtr bitmap, ref IntPtr bits, ref IntPtr old, ref int haveWidth, ref int haveHeight, int width, int height)
        {
            if (dc != IntPtr.Zero && haveWidth == width && haveHeight == height) return;
            Release(ref dc, ref bitmap, ref old);
            var screen = Native.GetDC(IntPtr.Zero);
            try { dc = Native.CreateCompatibleDC(screen); }
            finally { Native.ReleaseDC(IntPtr.Zero, screen); }
            var header = new Native.BITMAPINFOHEADER
            {
                biSize = Marshal.SizeOf<Native.BITMAPINFOHEADER>(), biWidth = width, biHeight = -height, biPlanes = 1, biBitCount = 32,
            };
            bitmap = Native.CreateDIBSection(dc, ref header, 0, out bits, IntPtr.Zero, 0);
            old = Native.SelectObject(dc, bitmap);
            haveWidth = width;
            haveHeight = height;
        }

        static void Release(ref IntPtr dc, ref IntPtr bitmap, ref IntPtr old)
        {
            if (dc != IntPtr.Zero)
            {
                if (old != IntPtr.Zero) Native.SelectObject(dc, old);
                Native.DeleteDC(dc);
            }
            if (bitmap != IntPtr.Zero) Native.DeleteObject(bitmap);
            dc = bitmap = old = IntPtr.Zero;
        }

        public void Dispose()
        {
            Release(ref _outDC, ref _outBitmap, ref _oldOut);
            Release(ref _tmpDC, ref _tmpBitmap, ref _oldTmp);
        }
    }

    // --- Windows ------------------------------------------------------------------------

    static class Native
    {
        public const int SRCCOPY = 0x00CC0020, CAPTUREBLT = 0x40000000, HALFTONE = 4, PW_RENDERFULLCONTENT = 2;
        public const int CURSOR_SHOWING = 1, DI_NORMAL = 3, SM_CXCURSOR = 13;
        const int GW_OWNER = 4, GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80, WS_EX_APPWINDOW = 0x40000;
        const int DWMWA_EXTENDED_FRAME_BOUNDS = 9, DWMWA_CLOAKED = 14;

        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT ptScreenPos; }
        [StructLayout(LayoutKind.Sequential)] public struct ICONINFO { public bool fIcon; public int xHotspot; public int yHotspot; public IntPtr hbmMask; public IntPtr hbmColor; }
        [StructLayout(LayoutKind.Sequential)]
        public struct BITMAPINFOHEADER
        {
            public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct MONITORINFOEX { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }

        delegate bool MonitorProc(IntPtr monitor, IntPtr dc, ref RECT rect, IntPtr data);
        delegate bool WindowProc(IntPtr window, IntPtr data);

        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorProc proc, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfoW(IntPtr monitor, ref MONITORINFOEX info);
        [DllImport("user32.dll")] static extern bool EnumWindows(WindowProc proc, IntPtr data);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr window, char[] text, int count);
        [DllImport("user32.dll")] static extern int GetWindowTextLengthW(IntPtr window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr window, char[] name, int count);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, int command);
        [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtrW(IntPtr window, int index);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out RECT rect);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr window);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr window, IntPtr dc);
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, int flags);
        [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO info);
        [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr icon, out ICONINFO info);
        [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr dc, int x, int y, IntPtr icon, int width, int height, int step, IntPtr brush, int flags);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER header, uint usage, out IntPtr bits, IntPtr section, uint offset);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr item);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr item);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr dc, int x, int y, int width, int height, IntPtr source, int sx, int sy, int op);
        [DllImport("gdi32.dll")] public static extern bool StretchBlt(IntPtr dc, int x, int y, int width, int height, IntPtr source, int sx, int sy, int sw, int sh, int op);
        [DllImport("gdi32.dll")] public static extern int SetStretchBltMode(IntPtr dc, int mode);
        [DllImport("gdi32.dll")] public static extern bool SetBrushOrgEx(IntPtr dc, int x, int y, IntPtr previous);
        [DllImport("gdi32.dll")] public static extern bool GdiFlush();
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out RECT value, int size);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);

        public static List<RECT> Monitors()
        {
            var list = new List<RECT>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr _, ref RECT _, IntPtr _) =>
            {
                var info = new MONITORINFOEX { cbSize = Marshal.SizeOf<MONITORINFOEX>() };
                if (GetMonitorInfoW(monitor, ref info)) list.Add(info.rcMonitor);
                return true;
            }, IntPtr.Zero);
            // Головний монітор першим, далі — зліва направо, як їх бачить людина.
            return list.OrderBy(r => r.Left == 0 && r.Top == 0 ? 0 : 1).ThenBy(r => r.Left).ThenBy(r => r.Top).ToList();
        }

        /// Вікна, які людина бачить у Alt+Tab: видимі, не згорнуті, не сховані DWM, без власника.
        public static List<(IntPtr Handle, string Title, uint Pid, PixelRect Bounds)> Windows()
        {
            var list = new List<(IntPtr, string, uint, PixelRect)>();
            EnumWindows((window, _) =>
            {
                if (!IsWindowVisible(window) || IsIconic(window)) return true;
                var style = (long)GetWindowLongPtrW(window, GWL_EXSTYLE);
                if ((style & WS_EX_TOOLWINDOW) != 0 && (style & WS_EX_APPWINDOW) == 0) return true;
                if (GetWindow(window, GW_OWNER) != IntPtr.Zero && (style & WS_EX_APPWINDOW) == 0) return true;
                if (DwmGetWindowAttribute(window, DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
                var name = new char[64];
                var nameLength = GetClassNameW(window, name, name.Length);
                if (new string(name, 0, Math.Max(0, nameLength)) is "Progman" or "WorkerW") return true;
                var length = GetWindowTextLengthW(window);
                if (length <= 0) return true;
                var text = new char[length + 1];
                var got = GetWindowTextW(window, text, text.Length);
                GetWindowThreadProcessId(window, out var pid);
                var bounds = FrameBounds(window) ?? (GetWindowRect(window, out var r) ? r : default);
                list.Add((window, new string(text, 0, Math.Max(0, got)).Trim(), pid,
                          new PixelRect(bounds.Left, bounds.Top, Math.Max(0, bounds.Right - bounds.Left), Math.Max(0, bounds.Bottom - bounds.Top))));
                return true;
            }, IntPtr.Zero);
            return list;
        }

        /// Видимі межі вікна (без невидимих рамок для тягання, що є в GetWindowRect).
        public static RECT? FrameBounds(IntPtr window) =>
            DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, out RECT rect, Marshal.SizeOf<RECT>()) == 0 ? rect : null;
    }
}
