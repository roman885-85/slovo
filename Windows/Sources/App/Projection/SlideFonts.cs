// =============================================================================
//  SlideFonts.cs — шрифти слайда: з теки Fonts і з системи
// =============================================================================
//  Як FontLoader на Mac: шрифти з `Fonts` у теці даних підхоплюються без
//  встановлення в систему; шаблон називає шрифт іменем родини. Немає такого —
//  найближчий системний (шаблони VisioBible писались під Windows: Arial, Times
//  New Roman, Segoe UI…), а «Helvetica Neue» Mac-шаблонів — Arial.
// =============================================================================

using SkiaSharp;

namespace Slovo.App;

public static class SlideFonts
{
    static readonly object Lock = new();
    static readonly Dictionary<string, List<SKTypeface>> Loaded = new(StringComparer.OrdinalIgnoreCase);
    static readonly Dictionary<(string, bool, bool), SKTypeface> Cache = new();
    /// Уже підхоплені файли: бібліотека перечитується не раз (ресурси, імпорт), а
    /// той самий шрифт удруге в список родини класти нема чого.
    static readonly HashSet<string> Files = new(StringComparer.OrdinalIgnoreCase);

    /// Підхопити всі .ttf/.otf/.ttc з теки (Fonts у теці даних).
    public static int RegisterFonts(string folder)
    {
        if (!Directory.Exists(folder)) return 0;
        var count = 0;
        foreach (var file in Directory.EnumerateFiles(folder, "*.*", SearchOption.AllDirectories))
        {
            var ext = Path.GetExtension(file).ToLowerInvariant();
            if (ext is not (".ttf" or ".otf" or ".ttc")) continue;
            lock (Lock) if (!Files.Add(Path.GetFullPath(file))) continue;
            try
            {
                for (var index = 0; index < 8; index++)
                {
                    var face = SKTypeface.FromFile(file, index);
                    if (face == null) break;
                    lock (Lock)
                    {
                        if (!Loaded.TryGetValue(face.FamilyName, out var list)) Loaded[face.FamilyName] = list = new();
                        list.Add(face);
                        Cache.Clear();
                        FamilyFiles.TryAdd(face.FamilyName, file);
                    }
                    count++;
                    if (ext != ".ttc") break;
                }
            }
            catch { }
        }
        return count;
    }

    /// Родина шрифту → файл, з якого її підхоплено (перший, що трапився).
    static readonly Dictionary<string, string> FamilyFiles = new(StringComparer.OrdinalIgnoreCase);

    /// Де лежить файл шрифту з таким іменем родини (як FontLoader.fileURL на Mac): веб-виводу
    /// шрифт треба віддати файлом — установити його в браузері чужої системи ми не можемо.
    public static string? FileFor(string family)
    {
        lock (Lock) return FamilyFiles.TryGetValue(family, out var file) ? file : null;
    }

    static readonly Dictionary<string, string> Substitutes = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Helvetica Neue"] = "Arial", ["Helvetica"] = "Arial", ["San Francisco"] = "Segoe UI",
        [".AppleSystemUIFont"] = "Segoe UI", ["SF Pro"] = "Segoe UI", ["Lucida Grande"] = "Segoe UI",
    };

    /// Шрифт за іменем родини (або повним іменем) з напівжирністю й курсивом.
    public static SKTypeface Typeface(string name, bool bold, bool italic)
    {
        var key = (name, bold, italic);
        lock (Lock) if (Cache.TryGetValue(key, out var ready)) return ready;
        var weight = bold ? SKFontStyleWeight.Bold : SKFontStyleWeight.Normal;
        var slant = italic ? SKFontStyleSlant.Italic : SKFontStyleSlant.Upright;
        SKTypeface? face = null;
        lock (Lock)
        {
            if (Loaded.TryGetValue(name, out var list))
                face = list.FirstOrDefault(f => (f.FontWeight >= 600) == bold && (f.FontSlant != SKFontStyleSlant.Upright) == italic)
                       ?? list.FirstOrDefault(f => (f.FontWeight >= 600) == bold) ?? list[0];
        }
        if (face == null)
        {
            var family = Substitutes.TryGetValue(name, out var sub) ? sub : name;
            var system = SKTypeface.FromFamilyName(family, weight, SKFontStyleWidth.Normal, slant);
            if (system != null && string.Equals(system.FamilyName, family, StringComparison.OrdinalIgnoreCase)) face = system;
            face ??= SKTypeface.FromFamilyName("Arial", weight, SKFontStyleWidth.Normal, slant)
                     ?? SKTypeface.FromFamilyName(null, weight, SKFontStyleWidth.Normal, slant);
        }
        lock (Lock) Cache[key] = face!;
        return face!;
    }
}
