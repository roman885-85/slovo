// =============================================================================
//  MainThreadWatchdog.cs — сторож головного потоку (MainThreadWatchdog Mac)
// =============================================================================
//  Власник (про Mac): «пропадает изображение на проекторе… отзывчивость может
//  пропасть и не реагировать ни на что, а со временем все накопившиеся нажатия
//  начинают последовательно срабатывать». Щоденник пульта показував паузи по
//  5–12 с, але не казав, чиї вони: програми чи перевантаженої машини. Тепер
//  кожна затримка головного потоку, довша за секунду, лягає в journal.txt —
//  скільки тривала і яке було навантаження процесора, — поруч із командами
//  пульта й подіями проектора.
//
//  Міряємо не «скільки мовчав», а скільки чекав виклик, поставлений у чергу
//  головного потоку: таймер сторожа на перевантаженій машині й сам буває пізнім,
//  і тоді «мовчання» вийшло б і без вини головного потоку.
// =============================================================================

using System.Diagnostics;
using System.Runtime.InteropServices;
using Avalonia.Threading;

namespace Slovo.App;

public sealed class MainThreadWatchdog
{
    public static readonly MainThreadWatchdog Shared = new();

    /// Від скількох секунд затримка варта запису.
    const double Threshold = 1.0;

    readonly object _lock = new();
    Timer? _timer;
    bool _waiting;
    long _sentAt;

    /// Для перевірки: скільки затримок записано.
    public int Reported { get; private set; }

    public void Start()
    {
        lock (_lock)
        {
            if (_timer != null) return;
            CpuLoad.Sample();
            _timer = new Timer(_ => Ping(), null, TimeSpan.FromSeconds(2), TimeSpan.FromMilliseconds(250));
        }
    }

    void Ping()
    {
        lock (_lock)
        {
            if (_waiting) return;
            _waiting = true;
            _sentAt = Stopwatch.GetTimestamp();
        }
        Dispatcher.UIThread.Post(Answer, DispatcherPriority.Normal);
    }

    void Answer()
    {
        double delay;
        lock (_lock)
        {
            _waiting = false;
            delay = Stopwatch.GetElapsedTime(_sentAt).TotalSeconds;
        }
        if (delay < Threshold) return;
        Reported++;
        Journal.Say($"головний потік не відповідав {delay:0.0} с (навантаження процесора {CpuLoad.Describe()})");
    }

    /// Навантаження всієї машини між двома замірами — замість load average Mac.
    static class CpuLoad
    {
        [StructLayout(LayoutKind.Sequential)]
        struct FileTime { public uint Low, High; public ulong Value => ((ulong)High << 32) | Low; }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetSystemTimes(out FileTime idle, out FileTime kernel, out FileTime user);

        static ulong _idle, _total;

        public static void Sample() => Describe();

        public static string Describe()
        {
            if (!OperatingSystem.IsWindows()) return "—";
            try
            {
                if (!GetSystemTimes(out var idle, out var kernel, out var user)) return "—";
                var total = kernel.Value + user.Value;   // kernel уже містить idle
                var dIdle = idle.Value - _idle;
                var dTotal = total - _total;
                _idle = idle.Value; _total = total;
                return dTotal == 0 ? "—" : $"{100.0 * (dTotal - dIdle) / dTotal:0}%";
            }
            catch { return "—"; }
        }
    }
}
