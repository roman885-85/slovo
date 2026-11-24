// =============================================================================
//  Program.cs — вхід «Слова» для Windows
// =============================================================================
//  Ключі запуску (як у Mac-версії, де вони є):
//    --data <тека>      дані не з %APPDATA%\Slovo, а з цієї теки (перевірки);
//    --snapshot <тека>  без вікна на екрані: знімки головного вікна в усіх
//                       режимах і вікон налаштувань — для порівняння зі знімками Mac;
//    --core-check <тека>  перевірка ядра на теці даних (друк у консоль);
//    --remote-port N [--web-port M]  пульт на своїх портах, без маяка й slovo.local (перевірки);
//    --web-slides-port N [--web-socket-port M] [--remote-api-tcp T] [--remote-api-udp U]  веб-слайди на своїх портах (сторінки N, WebSocket
//                       M, за умовчанням N+1) — і при знімках без екрана; без запасних портів (перевірки);
//    --quiet-start      вікно не забирає клавіатуру, вікна залу немає.
// =============================================================================

using Avalonia;

namespace Slovo;

public static class Program
{
    /// Програма знімає свої вікна без екрана (`--snapshot`) — вікно залу не піднімати.
    public static bool Snapshotting { get; set; }

    /// Тека даних, якщо її задали ключем `--data`.
    public static string? DataOverride { get; private set; }

    /// Тихий запуск (--quiet-start) — перевірки поруч із людиною за комп'ютером.
    public static bool QuietStart { get; private set; }

    static string? Arg(string[] args, string name) => Array.IndexOf(args, name) is var i and >= 0 && i + 1 < args.Length ? args[i + 1] : null;

    [STAThread]
    public static int Main(string[] args)
    {
        var data = Array.IndexOf(args, "--data");
        if (data >= 0 && data + 1 < args.Length) DataOverride = Path.GetFullPath(args[data + 1]);
        // Перевірки на тому самому комп'ютері, де працює справжнє «Слово»: свої порти пульта,
        // без крику в мережу (8104), без імені slovo.local і без порту 80.
        if (Arg(args, "--remote-port") is { } phone && int.TryParse(phone, out var phonePort))
        {
            Slovo.App.RemoteControlServer.PortOverride = phonePort;
            Slovo.App.RemoteControlServer.WebPortOverride = int.TryParse(Arg(args, "--web-port"), out var webPort) ? webPort : phonePort + 2;
            Slovo.App.RemoteControlServer.NoPlainPort = true;
            Slovo.App.RemoteControlServer.Quiet = true;
        }
        // Веб-слайди на своїх портах (перевірки): не чіпати 82/8100 справжнього «Слова».
        if (Arg(args, "--web-slides-port") is { } slides && int.TryParse(slides, out var slidesPort))
        {
            Slovo.App.AppState.WebPortOverride = slidesPort;
            Slovo.App.AppState.WebSocketPortOverride = int.TryParse(Arg(args, "--web-socket-port"), out var socketPort) ? socketPort : slidesPort + 1;
            if (int.TryParse(Arg(args, "--remote-api-tcp"), out var tcpPort)) Slovo.App.AppState.TcpPortOverride = tcpPort;
            if (int.TryParse(Arg(args, "--remote-api-udp"), out var udpPort)) Slovo.App.AppState.UdpPortOverride = udpPort;
        }
        // Тихий запуск: вікно не забирає клавіатуру, вікно залу не відкривається.
        QuietStart = Array.IndexOf(args, "--quiet-start") >= 0;

        var core = Array.IndexOf(args, "--core-check");
        if (core >= 0)
        {
            // Перевірка ядра — без вікон. Клас з'являється разом із ядром.
            var check = Type.GetType("Slovo.Core.CoreCheck");
            var run = check?.GetMethod("Run");
            if (run == null) { Console.WriteLine("перевірки ядра ще немає"); return 2; }
            return (int)run.Invoke(null, new object[] { args })!;
        }

        // Перевірка довідки: зібрана сторінка (мова, тема) — у файл.
        if (Arg(args, "--help-page") is { } helpFile)
        {
            File.WriteAllText(helpFile, Slovo.App.HelpWindow.Page(Arg(args, "--help-lang") ?? "uk", Arg(args, "--help-topic")) ?? "");
            return 0;
        }

        var snap = Array.IndexOf(args, "--snapshot");
        if (snap >= 0 && snap + 1 < args.Length) { Snapshotting = true; return Slovo.App.Snapshot.Run(args[snap + 1], args); }

        return BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<SlovoApplication>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
