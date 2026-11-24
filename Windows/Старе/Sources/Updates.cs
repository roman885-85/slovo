// =============================================================================
//  Updates.cs — оновлення самої програми з релізів GitHub
// =============================================================================
//  Як у «Проповіднику»: раз на кілька днів дивимося `releases/latest`
//  репозиторію «Слова» і, якщо там новіший «Slovo-X.Y.Z-Windows.exe»,
//  пропонуємо оновитися. Новий файл лягає поруч («…exe.new»), короткий .cmd
//  чекає, поки програма закриється, підміняє файл і запускає його знову.
// =============================================================================

using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Avalonia.Controls;
using Slovo.Views;

namespace Slovo;

public static class Updates
{
    public const string Latest = "https://api.github.com/repos/roman885-85/slovo/releases/latest";
    public const string ReleasesPage = "https://github.com/roman885-85/slovo/releases/latest";
    const string Prefix = "Slovo-";
    const string Suffix = "-Windows.exe";

    public sealed record Found(string Version, string Name, string Url, long Size);

    public static string Ours =>
        Assembly.GetEntryAssembly()?.GetName().Version is { } version
            ? $"{version.Major}.{version.Minor}.{version.Build}"
            : "0";

    /// Тиха перевірка при запуску: мовчить, поки немає новішої версії.
    public static async Task CheckQuietly(Window owner, AppState state)
    {
        var settings = state.Settings;
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var often = TimeSpan.FromDays(Math.Max(1, settings.UpdateIntervalDays)).TotalSeconds;
        if (now - settings.LastUpdateCheck < often) return;
        try
        {
            var found = await Ask();
            settings.LastUpdateCheck = now;
            settings.Save();
            if (found == null || found.Version == settings.SkippedUpdate) return;
            await Propose(owner, state, found);
        }
        catch (Exception error)
        {
            Paths.Say("оновлення: не вийшло спитати GitHub — " + error.Message);
        }
    }

    public static async Task CheckNow(Window owner, AppState state)
    {
        Found? found;
        try { found = await Ask(); }
        catch (Exception error)
        {
            await Ui.Message(owner, Lang.T("Оновлення", "Update"), Lang.F("GitHub не відповів: {0}", "GitHub did not answer: {0}", error.Message));
            return;
        }
        state.Settings.LastUpdateCheck = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        state.Settings.Save();
        if (found == null)
        {
            await Ui.Message(owner, Lang.T("Оновлення", "Update"), Lang.F("Версія {0} — новішої немає.", "Version {0} — this is the latest one.", Ours));
            return;
        }
        await Propose(owner, state, found);
    }

