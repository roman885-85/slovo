// =============================================================================
//  AppUpdater.cs — оновлення програми з GitHub (як AppUpdater на Mac)
// =============================================================================
//  Той самий канал, що в усіх програм «Слова»: releases/latest репозиторію
//  roman885-85/slovo. Windows-програма бере файл `Slovo-X.Y.Z-Windows.exe`.
//  Перевірка при запуску — не частіше, ніж задано у «Параметри → Оновлення»
//  (тиждень/місяць/рік; 0 — ніколи). Знайдено новішу — кнопка «Оновлення X»
//  угорі вікна й пропозиція встановити: файл завантажується, програма
//  закривається, сценарій міняє файл і запускає нову версію. Дані не чіпаються.
// =============================================================================

using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using Avalonia.Threading;

namespace Slovo.App;

public static class AppUpdater
{
    public const string Latest = "https://api.github.com/repos/roman885-85/slovo/releases/latest";
    public const string ReleasesPage = "https://github.com/roman885-85/slovo/releases/latest";
    const string Prefix = "Slovo-", Suffix = "-Windows.exe";
    const string LastCheckKey = "lastUpdateCheck", SkippedKey = "skippedUpdate";

    public sealed record Release(string Version, string Name, string Url, long Size);

    /// Новіша версія, якщо її знайдено (кнопка «Оновлення X» угорі вікна).
    public static Release? Available { get; private set; }
    public static event Action? AvailabilityChanged;

    public static string CurrentVersion =>
        Assembly.GetEntryAssembly()?.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0";

