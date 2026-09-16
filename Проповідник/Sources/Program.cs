// =============================================================================
//  Program.cs — точка входу «Проповідника Слова»
// =============================================================================
//  Звичайний запуск відкриває вікно плану проповіді. Режим --selftest без
//  вікна проганяє все, що вміє програма (розбір модулів, план, пошук «Слова»
//  в мережі, завантаження плану), і друкує звіт — для перевірки на чистій
//  Windows без клацання мишею.
// =============================================================================

using System;
using System.Runtime.InteropServices;
using Avalonia;

namespace Propovidnyk;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (Array.IndexOf(args, "--selftest") >= 0 || Array.IndexOf(args, "--help") >= 0)
        {
            if (OperatingSystem.IsWindows()) AttachConsole(-1);
            return Cli.Run(args).GetAwaiter().GetResult();
        }
        var settings = Settings.Load();
        Lang.Choice = settings.Language;
        Paths.Say("запуск");
        return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
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
