// =============================================================================
//  DataMigration.cs — перенесення даних із пакета в дім даних
//  (з Settings/DataMigration.swift)
// =============================================================================

namespace Slovo.Core;

/// Перенесення даних із пакета програми в дім даних (`DataHome.Folder`).
///
/// Власник 15.09.2026: дані — поза пакетом. Звідки: «пакет» (на Mac —
/// `Contents/Resources/app`: модулі, фони, шаблони, шрифти, плани, так везли
/// їх старі збірки й повний випуск; на Windows — `DataHome.BundleData`).
///
/// Правила обережні: нічого не перезаписується й не видаляється. Чого в новому
/// домі ще немає — переїжджає (перенесенням, а коли джерело лише для читання —
/// копією). Теки з тим самим іменем зливаються поелементно. Файл, що вже є в
/// новому домі, лишається де був — новий дім головніший. Кеші службової теки й
/// умовчання пакета не чіпаються.
public static class DataMigration
{
    public sealed class Report
    {
        /// Що переїхало (шляхи відносно нового дому).
        public List<string> Moved = new();
        /// Що скопійовано, бо з джерела забрати не можна.
        public List<string> Copied = new();
        /// Що вже було в новому домі й лишилося в джерелі.
        public List<string> Kept = new();
        public List<string> Errors = new();

        public bool IsEmpty => Moved.Count == 0 && Copied.Count == 0 && Errors.Count == 0;

        public string Summary
        {
            get
            {
                var parts = new List<string>();
                if (Moved.Count > 0) parts.Add($"перенесено {Moved.Count}: " + string.Join(", ", Moved.Take(12)));
                if (Copied.Count > 0) parts.Add($"скопійовано {Copied.Count}: " + string.Join(", ", Copied.Take(12)));
                if (Kept.Count > 0) parts.Add($"уже були в новому домі {Kept.Count}");
                if (Errors.Count > 0) parts.Add("помилки: " + string.Join("; ", Errors));
                return parts.Count == 0 ? "переносити нічого" : string.Join("; ", parts);
            }
        }
    }

    /// Звіт останнього запуску — для журналу й самоперевірки.
    public static Report LastReport { get; set; } = new();

    /// Чи довелося перепечатати пакет після перенесення (звіт для журналу).
    public static string Resealed { get; set; } = "";

    public static Report Run(string? target = null, string? bundleData = null)
    {
        target ??= DataHome.Folder;
        bundleData ??= DataHome.BundleData;
        var report = new Report();
        try
        {
            Directory.CreateDirectory(target);
        }
        catch (Exception error)
        {
            report.Errors.Add($"не створилася тека {target}: {error.Message}");
            LastReport = report;
            return report;
        }
        // Налаштування, історія й шаблони вже лежать у домі даних — забираємо
        // з пакета те, чого тут ще немає: модулі, фони, шаблони, шрифти, плани.
        var skipping = new HashSet<string>(DataHome.BundledDefaults, StringComparer.Ordinal);
        skipping.UnionWith(DataHome.VisioBibleLeftovers);
        Merge(bundleData, target, skipping, "", report);
        if (report.Moved.Count > 0
            && SwiftPath.Standardized(bundleData) == SwiftPath.Standardized(DataHome.BundleData))
        {
            Reseal();
        }
        LastReport = report;
        return report;
    }

    /// Перепечатати свій пакет після того, як дані з нього поїхали.
    ///
    /// Лише Mac: підпис накладено на ВЕСЬ пакет разом із даними, і забравши їх,
    /// програма клала тимчасовий підпис (`codesign --force --deep --sign -`).
    /// На Windows .exe даних не містить і підпису від них не залежить —
    /// перепечатувати нічого.
    private static void Reseal()
    {
        Resealed = "Windows: пакет не підписується — перепечатувати нічого";
    }

    /// Чи лишилося в пакеті щось, чого немає в новому домі, — помічнику
    /// оновлення: тільки це й треба переносити в новий пакет.
    public static List<string> UnmigratedBundleItems(string bundleData, string? target = null)
    {
        target ??= DataHome.Folder;
        var entries = SwiftPath.Names(bundleData) ?? Array.Empty<string>();
        return entries.Where(name => !name.StartsWith('.') && !DataHome.BundledDefaults.Contains(name)
                                     && !DataHome.VisioBibleLeftovers.Contains(name)
                                     && !SwiftPath.Exists(Path.Combine(target, name)))
            .OrderBy(name => name, StringComparer.Ordinal).ToList();
    }

    private static void Merge(string source, string target, IReadOnlySet<string> skipping, string prefix, Report report)
    {
        if (!Directory.Exists(source) || SwiftPath.Standardized(source) == SwiftPath.Standardized(target)) return;
        var entries = SwiftPath.Names(source) ?? Array.Empty<string>();
        foreach (var name in entries.OrderBy(name => name, StringComparer.Ordinal))
        {
            if (name == ".DS_Store" || skipping.Contains(name)) continue;
            var from = Path.Combine(source, name);
            var to = Path.Combine(target, name);
            var relative = prefix.Length == 0 ? name : prefix + "/" + name;
            var fromIsDirectory = Directory.Exists(from);
            if (!SwiftPath.Exists(to))
            {
                try
                {
                    Move(from, to, fromIsDirectory);
                    report.Moved.Add(relative);
                }
                catch
                {
                    try
                    {
                        Copy(from, to, fromIsDirectory);
                        report.Copied.Add(relative);
                    }
                    catch (Exception error)
                    {
                        report.Errors.Add($"{relative}: {error.Message}");
                    }
                }
            }
            else if (fromIsDirectory && Directory.Exists(to))
            {
                Merge(from, to, new HashSet<string>(), relative, report);
                // Злили й нічого не лишилося — прибрати порожню теку.
                var rest = SwiftPath.Names(from);
                if (rest != null && rest.All(item => item == ".DS_Store"))
                {
                    try { Directory.Delete(from, recursive: true); } catch { }
                }
            }
            else
            {
                report.Kept.Add(relative);
            }
        }
    }

    private static void Move(string from, string to, bool isDirectory)
    {
        if (isDirectory) Directory.Move(from, to);
        else File.Move(from, to);
    }

    private static void Copy(string from, string to, bool isDirectory)
    {
        if (!isDirectory)
        {
            File.Copy(from, to);
            return;
        }
        Directory.CreateDirectory(to);
        foreach (var entry in Directory.EnumerateFileSystemEntries(from))
            Copy(entry, Path.Combine(to, Path.GetFileName(entry)), Directory.Exists(entry));
    }
}
