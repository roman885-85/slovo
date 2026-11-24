// =============================================================================
//  NdiRuntime.cs — бібліотека NDI: пошук, завантаження, плоскі функції (NDIRuntime Mac)
// =============================================================================
//  NDI не входить до програми: у Windows бібліотеку ставить «NDI Runtime» (або
//  NDI Tools) і називає теку змінною NDI_RUNTIME_DIR_V6/V5/V4; можна покласти
//  Processing.NDI.Lib.x64.dll і поруч із Слово.exe. Беремо плоскі символи, а не
//  таблицю NDIlib_v5_load: імена функцій документовані й стабільні поколіннями SDK.
//  На Mac (розробка) — libndi.dylib, щоб той самий код перевірявся і там.
// =============================================================================

using System.Runtime.InteropServices;

namespace Slovo.App;

public static unsafe class NdiRuntime
{
    public const uint FourCC_BGRA = 'B' | ('G' << 8) | ('R' << 16) | ((uint)'A' << 24);
    public const uint FourCC_BGRX = 'B' | ('G' << 8) | ('R' << 16) | ((uint)'X' << 24);
    public const int FrameProgressive = 1;
    public const long TimecodeSynthesize = long.MaxValue;

    [StructLayout(LayoutKind.Sequential)]
    public struct SendCreate { public IntPtr Name, Groups; [MarshalAs(UnmanagedType.U1)] public bool ClockVideo; [MarshalAs(UnmanagedType.U1)] public bool ClockAudio; }

    [StructLayout(LayoutKind.Sequential)]
    public struct VideoFrame
    {
        public int XRes, YRes; public uint FourCC; public int FrameRateN, FrameRateD; public float AspectRatio; public int FrameFormat;
        public long Timecode; public IntPtr Data; public int LineStride; public IntPtr Metadata; public long Timestamp;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FindCreate { [MarshalAs(UnmanagedType.U1)] public bool ShowLocalSources; public IntPtr Groups, ExtraIps; }

    [StructLayout(LayoutKind.Sequential)]
    public struct Source { public IntPtr Name, Address; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RecvCreate { public Source Source; public int ColorFormat, Bandwidth; [MarshalAs(UnmanagedType.U1)] public bool AllowFields; public IntPtr Name; }

    static IntPtr _library;
    static bool _tried;
    static string? _problem;
    public static string? LoadedFrom { get; private set; }

    public static delegate* unmanaged[Cdecl]<byte> Initialize;
    public static delegate* unmanaged[Cdecl]<SendCreate*, IntPtr> SendCreateFn;
    public static delegate* unmanaged[Cdecl]<IntPtr, VideoFrame*, void> SendVideo;
    public static delegate* unmanaged[Cdecl]<IntPtr, void> SendDestroy;
    public static delegate* unmanaged[Cdecl]<IntPtr, uint, int> SendConnections;
    public static delegate* unmanaged[Cdecl]<FindCreate*, IntPtr> FindCreateFn;
    public static delegate* unmanaged[Cdecl]<IntPtr, uint, byte> FindWait;
    public static delegate* unmanaged[Cdecl]<IntPtr, uint*, Source*> FindSources;
    public static delegate* unmanaged[Cdecl]<IntPtr, void> FindDestroy;
    public static delegate* unmanaged[Cdecl]<RecvCreate*, IntPtr> RecvCreateFn;
    public static delegate* unmanaged[Cdecl]<IntPtr, VideoFrame*, IntPtr, IntPtr, uint, int> RecvCapture;
    public static delegate* unmanaged[Cdecl]<IntPtr, VideoFrame*, void> RecvFreeVideo;
    public static delegate* unmanaged[Cdecl]<IntPtr, void> RecvDestroy;

    /// Чому NDI немає (null — бібліотека завантажена).
    public static string? Problem { get { Load(); return _problem; } }
    public static bool IsAvailable => Load();

