// =============================================================================
//  DataPaths.cs — файл даних за застарілим шляхом (з Settings/DataPaths.swift)
// =============================================================================

namespace Slovo.Core;

/// Знайти файл даних, на який показує застарілий шлях.
///
/// Налаштування й шаблони пам'ятають картинки ПОВНИМ шляхом: фон слайда —
/// «/Users/…/Desktop/Слово.app/Contents/Resources/app/BackGrounds/Black.jpg»,
/// картинки шаблонів — «/Users/…/Desktop/Слово/Слово.app/…/Templates/Autumn/…».
/// Перенесли програму (або дані з Mac на Windows) — і фони пропали, хоч самі
/// файли на місці. Тут шлях переводиться на поточні корені даних за хвостом
/// після `Contents/Resources/app/`, `Application Support/Slovo/` чи після теки
/// даних (`BackGrounds/`, `Templates/`…).
public static class DataPaths
{
    /// Корені даних, у яких шукати: тека даних програми (батько теки модулів).
    /// Ставить стан програми, коли тека модулів відома.
    public static List<string> Roots { get; set; } = new();

    private static readonly string[] Folders =
        ["BackGrounds", "Templates", "Fonts", "RemoteAPI", "Plans", "WebSlides", "Presets", "Modules"];

    /// Позначки дому даних: колишній (пакет Mac), теперішній на Mac і на
    /// Windows (`%APPDATA%\Slovo` — та сама роль, що й Application Support).
    private static readonly string[] HomeMarkers =
        ["/Contents/Resources/app/", "/Application Support/Slovo/", "/AppData/Roaming/Slovo/"];

    /// Шлях, що існує: сам або переведений на поточні корені; `null` — нема ніде.
    public static string? Existing(string path)
    {
        if (path.Length == 0) return null;
        if (SwiftPath.Exists(path)) return path;
        var cleaned = path.Replace("\\", "/");
        var tails = new List<string>();
        // Шляхи в пакет, збережені до перенесення (15.09.2026), знаходять
        // файл у домі даних.
        foreach (var marker in HomeMarkers)
        {
            var at = cleaned.LastIndexOf(marker, StringComparison.Ordinal);
            if (at >= 0) tails.Add(cleaned[(at + marker.Length)..]);
        }
        foreach (var folder in Folders)
        {
            var needle = "/" + folder + "/";
            var at = cleaned.LastIndexOf(needle, StringComparison.OrdinalIgnoreCase);
            if (at >= 0) tails.Add(folder + "/" + cleaned[(at + needle.Length)..]);
        }
        if (!SwiftPath.IsAbsolute(cleaned)) tails.Add(cleaned);
        var bases = new List<string>(Roots) { DataHome.Folder, DataHome.BundleData };
        foreach (var tail in tails)
        {
            if (tail.Length == 0) continue;
            foreach (var root in bases)
            {
                var candidate = SwiftPath.Append(root, tail);
                if (SwiftPath.Exists(candidate)) return candidate;
            }
        }
        return null;
    }
}
