// =============================================================================
//  Program.cs — точка входу «Слова» для Windows
// =============================================================================
//  Звичайний запуск відкриває головне вікно. Режим --selftest без вікна
//  проганяє все, що вміє програма (модулі, слайди, план, пульт), і друкує
//  звіт — для перевірки на чистій Windows без клацання мишею.
//
//      Slovo.exe [--data <тека>] [--selftest [--keep]] [--port 8103] [--import <тека|файл>] [--quiet-start]
// =============================================================================

using System;
using System.Runtime.InteropServices;
using Avalonia;

namespace Slovo;

public static class Program
{
    /// Тихий запуск (--quiet-start): вікно не забирає клавіатуру, вікно слайда не відкривається —
    /// для перевірок на машині, за якою працює людина.
    public static bool QuietStart { get; private set; }

    [STAThread]
    public static int Main(string[] args)
    {
        QuietStart = Array.IndexOf(args, "--quiet-start") >= 0;
        var data = Arg(args, "--data");
        if (data != null) Paths.Override = data;
        if (Array.IndexOf(args, "--selftest") >= 0 || Array.IndexOf(args, "--help") >= 0)
        {
            if (OperatingSystem.IsWindows()) AttachConsole(-1);
            return SelfTest.Run(args).GetAwaiter().GetResult();
        }
        // Без вікна: поставити модулі з теки чи файла (тека VisioBible, zip, .vbm…).
        var import = Arg(args, "--import");
        if (import != null)
        {
            if (OperatingSystem.IsWindows()) AttachConsole(-1);
            Console.OutputEncoding = System.Text.Encoding.UTF8;
            Lang.Choice = Settings.Load().Language;
            using var library = new Library();
            var result = System.IO.Directory.Exists(import) ? ResourceStore.ImportFolder(library, import, "folder", name => Console.WriteLine("  " + name))
                                                           : ResourceStore.ImportFile(library, import, "file");
            var settingsForImport = Settings.Load();
            foreach (var id in result.Modules) if (!settingsForImport.ModuleOrder.Contains(id)) settingsForImport.ModuleOrder.Add(id);
            settingsForImport.Save();
            Console.WriteLine(result.Summary());
            foreach (var failure in result.Failures) Console.WriteLine("  ! " + failure);
            return result.Failures.Count == 0 ? 0 : 1;
        }
        var settings = Settings.Load();
        Lang.Choice = settings.Language;
        Paths.Say("запуск " + Updates.Ours);
        try
        {
            return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        catch (Exception error)
        {
            Paths.Say("програма впала: " + error);
            throw;
        }
    }

    public static string? Arg(string[] args, string name)
    {
        var at = Array.IndexOf(args, name);
        return at >= 0 && at + 1 < args.Length ? args[at + 1] : null;
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();

    /// Програма віконна (WinExe): без цього виклику --selftest мовчав би в консолі.
    [DllImport("kernel32.dll")]
    static extern bool AttachConsole(int processId);
}
