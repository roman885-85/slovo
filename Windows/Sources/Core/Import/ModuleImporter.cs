// =============================================================================
//  ModuleImporter.cs — майстер імпорту даних, розділ 4.2 посібника
//  (з Import/ModuleImporter.swift)
// =============================================================================
//  Платформне: `ditto` → System.IO.Compression (тека __MACOSX не розпаковується,
//  як і в ditto), `zipinfo -1` → перелік записів ZipArchive, `Compression` →
//  DeflateStream, URL → рядки-шляхи. Пошук установленої старої програми: на
//  Mac — пляшки CrossOver, /Applications, Application Support (як у Swift);
//  на Windows — ті самі теки «drive_c» без пляшки: Program Files, ProgramData,
//  AppData і Документи.
// =============================================================================

using System.Globalization;
using System.IO.Compression;

namespace Slovo.Core;

// Майстер імпорту — розділ 4.2 посібника, але лише в частині даних.
//
// В оригіналі майстер сам знаходив попередню версію старої програми і переносив
// модулі, шаблони, фони та налаштування. Тут джерелом служить будь-яка тека
// з даними або архів .zip — цим же закривається звичайне «додати модуль»:
// людина завантажила теку з bibleqt.ini чи .vbm, показала її майстру, і
// вона лягла в бібліотеку. Переносяться тільки дані: модулі й пісенники,
// шаблони слайда, фонові зображення. Налаштувань чужої програми майстер не
// переносить — у «Слова» свій файл налаштувань і свої відмінності, і чужий
// ini не має переробляти його під себе. Сам собою майстер не відкривається:
// його кличуть із меню.
//
// Розкладка — у термінах оригіналу, щоб вікно можна було звірити з
// посібником порядково: «Версія»/«Шлях» у списку версій, «Коротка
// назва»/«Повна назва» у списку модулів, «Немає»/«Застар.» у колонці стану.

// ── Куди переносимо ────────────────────────────────────────────────────────

/// Бібліотека самої програми: сюди майстер розкладає все, що переносить.
///
/// Окремий тип потрібен з однієї причини: писати в чужі дані не можна.
/// Робоча тека модулів може вказувати всередину `стара програма.app` або в
/// пляшку CrossOver — туди майстер не пише за жодних умов, інакше імпорт
/// зіпсує встановлений оригінал.
public readonly record struct ImportDestination(string DataRoot)
{
    /// Дім даних програми: перенесене лягає сюди, а бібліотека підхоплює його
    /// поіменно — через список модулів і список тек із фонами у «Параметрах».
    public static ImportDestination ApplicationLibrary => new(DataHome.Folder);

    public string ModulesFolder => Path.Combine(DataRoot, "Modules");
    public string TemplatesFolder => Path.Combine(DataRoot, "Templates");
    public string BackgroundsFolder => Path.Combine(DataRoot, "BackGrounds");
    public string PlansFolder => Path.Combine(DataRoot, "Plans");

    /// Дані встановленої старої програми чіпати на запис не можна: це чужа
    /// програма й чужа копія модулів.
    public bool IsSafeToWrite
    {
        get
        {
            // Розділювачі Windows — як на Mac, інакше перевірки нічого не впізнають.
            var path = DataRoot.Replace('\\', '/');
            if (path.Contains("/VisioBible.app/", StringComparison.Ordinal)) return false;
            if (path.Contains("/CrossOver/Bottles/", StringComparison.Ordinal)) return false;
            if (path.Contains("/drive_c/", StringComparison.Ordinal)) return false;
            // Всередину будь-якої обгортки застосунку, включно з власною: файли
            // там підписані, і підкладений модуль ламає підпис усієї програми.
            if (path.Contains(".app/Contents/", StringComparison.Ordinal)) return false;
            return true;
        }
    }

    /// Створюємо лише корінь. Підтеки заводить саме копіювання, коли в них
    /// справді щось лягає: порожня `Modules` — пастка, бо пошук теки модулів
    /// бере першу наявну.
    public void Prepare() => Directory.CreateDirectory(DataRoot);
}

// ── Звідки переносимо ──────────────────────────────────────────────────────

public enum ImportSourceKind
{
    /// Знайдена автоматично — встановлена копія програми.
    Installed,
    /// Тека, вибрана руками.
    Folder,
    /// Архів `.zip`, розпакований у тимчасову теку.
    Archive,
}

/// Рядок списку «Попередні версії програми» (4.2.1).
/// Колонки ті самі, що в автора: `LVVersions->Column0` «Версія»,
/// `LVVersions->Column1` «Шлях».
public sealed record ImportSource
{
    /// Колонка «Версія».
    public string Version { get; }
    /// Тека з даними: `Modules`, `Templates`, `BackGrounds`, `VisioBible.ini`.
    public string Url { get; }
    /// Що саме вибрав користувач. Для архіву це сам файл — його й треба
    /// показувати в колонці «Шлях», а не тимчасову теку.
    public string OriginUrl { get; }
    public ImportSourceKind Kind { get; }

    public string Id => OriginUrl;
    /// Колонка «Шлях».
    public string Path => OriginUrl;

    public ImportSource(string version, string url, string? originUrl, ImportSourceKind kind)
    {
        Version = version;
        Url = url;
        OriginUrl = originUrl ?? url;
        Kind = kind;
    }
}

/// Помилки майстра. Формулювання взято з `ErrorMessages0…3` форми
/// `ImportFromOldVersForm`, щоб людина, яка знає оригінал, побачила знайомий
/// текст.
public sealed class ImportProblem : Exception
{
    public enum Kind
    {
        /// `ErrorMessages0` — «в папке "%s" нет программы». Узагальнено: у теці
        /// взагалі немає нічого, що можна перенести.
        NothingToImport,
        /// `ErrorMessages1` — «В папке "%s" файл "VisioBible.ini" некорректен».
        BadConfig,
        /// `ErrorMessages2` — «Папка "%s" уже добавлена».
        AlreadyAdded,
        UnpackFailed,
        DestinationNotWritable,
    }

    public Kind ProblemKind { get; }
    /// Шлях, який підставляється на місце `%s`.
    public string Path { get; }
    public string Reason { get; }

    private ImportProblem(Kind kind, string path, string reason, string message) : base(message)
    {
        ProblemKind = kind;
        Path = path;
        Reason = reason;
    }