    public static async Task<Found?> Ask()
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        http.DefaultRequestHeaders.Add("User-Agent", "Slovo-Windows");
        http.DefaultRequestHeaders.Add("Accept", "application/vnd.github+json");
        var body = await http.GetStringAsync(Latest);
        var assets = JsonNode.Parse(body)?["assets"]?.AsArray();
        if (assets == null) return null;
        foreach (var item in assets)
        {
            var name = (string?)item?["name"] ?? "";
            if (!name.StartsWith(Prefix, StringComparison.Ordinal) || !name.EndsWith(Suffix, StringComparison.OrdinalIgnoreCase)) continue;
            var version = name[Prefix.Length..^Suffix.Length];
            if (!IsNewer(version, Ours)) return null;
            return new Found(version, name, (string?)item?["browser_download_url"] ?? "", (long?)item?["size"] ?? 0);
        }
        return null;
    }

    public static bool IsNewer(string a, string b)
    {
        var left = a.Split('.');
        var right = b.Split('.');
        for (var i = 0; i < Math.Max(left.Length, right.Length); i++)
        {
            var l = Number(i < left.Length ? left[i] : "0");
            var r = Number(i < right.Length ? right[i] : "0");
            if (l != r) return l > r;
        }
        return false;
    }

    static int Number(string text)
    {
        var digits = new StringBuilder();
        foreach (var sign in text) { if (sign is >= '0' and <= '9') digits.Append(sign); else break; }
        return digits.Length == 0 ? 0 : int.Parse(digits.ToString());
    }

    static async Task Propose(Window owner, AppState state, Found found)
    {
        var size = found.Size > 0 ? $" ({Math.Max(1, found.Size / (1024 * 1024))} {Lang.T("МБ", "MB")})" : "";
        var yes = await Ui.Ask(owner,
            Lang.F("Вийшла версія {0}", "Version {0} is out", found.Version),
            Lang.F("У вас {0}, нова — {1}{2}.\n\nПрограма завантажить новий файл, закриється й відкриється вже оновленою. Дані (переклади, пісенники, плани) лишаються в теці програми.",
                   "You have {0}, the new one is {1}{2}.\n\nThe program will download the new file, close and open again updated. Data (translations, songbooks, plans) stays in the program's folder.",
                   Ours, found.Version, size),
            Lang.T("Оновити", "Update"));
        if (!yes)
        {
            state.Settings.SkippedUpdate = found.Version;
            state.Settings.Save();
            return;
        }
        await Install(owner, state, found);
    }

    static async Task Install(Window owner, AppState state, Found found)
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe) || !OperatingSystem.IsWindows())
        {
            await Ui.Message(owner, Lang.T("Оновлення", "Update"),
                             Lang.F("Завантажте файл самі: {0}", "Please take the file yourself: {0}", ReleasesPage));
            return;
        }
        var fresh = exe + ".new";
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(20) };
            http.DefaultRequestHeaders.Add("User-Agent", "Slovo-Windows");
            var bytes = await http.GetByteArrayAsync(found.Url);
            if (bytes.Length < 1_000_000) throw new Exception(Lang.T("файл прийшов неповним", "the file arrived incomplete"));
            await File.WriteAllBytesAsync(fresh, bytes);
        }
        catch (Exception error)
        {
            Paths.Say("оновлення: не завантажилося — " + error);
            await Ui.Message(owner, Lang.T("Оновлення", "Update"),
                             Lang.F("Не вдалося завантажити: {0}\n\nМожна взяти файл самому: {1}", "Download failed: {0}\n\nYou can take the file yourself: {1}", error.Message, ReleasesPage));
            try { File.Delete(fresh); } catch { /* сміття прибирати не обов'язково */ }
            return;
        }
        try
        {
            var script = Path.Combine(Paths.Cache, "update.cmd");
            await File.WriteAllTextAsync(script, Script(Environment.ProcessId, exe, fresh), new UTF8Encoding(false));
            state.Shutdown();
            Process.Start(new ProcessStartInfo { FileName = "cmd.exe", Arguments = "/c \"" + script + "\"", CreateNoWindow = true, UseShellExecute = false });
            Paths.Say("оновлення: беру " + found.Name + ", закриваюся для заміни");
            Environment.Exit(0);
        }
        catch (Exception error)
        {
            Paths.Say("оновлення: заміна не почалася — " + error);
            await Ui.Message(owner, Lang.T("Оновлення", "Update"),
                             Lang.F("Новий файл лежить поруч зі старим: {0}\nЗакрийте програму й перейменуйте його замість старого.",
                                    "The new file is next to the old one: {0}\nClose the program and rename it over the old one.", fresh));
        }
    }

    public static string Script(int pid, string exe, string fresh) =>
        "@echo off\r\n" +
        "chcp 65001 >nul\r\n" +
        ":wait\r\n" +
        $"tasklist /fi \"PID eq {pid}\" | find \"{pid}\" >nul && (ping -n 2 127.0.0.1 >nul & goto wait)\r\n" +
        $"move /y \"{fresh}\" \"{exe}\" >nul\r\n" +
        "if errorlevel 1 (\r\n" +
        $"  echo Не вдалося замінити \"{exe}\"\r\n" +
        "  pause\r\n" +
        "  exit /b 1\r\n" +
        ")\r\n" +
        $"start \"\" \"{exe}\"\r\n" +
        "del \"%~f0\"\r\n";
}
