// =============================================================================
//  ModuleLibrary.cs — каталог модулів (з Bible/ModuleLibrary.swift)
// =============================================================================

namespace Slovo.Core;

/// Каталог модулів: обходить теку `Modules` і відкриває все, що там лежить.
public sealed class ModuleLibrary
{
    public sealed record LoadFailure(string Directory, string Reason);

    /// Модулі всіх форматів упереміш — зовні різниця не важлива.
    public IReadOnlyList<TextModule> Modules { get; }
    public IReadOnlyList<LoadFailure> Failures { get; }
    public IReadOnlyList<string> SongFiles { get; }

    /// <param name="extraModules">шляхи зі списку «Модулі» вікна «Параметри»,
    /// що лежать поза текою `Modules`. Тека обходиться цілком, а ці
    /// відкриваються поіменно: без них модуль, доданий кнопкою «+» з іншого
    /// диска, ніколи не відкривався.</param>
    public ModuleLibrary(string modulesDirectory, IEnumerable<string>? extraModules = null)
    {
        var entries = SwiftPath.Contents(modulesDirectory, skipsHidden: true);

        var modules = new List<TextModule>();
        var failures = new List<LoadFailure>();
        var songs = new List<string>();

        var inside = entries.OrderBy(SwiftPath.LastComponent, SwiftText.StandardOrder).ToList();
        // Чужі шляхи — після своих: за однакового імені перемагає тека
        // програми, а повтор зовні мовчки пропускається.
        var root = SwiftPath.Standardized(modulesDirectory);
        var separator = Path.DirectorySeparatorChar.ToString();
        var outside = (extraModules ?? Array.Empty<string>())
            .Select(SwiftPath.Standardized)
            .Where(path => !path.StartsWith(root + separator, StringComparison.Ordinal) && path != root);
        var seen = new HashSet<string>(StringComparer.Ordinal);

        foreach (var entry in inside.Concat(outside))
        {
            var name = SwiftPath.LastComponent(entry);
            var isDirectory = Directory.Exists(entry);
            if (!seen.Add(name.ToLowerInvariant())) continue;

            if (isDirectory)
            {
                try { modules.Add(new BibleModule(entry)); }
                catch (Exception error) { failures.Add(new LoadFailure(name, error.Message)); }
                continue;
            }

            switch (SwiftPath.Extension(entry).ToLowerInvariant())
            {
                case "vbm":
                case "songbook":
                    songs.Add(entry);
                    break;
                case "sqlite3":
                case "sqlite":
                {
                    // Супутники модуля MyBible — словники, коментарі, перехресні
                    // посилання — лежать поруч і віршів не містять: їх пропускаємо.
                    var stem = SwiftPath.LastComponent(SwiftPath.DeletingExtension(entry)).ToLowerInvariant();
                    string[] companions = ["commentaries", "dictionary", "crossreferences", "subheadings", "plan", "notes"];
                    if (companions.Any(companion => stem.EndsWith("." + companion, StringComparison.Ordinal))) continue;
                    try { modules.Add(new MyBibleModule(entry)); }
                    catch (Exception error) { failures.Add(new LoadFailure(name, error.Message)); }
                    break;
                }
                case "mybible":
                    // В одне розширення MySword кладе все підряд, а тип модуля
                    // стоїть перед ним. Вірші є лише в `.bbl`.
                    if (!MySwordModule.IsBibleModuleName(name)) continue;
                    try { modules.Add(new MySwordModule(entry)); }
                    catch (Exception error) { failures.Add(new LoadFailure(name, error.Message)); }
                    break;
            }
        }

        Modules = modules;
        Failures = failures;
        // Свій формат головніший: коли поруч лежать `pv3055.songbook` і
        // `pv3055.vbm` (той, з якого перетворили), у списку — лише перший.
        var own = new HashSet<string>(
            songs.Where(song => SwiftPath.Extension(song).ToLowerInvariant() == DataHome.SongBookExtension)
                 .Select(song => SwiftPath.LastComponent(SwiftPath.DeletingExtension(song)).ToLowerInvariant()),
            StringComparer.Ordinal);
        SongFiles = songs.Where(song => SwiftPath.Extension(song).ToLowerInvariant() != "vbm"
                                        || !own.Contains(SwiftPath.LastComponent(SwiftPath.DeletingExtension(song)).ToLowerInvariant()))
            .ToList();
    }

    public TextModule? Module(string identifier) =>
        Modules.FirstOrDefault(module => SwiftText.SameIgnoringCase(module.Identifier, identifier));
}
