// =============================================================================
//  Diagnostics.cs — «Діагностика…» (як showDiagnostics на Mac)
// =============================================================================
//  Звіт про стан програми — те, що питають, коли «щось не так»: версія й
//  система, тека даних, модулі й пісенники, пульт і його порти, екрани, мова.
//  Пишеться у файл (Logs у теці даних) і показується вікном з «Показати файл».
// =============================================================================

using System.Diagnostics;
using System.Text;
using Slovo.Core;

namespace Slovo.App;

public static class Diagnostics
{
    public static string ReportPath => Path.Combine(DataHome.Folder, "Logs", "slovo-diagnostics.txt");

    public static string Report(AppState state)
    {
        var lines = new List<string>();
        void Line(string title, string value, bool ok = true) => lines.Add($"{(ok ? "✓" : "✗")} {title}: {value}");
        Line(Captions.T("Версия"), $"{AppUpdater.CurrentVersion} · {Environment.OSVersion.VersionString} · .NET {Environment.Version}");
        var folderWritable = IsWritable(DataHome.Folder);
        Line(Captions.T("Папка данных"), DataHome.DisplayPath + (folderWritable ? "" : " — " + Captions.T("запись запрещена")), folderWritable);
        var modules = state.AllModules;
        Line(Captions.T("Папка с модулями"), state.ModulesFolder, Directory.Exists(state.ModulesFolder));
        Line(Captions.T("Модули"), modules.Count == 0 ? Captions.T("ни одного") : string.Join(", ", modules.Select(m => m.Identifier)), modules.Count > 0);
        Line(Captions.T("Основной перевод"), state.PrimaryModule?.DisplayName ?? "—", state.PrimaryModule != null);
        var books = state.AllSongBooks;
        Line(Captions.T("Песенники"), books.Count == 0 ? Captions.T("ни одного") : string.Join(", ", books.Select(b => b.Id)), true);
        var failed = books.Where(b => b.Failure != null).ToList();
        if (failed.Count > 0) Line(Captions.T("Не открылись"), string.Join("; ", failed.Select(b => $"{b.Id}: {b.Failure}")), false);
        var server = RemoteControlServer.Shared;
        Line(Captions.T("Пульт на телефоне"), server.IsRunning ? Captions.T("работает на порту %s", server.Port.ToString()) : server.LastError ?? Captions.T("не запущен"), server.IsRunning || server.LastError == null);
        Line(Captions.T("Пульт в браузере"), server.WebRunning ? Captions.T("работает на порту %s", server.WebPort.ToString())
                                              + (server.PlainReady ? " · " + Captions.T("адрес без номера порта") : "") : server.WebError ?? Captions.T("не запущен"),
             server.WebRunning || server.WebError == null);
        Line(Captions.T("Имя в сети"), server.MdnsName ?? "—");
        var addresses = Names.Addresses().Select(a => a.Address.ToString()).ToList();
        Line(Captions.T("Адреса"), addresses.Count == 0 ? Captions.T("нет сети") : string.Join(", ", addresses), addresses.Count > 0);
        var screens = MainWindow.Shared?.Screens;
        Line(Captions.T("Экраны"), screens == null ? "—" : string.Join("; ", screens.All.Select((s, i) => $"{i + 1}: {s.Bounds.Width}×{s.Bounds.Height}{(s.IsPrimary ? " *" : "")}")));
        var (width, height) = ProjectionController.Shared.FrameSize();
        Line(Captions.T("Кадр зала"), $"{width}×{height}");
        Line(Captions.T("Язык интерфейса"), OurWords.Language);
        Line(Captions.T("План"), $"{state.Plan.Count}" + (state.IsSermon ? " · " + Captions.T("План проповеди") : ""));
        Line(Captions.T("История"), state.History.Records.Count.ToString());
        return string.Join("\n", lines);
    }

    static bool IsWritable(string folder)
    {
        try
        {
            Directory.CreateDirectory(folder);
            var probe = Path.Combine(folder, ".slovo-probe");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    public static void Show(AppState state)
    {
        var report = Report(state);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(ReportPath)!);
            File.WriteAllText(ReportPath, report + "\n", new UTF8Encoding(false));
        }
        catch (Exception error) { Journal.Say($"діагностика не записалась: {error.Message}"); }
        Alert.Ask(Captions.T("Диагностика"), report, new[] { Captions.T("Закрыть"), Captions.T("Показать файл") }, answer =>
        {
            if (answer != 1 || !File.Exists(ReportPath)) return;
            try
            {
                if (OperatingSystem.IsWindows()) Process.Start("explorer.exe", $"/select,\"{ReportPath}\"");
                else Process.Start(new ProcessStartInfo(ReportPath) { UseShellExecute = true });
            }
            catch (Exception error) { Journal.Say($"файл діагностики не відкрився: {error.Message}"); }
        });
    }
}
