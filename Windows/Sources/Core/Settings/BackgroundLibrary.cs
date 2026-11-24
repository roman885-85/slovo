// =============================================================================
//  BackgroundLibrary.cs — фонові малюнки за списком тек «Шляхи»
//  (з Settings/BackgroundLibrary.swift)
// =============================================================================

namespace Slovo.Core;

/// Збір фонових малюнків за списком тек вкладки «Шляхи» (6.1.5, елементи
/// (31) (32) (33)).
///
/// Джерело — саме список, а не одна зашита тека: в оператора фони часто
/// лежать на зовнішньому диску поруч із відео. Кнопка `SBSubFolder` (33)
/// перемикає у вибраного рядка ознаку «шукати у вкладених теках».
public static class BackgroundLibrary
{
    /// Розширення картинок. Список закритий навмисно: у теці з фонами лежать
    /// ще й `.ini`, і мінікартинки `thumbs`.
    public static readonly IReadOnlySet<string> ImageExtensions = new HashSet<string>(StringComparer.Ordinal)
    {
        "jpg", "jpeg", "png", "bmp", "tif", "tiff", "heic", "gif", "webp",
    };

    /// Тека за умовчанням — та сама, що лежить поруч із модулями в поставці.
    public const string DefaultFolderName = "BackGrounds";

    /// Розгорнути запис списку в справжній шлях.
    ///
    /// Оригінал пише шляхи всередині своєї теки коротко і зі зворотними скісними
    /// («BackGrounds\»), а зовнішні — повністю («Z:\Fon\» або «/Volumes/...»).
    /// Відрізняємо одне від одного за початком: «/» на Mac, «C:\»/«\\сервер» на Windows.
    public static string Resolve(string path, string dataRoot)
    {
        if (SwiftPath.IsAbsolute(path)) return path;
        var unix = path.Replace("\\", "/");
        return SwiftPath.Append(dataRoot, unix);
    }

    /// Усі картинки з перелічених тек, без повторів і в зрозумілому людині
    /// порядку: теки — як у списку, усередині теки — за ім'ям «як у Finder».
    public static List<string> Images(IReadOnlyList<PicturePathEntry> paths, string dataRoot)
    {
        var folders = paths.Count == 0
            ? new List<(string Folder, bool Deep)> { (Path.Combine(dataRoot, DefaultFolderName), false) }
            : paths.Select(entry => (Resolve(entry.Path, dataRoot), entry.ScansSubfolders)).ToList();

        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (folder, deep) in folders)
        {
            foreach (var file in Images(folder, deep))
                if (seen.Add(file)) result.Add(file);
        }
        return result;
    }

    /// Картинки однієї теки. Вкладені теки обходяться лише на вимогу:
    /// в оператора в корені фонів може лежати вся медіатека.
    public static List<string> Images(string folder, bool deep)
    {
        var found = new List<string>();
        if (deep)
        {
            if (!Directory.Exists(folder)) return found;
            Walk(folder, found);
        }
        else
        {
            found = SwiftPath.Contents(folder, skipsHidden: true)
                .Where(file => ImageExtensions.Contains(SwiftPath.Extension(file).ToLowerInvariant()))
                .ToList();
        }
        return found.OrderBy(SwiftPath.LastComponent, SwiftText.StandardOrder).ToList();
    }

    private static void Walk(string folder, List<string> found)
    {
        foreach (var entry in SwiftPath.Contents(folder, skipsHidden: true))
        {
            if (Directory.Exists(entry))
            {
                Walk(entry, found);
                continue;
            }
            if (ImageExtensions.Contains(SwiftPath.Extension(entry).ToLowerInvariant())) found.Add(entry);
        }
    }

    /// Скільки картинок дасть список — для напису під ним на вкладці «Шляхи».
    public static int Count(IReadOnlyList<PicturePathEntry> paths, string dataRoot) => Images(paths, dataRoot).Count;
}