    static IEnumerable<string> Candidates()
    {
        if (OperatingSystem.IsWindows())
        {
            foreach (var key in new[] { "NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5", "NDI_RUNTIME_DIR_V4" })
                if (Environment.GetEnvironmentVariable(key) is { Length: > 0 } dir) yield return Path.Combine(dir, "Processing.NDI.Lib.x64.dll");
            yield return Path.Combine(YouTubeResolver.ProgramFolder, "Processing.NDI.Lib.x64.dll");
            yield return Path.Combine(Slovo.Core.DataHome.Folder, "Processing.NDI.Lib.x64.dll");
            var programs = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            foreach (var version in new[] { "6", "5" })
                yield return Path.Combine(programs, "NDI", $"NDI {version} Runtime", "v" + version, "Processing.NDI.Lib.x64.dll");
            yield break;
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        yield return Path.Combine(home, "Documents", "Слово", "Слово.app", "Contents", "Frameworks", "libndi.dylib");
        yield return "/usr/local/lib/libndi.dylib";
        yield return "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib";
    }

    static bool Load()
    {
        if (_tried) return _library != IntPtr.Zero;
        _tried = true;
        var searched = new List<string>();
        foreach (var path in Candidates())
        {
            searched.Add(path);
            if (!File.Exists(path) || !NativeLibrary.TryLoad(path, out var handle)) continue;
            try
            {
                IntPtr Get(string name) => NativeLibrary.GetExport(handle, name);
                Initialize = (delegate* unmanaged[Cdecl]<byte>)Get("NDIlib_initialize");
                SendCreateFn = (delegate* unmanaged[Cdecl]<SendCreate*, IntPtr>)Get("NDIlib_send_create");
                SendVideo = (delegate* unmanaged[Cdecl]<IntPtr, VideoFrame*, void>)Get("NDIlib_send_send_video_v2");
                SendDestroy = (delegate* unmanaged[Cdecl]<IntPtr, void>)Get("NDIlib_send_destroy");
                SendConnections = (delegate* unmanaged[Cdecl]<IntPtr, uint, int>)Get("NDIlib_send_get_no_connections");
                FindCreateFn = (delegate* unmanaged[Cdecl]<FindCreate*, IntPtr>)Get("NDIlib_find_create_v2");
                FindWait = (delegate* unmanaged[Cdecl]<IntPtr, uint, byte>)Get("NDIlib_find_wait_for_sources");
                FindSources = (delegate* unmanaged[Cdecl]<IntPtr, uint*, Source*>)Get("NDIlib_find_get_current_sources");
                FindDestroy = (delegate* unmanaged[Cdecl]<IntPtr, void>)Get("NDIlib_find_destroy");
                RecvCreateFn = (delegate* unmanaged[Cdecl]<RecvCreate*, IntPtr>)Get("NDIlib_recv_create_v3");
                RecvCapture = (delegate* unmanaged[Cdecl]<IntPtr, VideoFrame*, IntPtr, IntPtr, uint, int>)Get("NDIlib_recv_capture_v2");
                RecvFreeVideo = (delegate* unmanaged[Cdecl]<IntPtr, VideoFrame*, void>)Get("NDIlib_recv_free_video_v2");
                RecvDestroy = (delegate* unmanaged[Cdecl]<IntPtr, void>)Get("NDIlib_recv_destroy");
                if (Initialize() == 0) { _problem = Captions.T("NDI не поддерживает этот процессор"); NativeLibrary.Free(handle); return false; }
                _library = handle;
                LoadedFrom = path;
                Journal.Say($"NDI: бібліотека {path}");
                return true;
            }
            catch (Exception error)
            {
                Journal.Say($"NDI: {path} — {error.Message}");
                NativeLibrary.Free(handle);
            }
        }
        _problem = OperatingSystem.IsWindows()
            ? Captions.T("NDI не установлен: поставьте NDI Runtime (ndi.video/tools) или положите Processing.NDI.Lib.x64.dll рядом со Слово.exe")
            : Captions.T("NDI не установлен");
        Journal.Say("NDI: бібліотеки немає — шукано: " + string.Join("; ", searched));
        return false;
    }
}
