// =============================================================================
//  Updates.cs — оновлення самої програми з релізів GitHub
// =============================================================================
//  Власник: «программы не обновляются автоматически». «Проповідник» ставлять
//  одним файлом, з жодної крамниці він не оновлюється, тож питає сам: раз на
//  добу дивиться `releases/latest` того самого репозиторію, що й «Слово», і,
//  якщо там новіший «Propovidnyk-Slova-X.Y.Z.exe», пропонує оновитися.
//
//  Як відбувається заміна: новий файл лягає поруч зі старим («…exe.new»), і
//  короткий .cmd чекає, поки програма закриється, підміняє файл і запускає
//  його знову. Підмінити себе на ходу Windows не дасть — файл зайнятий
//  власним процесом.
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
using Propovidnyk.Views;

namespace Propovidnyk;

public static class Updates
{
    const string Latest = "https://api.github.com/repos/roman885-85/slovo/releases/latest";
    const string Prefix = "Propovidnyk-Slova-";
    /// Раз на добу: частіше смикати GitHub нема потреби.
    static readonly TimeSpan Often = TimeSpan.FromDays(1);

    public sealed record Found(string Version, string Name, string Url, long Size);

    public static string Ours =>
        Assembly.GetEntryAssembly()?.GetName().Version is { } version
            ? $"{version.Major}.{version.Minor}.{version.Build}"
            : "0";

    /// Тиха перевірка при запуску: мовчить, поки немає новішої версії.
    public static async Task CheckQuietly(Window owner, Settings settings)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (now - settings.LastUpdateCheck < Often.TotalSeconds) return;
        try
        {
            var found = await Ask();
            settings.LastUpdateCheck = now;
            settings.Save();
            if (found == null || found.Version == settings.SkippedUpdate) return;
            await Propose(owner, settings, found);
        }
        catch (Exception error)
        {
            Paths.Say("оновлення: не вийшло спитати GitHub — " + error.Message);
        }
    }

    /// Перевірка кнопкою: каже і тоді, коли все свіже.
    public static async Task CheckNow(Window owner, Settings settings)
    {
        Found? found;
        try
        {
            found = await Ask();
        }
        catch (Exception error)
        {
            await Ui.Message(owner, Lang.T("Оновлення", "Update"),
                             Lang.F("GitHub не відповів: {0}", "GitHub did not answer: {0}", error.Message));
            return;
        }
        settings.LastUpdateCheck = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        settings.Save();
        if (found == null)
        {
            await Ui.Message(owner, Lang.T("Оновлення", "Update"),
                             Lang.F("Версія {0} — новішої немає.", "Version {0} — this is the latest one.", Ours));
            return;
        }
        await Propose(owner, settings, found);
    }

    /// Що лежить у найсвіжішому релізі. null — у нас уже остання версія.
    public static async Task<Found?> Ask()
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        http.DefaultRequestHeaders.Add("User-Agent", "Propovidnyk-Slova");
        http.DefaultRequestHeaders.Add("Accept", "application/vnd.github+json");
        var body = await http.GetStringAsync(Latest);
        var assets = JsonNode.Parse(body)?["assets"]?.AsArray();
        if (assets == null) return null;
        foreach (var item in assets)
        {
            var name = (string?)item?["name"] ?? "";
            if (!name.StartsWith(Prefix, StringComparison.Ordinal) || !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) continue;
            var version = name[Prefix.Length..^4];
            if (!IsNewer(version, Ours)) return null;
            return new Found(version, name, (string?)item?["browser_download_url"] ?? "", (long?)item?["size"] ?? 0);
        }
        return null;
    }

    /// Версії «Проповідника» — трійка чисел: 1.2.0 новіше за 1.1.9.
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
        foreach (var sign in text)
        {
            if (sign is >= '0' and <= '9') digits.Append(sign); else break;
        }
        return digits.Length == 0 ? 0 : int.Parse(digits.ToString());
    }

    static async Task Propose(Window owner, Settings settings, Found found)
    {
        var size = found.Size > 0 ? $" ({Math.Max(1, found.Size / (1024 * 1024))} {Lang.T("МБ", "MB")})" : "";
        var yes = await Ui.Ask(owner,
            Lang.F("Вийшла версія {0}", "Version {0} is out", found.Version),
            Lang.F("У вас {0}, нова — {1}{2}.\n\nПрограма завантажить новий файл, закриється й відкриється вже оновленою. Незбережений план не втрачається — він лежить у теці програми.",
                   "You have {0}, the new one is {1}{2}.\n\nThe program will download the new file, close and open again updated. An unsaved plan is not lost — it lives in the program's folder.",
                   Ours, found.Version, size),
            Lang.T("Оновити", "Update"));
        if (!yes)
        {
            settings.SkippedUpdate = found.Version;
            settings.Save();
            return;
        }
        await Install(owner, found);
    }

    static async Task Install(Window owner, Found found)
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe))
        {
            await Ui.Message(owner, Lang.T("Оновлення", "Update"),
                             Lang.T("Не видно, звідки запущено програму — оновіть файл вручну.",
                                    "Cannot tell where the program was started from — please replace the file by hand."));
            return;
        }
        var fresh = exe + ".new";
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(20) };
            http.DefaultRequestHeaders.Add("User-Agent", "Propovidnyk-Slova");
            var bytes = await http.GetByteArrayAsync(found.Url);
            if (bytes.Length < 1_000_000) throw new Exception(Lang.T("файл прийшов неповним", "the file arrived incomplete"));
            await File.WriteAllBytesAsync(fresh, bytes);
        }
        catch (Exception error)
        {
            Paths.Say("оновлення: не завантажилося — " + error);
            await Ui.Message(owner, Lang.T("Оновлення", "Update"),
                             Lang.F("Не вдалося завантажити: {0}\n\nМожна взяти файл самому: {1}",
                                    "Download failed: {0}\n\nYou can take the file yourself: {1}",
                                    error.Message, "https://github.com/roman885-85/slovo/releases/latest"));
            try { File.Delete(fresh); } catch { /* сміття прибирати не обов'язково */ }
            return;
        }
        try
        {
            var script = Path.Combine(Paths.Cache, "update.cmd");
            // UTF-8 без BOM: сам сценарій першим рядком перемикає вікно на 65001.
            await File.WriteAllTextAsync(script, Script(Environment.ProcessId, exe, fresh), new UTF8Encoding(false));
            Process.Start(new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = "/c \"" + script + "\"",
                CreateNoWindow = true,
                UseShellExecute = false,
            });
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

    /// Сценарій заміни: дочекатися, поки програма закриється, підмінити файл,
    /// запустити нову й прибрати себе.
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