    public static ImportProblem NothingToImport(string path) =>
        new(Kind.NothingToImport, path, "", OurWords.T("В папке «%s» нет ничего, что можно импортировать", path));
    public static ImportProblem BadConfig(string path) =>
        new(Kind.BadConfig, path, "", $"В папке «{path}» файл «VisioBible.ini» некорректен");
    public static ImportProblem AlreadyAdded(string path) =>
        new(Kind.AlreadyAdded, path, "", OurWords.T("Папка «%s» уже добавлена", path));
    public static ImportProblem UnpackFailed(string path, string reason) =>
        new(Kind.UnpackFailed, path, reason, $"Не удалось распаковать «{path}»: {reason}");
    public static ImportProblem DestinationNotWritable(string path) =>
        new(Kind.DestinationNotWritable, path, "", OurWords.T("В папку «%s» писать нельзя: это данные установленной программы", path));

    /// Ключ повідомлення у формі `ImportFromOldVersForm` файла перекладу автора.
    /// У двох останніх випадків свого ключа в автора немає — їх в оригіналі
    /// не буває (майстер там не розпаковує архівів і завжди пише в теку
    /// самої програми).
    public string? MessageKey => ProblemKind switch
    {
        Kind.NothingToImport => "ErrorMessages0",
        Kind.BadConfig => "ErrorMessages1",
        Kind.AlreadyAdded => "ErrorMessages2",
        _ => null,
    };

    /// Текст мовою інтерфейсу.
    ///
    /// Раніше тут були свої російські рядки, і за будь-якої іншої мови
    /// майстер усе одно лаявся російською. Беремо формулювання автора і
    /// підставляємо шлях на місце `%s` — так само, як це робить Delphi.
    public string Localized(LanguageFile? language)
    {
        if (MessageKey is not { } key) return Message;
        var pattern = language?.Caption(key, "ImportFromOldVersForm", "") ?? "";
        return pattern.Length == 0 ? Message : Format(pattern, Path);
    }

    /// Підстановка `%s` (і Delphi-варіанта `%0:s`) плюс розгортка `\n`.
    internal static string Format(string pattern, string path)
    {
        var text = pattern;
        foreach (var placeholder in new[] { "%0:s", "%s" })
        {
            if (!text.Contains(placeholder, StringComparison.Ordinal)) continue;
            text = text.Replace(placeholder, path);
            break;
        }
        return text.Replace("\\n", "\n");
    }

    /// Будь-яка помилка майстра у вигляді тексту для людини: своя — словами
    /// автора, чужа (файлова система, розпакування) — як є.
    public static string Text(Exception error, LanguageFile? language) =>
        error is ImportProblem problem ? problem.Localized(language) : error.Message;

    public override string ToString() => Message;
}

// ── Що переносимо ──────────────────────────────────────────────────────────

public enum ImportCategory
{
    Module,        // тека «Цитата з Біблії» або файл MyBible
    SongBook,      // пісенник .vbm
    Template,      // шаблон слайда Templates/*.sch
    Image,         // фонове зображення
}

/// Стан того, що вже є в програмі. Підписи авторські:
/// `TextMessages4` «Нет» і `TextMessages2` «Устар.».
public enum ImportCondition
{
    Missing,       // у поточній версії цього немає
    Outdated,      // те, що є, старіше за джерело
    UpToDate,      // те саме або свіжіше
}

/// Рядок будь-якого зі списків майстра. Значення (як struct у Swift): галочку
/// міняють у копії й кладуть копію назад у список.
public record struct ImportItem
{
    public string Id;
    public ImportCategory Category;
    /// Колонка «Коротка назва».
    public string Title;
    /// Колонка «Повна назва».
    public string Subtitle;
    public string SourceUrl;
    public string DestinationUrl;
    /// Файли-супутники: `.vbi` поруч із `.vbm`, словники поруч із MyBible,
    /// тека шаблону поруч із `.sch`.
    public IReadOnlyList<string> Companions;
    public ImportCondition Condition;
    public long ByteSize;
    public DateTime? Modified;
    /// Чи позначено рядок. Автоматично позначаються відсутні й новіші
    /// — так написано в 4.2.2, 4.2.3 і 4.2.4.
    public bool IsSelected;

    public ImportItem(string id, ImportCategory category, string title, string subtitle, string sourceUrl,
                      string destinationUrl, IReadOnlyList<string>? companions, ImportCondition condition,
                      long byteSize = 0, DateTime? modified = null)
    {
        Id = id;
        Category = category;
        Title = title;
        Subtitle = subtitle;
        SourceUrl = sourceUrl;
        DestinationUrl = destinationUrl;
        Companions = companions ?? Array.Empty<string>();
        Condition = condition;
        ByteSize = byteSize;
        Modified = modified;
        // 4.2.2 і 4.2.3 кажуть «відсутні … або новіші», а 4.2.4 про
        // фони — лише «відсутні в поточній версії шляхи та/або
        // зображення». Різниця видна на справжніх даних: картинка, яка
        // в бібліотеці вже є, але на секунду старша за вихідну, потрапляла в
        // позначені й переносилася заново.
        IsSelected = category == ImportCategory.Image ? condition == ImportCondition.Missing : condition != ImportCondition.UpToDate;
    }
}

/// Усе, що знайшлося в джерелі, розкладене за сторінками майстра.
///
/// Опис збирає `ModuleImporter.Inventory`, але вікно майстра перезбирає його
/// зі своїх списків перед самим перенесенням: галочки живуть у них, і передати
/// треба саме те, що людина позначила.
public sealed class ImportInventory
{
    public ImportSource Source { get; }
    public List<ImportItem> Modules { get; set; }
    public List<ImportItem> Templates { get; set; }
    public List<ImportItem> Images { get; set; }

    public ImportInventory(ImportSource source, IEnumerable<ImportItem> modules, IEnumerable<ImportItem> templates, IEnumerable<ImportItem> images)
    {
        Source = source;
        Modules = modules.ToList();
        Templates = templates.ToList();
        Images = images.ToList();
    }

    public bool IsEmpty => Modules.Count == 0 && Templates.Count == 0 && Images.Count == 0;

    public List<ImportItem> Selected => Modules.Concat(Templates).Concat(Images).Where(item => item.IsSelected).ToList();

    public List<ImportItem> SelectedIn(ImportCategory category) => Selected.Where(item => item.Category == category).ToList();
}

/// Підсумок імпорту — те, що показується після натискання «Імпортувати».
public sealed class ImportOutcome
{
    public readonly record struct Failure(string Title, string Reason)
    {
        public string Id => Title + Reason;
    }

    public List<string> Modules { get; } = new();
    public List<string> Templates { get; } = new();
    public List<string> Images { get; } = new();
    public List<Failure> Failures { get; } = new();
    /// Куди лягли перенесені модулі й пісенники — щоб програма підключила
    /// їх до списку перекладів поіменно, не перемикаючи всієї бібліотеки.
    public List<string> ImportedModules { get; } = new();

