// =============================================================================
//  YouTubeToolUpdater.cs — свій yt-dlp, що оновлюється сам (YouTubeToolUpdater на Mac)
// =============================================================================
//  Власник 24.11.2026: «yt-dlp — нужно чтобы он автоматически обновлялся в
//  программах, если выходит его обновление». YouTube часто міняє сторінки, і
//  старий yt-dlp перестає діставати ролики — оновлення виходять щотижня.
//
//  Програма тримає СВОЮ копію в теці даних (Tools\yt-dlp.exe) і раз на добу
//  (у фоні, після запуску) звіряє її з останнім випуском на GitHub: новіший —
//  завантажує, звіряє суму SHA-256 з SHA2-256SUMS того самого випуску й підміняє.
//  Копії немає — завантажує. Вимикається галочкою в «Параметри → Медіа → YouTube»
//  (кожен автомат — з видимим вимикачем); там же «Перевірити зараз» і стан.
//  Шлях, указаний людиною вручну, не чіпаємо — то її вибір.
// =============================================================================

using System.Diagnostics;
using System.Security.Cryptography;

namespace Slovo.App;

public static class YouTubeToolUpdater
{
    static string T(string text, params object[] args) => Captions.T(text, args);
    const string AutoKey = "youTubeToolAutoUpdate", CheckedKey = "youTubeToolCheckedAt", StatusKey = "youTubeToolStatus";
    const string Releases = "https://github.com/yt-dlp/yt-dlp/releases";

    /// Ім'я файла у випуску yt-dlp для цієї системи.
    static string AssetName => OperatingSystem.IsWindows() ? "yt-dlp.exe" : "yt-dlp_macos";

    /// Своя копія — у теці даних (на Mac — Application Support/Slovo/Tools).
    public static string ManagedPath => Path.Combine(Slovo.Core.DataHome.Folder, "Tools", AssetName);

    /// «Оновлювати yt-dlp автоматично» — за замовчанням так.
    public static bool AutoUpdate
    {
        get => !Defaults.Has(AutoKey) || Defaults.Bool(AutoKey);
        set => Defaults.Set(AutoKey, value);
    }

    /// Що сказати в «Параметрах»: версія й коли перевірено, або чому не вийшло.
    public static string Status => Defaults.String(StatusKey) ?? "";
    public static event Action? StatusChanged;
    static int _running;

    static readonly HttpClient Web = MakeClient(true), NoRedirect = MakeClient(false);

