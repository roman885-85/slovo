// =============================================================================
//  Paths.cs — де програма тримає свої дані
// =============================================================================
//  %APPDATA%\Slovo Propovidnyk: бібліотека перекладів і пісенників
//  (library.db), збережені файли модулів, плани проповідей і копії файлів
//  планів. Поруч із .exe нічого не пишемо: програму часто запускають просто з
//  «Завантажень», а туди писати негарно й не завжди можна.
// =============================================================================

using System;
using System.IO;

namespace Propovidnyk;

public static class Paths
{
    /// Для перевірок: інша тека даних, щоб не чіпати справжню бібліотеку.
    public static string? Override { get; set; }

    public static string Home
    {
        get
        {
            var root = Override ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Slovo Propovidnyk");
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
    public static string Modules => Sub("modules");
    public static string Plans => Sub("plans");
    public static string PlanFiles => Sub("plan-files");
    public static string Cache => Sub("cache");
    public static string SettingsFile => Path.Combine(Home, "settings.json");
    public static string Log => Path.Combine(Home, "journal.txt");

    /// Рядок у щоденник програми — щоб розібрати, що сталося, без консолі.
    public static void Say(string line)
    {
        try
        {
            File.AppendAllText(Log, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {line}{Environment.NewLine}");
        }
        catch
        {
            // Щоденник — не привід падати.
        }
    }
}