    public static async Task<Release?> FetchLatest()
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        http.DefaultRequestHeaders.Add("User-Agent", "Slovo-Windows");
        http.DefaultRequestHeaders.Add("Accept", "application/vnd.github+json");
        var body = await http.GetStringAsync(Latest);
        var assets = JsonNode.Parse(body)?["assets"]?.AsArray();
        if (assets == null) return null;
        // Перший відповідний файл: старий Windows-файл треба прибирати з випуску.
        foreach (var item in assets)
        {
            var name = (string?)item?["name"] ?? "";
            if (!name.StartsWith(Prefix, StringComparison.Ordinal) || !name.EndsWith(Suffix, StringComparison.OrdinalIgnoreCase)) continue;
            return new Release(name[Prefix.Length..^Suffix.Length], name, (string?)item?["browser_download_url"] ?? "", (long?)item?["size"] ?? 0);
        }
        return null;
    }

    public static bool IsNewer(string a, string b)
    {
        var left = a.Split('.'); var right = b.Split('.');
        for (var i = 0; i < Math.Max(left.Length, right.Length); i++)
        {
            int N(string t) { var d = new string(t.TakeWhile(char.IsDigit).ToArray()); return d.Length == 0 ? 0 : int.Parse(d); }
            var l = N(i < left.Length ? left[i] : "0"); var r = N(i < right.Length ? right[i] : "0");
            if (l != r) return l > r;
        }
        return false;
    }

    /// Тиха перевірка при запуску — не частіше за інтервал із «Параметрів».
    public static async Task CheckOnLaunch(int intervalDays)
    {
        if (intervalDays <= 0) return;
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (now - (long)Defaults.Double(LastCheckKey) < TimeSpan.FromDays(intervalDays).TotalSeconds) return;
        try
        {
            var release = await FetchLatest();
            Defaults.Set(LastCheckKey, now);
            if (release == null || !IsNewer(release.Version, CurrentVersion)) return;
            Available = release;
            AvailabilityChanged?.Invoke();
            if (release.Version != Defaults.String(SkippedKey)) Offer(release);
        }
        catch (Exception error) { Journal.Say("оновлення: не вийшло спитати GitHub — " + error.Message); }
    }

    /// «Перевірити оновлення програми…» — відповідь словами в будь-якому разі.
    public static async Task CheckNow(Action<string>? say = null)
    {
        try
        {
            say?.Invoke(Captions.T("Спрашиваю GitHub…"));
            var release = await FetchLatest();
            Defaults.Set(LastCheckKey, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            if (release != null && IsNewer(release.Version, CurrentVersion))
            {
                Available = release;
                AvailabilityChanged?.Invoke();
                say?.Invoke(Captions.T("Есть новая версия: %s", release.Version));
                Offer(release);
            }
            else
            {
                var text = Captions.T("У вас последняя версия (%s)", release?.Version ?? CurrentVersion);
                if (say != null) say(text);
                else
                    // Як на Mac: ресурси оновлюються окремо — і кнопка до них поруч.
                    Alert.Ask(text, Captions.T("Ресурсы (переводы, песенники, фоны, шаблоны) обновляются отдельно: «Настройка» → «Ресурсы с GitHub…»."),
                              new[] { Captions.T("Ок"), Captions.T("Ресурсы с GitHub…") },
                              answer => { if (answer == 1) ResourcesWindow.Open(updatesOnly: true); });
            }
        }
        catch (Exception error)
        {
            if (say != null) say(error.Message); else Alert.Tell(Captions.T("Обновление"), error.Message);
        }
    }

    public static void Offer(Release release)
    {
        var size = release.Size > 0 ? $" ({Math.Max(1, release.Size / (1024 * 1024))} {Captions.T("МБ")})" : "";
        Alert.Ask(Captions.T("Вышла версия %s", release.Version),
                  Captions.T("У вас %s, новая — %s", CurrentVersion, release.Version) + size + "\n\n"
                  + Captions.T("Программа загрузит новый файл, закроется и откроется уже обновлённой. Данные (переводы, песенники, планы) остаются на месте."),
                  new[] { Captions.T("Обновить"), Captions.T("Позже") },
                  answer =>
                  {
                      if (answer == 0) _ = Install(release);
                      else Defaults.Set(SkippedKey, release.Version);
                  });
    }

    static async Task Install(Release release)
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe) || !OperatingSystem.IsWindows())
        {
            Alert.Tell(Captions.T("Обновление"), Captions.T("Загрузите файл сами: %s", ReleasesPage));
            return;
        }
        var fresh = exe + ".new";
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(20) };
            http.DefaultRequestHeaders.Add("User-Agent", "Slovo-Windows");
            var bytes = await http.GetByteArrayAsync(release.Url);
            if (bytes.Length < 1_000_000) throw new IOException(Captions.T("файл пришёл неполным"));
            await File.WriteAllBytesAsync(fresh, bytes);
            var script = Path.Combine(Path.GetTempPath(), "slovo-update.cmd");
            await File.WriteAllTextAsync(script, Script(Environment.ProcessId, exe, fresh), new UTF8Encoding(false));
            Journal.Say("оновлення: беру " + release.Name + ", закриваюся для заміни");
            Process.Start(new ProcessStartInfo { FileName = "cmd.exe", Arguments = "/c \"" + script + "\"", CreateNoWindow = true, UseShellExecute = false });
            Dispatcher.UIThread.Post(() => Environment.Exit(0));
        }
        catch (Exception error)
        {
            Journal.Say("оновлення: не вийшло — " + error);
            Alert.Tell(Captions.T("Обновление"), Captions.T("Не удалось загрузить: %s", error.Message) + "\n\n" + ReleasesPage);
            try { File.Delete(fresh); } catch { }
        }
    }

    /// Сценарій заміни: дочекатися виходу, перекласти файл, запустити нову версію.
    public static string Script(int pid, string exe, string fresh) =>
        "@echo off\r\nchcp 65001 >nul\r\n:wait\r\n" +
        $"tasklist /fi \"PID eq {pid}\" | find \"{pid}\" >nul && (ping -n 2 127.0.0.1 >nul & goto wait)\r\n" +
        $"move /y \"{fresh}\" \"{exe}\" >nul\r\nif errorlevel 1 (\r\n  echo Не вдалося замінити \"{exe}\"\r\n  pause\r\n  exit /b 1\r\n)\r\n" +
        $"start \"\" \"{exe}\"\r\ndel \"%~f0\"\r\n";
}
