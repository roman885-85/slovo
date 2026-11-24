// =============================================================================
//  YouTubeResolver.cs — ролики YouTube через yt-dlp (YouTubeResolver Mac 1.3.9)
// =============================================================================
//  yt-dlp — вільна програма, що дає прямі доріжки ролика YouTube (і сотень інших
//  сайтів). Коли вона є, ролик іде звичайним плеєром: у зал повним кадром, з
//  перемоткою, нічого не завантажується цілком (власник просив саме відтворення
//  за посиланням, «как в плеере YouTube»).
//
//  YouTube з 2025 року віддає картинку й звук окремими доріжками. На Mac їх
//  зводить сам плеєр macOS (HLS-доріжки) або ffmpeg на льоту; тут — LibVLC:
//  картинка — основна доріжка, звук — «підлегла» (AddSlave), перемотка спільна.
//  Трансляції (у них HLS зі звуком) — одним адресом.
//
//  yt-dlp — своя копія в теці даних, яку програма завантажує й оновлює сама
//  (YouTubeToolUpdater, вимикач у «Параметри» → «Медіа»); інакше шукаємо поруч
//  із програмою, у теці даних, на Робочому столі (тека «Слово»), там, куди їх
//  ставлять winget, scoop і choco, і в PATH; шлях можна вказати й руками.
//
//  Рушій JavaScript: з 2025.11 yt-dlp розв'язує задачки YouTube зовнішнім
//  рушієм (без нього — «some formats may be missing», далі — гірше) і типово
//  шукає лише deno. Як на Mac (helperPath, hasNode): теки помічників — deno,
//  node, ffmpeg — ідуть першими в PATH процесу yt-dlp, а коли є node, йому
//  додається `--js-runtimes node`.
// =============================================================================

using System.Diagnostics;
using System.Text.Json.Nodes;

namespace Slovo.App;

public static class YouTubeResolver
{
    static string T(string text, params object[] args) => Captions.T(text, args);
    const string ManualKey = "youTubeToolPath";

    /// Що знайшли: шлях до програми (null — немає) і рядок для «Параметрів».
    public sealed record Availability(string? Tool, string Note);

    /// Що вийшло: адреса картинки (чи всього потоку), окремий звук, назва, заголовки HTTP.
    public sealed record Resolved(string Url, string? Audio, string Title, bool IsLive, double Duration, string? UserAgent, string? Referer);

    public sealed class Failure : Exception
    {
        public Failure(string message) : base(message) { }
    }

    static string[] Names => OperatingSystem.IsWindows()
        ? new[] { "yt-dlp.exe", "yt-dlp_x86.exe", "yt-dlp_win7.exe" }
        : new[] { "yt-dlp", "yt-dlp_macos" };

    /// Тека, де лежить сама програма (у зібраному .exe AppContext.BaseDirectory — тимчасова).
    public static string ProgramFolder => Path.GetDirectoryName(Environment.ProcessPath) ?? AppContext.BaseDirectory;

    static IEnumerable<string> SearchFolders()
    {
        yield return ProgramFolder;
        yield return Slovo.Core.DataHome.Folder;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Слово");
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Links");
        yield return Path.Combine(home, "scoop", "shims");
        yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "chocolatey", "bin");
        foreach (var part in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            yield return part.Trim('"');
    }