    public int Total => Modules.Count + Templates.Count + Images.Count;
}

// ── Сам майстер ────────────────────────────────────────────────────────────

public static class ModuleImporter
{
    // ── 4.2.1 Пошук версій ──────────────────────────────────────────────────

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    private static IEnumerable<string> Names(string folder) => SwiftPath.Names(folder) ?? Array.Empty<string>();

    private static bool IsVisioBible(string name) => name.ToLowerInvariant().StartsWith("visiobible", StringComparison.Ordinal);

    /// Встановлені копії програми. Шукаємо там, де вони реально лежать: на
    /// Mac — у пляшці CrossOver, у теці застосунків і в підтримці застосунків;
    /// на Windows — у тих самих теках, що всередині пляшки (`drive_c`).
    public static List<ImportSource> InstalledVersions()
    {
        var candidates = new List<string>();
        if (OperatingSystem.IsWindows())
        {
            foreach (var parent in new[]
                     {
                         Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                         Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                         Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                         Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                         Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                         Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                     })
            {
                if (parent.Length == 0) continue;
                foreach (var entry in Names(parent))
                    if (IsVisioBible(entry)) candidates.Add(Path.Combine(parent, entry));
            }
        }
        else
        {
            // Пляшки CrossOver: і дані (ProgramData), і сама установка.
            var bottles = Path.Combine(Home, "Library/Application Support/CrossOver/Bottles");
            foreach (var bottle in Names(bottles))
            {
                var drive = Path.Combine(bottles, bottle, "drive_c");
                foreach (var parent in new[] { "ProgramData", "Program Files", "Program Files (x86)", "users/crossover/Documents" })
                {
                    var folder = Path.Combine(drive, parent);
                    foreach (var entry in Names(folder))
                        if (IsVisioBible(entry)) candidates.Add(Path.Combine(folder, entry));
                }
            }
            // Обгортка застосунку й особиста підтримка.
            foreach (var root in new[] { Path.Combine(Home, "Applications"), "/Applications" })
                foreach (var entry in Names(root))
                    if (IsVisioBible(entry)) candidates.Add(Path.Combine(root, entry, "Contents/Resources/app"));
            var support = Path.Combine(Home, "Library/Application Support");
            foreach (var entry in Names(support))
                if (IsVisioBible(entry)) candidates.Add(Path.Combine(support, entry));
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var found = new List<ImportSource>();
        foreach (var candidate in candidates)
        {
            var resolved = ResolvingSymlinks(candidate);
            if (!seen.Add(resolved) || !LooksLikeDataFolder(resolved)) continue;
            found.Add(new ImportSource(VersionName(resolved), resolved, null, ImportSourceKind.Installed));
        }
        return found.OrderBy(source => source.Version, SwiftText.StandardOrder).ToList();
    }

    /// Тека, вибрана руками («Вибрати теку з попередньою версією»).
    /// Приймаємо і теку з даними, і теку одного модуля, і теку, всередині
    /// якої лежать модулі без обгортки `Modules`.
    public static ImportSource SourceAtFolder(string url, IReadOnlyList<ImportSource>? existing = null)
    {
        var resolved = ResolvingSymlinks(url);
        if ((existing ?? Array.Empty<ImportSource>()).Any(source => source.Url == resolved || source.OriginUrl == resolved))
            throw ImportProblem.AlreadyAdded(resolved);
        if (!LooksLikeDataFolder(resolved, archives: true)) throw ImportProblem.NothingToImport(resolved);
        if (ConfigUrl(resolved) is { } config)
        {
            IniSettings? ini = null;
            try { ini = IniSettings.FromFile(config); } catch (Exception) { }
            if (ini == null || ini.Sections.Count == 0) throw ImportProblem.BadConfig(resolved);
        }
        return new ImportSource(VersionName(resolved), resolved, null, ImportSourceKind.Folder);
    }

    /// Архів `.zip`. Розпаковуємо в тимчасову теку і далі працюємо з нею
    /// як зі звичайною текою джерела.
    public static ImportSource SourceAtArchive(string url, IReadOnlyList<ImportSource>? existing = null)
    {
        if ((existing ?? Array.Empty<ImportSource>()).Any(source => source.OriginUrl == url))
            throw ImportProblem.AlreadyAdded(url);
        var unpacked = Unpack(url);
        // Архіви майже завжди обгорнуті в одну теку з ім'ям модуля —
        // розгортаємо її, інакше модуль ляже на рівень глибше, ніж треба.
        var root = DescendIntoSingleFolder(unpacked);
        if (!LooksLikeDataFolder(root)) throw ImportProblem.NothingToImport(url);
        return new ImportSource(SwiftPath.LastComponent(SwiftPath.DeletingExtension(url)), root, url, ImportSourceKind.Archive);
    }

    /// Те, що вибрали у вікні вибору: тека, архів `.zip` або один файл
    /// модуля. Розбір за тим, чим це виявилося насправді, а не за
    /// розширенням в імені: користувач тягне в майстер що завгодно.
    ///
    /// Одиночний файл (`.vbm`, `.SQLite3`) джерелом сам по собі бути не
    /// може — опис будується за текою. Беремо теку, де він лежить; сам файл
    /// у ній усе одно виявиться позначеним, а заразом підхопляться сусідні.
    public static ImportSource SourceAt(string url, IReadOnlyList<ImportSource>? existing = null)
    {
        if (Directory.Exists(url)) return SourceAtFolder(url, existing);
        if (SwiftPath.Extension(url).ToLowerInvariant() == "zip") return SourceAtArchive(url, existing);
        return SourceAtFolder(SwiftPath.Parent(url), existing);
    }

    /// «Знайти інші версії автоматично» — обхід дисків.
    ///
    /// Глибину обмежуємо: без неї обхід домашньої теки з чужими проєктами
    /// іде хвилинами, а дані програми ніколи не лежать на десятому рівні.
    /// `shouldStop` опитується на кожній теці — це кнопка «Зупинити».
    public static List<ImportSource> SearchAllDisks(Func<bool>? shouldStop = null, Action<string>? progress = null,
                                                    Action<ImportSource>? found = null)
    {
        shouldStop ??= () => false;
        var roots = new List<string> { Home };
        if (OperatingSystem.IsWindows())
        {
            foreach (var drive in DriveInfo.GetDrives())
                if (drive.DriveType is DriveType.Fixed or DriveType.Removable && drive.IsReady) roots.Add(drive.RootDirectory.FullName);
        }
        else
        {
            roots.Add("/Applications");
            foreach (var volume in Names("/Volumes")) roots.Add(Path.Combine("/Volumes", volume));
        }

        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<ImportSource>();
        foreach (var root in roots)
        {
            Walk(root, 0, 6, shouldStop, folder =>
            {
                progress?.Invoke(folder);
                if (!LooksLikeDataFolder(folder)) return false;
                var resolved = ResolvingSymlinks(folder);
                if (!seen.Add(resolved)) return true;
                var source = new ImportSource(VersionName(resolved), resolved, null, ImportSourceKind.Installed);
                result.Add(source);
                found?.Invoke(source);
                // Усередину знайденої теки з даними спускатися нема чого.
                return true;
            });
            if (shouldStop()) break;
        }
        return result;
    }

    // ── 4.2.2–4.2.4 Опис джерела ────────────────────────────────────────────

    /// Що можна перенести з джерела і в якому стані воно в нас.
    public static ImportInventory Inventory(ImportSource source, ImportDestination destination) =>
        new(source, ScanModules(source, destination), ScanTemplates(source, destination), ScanImages(source, destination));

    // ── 4.2.6 Імпорт ────────────────────────────────────────────────────────

    /// Перенесення позначеного. Кожен модуль перед копіюванням відкривається —
    /// до бібліотеки не має потрапити те, чого програма потім не прочитає.
    public static ImportOutcome Run(ImportInventory inventory, ImportDestination destination, Action<string, double>? progress = null)
    {
        var outcome = new ImportOutcome();

        if (!destination.IsSafeToWrite)
        {
            outcome.Failures.Add(new ImportOutcome.Failure(destination.DataRoot, ImportProblem.DestinationNotWritable(destination.DataRoot).Message));
            return outcome;
        }
        try { destination.Prepare(); }
        catch (Exception error)
        {
            outcome.Failures.Add(new ImportOutcome.Failure(destination.DataRoot, error.Message));
            return outcome;
        }

        var items = inventory.Selected;
        var total = Math.Max(items.Count, 1);

        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            progress?.Invoke(item.Title, (double)index / total);

            switch (item.Category)
            {
                case ImportCategory.Module:
                case ImportCategory.SongBook:
                    if (Validate(item) is { } reason)
                    {
                        outcome.Failures.Add(new ImportOutcome.Failure(item.Title, reason));
                        continue;
                    }
                    if (Copy(item) is { } failure) outcome.Failures.Add(new ImportOutcome.Failure(item.Title, failure));
                    else
                    {
                        outcome.Modules.Add(item.Title);
                        outcome.ImportedModules.Add(item.DestinationUrl);
                    }
                    break;
                case ImportCategory.Template:
                    if (Copy(item) is { } templateFailure) outcome.Failures.Add(new ImportOutcome.Failure(item.Title, templateFailure));
                    else outcome.Templates.Add(item.Title);
                    break;
                default:
                    if (Copy(item) is { } imageFailure) outcome.Failures.Add(new ImportOutcome.Failure(item.Title, imageFailure));
                    else outcome.Images.Add(item.Title);
                    break;
            }
        }

        progress?.Invoke("", 1);
        return outcome;
    }

