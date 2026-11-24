// =============================================================================
//  Paths.cs — де програма тримає свої дані
// =============================================================================
//  %APPDATA%\Slovo — як на Mac у ~/Library/Application Support/Slovo: бібліотека
//  перекладів і пісенників (library.db), збережені файли модулів, шаблони
//  слайда, фони, плани, Історія, налаштування, файли від пульта, щоденник.
//  Поруч із .exe нічого не пишемо: програму часто запускають просто з
//  «Завантажень», а туди писати негарно й не завжди можна.
//
//  Для перевірок (--selftest, --data) тека інша, щоб не чіпати справжню.
// =============================================================================

using System;
using System.IO;

namespace Slovo;

public static class Paths
{
    /// Інша тека даних — перевірки й друга копія програми на тій самій машині.
    public static string? Override { get; set; }

    public static string Home
    {
        get
        {
            var root = Override ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Slovo");
            Directory.CreateDirectory(root);
            return root;
        }
    }

    static string Sub(string name)
    {
        var folder = Path.Combine(Home, name);
        Directory.CreateDirectory(folder);
        return folder;
    }

    public static string Library => Path.Combine(Home, "library.db");
    /// Привезені файли модулів — щоб віддати їх планшету чи «Проповіднику».
    public static string Modules => Sub("Modules");
    /// Шаблони слайда `.sch` — кожен у своїй теці з фоном і картинками.
    public static string Templates => Sub("Templates");
    /// Фонові зображення.
    public static string Backgrounds => Sub("BackGrounds");
    /// Шрифти, привезені з ресурсів «Слова».
    public static string Fonts => Sub("Fonts");
    public static string Plans => Sub("Plans");
    /// Файли, що прийшли з телефона, планшета чи «Проповідника».
    public static string Uploads => Sub("Пульт");
    public static string Cache => Sub("cache");
    public static string Screenshots => Sub("ScreenShots");
    public static string SettingsFile => Path.Combine(Home, "settings.json");
    public static string HotkeysFile => Path.Combine(Home, "hotkeys.ini");
    public static string HistoryFile => Path.Combine(Home, "History.json");
    public static string Log => Path.Combine(Home, "journal.txt");

    static readonly object Lock = new();

    /// Рядок у щоденник програми — щоб розібрати, що сталося, без консолі.
    public static void Say(string line)
    {
        try
        {
            lock (Lock)
            {
                var file = Log;
                // Щоденник не росте без межі: за мегабайт — лишаємо хвіст.
                if (File.Exists(file) && new FileInfo(file).Length > 1_500_000)
                {
                    var text = File.ReadAllText(file);
                    File.WriteAllText(file, text[(text.Length / 2)..]);
                }
                File.AppendAllText(file, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {line}{Environment.NewLine}");
            }
        }
        catch
        {
            // Щоденник — не привід падати.
        }
        if (Echo) Console.Error.WriteLine(line);
    }

    /// Дублювати щоденник у консоль — для перевірок.
    public static bool Echo { get; set; }
}
