// =============================================================================
//  BackingConversion.cs — фонограми чужих форматів (.ogg, .opus, .ape, .wv…)
// =============================================================================
//  За BackingTrackPlayer.converted Mac 1.3.9: чого система сама не грає, те
//  перетворюється в тимчасову теку й береться повторно, поки свіже (на служінні
//  ту саму мінусовку відкривають не раз). На Mac це робить ffmpeg; тут — LibVLC,
//  що вже є в програмі заради плеєра (той самий ffmpeg усередині): транскодування
//  в WAV іде швидше за реальний час, бо вихід — файл, а не динаміки.
// =============================================================================

using LibVLCSharp.Shared;

namespace Slovo.App;

public static class BackingConversion
{
    /// Чи є чим перетворювати (LibVLC лише у Windows-збірці).
    public static bool Available => OperatingSystem.IsWindows() && MediaEngine.Library != null;

    static string Folder
    {
        get
        {
            var folder = Path.Combine(Path.GetTempPath(), "slovo-фонограми");
            Directory.CreateDirectory(folder);
            return folder;
        }
    }

    /// Ім'я готового файла — ОДНАКОВЕ між запусками (шлях і час правки, FNV-1a):
    /// змінили файл — зміниться й ім'я, а та сама мінусовка вдруге не перетворюється.
    static string CacheName(string source, string extension)
    {
        var stamp = File.Exists(source) ? (long)(File.GetLastWriteTimeUtc(source) - DateTime.UnixEpoch).TotalSeconds : 0;
        ulong mark = 0xcbf29ce484222325;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(source + stamp))
            mark = (mark ^ b) * 0x100000001b3;
        // У назві лишаємо лише безпечні знаки: шлях іде в рядок налаштувань LibVLC.
        var name = new string(Path.GetFileNameWithoutExtension(source).Where(c => char.IsLetterOrDigit(c) || c is ' ' or '-' or '_').ToArray());
        if (name.Length > 60) name = name[..60];
        return name + "-" + mark.ToString("x16") + extension;
    }

    /// Перетворити в WAV (16 біт, 44,1 кГц, стерео). null — не вийшло.
    public static string? Converted(string source)
    {
        if (MediaEngine.Library is not { } library) return null;
        var ready = Path.Combine(Folder, CacheName(source, ".wav"));
        if (File.Exists(ready) && new FileInfo(ready).Length > 4096) return ready;
        Tidy();
        var partial = ready + ".part";
        try
        {
            using var media = new Media(library, source, FromType.FromPath);
            var target = partial.Replace('\\', '/');
            media.AddOption(":sout=#transcode{vcodec=none,scodec=none,acodec=s16l,channels=2,samplerate=44100}" +
                            ":std{access=file,mux=wav,dst='" + target + "'}");
            media.AddOption(":no-sout-video");
            media.AddOption(":no-sout-spu");
            using var player = new MediaPlayer(media);
            using var done = new ManualResetEventSlim();
            var failed = false;
            player.EndReached += (_, _) => done.Set();
            player.EncounteredError += (_, _) => { failed = true; done.Set(); };
            if (!player.Play()) return null;
            // Година музики перетворюється за десятки секунд; більше 15 хвилин — щось не так.
            if (!done.Wait(TimeSpan.FromMinutes(15))) failed = true;
            player.Stop();
            if (failed || !File.Exists(partial) || new FileInfo(partial).Length <= 4096)
            {
                Journal.Say($"фонограма: LibVLC не перетворив «{Path.GetFileName(source)}»");
                TryDelete(partial);
                return null;
            }
            File.Move(partial, ready, true);
            Journal.Say($"фонограма: «{Path.GetFileName(source)}» перетворено в {Path.GetFileName(ready)}");
            return ready;
        }
        catch (Exception error)
        {
            Journal.Say($"фонограма: перетворення «{Path.GetFileName(source)}» не вдалося — {error.Message}");
            TryDelete(partial);
            return null;
        }
    }

    /// Старі копії (понад місяць без вжитку) й недороблені — геть: WAV великі.
    static void Tidy()
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(Folder))
            {
                var info = new FileInfo(file);
                if (file.EndsWith(".part") ? info.LastWriteTimeUtc < DateTime.UtcNow.AddHours(-1)
                                           : info.LastAccessTimeUtc < DateTime.UtcNow.AddDays(-30) && info.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-30))
                    TryDelete(file);
            }
        }
        catch { }
    }

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }
}
