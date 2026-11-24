// =============================================================================
//  RemoteWakefulness.cs — комп'ютер не засинає, поки пульт на зв'язку
// =============================================================================
//  Як RemoteWakefulness на Mac: кожен запит пульта тримає систему від сну
//  (SetThreadExecutionState у Windows); 10 хвилин тиші — знову може засинати.
// =============================================================================

using System.Runtime.InteropServices;
using Avalonia.Threading;

namespace Slovo.App;

public sealed class RemoteWakefulness
{
    public static readonly RemoteWakefulness Shared = new();
    const double QuietAfter = 600;
    DateTime _lastRequest = DateTime.MinValue;
    DispatcherTimer? _watch;
    public bool KeepsAwake { get; private set; }
    bool _listening;

    RemoteWakefulness() { }

    [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
    const uint Continuous = 0x80000000, SystemRequired = 0x00000001;

    public void Listening(bool on)
    {
        _listening = on;
        if (!on) Release();
    }

    public void Request()
    {
        _lastRequest = DateTime.Now;
        if (KeepsAwake || !_listening) return;
        KeepsAwake = true;
        if (OperatingSystem.IsWindows()) SetThreadExecutionState(Continuous | SystemRequired);
        Journal.Say("пульт на зв'язку — комп'ютер не засинає");
        _watch = new DispatcherTimer { Interval = TimeSpan.FromSeconds(60) };
        _watch.Tick += (_, _) => { if ((DateTime.Now - _lastRequest).TotalSeconds > QuietAfter) Release(); };
        _watch.Start();
    }

    void Release()
    {
        _watch?.Stop();
        _watch = null;
        if (!KeepsAwake) return;
        KeepsAwake = false;
        if (OperatingSystem.IsWindows()) SetThreadExecutionState(Continuous);
        Journal.Say("пульт мовчить 10 хвилин — комп'ютер знову може засинати");
    }
}