    /// Перевірка, що модуль читається. Повертає причину відмови або `null`.
    ///
    /// Читаємо не лише заголовок: заголовок цілий і в модуля, у якого немає
    /// жодного файлу книги. Справжня перевірка — відкрити перший розділ.
    public static string? Validate(ImportItem item)
    {
        var url = item.SourceUrl;
        try
        {
            switch (item.Category)
            {
                case ImportCategory.SongBook:
                {
                    var book = SongBook.FromFile(url);
                    return book.Songs.Count == 0 ? OurWords.T("в песеннике нет ни одной песни") : null;
                }
                case ImportCategory.Module:
                {
                    TextModule module;
                    if (Directory.Exists(url)) module = new BibleModule(url);
                    else if (MySwordModule.IsBibleModuleName(SwiftPath.LastComponent(url))) module = new MySwordModule(url);
                    else module = new MyBibleModule(url);
                    if (module.Books.Count == 0) return OurWords.T("в модуле нет ни одной книги");
                    var first = module.Books[0];
                    var chapters = module.Chapters(first);
                    if (chapters.Count == 0 || chapters[0].Verses.Count == 0)
                        return $"первая глава книги «{first.FullName}» пуста";
                    module.ReleaseCache();
                    return null;
                }
                default:
                    return null;
            }
        }
        catch (Exception error)
        {
            return error.Message;
        }
    }

    // ── Опис за розділами ───────────────────────────────────────────────────

    private static List<ImportItem> ScanModules(ImportSource source, ImportDestination destination)
    {
        // Сама вибрана тека може бути одним модулем — так виглядає
        // завантажений окремо переклад і розпакований архів.
        if (ModuleItem(source.Url, destination) is { } single) return [single];

        var items = new List<ImportItem>();
        var folder = ModulesFolderIn(source.Url);
        foreach (var entry in SwiftPath.Contents(folder, skipsHidden: true).OrderBy(SwiftPath.LastComponent, SwiftText.StandardOrder))
        {
            if (ModuleItem(entry, destination) is { } item) items.Add(item);
            else if (SwiftPath.Extension(entry).ToLowerInvariant() == "zip") items.AddRange(ArchivedModuleItems(entry, destination));
        }
        return items;
    }

    /// Модулі з архівів `.zip`, що лежать у теці джерела.
    ///
    /// Так виглядає тека завантажень: модулі «Цитати з Біблії» з GitHub
    /// приходять архівами, і людина вибирає теку, де їх кілька. Раніше майстер
    /// показував лише розпаковані модулі, а архіви мовчки пропускав
    /// (0.84, перевірка скачаної збірки). Розпаковуємо лише ті архіви, у
    /// переліку файлів яких видно модуль, — тека завантажень повна чужих zip.
    private static List<ImportItem> ArchivedModuleItems(string zip, ImportDestination destination)
    {
        if (!ArchiveMentionsModule(zip)) return new List<ImportItem>();
        string unpacked;
        try { unpacked = UnpackedOnce(zip); }
        catch (Exception) { return new List<ImportItem>(); }
        var root = DescendIntoSingleFolder(unpacked);
        if (ModuleItem(root, destination) is { } single) return [single];
        var folder = ModulesFolderIn(root);
        return SwiftPath.Contents(folder, skipsHidden: true)
            .OrderBy(SwiftPath.LastComponent, SwiftText.StandardOrder)
            .Select(entry => ModuleItem(entry, destination))
            .Where(item => item != null).Select(item => item!.Value).ToList();
    }

