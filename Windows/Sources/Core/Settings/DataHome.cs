// =============================================================================
//  DataHome.cs — свій дім даних «Слова» (з Settings/DataHome.swift)
// =============================================================================
//  Mac: ~/Library/Application Support/Slovo. Windows: %APPDATA%\Slovo (або
//  тека з ключа запуску --data, Slovo.Program.DataOverride). Теку з Mac можна
//  просто скопіювати сюди — файли ті самі.
// =============================================================================

using System.Reflection;

namespace Slovo.Core;

/// Свій дім даних «Слова».
///
/// Власник 15.09.2026: дані — поза пакетом програми, «Application Support
/// пусть будет там все», а де все зберігається — писати в налаштуваннях і
/// підказках. Пакет (на Windows — сам .exe) містить лише програму й свої
/// умовчання (`BundledDefaults`), а все людське лежить тут.
///
/// Формат пісенників `.vbm` переводиться у свій `.songbook` просто в теці
/// модулів, а оригінали відкладаються в «Імпорт зі старої програми» поруч із нею.
public static class DataHome
{
    public static string Folder =>
        Slovo.Program.DataOverride
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Slovo");

    /// Та сама тека — для кешів: власник хоче, щоб усе було в одному місці.
    public static string SupportFolder => Folder;

    /// Шлях для людини — повний, як є на цьому комп'ютері.
    public static string DisplayPath => Folder;

    /// Речення для підказок: що і де лежить, повною адресою.
    public static string WhereText => OurWords.T("Всё загруженное и настроенное лежит в папке: %s", DisplayPath);

    /// Дописати адресу до готової підказки — окремим рядком.
    public static string Hint(string text) => text + "\n" + WhereText;

    /// Що лишається в пакеті: умовчання, які йдуть із програмою.
    public static readonly IReadOnlySet<string> BundledDefaults =
        new HashSet<string>(StringComparer.Ordinal) { "Slovo.ini", "hotkeys.ini", "ЧИТАТИ.md", "inconsistencies.sqlite3" };

    /// Кеші службової теки — не дані, їх не переносимо.
    public static readonly IReadOnlySet<string> SupportCaches =
        new HashSet<string>(StringComparer.Ordinal) { "ndi", "ytdlp-build", "LanguageMerged" };

    /// Залишки старої програми: довідка `.chm`, мови `.lng`, стилі `.vsf`, знімки й
    /// службові ini. Власник просив їх позбутися — з пакета старої збірки вони
    /// в дім даних не їдуть.
    public static readonly IReadOnlySet<string> VisioBibleLeftovers =
        new HashSet<string>(StringComparer.Ordinal)
        {
            "Help", "Language", "Styles", "ScreenShots",
            "fonts_correct.ini", "hebrnew.ini", "shortnames.json",
        };

    // ── Умовчання програми («пакет») ────────────────────────────────────────

    /// Умовчання, що на Mac лежать у пакеті (`Contents/Resources/app`), у
    /// Windows-збірці вшиті в .exe (Slovo.csproj, EmbeddedResource). Щоб
    /// читачі, які чекають ФАЙЛ (ini, база SQLite), працювали так само, вони
    /// розпаковуються в службову теку поруч із тимчасовими файлами системи.
    /// Дім даних при цьому не засмічується.
    private static readonly string[] EmbeddedDefaults = ["Slovo.ini", "hotkeys.ini", "inconsistencies.sqlite3"];

    private static readonly object BundleLock = new();
    private static string? bundleFolder;

    /// Дані «в пакеті програми» — тека з розпакованими умовчаннями.
    public static string BundleData
    {
        get
        {
            lock (BundleLock)
            {
                if (bundleFolder != null && Directory.Exists(bundleFolder)) return bundleFolder;
                var version = typeof(DataHome).Assembly.GetName().Version?.ToString() ?? "0";
                var folder = Path.Combine(Path.GetTempPath(), "Slovo-" + version, "app");
                try
                {
                    Directory.CreateDirectory(folder);
                    foreach (var name in EmbeddedDefaults) Unpack(name, folder);
                }
                catch
                {
                    // Без умовчань програма живе значеннями, зашитими в код.
                }
                bundleFolder = folder;
                return folder;
            }
        }
    }

    private static void Unpack(string name, string folder)
    {
        using var stream = typeof(DataHome).Assembly.GetManifestResourceStream(name);
        if (stream == null) return;
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        var bytes = buffer.ToArray();
        var target = Path.Combine(folder, name);
        if (File.Exists(target) && File.ReadAllBytes(target).AsSpan().SequenceEqual(bytes)) return;
        SwiftPath.WriteAtomically(target, bytes);
    }

    /// Тека модулів, коли пакет своєї не має.
    public static string Modules => Path.Combine(Folder, "Modules");

    /// Куди відкладаються `.vbm`/`.vbi` після перетворення в `.songbook`.
    public const string ImportArchiveName = "Імпорт зі старої програми";

    /// Теки, в яких пісенники вже перетворювали, — щоб не робити цього
    /// вдруге, коли в теці навмисно лишили `.vbm`.
    public static string Ledger => Path.Combine(Folder, "перенесено.json");

    public static List<string> RecordedSources()
    {
        try
        {
            return SwiftJson.TryDecode<List<string>>(File.ReadAllBytes(Ledger)) ?? new List<string>();
        }
        catch
        {
            return new List<string>();
        }
    }