    static HttpClient MakeClient(bool redirects)
    {
        var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = redirects }) { Timeout = TimeSpan.FromMinutes(5) };
        // Своє ім'я без жодних даних про людину чи комп'ютер.
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Slovo-yt-dlp-updater/1.0");
        return client;
    }

    /// Після запуску: раз на добу, у фоні, якщо не вимкнено. У знімках — ніколи.
    public static void CheckInBackground()
    {
        if (Program.Snapshotting || !AutoUpdate) return;
        if (Defaults.String(CheckedKey) is { } stamp && DateTime.TryParse(stamp, null, System.Globalization.DateTimeStyles.RoundtripKind, out var last)
            && DateTime.UtcNow - last < TimeSpan.FromHours(24) && File.Exists(ManagedPath)) return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(15));
            await CheckAsync();
        });
    }

    /// Перевірити й, якщо треба, оновити зараз. Повертає рядок стану.
    public static async Task<string> CheckAsync()
    {
        if (Interlocked.Exchange(ref _running, 1) == 1) return Status;
        try
        {
            var latest = await LatestVersion();
            var current = File.Exists(ManagedPath) ? await InstalledVersion(ManagedPath) : null;
            string text;
            if (current != null && Compare(current, latest) >= 0)
                text = T("yt-dlp %s — последняя версия (проверено %s)", current, DateTime.Now.ToString("dd.MM HH:mm"));
            else
            {
                await Download(latest);
                var installed = await InstalledVersion(ManagedPath) ?? latest;
                text = current == null
                    ? T("yt-dlp %s скачан с GitHub (%s)", installed, DateTime.Now.ToString("dd.MM HH:mm"))
                    : T("yt-dlp обновлён: %s → %s (%s)", current, installed, DateTime.Now.ToString("dd.MM HH:mm"));
                Journal.Say("yt-dlp: " + text);
            }
            Defaults.Set(CheckedKey, DateTime.UtcNow.ToString("o"));
            return SetStatus(text);
        }
        catch (Exception error)
        {
            Journal.Say($"yt-dlp: оновлення не вдалося — {error.Message}");
            return SetStatus(T("Не удалось проверить обновление yt-dlp: %s", error.Message));
        }
        finally { Interlocked.Exchange(ref _running, 0); }
    }

    static string SetStatus(string text)
    {
        Defaults.Set(StatusKey, text);
        Avalonia.Threading.Dispatcher.UIThread.Post(() => StatusChanged?.Invoke());
        return text;
    }

    /// Останній випуск — з переадресації сторінки «latest» (без API GitHub і його лімітів).
    static async Task<string> LatestVersion()
    {
        using var response = await NoRedirect.GetAsync(Releases + "/latest");
        var location = response.Headers.Location?.ToString() ?? "";
        var mark = location.LastIndexOf("/tag/", StringComparison.Ordinal);
        if (mark < 0) throw new InvalidOperationException(T("GitHub не назвал последний выпуск"));
        return Uri.UnescapeDataString(location[(mark + 5)..]).Trim();
    }

    /// Версія встановленого файла (`--version`), null — не відповів.
    static async Task<string?> InstalledVersion(string path)
    {
        try
        {
            var info = new ProcessStartInfo(path, "--version") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            using var process = Process.Start(info);
            if (process == null) return null;
            var output = process.StandardOutput.ReadToEndAsync();
            if (!process.WaitForExit(60_000)) { try { process.Kill(true); } catch { } return null; }
            var text = (await output).Trim();
            return text.Length > 0 && char.IsDigit(text[0]) ? text : null;
        }
        catch { return null; }
    }

    /// Завантажити файл випуску, звірити SHA-256 і покласти на місце своєї копії.
    static async Task Download(string version)
    {
        var folder = Path.GetDirectoryName(ManagedPath)!;
        Directory.CreateDirectory(folder);
        var sums = await Web.GetStringAsync($"{Releases}/download/{version}/SHA2-256SUMS");
        var expected = sums.Split('\n').Select(line => line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries))
                           .FirstOrDefault(parts => parts.Length == 2 && parts[1] == AssetName)?[0];
        if (expected == null) throw new InvalidOperationException(T("в выпуске %s нет суммы для %s", version, AssetName));
        var partial = ManagedPath + ".download";
        using (var response = await Web.GetAsync($"{Releases}/download/{version}/{AssetName}", HttpCompletionOption.ResponseHeadersRead))
        {
            response.EnsureSuccessStatusCode();
            await using var file = File.Create(partial);
            await response.Content.CopyToAsync(file);
        }
        string actual;
        await using (var check = File.OpenRead(partial)) actual = Convert.ToHexString(await SHA256.HashDataAsync(check)).ToLowerInvariant();
        if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(partial);
            throw new InvalidOperationException(T("сумма SHA-256 не совпала — файл не принят"));
        }
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(partial, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute | UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
        // Працює саме зараз (розбирає ролик) — Windows не дасть підмінити; тоді наступного разу.
        File.Move(partial, ManagedPath, true);
    }

    /// Порівняти версії yt-dlp («2025.11.12», «2025.11.12.1»).
    public static int Compare(string one, string two)
    {
        var a = one.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        var b = two.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var x = i < a.Length ? a[i] : 0;
            var y = i < b.Length ? b[i] : 0;
            if (x != y) return x.CompareTo(y);
        }
        return 0;
    }
}