    /// Чи згадано в переліку файлів архіву модуль або пісенник. Перелік
    /// читається без розпакування (на Mac — `zipinfo -1`).
    internal static bool ArchiveMentionsModule(string zip)
    {
        string[] marks = ["bibleqt.ini", ".vbm", "." + SongBookJSON.PathExtension, ".sqlite3", ".sqlite", ".bbl.mybible"];
        try
        {
            using var archive = ZipFile.OpenRead(zip);
            return archive.Entries.Any(entry =>
            {
                var line = entry.FullName.ToLowerInvariant();
                return marks.Any(mark => line.EndsWith(mark, StringComparison.Ordinal));
            });
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// Розпаковані архіви цього запуску: опис джерела будується не раз
    /// (відкрили майстер, повернулися «Назад»), а розпаковувати той самий
    /// архів щоразу в нову тимчасову теку ні до чого.
    private static readonly Dictionary<string, string> UnpackedArchives = new(StringComparer.Ordinal);
    private static readonly object UnpackedLock = new();

    private static string UnpackedOnce(string zip)
    {
        var key = zip + "|" + (ModificationDate(zip)?.Ticks ?? 0).ToString(CultureInfo.InvariantCulture);
        string? known;
        lock (UnpackedLock) UnpackedArchives.TryGetValue(key, out known);
        if (known != null && SwiftPath.Exists(known)) return known;
        var fresh = Unpack(zip);
        lock (UnpackedLock) UnpackedArchives[key] = fresh;
        return fresh;
    }

    /// Один рядок списку модулів — або `null`, якщо це не модуль.
    private static ImportItem? ModuleItem(string url, ImportDestination destination)
    {
        var name = SwiftPath.LastComponent(url);

        if (Directory.Exists(url))
        {
            if (IniUrl(url) is not { } ini) return null;
            // Читаємо лише шапку: повний розбір усіх книг у 96 модулів
            // займає секунди, а для списку потрібні дві назви.
            var header = ModuleHeader(ini);
            var target = Path.Combine(destination.ModulesFolder, name);
            return new ImportItem("module:" + name, ImportCategory.Module,
                                  header.Short.Length == 0 ? name : header.Short,
                                  header.Full.Length == 0 ? name : header.Full,
                                  url, target, null,
                                  Condition(ini, IniUrl(target) ?? target),
                                  FolderSize(url), ModificationDate(ini));
        }

        switch (SwiftPath.Extension(url).ToLowerInvariant())
        {
            case "vbm":
            {
                // Пісенник старої програми при імпорті перетворюється у свій формат:
                // лягає як `<ім'я>.songbook`; `.vbi` (покажчик старої програми) не
                // потрібен і не переноситься.
                var stem = SwiftPath.LastComponent(SwiftPath.DeletingExtension(url));
                var target = Path.Combine(destination.ModulesFolder, stem + "." + SongBookJSON.PathExtension);
                var header = SongBookHeader(url);
                return new ImportItem("song:" + name, ImportCategory.SongBook,
                                      header.Short.Length == 0 ? stem : header.Short,
                                      header.Full.Length == 0 ? name : header.Full,
                                      url, target, null, Condition(url, target), FileSize(url), ModificationDate(url));
            }
            case SongBookJSON.PathExtension:
            {
                var target = Path.Combine(destination.ModulesFolder, name);
                SongBook? parsed = null;
                try { parsed = SongBook.FromFile(url); } catch (Exception) { }
                var stem = SwiftPath.LastComponent(SwiftPath.DeletingExtension(url));
                return new ImportItem("song:" + name, ImportCategory.SongBook,
                                      parsed?.ShortName is { Length: > 0 } shortName ? shortName : stem,
                                      parsed?.Title is { Length: > 0 } title ? title : name,
                                      url, target, null, Condition(url, target), FileSize(url), ModificationDate(url));
            }
            case "sqlite3":
            case "sqlite":
            {
                var stem = SwiftPath.LastComponent(SwiftPath.DeletingExtension(url)).ToLowerInvariant();
                // Супутники MyBible віршів не містять — окремим рядком вони не
                // потрібні, але переїхати разом із модулем мають.
                string[] companionKinds = ["commentaries", "dictionary", "crossreferences", "subheadings", "plan", "notes"];
                if (companionKinds.Any(kind => stem.EndsWith("." + kind, StringComparison.Ordinal))) return null;
                var target = Path.Combine(destination.ModulesFolder, name);
                var siblings = SwiftPath.Contents(SwiftPath.Parent(url), skipsHidden: false);
                var companions = siblings.Where(candidate =>
                {
                    var other = SwiftPath.LastComponent(SwiftPath.DeletingExtension(candidate)).ToLowerInvariant();
                    return other != stem && companionKinds.Any(kind => other == $"{stem}.{kind}");
                }).ToList();
                var header = MyBibleHeader(url);
                return new ImportItem("mybible:" + name, ImportCategory.Module,
                                      header.Short.Length == 0 ? SwiftPath.LastComponent(SwiftPath.DeletingExtension(url)) : header.Short,
                                      header.Full.Length == 0 ? name : header.Full,
                                      url, target, companions, Condition(url, target), FileSize(url), ModificationDate(url));
            }
            case "mybible":
            {
                // Тип модуля MySword стоїть розширенням ПЕРЕД `.mybible`. Вірші
                // є лише в `.bbl`; коментарі, словники, щоденники й особисті
                // нотатки окремим рядком не потрібні — переносити нічого.
                if (!MySwordModule.IsBibleModuleName(name)) return null;
                var target = Path.Combine(destination.ModulesFolder, name);
                var header = MySwordHeader(url);
                var stem = SwiftPath.LastComponent(SwiftPath.DeletingExtension(SwiftPath.DeletingExtension(url)));
                return new ImportItem("mysword:" + name, ImportCategory.Module,
                                      header.Short.Length == 0 ? stem : header.Short,
                                      header.Full.Length == 0 ? name : header.Full,
                                      url, target, null, Condition(url, target), FileSize(url), ModificationDate(url));
            }
            default:
                return null;
        }
    }

    private static List<ImportItem> ScanTemplates(ImportSource source, ImportDestination destination)
    {
        var folder = Path.Combine(source.Url, "Templates");
        return SwiftPath.Contents(folder, skipsHidden: false)
            .Where(file => SwiftPath.Extension(file).ToLowerInvariant() == "sch")
            .OrderBy(SwiftPath.LastComponent, SwiftText.StandardOrder)
            .Select(file =>
            {
                var name = SwiftPath.LastComponent(SwiftPath.DeletingExtension(file));
                // Поруч із `<Ім'я>.sch` лежить однойменна тека з картинками —
                // без неї шаблон приїде порожнім.
                var assets = Path.Combine(folder, name);
                var target = Path.Combine(destination.TemplatesFolder, SwiftPath.LastComponent(file));
                return new ImportItem("template:" + name, ImportCategory.Template, name, SchemeDescription(file),
                                      file, target, SwiftPath.Exists(assets) ? [assets] : null,
                                      Condition(file, target), FileSize(file) + FolderSize(assets), ModificationDate(file));
            })
            .ToList();
    }

    /// 4.2.4: фонові зображення з тек джерела (`TextMessages7` «Файл»);
    /// шляхи самі по собі не переносяться — їх заводить програма.
    private static List<ImportItem> ScanImages(ImportSource source, ImportDestination destination)
    {
        var items = new List<ImportItem>();
        var folders = new List<(string Raw, string? Url)>();

        // Шляхи з [PicturePath] вихідного ini.
        if (ConfigUrl(source.Url) is { } config)
        {
            IniSettings? ini = null;
            try { ini = IniSettings.FromFile(config); } catch (Exception) { }
            if (ini != null)
            {
                var section = ini.Sections.TryGetValue("PicturePath", out var found) ? found : new Dictionary<string, string>();
                foreach (var key in section.Keys.OrderBy(key => SwiftText.ParseInt(key) ?? 0))
                {
                    if (PicturePathEntry.FromRawValue(section[key]) is not { } entry) continue;
                    folders.Add((entry.Path, ResolveWindowsPath(entry.Path, source.Url)));
                }
            }
        }
        // Тека BackGrounds є навіть там, де ini немає.
        var backgrounds = Path.Combine(source.Url, "BackGrounds");
        if (SwiftPath.Exists(backgrounds) && !folders.Any(folder => folder.Url == backgrounds))
            folders.Add(("BackGrounds\\", backgrounds));

        var allowed = new HashSet<string>(StringComparer.Ordinal) { "jpg", "jpeg", "png", "bmp", "gif", "tif", "tiff", "heic", "webp" };
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var folder in folders)
        {
            if (folder.Url is not { } url) continue;
            foreach (var file in SwiftPath.Contents(url, skipsHidden: true).OrderBy(SwiftPath.LastComponent, SwiftText.StandardOrder))
            {
                var name = SwiftPath.LastComponent(file);
                if (!allowed.Contains(SwiftPath.Extension(file).ToLowerInvariant()) || !seen.Add(name.ToLowerInvariant())) continue;
                var target = Path.Combine(destination.BackgroundsFolder, name);
                items.Add(new ImportItem("image:" + name, ImportCategory.Image, name, folder.Raw, file, target, null,
                                         Condition(file, target), FileSize(file), ModificationDate(file)));
            }
        }
        return items;
    }

    // ── Копіювання ──────────────────────────────────────────────────────────

    /// Копіювання із заміною. Спершу в тимчасове ім'я поруч, потім підміна —
    /// інакше перерваний імпорт лишить на місці робочого модуля половину.
    private static string? Copy(ImportItem item)
    {
        try
        {
            Directory.CreateDirectory(SwiftPath.Parent(item.DestinationUrl));
            if (item.Category == ImportCategory.SongBook && SwiftPath.Extension(item.SourceUrl).ToLowerInvariant() == "vbm")
            {
                ConvertSongBook(item.SourceUrl, item.DestinationUrl);
                return null;
            }
            Replace(item.SourceUrl, item.DestinationUrl);

            foreach (var companion in item.Companions)
                Replace(companion, Path.Combine(SwiftPath.Parent(item.DestinationUrl), SwiftPath.LastComponent(companion)));
            return null;
        }
        catch (Exception error)
        {
            return error.Message;
        }
    }

    /// Пісенник старої програми → свій формат: розібрати `.vbm` і записати
    /// `.songbook`. Відкрито — щоб перевірка йшла тим самим шляхом, що й
    /// майстер.
    public static void ConvertSongBook(string source, string destination)
    {
        var book = SongBook.FromFile(source);
        Directory.CreateDirectory(SwiftPath.Parent(destination));
        SongBookJSON.Write(book, destination);
    }

    private static void Replace(string source, string destination)
    {
        if (!SwiftPath.Exists(source)) return;
        // Шлях до самого себе — джерело вже лежить там, куди його переносять.
        if (ResolvingSymlinks(source) == ResolvingSymlinks(destination)) return;

        var staging = Path.Combine(SwiftPath.Parent(destination), ".slovo-import-" + Guid.NewGuid().ToString().ToUpperInvariant());
        CopyItem(source, staging);
        if (SwiftPath.Exists(destination))
        {
            try { RemoveItem(destination); } catch { }
        }
        try
        {
            if (Directory.Exists(staging)) Directory.Move(staging, destination);
            else File.Move(staging, destination);
        }
        catch
        {
            try { RemoveItem(staging); } catch { }
            throw;
        }
    }

    /// `copyItem(at:to:)` — файл або тека з усім вмістом.
    private static void CopyItem(string source, string destination)
    {
        if (!Directory.Exists(source))
        {
            File.Copy(source, destination);
            return;
        }
        Directory.CreateDirectory(destination);
        foreach (var entry in Directory.EnumerateFileSystemEntries(source))
            CopyItem(entry, Path.Combine(destination, SwiftPath.LastComponent(entry)));
    }

    private static void RemoveItem(string path)
    {
        if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
        else File.Delete(path);
    }

    // ── Дрібниці ────────────────────────────────────────────────────────────

    /// Чи схоже на теку з даними: є модулі, шаблони, фони або ini.
    /// `archives` — зважати й на архіви `.zip` із модулями. Лише для теки,
    /// вибраної руками: обхід дисків відкривав би кожен zip у домашній теці.
    public static bool LooksLikeDataFolder(string url, bool archives = false)
    {
        if (!Directory.Exists(url)) return false;
        if (IniUrl(url) != null) return true;
        foreach (var name in new[] { "Modules", "Templates", "BackGrounds", "VisioBible.ini", "VisioBible.exe" })
            if (SwiftPath.Exists(Path.Combine(url, name))) return true;
        // Гола тека з модулями чи пісенниками — теж джерело.
        var entries = SwiftPath.Contents(url, skipsHidden: true);
        // `.songbook` — свій формат пісенника: тека лише з ними раніше
        // відкидалася як «нічого імпортувати».
        string[] fileKinds = ["vbm", SongBookJSON.PathExtension, "sqlite3", "sqlite", "mybible"];
        if (entries.Any(entry => fileKinds.Contains(SwiftPath.Extension(entry).ToLowerInvariant()) || IniUrl(entry) != null))
            return true;
        if (!archives) return false;
        return entries.Any(entry => SwiftPath.Extension(entry).ToLowerInvariant() == "zip" && ArchiveMentionsModule(entry));
    }

    /// Ім'я версії для колонки «Версія»: з ini, інакше з імені теки.
    private static string VersionName(string url)
    {
        var name = SwiftPath.LastComponent(url);
        // В обгортки застосунку ім'я даних беззмістовне — беремо ім'я програми.
        if (name is "app" or "Resources" or "Contents")
            name = SwiftPath.LastComponent(SwiftPath.DeletingExtension(SwiftPath.Parent(SwiftPath.Parent(SwiftPath.Parent(url)))));
        if (ConfigUrl(url) is { } config)
        {
            IniSettings? ini = null;
            try { ini = IniSettings.FromFile(config); } catch (Exception) { }
            if (ini != null && (ini.String("Version", "settings") ?? ini.String("ProgramVersion", "settings")) is { } version)
                return $"{name} {version}";
        }
        return name;
    }

    private static string? ConfigUrl(string root)
    {
        var url = Path.Combine(root, "VisioBible.ini");
        return SwiftPath.Exists(url) ? url : null;
    }

    private static string ModulesFolderIn(string root)
    {
        var nested = Path.Combine(root, "Modules");
        return SwiftPath.Exists(nested) ? nested : root;
    }

    private static string? IniUrl(string directory)
    {
        var name = SwiftPath.Names(directory)?.FirstOrDefault(entry => entry.ToLowerInvariant() == "bibleqt.ini");
        return name == null ? null : Path.Combine(directory, name);
    }

    /// Дві назви модуля без розбору всіх книг.
    private static (string Short, string Full) ModuleHeader(string ini)
    {
        byte[] data;
        try { data = File.ReadAllBytes(ini); }
        catch (Exception) { return ("", ""); }
        // Вистачає перших кілобайтів: BibleName і BibleShortName стоять у шапці,
        // а далі йдуть сотні рядків зі списком книг.
        var head = data.Length > 4096 ? data[..4096] : data;
        var text = CodePage.Decode(head, CodePage.TryDecode(head, CodePage.Utf8) != null ? CodePage.Utf8 : null);
        string shortName = "", full = "";
        foreach (var line in text.SplitLines())
        {
            var eq = line.IndexOf('=');
            if (eq < 0) continue;
            var key = line[..eq].TrimWhitespaces().ToLowerInvariant();
            var value = line[(eq + 1)..].TrimWhitespaces();
            if (key == "bibleshortname") shortName = value;
            if (key == "biblename") full = value;
        }
        return (shortName, full);
    }

    /// Дві назви пісенника без розбору самих пісень.
    ///
    /// Повний `SongBook.FromFile` по 23 збірниках із теки оригіналу працює
    /// понад шість секунд: у «Піснях Відродження» три тисячі пісень, і всі вони
    /// розбираються заради двох рядків у колонках списку. Тут розпаковується
    /// лише початок потоку, а з нього читаються п'ять перших рядків і число пісень.
    private static (string Short, string Full) SongBookHeader(string url)
    {
        if (SongBookHead(url) is not { } head) return ("", "");
        var reader = new HeadReader(head);
        var title = reader.String();
        var shortName = reader.String();
        _ = reader.String();          // видавець
        _ = reader.String();          // дата правки
        _ = reader.String();          // примітка
        var count = (long)reader.UInt32();

        if (title.Length == 0 && shortName.Length == 0) return ("", "");
        // Числу пісень довіряємо лише правдоподібному: якщо початок потоку
        // прочитався не так, краще показати одну назву, ніж «пісень 4 млрд».
        var sane = count > 0 && count < 100_000;
        var full = title.Length == 0 ? SwiftPath.LastComponent(url) : title;
        return (shortName, sane ? $"{full} — песен {count}" : full);
    }

    /// Початок розпакованого потоку пісенника (не більше 16 КБ).
    private static byte[]? SongBookHead(string url)
    {
        byte[] data;
        try { data = File.ReadAllBytes(url); }
        catch (Exception) { return null; }
        if (data.Length <= 24 || !data.AsSpan(0, 16).SequenceEqual("VisioBibleModule"u8)) return null;

        // Розкладка шапки та сама, що читає `SongBook`: за зсувом 20 —
        // довжина стиснутого блоку, сам блок лежить у хвості перед контрольною
        // сумою і починається двома байтами заголовка zlib.
        var compressedSize = (long)BitConverter.ToUInt32(data, 20);
        var start = data.Length - 4 - compressedSize;
        if (start <= 16 || start >= data.Length) return null;
        var offset = (int)start + 2;
        if (offset > data.Length) return null;

        const int capacity = 1 << 14;
        try
        {
            using var input = new MemoryStream(data, offset, data.Length - offset, writable: false);
            using var inflater = new DeflateStream(input, CompressionMode.Decompress);
            var buffer = new byte[capacity];
            var total = 0;
            int read;
            // Обрізаний вивід тут не біда — шапка вкладається в перші
            // сотні байтів, а хвіст потоку нам і не потрібен.
            while (total < capacity && (read = inflater.Read(buffer, total, capacity - total)) > 0) total += read;
            return total > 0 ? buffer[..total] : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// Читання шапки пісенника: рядки в UTF-16LE із довжиною в UInt16 попереду.
    private sealed class HeadReader(byte[] bytes)
    {
        private int offset;

        public uint UInt32()
        {
            if (offset + 4 > bytes.Length)
            {
                offset = bytes.Length;
                return 0;
            }
            var value = (uint)(bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16 | bytes[offset + 3] << 24);
            offset += 4;
            return value;
        }

        public string String()
        {
            if (offset + 2 > bytes.Length)
            {
                offset = bytes.Length;
                return "";
            }
            var characters = bytes[offset] | bytes[offset + 1] << 8;
            offset += 2;
            var length = characters * 2;
            if (characters <= 0 || offset + length > bytes.Length)
            {
                offset = Math.Min(offset + Math.Max(0, length), bytes.Length);
                return "";
            }
            var text = System.Text.Encoding.Unicode.GetString(bytes, offset, length);
            offset += length;
            return text;
        }
    }

    private static (string Short, string Full) MyBibleHeader(string url)
    {
        try
        {
            var module = new MyBibleModule(url);
            try { return (module.Info.ShortName, module.Info.Name); }
            finally { module.ReleaseCache(); }
        }
        catch (Exception)
        {
            return ("", "");
        }
    }

    private static (string Short, string Full) MySwordHeader(string url)
    {
        try
        {
            var module = new MySwordModule(url);
            try { return (module.Info.ShortName, module.Info.Name); }
            finally { module.ReleaseCache(); }
        }
        catch (Exception)
        {
            return ("", "");
        }
    }

    /// Короткий опис шаблону для колонки «Повна назва».
    private static string SchemeDescription(string file)
    {
        try
        {
            var scheme = SchemeParser.Scheme(file);
            return OurWords.T("объектов %s", scheme.Elements.Count.ToString(CultureInfo.InvariantCulture));
        }
        catch (Exception)
        {
            return SwiftPath.LastComponent(file);
        }
    }

    private static ImportCondition Condition(string source, string destination)
    {
        if (!SwiftPath.Exists(destination)) return ImportCondition.Missing;
        if (ModificationDate(source) is not { } left || ModificationDate(destination) is not { } right) return ImportCondition.UpToDate;
        // Секунда допуску: копіювання не зберігає часу з точністю до
        // мікросекунд, і без допуску все виглядає «новішим».
        return (left - right).TotalSeconds > 1 ? ImportCondition.Outdated : ImportCondition.UpToDate;
    }

    private static DateTime? ModificationDate(string url)
    {
        try
        {
            if (Directory.Exists(url)) return Directory.GetLastWriteTimeUtc(url);
            if (File.Exists(url)) return File.GetLastWriteTimeUtc(url);
            return null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static long FileSize(string url)
    {
        try { return File.Exists(url) ? new FileInfo(url).Length : 0; }
        catch (Exception) { return 0; }
    }

    private static long FolderSize(string url)
    {
        if (!Directory.Exists(url)) return 0;
        long total = 0;
        try
        {
            foreach (var file in Directory.EnumerateFiles(url, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = 0, IgnoreInaccessible = true }))
                total += FileSize(file);
        }
        catch (Exception) { }
        return total;
    }

    /// Шлях з ini у наш: `BackGrounds\` поруч із джерелом, `Z:\…` — на Mac
    /// корінь диска під CrossOver (на Windows — сам цей шлях), усе інше —
    /// як є, якщо таке є на диску.
    private static string? ResolveWindowsPath(string raw, string root)
    {
        var cleaned = raw.Replace('\\', '/');
        if (SwiftText.CharacterCount(cleaned) > 2 && SwiftText.DropFirstCharacters(cleaned, 1).StartsWith(":/", StringComparison.Ordinal))
        {
            var tail = SwiftText.DropFirstCharacters(cleaned, 3);
            var candidates = OperatingSystem.IsWindows()
                ? new[] { cleaned, Path.Combine(Home, tail) }
                : new[] { "/" + tail, Path.Combine(Home, tail) };
            return candidates.FirstOrDefault(SwiftPath.Exists);
        }
        var url = cleaned.StartsWith('/') ? cleaned : SwiftPath.Append(root, cleaned);
        return SwiftPath.Exists(url) ? url.TrimEnd('/') : null;
    }

    /// Обхід дерева з обмеженням глибини і правом зупинитися.
    /// `visit` повертає `true`, якщо всередину цієї теки заходити не треба.
    private static void Walk(string url, int depth, int limit, Func<bool> shouldStop, Func<string, bool> visit)
    {
        if (shouldStop() || depth > limit) return;
        if (depth > 0 && visit(url)) return;

        var skipped = new HashSet<string>(StringComparer.Ordinal)
        {
            "Library", "node_modules", ".git", ".build", "System", "Photos Library.photoslibrary", "Music", "Pictures",
        };
        foreach (var entry in SwiftPath.Contents(url, skipsHidden: true))
        {
            if (shouldStop()) return;
            if (!Directory.Exists(entry)) continue;
            // Обгортки застосунків пропускаємо як теки, але всередину пакета .app
            // зазирнути треба — там і лежать його дані.
            var name = SwiftPath.LastComponent(entry);
            if (SwiftPath.Extension(entry) == "app" && !IsVisioBible(name)) continue;
            if (depth == 0 && skipped.Contains(name) && !IsVisioBible(name))
            {
                // Домашня Library — єдиний виняток: там пляшки.
                if (name == "Library")
                    Walk(Path.Combine(entry, "Application Support"), depth + 1, limit, shouldStop, visit);
                continue;
            }
            Walk(entry, depth + 1, limit, shouldStop, visit);
        }
    }

    // ── Архів ───────────────────────────────────────────────────────────────

    private static string Unpack(string archive)
    {
        // Усередині тимчасової теки — тека з ім'ям архіву: архів без обгортки
        // (bibleqt.ini одразу в корені) інакше ліг би модулем з ім'ям
        // «slovo-import-<UUID>».
        var target = Path.Combine(Path.GetTempPath(), "slovo-import-" + Guid.NewGuid().ToString().ToUpperInvariant(),
                                  SwiftPath.LastComponent(SwiftPath.DeletingExtension(archive)));
        Directory.CreateDirectory(target);
        try
        {
            ResourceHub.Unzip(archive, target);
        }
        catch (Exception error)
        {
            throw ImportProblem.UnpackFailed(SwiftPath.LastComponent(archive), error.Message);
        }
        return target;
    }

    /// Архів майже завжди обгорнутий в одну теку — спускаємося всередину, поки
    /// вкладення єдине і саме не є модулем.
    private static string DescendIntoSingleFolder(string url)
    {
        var current = url;
        for (var step = 0; step < 4; step++)
        {
            if (IniUrl(current) != null) return current;
            var entries = SwiftPath.Contents(current, skipsHidden: true).Where(entry => SwiftPath.LastComponent(entry) != "__MACOSX").ToList();
            if (entries.Count != 1 || !Directory.Exists(entries[0])) return current;
            current = entries[0];
        }
        return current;
    }

    /// `resolvingSymlinksInPath()`: посилання в шляху розгортаються; на Mac
    /// початкове «/private» знімається, якщо без нього шлях теж є (як у Foundation).
    internal static string ResolvingSymlinks(string path)
    {
        string full;
        try { full = Path.GetFullPath(path); }
        catch (Exception) { return path; }
        if (full.Length > 1) full = full.TrimEnd(Path.DirectorySeparatorChar);
        try
        {
            var root = Path.GetPathRoot(full) ?? "";
            var resolved = root;
            foreach (var part in full[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            {
                var next = Path.Combine(resolved, part);
                FileSystemInfo info = Directory.Exists(next) ? new DirectoryInfo(next) : new FileInfo(next);
                if (info.Exists && info.LinkTarget != null && info.ResolveLinkTarget(returnFinalTarget: true) is { } target)
                    next = target.FullName.TrimEnd(Path.DirectorySeparatorChar);
                resolved = next;
            }
            full = resolved;
        }
        catch (Exception) { }
        if (!OperatingSystem.IsWindows() && full.StartsWith("/private/", StringComparison.Ordinal) && SwiftPath.Exists(full["/private".Length..]))
            full = full["/private".Length..];
        return full;
    }
}