    public static void Record(string source)
    {
        var list = RecordedSources();
        var path = SwiftPath.Standardized(source);
        if (list.Contains(path)) return;
        list.Add(path);
        try
        {
            Directory.CreateDirectory(Folder);
            SwiftPath.WriteAtomically(Ledger, SwiftJson.EncodeBytes(list));
        }
        catch
        {
            // try? — журнал перенесення не привід падати.
        }
    }

    public sealed class Report
    {
        public string Source = "";
        public int Converted;
        public int Archived;
        public List<string> Errors = new();

        public Report(string source) => Source = source;

        public string Summary =>
            $"тека модулів «{Source}»: пісенників перетворено у .songbook: {Converted}, .vbm/.vbi відкладено: {Archived}"
            + (Errors.Count == 0 ? "" : "; помилки: " + string.Join("; ", Errors));
    }

    /// Перетворення одного `.vbm` у `.songbook` (шлях джерела, шлях результату) —
    /// як на Mac: `SongBookJSON.write(SongBook(fileAt:), to:)`. Порожній вимикач
    /// (null) — пісенники не перетворюються й не відкладаються зовсім: оригінал
    /// не має їхати в архів без копії.
    public static Action<string, string>? SongBookConversion { get; set; } =
        (source, destination) => SongBookJSON.Write(SongBook.FromFile(source), destination);

    /// Розширення свого пісенника (`SongBookJSON.pathExtension`).
    public const string SongBookExtension = SongBookJSON.PathExtension;

    /// Кожен `.vbm` у теці модулів → `.songbook`; оригінал разом із `.vbi`
    /// — в архів імпорту. Невдалий — лишається на місці й далі читається.
    public static void ConvertSongBooks(string modules, string archive, Report report)
    {
        var convert = SongBookConversion;
        if (convert == null) return;
        foreach (var url in SwiftPath.Contents(modules, skipsHidden: true))
        {
            if (!string.Equals(SwiftPath.Extension(url), "vbm", StringComparison.OrdinalIgnoreCase)) continue;
            var own = SwiftPath.DeletingExtension(url) + "." + SongBookExtension;
            if (!SwiftPath.Exists(own))
            {
                try
                {
                    convert(url, own);
                    report.Converted += 1;
                }
                catch (Exception error)
                {
                    report.Errors.Add($"{SwiftPath.LastComponent(url)}: {error.Message}");
                    continue;
                }
            }
            try { Directory.CreateDirectory(archive); } catch { }
            foreach (var companion in new[] { url, SwiftPath.DeletingExtension(url) + ".vbi" })
            {
                if (!SwiftPath.Exists(companion)) continue;
                var parked = Path.Combine(archive, SwiftPath.LastComponent(companion));
                if (SwiftPath.Exists(parked)) { try { File.Delete(parked); } catch { } }
                try
                {
                    File.Move(companion, parked);
                    if (string.Equals(SwiftPath.Extension(companion), "vbm", StringComparison.OrdinalIgnoreCase))
                        report.Archived += 1;
                }
                catch
                {
                    // try? — не відклали, то й не відклали.
                }
            }
        }
    }

    /// Полагодити модулі, що лягли ТЕКОЮ з іменем файла: «pv3055.songbook/»
    /// з файлом «pv3055.songbook» усередині (так ставила пісенники й модулі
    /// MySword програма 0.8 з архівів ресурсів 14.09). Повертає, скільки полагоджено.
    public static int RepairNestedModules(string modules)
    {
        var repaired = 0;
        foreach (var entry in SwiftPath.Contents(modules, skipsHidden: false))
        {
            var name = SwiftPath.LastComponent(entry);
            var lower = name.ToLowerInvariant();
            var suffixes = new[] { "songbook", "vbm", "sqlite3", "sqlite", "mybible" };
            if (!suffixes.Any(suffix => lower.EndsWith("." + suffix, StringComparison.Ordinal))
                || !Directory.Exists(entry)) continue;
            string[] files;
            try
            {
                files = Directory.EnumerateFiles(entry, "*", SearchOption.AllDirectories)
                    .Where(file => SwiftPath.LastComponent(file) != ".DS_Store").ToArray();
            }
            catch
            {
                continue;
            }
            var inner = files.FirstOrDefault(file => SwiftPath.LastComponent(file).ToLowerInvariant() == lower)
                        ?? (files.Length == 1 ? files[0] : null);
            if (inner == null) continue;
            var parked = Path.Combine(modules, ".slovo-repair-" + Guid.NewGuid().ToString().ToUpperInvariant());
            try
            {
                File.Move(inner, parked);
                Directory.Delete(entry, recursive: true);
                File.Move(parked, entry);
                repaired += 1;
            }
            catch
            {
                try { File.Delete(parked); } catch { }
            }
        }
        return repaired;
    }

    /// Перетворити пісенники в теці модулів — один раз на теку (за журналом).
    /// Повертає звіт, коли щось справді зробили.
    public static Report? ConvertSongBooksOnce(string modules)
    {
        // Перетворювач вимкнено — і теку не записуємо, щоб перетворення
        // відбулося, щойно його ввімкнуть.
        if (SongBookConversion == null) return null;
        if (RecordedSources().Contains(SwiftPath.Standardized(modules))) return null;
        var report = new Report(modules);
        ConvertSongBooks(modules, Path.Combine(SwiftPath.Parent(modules), ImportArchiveName), report);
        Record(modules);
        return report.Converted + report.Archived > 0 || report.Errors.Count > 0 ? report : null;
    }
}