    /// Теки помічників yt-dlp — deno, node, ffmpeg (helperPath Mac): ті самі, де шукаємо yt-dlp,
    /// і звичні місця встановлення node й deno.
    static IEnumerable<string> HelperFolders()
    {
        foreach (var folder in SearchFolders()) yield return folder;
        if (OperatingSystem.IsWindows())
        {
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs");
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "nodejs");
            if (Environment.GetEnvironmentVariable("NVM_SYMLINK") is { Length: > 0 } nvm) yield return nvm;
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "nodejs");
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".deno", "bin");
        }
        else
        {
            foreach (var folder in new[] { "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin" }) yield return folder;
        }
    }

    static List<string> ExistingHelperFolders()
    {
        var list = new List<string>();
        foreach (var folder in HelperFolders())
        {
            try
            {
                if (folder.Length > 0 && Directory.Exists(folder) && !list.Contains(folder, StringComparer.OrdinalIgnoreCase)) list.Add(folder);
            }
            catch { }
        }
        return list;
    }

    /// node для задачок YouTube (hasNode Mac); null — немає.
    public static string? Node
    {
        get
        {
            var name = OperatingSystem.IsWindows() ? "node.exe" : "node";
            foreach (var folder in ExistingHelperFolders())
                if (File.Exists(Path.Combine(folder, name))) return Path.Combine(folder, name);
            return null;
        }
    }

    /// Знайти yt-dlp: вказаний руками шлях (файл чи тека з ним) — або пошук у звичних місцях.
    public static Availability Locate()
    {
        if (Defaults.String(ManualKey) is { } manual && manual.Trim().Length > 0)
        {
            var path = manual.Trim().Trim('"');
            if (Directory.Exists(path))
            {
                foreach (var name in Names)
                    if (File.Exists(Path.Combine(path, name))) return new(Path.Combine(path, name), T("yt-dlp: %s", Path.Combine(path, name)));
                return new(null, T("По указанному пути yt-dlp нет: %s", path));
            }
            return File.Exists(path) ? new(path, T("yt-dlp: %s", path)) : new(null, T("По указанному пути yt-dlp нет: %s", path));
        }
        // Своя копія, яку програма оновлює сама (YouTubeToolUpdater), — першою.
        if (File.Exists(YouTubeToolUpdater.ManagedPath)) return new(YouTubeToolUpdater.ManagedPath, T("yt-dlp: %s", YouTubeToolUpdater.ManagedPath));
        foreach (var folder in SearchFolders())
        {
            foreach (var name in Names)
            {
                string candidate;
                try { candidate = Path.Combine(folder, name); } catch { continue; }
                if (File.Exists(candidate)) return new(candidate, T("yt-dlp: %s", candidate));
            }
        }
        return new(null, YouTubeToolUpdater.AutoUpdate
            ? T("yt-dlp ещё не скачан — программа скачает его сама с GitHub (или нажмите «Проверить сейчас» в «Параметрах» → «Медиа»)")
            : T("yt-dlp не найден — положите yt-dlp.exe в папку %s (или укажите путь в «Параметрах» → «Медиа»)", ProgramFolder));
    }

    /// Спитати потік ролика (у фоні: yt-dlp думає секунди). Не вийшло — Failure зі словами для людини.
    public static Resolved Obtain(string link, string tool, CancellationToken cancel)
    {
        var json = Run(tool, new[] { "-j", "--no-playlist", "--no-warnings", "--no-progress", "--encoding", "utf-8", link }, cancel, TimeSpan.FromSeconds(90));
        JsonObject? root;
        try { root = JsonNode.Parse(json) as JsonObject; } catch { root = null; }
        if (root == null) throw new Failure(T("yt-dlp: %s", T("ответ не разобран")));
        string Text(JsonNode? node, string key) => node?[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : "";
        double Number(JsonNode? node, string key) => node?[key] is JsonValue v && v.TryGetValue<double>(out var d) ? d : 0;
        bool Has(JsonNode? node, string key) => Text(node, key) is { Length: > 0 } s && s != "none";
        var title = Text(root, "title");
        var live = root["is_live"] is JsonValue lv && lv.TryGetValue<bool>(out var isLive) && isLive;
        var duration = Number(root, "duration");
        (string?, string?) Headers(JsonNode? format)
        {
            var headers = format?["http_headers"] as JsonObject;
            return (Text(headers, "User-Agent") is { Length: > 0 } agent ? agent : null, Text(headers, "Referer") is { Length: > 0 } referer ? referer : null);
        }
        // Потік зі звуком і картинкою разом — одразу (так живуть трансляції).
        if (Text(root, "url") is { Length: > 0 } whole && Has(root, "vcodec") && Has(root, "acodec"))
        {
            var (agent, referer) = Headers(root);
            return new Resolved(whole, null, title, live, duration, agent, referer);
        }
        var formats = (root["formats"] as JsonArray)?.OfType<JsonObject>().ToList() ?? new();
        // Свої HLS-доріжки YouTube — збірним плейлистом (як на Mac): перемотка йде по шматках.
        // Окремий звук «підлеглою» доріжкою по https LibVLC перемотує погано — кадр ставав
        // (знайдено у ВМ); тому той шлях — лише запасний.
        if (MasterPlaylist(formats, Text, Number) is { } master)
        {
            var folder = Path.Combine(Path.GetTempPath(), "slovo-youtube");
            Directory.CreateDirectory(folder);
            foreach (var old in Directory.EnumerateFiles(folder, "*.m3u8"))
                try { if (File.GetLastWriteTimeUtc(old) < DateTime.UtcNow.AddDays(-1)) File.Delete(old); } catch { }
            var file = Path.Combine(folder, Guid.NewGuid().ToString("N") + ".m3u8");
            File.WriteAllText(file, master);
            return new Resolved(new Uri(file).AbsoluteUri, null, title, live, duration, null, null);
        }
        // Картинка — як на Mac: H.264 по https до 1080 рядків, найкраща; немає H.264 — будь-яка (LibVLC грає й VP9/AV1).
        var videos = formats.Where(f => Has(f, "vcodec") && !Has(f, "acodec") && Text(f, "protocol") == "https" && Number(f, "height") <= 1080 && Text(f, "url").Length > 0).ToList();
        var preferred = videos.Where(f => Text(f, "vcodec").StartsWith("avc1")).ToList();
        if (preferred.Count > 0) videos = preferred;
        var video = videos.OrderBy(f => Number(f, "height")).ThenBy(f => Number(f, "tbr")).LastOrDefault();
        var audios = formats.Where(f => !Has(f, "vcodec") && Has(f, "acodec") && Text(f, "protocol") == "https" && Text(f, "url").Length > 0).ToList();
        var m4a = audios.Where(f => Text(f, "ext") == "m4a").ToList();
        if (m4a.Count > 0) audios = m4a;
        var audio = audios.OrderBy(f => Number(f, "abr")).LastOrDefault();
        if (video == null || audio == null)
        {
            // Звичайний «склеєний» формат (рідко, але буває) — теж годиться.
            var muxed = formats.Where(f => Has(f, "vcodec") && Has(f, "acodec") && Text(f, "url").Length > 0).OrderBy(f => Number(f, "height")).LastOrDefault();
            if (muxed == null) throw new Failure(T("yt-dlp не дал потока: %s", T("нет дорожек, которые можно склеить")));
            var (a, r) = Headers(muxed);
            return new Resolved(Text(muxed, "url"), null, title, live, duration, a, r);
        }
        var (userAgent, referrer) = Headers(video);
        return new Resolved(Text(video, "url"), Text(audio, "url"), title, live, duration, userAgent, referrer);
    }

    /// Збірний плейлист із HLS-доріжок YouTube (masterPlaylist на Mac): усі якості H.264 до 1080p
    /// як варіанти й один звук окремою доріжкою групи. null — HLS-доріжок у ролика немає.
    static string? MasterPlaylist(List<JsonObject> formats, Func<JsonNode?, string, string> text, Func<JsonNode?, string, double> number)
    {
        var hls = formats.Where(f => text(f, "protocol").StartsWith("m3u8") && text(f, "url").Length > 0).ToList();
        var videos = hls.Where(f => text(f, "vcodec").StartsWith("avc1") && number(f, "height") > 0 && number(f, "height") <= 1080)
                        .OrderBy(f => number(f, "height")).ToList();
        var audio = hls.Where(f => (text(f, "vcodec") is "none" or "") && text(f, "resolution") == "audio only")
                       .OrderBy(f => number(f, "tbr")).ThenBy(f => text(f, "format_id")).LastOrDefault();
        if (audio == null || videos.Count == 0) return null;
        var lines = new List<string>
        {
            "#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"zvuk\",NAME=\"звук\",DEFAULT=YES,AUTOSELECT=YES,URI=\"" + text(audio, "url") + "\"",
        };
        var audioBits = (int)(Math.Max(number(audio, "tbr"), 128) * 1000);
        foreach (var video in videos)
        {
            var bits = (int)(number(video, "tbr") * 1000) + audioBits;
            lines.Add($"#EXT-X-STREAM-INF:BANDWIDTH={bits},AVERAGE-BANDWIDTH={bits},CODECS=\"{text(video, "vcodec")},mp4a.40.2\"," +
                      $"RESOLUTION={(int)number(video, "width")}x{(int)number(video, "height")},AUDIO=\"zvuk\"");
            lines.Add(text(video, "url"));
        }
        return string.Join("\n", lines) + "\n";
    }

    /// Процес yt-dlp: без вікна консолі, теки помічників першими в PATH, рушій JavaScript — node, коли він є.
    static ProcessStartInfo Prepare(string tool, IEnumerable<string> arguments, bool javaScript)
    {
        var info = new ProcessStartInfo(tool)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        // На Windows Environment не зважає на регістр («Path» і «PATH» — одне).
        var inherited = info.Environment.TryGetValue("PATH", out var current) ? current ?? "" : "";
        info.Environment["PATH"] = string.Join(Path.PathSeparator, ExistingHelperFolders().Append(inherited).Where(p => p.Length > 0));
        if (javaScript && Node != null && !info.ArgumentList.Contains("--js-runtimes"))
        {
            info.ArgumentList.Add("--js-runtimes");
            info.ArgumentList.Add("node");
        }
        return info;
    }

    /// Запуск yt-dlp з читанням виводу цілком; вікна консолі не видно.
    static string Run(string tool, IEnumerable<string> arguments, CancellationToken cancel, TimeSpan timeout)
    {
        try { return RunOnce(tool, arguments, cancel, timeout, javaScript: true); }
        catch (Failure failure) when (Node != null && failure.Message.Contains("no such option", StringComparison.OrdinalIgnoreCase))
        {
            // yt-dlp, старіший за 2025.11.12 (вказаний руками), ключа --js-runtimes не знає — без нього.
            return RunOnce(tool, arguments, cancel, timeout, javaScript: false);
        }
    }

    static string RunOnce(string tool, IEnumerable<string> arguments, CancellationToken cancel, TimeSpan timeout, bool javaScript)
    {
        var info = Prepare(tool, arguments, javaScript);
        Process process;
        try { process = Process.Start(info) ?? throw new InvalidOperationException("Process.Start"); }
        catch (Exception error) { throw new Failure(T("yt-dlp не запустился: %s", error.Message)); }
        using (process)
        using (cancel.Register(() => { try { process.Kill(true); } catch { } }))
        {
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit((int)timeout.TotalMilliseconds))
            {
                try { process.Kill(true); } catch { }
                throw new Failure(T("yt-dlp не ответил за отведённое время"));
            }
            cancel.ThrowIfCancellationRequested();
            if (process.ExitCode != 0)
            {
                var last = errors.Result.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0) ?? process.ExitCode.ToString();
                throw new Failure(T("yt-dlp: %s", last));
            }
            return output.Result;
        }
    }

    /// Для перевірки (ключ знімка --youtube): яким рушієм JavaScript yt-dlp розв'язав би задачки
    /// цього ролика — рядок «JS runtimes: …» з його докладного виводу.
    public static string JavaScriptReport(string link, string tool)
    {
        try
        {
            using var process = Process.Start(Prepare(tool, new[] { "-v", "--simulate", "--print", "id", link }, javaScript: true))!;
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(90_000)) { try { process.Kill(true); } catch { } return "не відповів за 90 с"; }
            var lines = errors.Result.Split('\n').Select(l => l.Trim());
            var runtimes = lines.FirstOrDefault(l => l.Contains("JS runtimes:")) ?? "рядка «JS runtimes» немає";
            var warned = lines.Any(l => l.Contains("No supported JavaScript runtime"));
            return $"{runtimes}{(warned ? " — є попередження про відсутній рушій" : "")}, код {process.ExitCode}";
        }
        catch (Exception error) { return error.Message; }
    }
}
