// =============================================================================
//  ResourceHub.cs — завантаження ресурсів і розкладання на місце
//  (з Resources/ResourceHub.swift)
// =============================================================================
//  URLSession → HttpClient; `ditto -x -k` → System.IO.Compression (тека
//  `__MACOSX` пропускається — ditto теж її не розпаковує). Посилання `file://`
//  працюють так само, як на Mac: ресурс копіюється з теки.
// =============================================================================

using System.IO.Compression;
using System.Net;
using System.Text;

namespace Slovo.Core;

/// Завантаження ресурсів із мережі й розкладання їх на місце.
///
/// Каталог — свій (`slovo-resources`) або «Цитата з Біблії»; кожен ресурс
/// — zip, який розпаковується в теку модулів (переклад чи пісенник) або
/// в корінь даних (фони, шаблони, шрифти, сторінки). Після кожного — запис у
/// журнал `resources.json` з версією з каталогу: за нею потім видно
/// оновлення. Усе тут без головного потоку: викликається з фону, хід
/// повідомляється замиканням.
public sealed class ResourceHub
{
    public static readonly Uri OwnCatalogURL = new("https://raw.githubusercontent.com/roman885-85/slovo-resources/main/catalog.json");
    public const string BibleQuoteBase = "https://raw.githubusercontent.com/BibleQuote/BibleQuote-Modules/master/";

    public enum Source { Slovo, BibleQuote, MyBible, EBible, SoftProjector }

    public static readonly Uri MyBibleRegistryURL = new("https://mybible.zone/repository/registry/registry.zip");
    /// Перелік перекладів eBible.org (понад півтори тисячі, вільні ліцензії).
    public static readonly Uri EBibleCatalogURL = new("https://ebible.org/Scriptures/translations.csv");
    /// Сторінка пісенників SoftProjector.
    public static readonly Uri SoftProjectorPageURL = new("https://softprojector.org/download_mod_songbooks.html");
    public const string SoftProjectorBase = "https://softprojector.org/";

    public ResourceLayout Layout { get; }

    /// Ефемерний сеанс, як на Mac: 30 секунд на з'єднання, година на файл.
    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var handler = new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(30),
            AllowAutoRedirect = true,
            UseCookies = false,
            AutomaticDecompression = DecompressionMethods.All,
        };
        var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(3600) };
        // Версія — з самої програми, щоб не застарівала разом із жорстким числом.
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Slovo/" + (typeof(ResourceHub).Assembly.GetName().Version?.ToString(3) ?? "1.0"));
        return client;
    }

    public ResourceHub(ResourceLayout layout) => Layout = layout;

    // ── Каталог ─────────────────────────────────────────────────────────────

    public static Uri CatalogURL(Source source) => source switch
    {
        Source.Slovo => OwnCatalogURL,
        Source.BibleQuote => new Uri(BibleQuoteBase + "modules.ini"),
        Source.MyBible => MyBibleRegistryURL,
        Source.EBible => EBibleCatalogURL,
        _ => SoftProjectorPageURL,
    };

    /// Каталог джерела — з мережі. Помилка — `ResourceError` з причиною, як
    /// просив власник бачити причини, а не «не вдалося».
    public async Task<ResourceCatalog> FetchCatalogAsync(Source source)
    {
        var url = CatalogURL(source);
        var (data, status) = await Get(url).ConfigureAwait(false);
        if (status != 200) throw ResourceError.Network(OurWords.T("сервер ответил %s", status.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        switch (source)
        {
            case Source.Slovo:
                try { return ResourceCatalog.Decode(data); }
                catch (Exception) { throw ResourceError.BadCatalog(); }
            case Source.BibleQuote:
                return ResourceCatalog.BibleQuote(Text(data), BibleQuoteBase);
            case Source.MyBible:
            {
                // Реєстр — zip з одним registry.json.
                if (UnzipFirst(data, "registry.json") is not { } json || ResourceCatalog.MyBible(json) is not { } catalog)
                    throw ResourceError.BadCatalog();
                return catalog;
            }
            case Source.EBible:
            {
                var catalog = ResourceCatalog.EBible(Text(data));
                return catalog.Items.Count == 0 ? throw ResourceError.BadCatalog() : catalog;
            }
            default:
            {
                var catalog = ResourceCatalog.SoftProjector(Text(data), SoftProjectorBase);
                return catalog.Items.Count == 0 ? throw ResourceError.BadCatalog() : catalog;
            }
        }
    }

    /// Те саме із замиканням (`fetchCatalog(_:completion:)`): відповідь приходить у фоні.
    public void FetchCatalog(Source source, Action<ResourceCatalog?, ResourceError?> completion)
    {
        Task.Run(async () =>
        {
            try { completion(await FetchCatalogAsync(source).ConfigureAwait(false), null); }
            catch (ResourceError error) { completion(null, error); }
            catch (Exception error) { completion(null, ResourceError.Network(error.Message)); }
        });
    }

    /// `String(data:encoding:.utf8) ?? String(decoding:as:UTF8.self)`.
    private static string Text(byte[] data) => CodePage.TryDecode(data, CodePage.Utf8) ?? Encoding.UTF8.GetString(data);

    /// Відповідь цілком і код стану. Файл із диска (`file://`) — це теж успіх, 200.
    private static async Task<(byte[] Data, int Status)> Get(Uri url)
    {
        try
        {
            if (url.IsFile) return (await File.ReadAllBytesAsync(url.LocalPath).ConfigureAwait(false), 200);
            using var response = await Http.GetAsync(url, HttpCompletionOption.ResponseContentRead).ConfigureAwait(false);
            return (await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false), (int)response.StatusCode);
        }
        catch (Exception error)
        {
            throw ResourceError.Network(error.Message);
        }
    }

    /// Що в розпакованому архіві є самим ресурсом.
    public enum PayloadKind
    {
        /// Файл чи тека — лягає на місце цілком під іменем ресурсу.
        Item,
        /// Файли модуля без теки — лягають у теку з іменем ресурсу.
        Files,
    }

    public readonly record struct Payload(PayloadKind Kind, string Path);

    /// Розширення, за якими ресурс — один ФАЙЛ, а не тека.
    public static readonly IReadOnlyList<string> FileExtensions = ["songbook", "vbm", "sqlite3", "sqlite", "mybible"];

    private static readonly HashSet<string> Skip = new(StringComparer.Ordinal) { "__MACOSX", ".DS_Store" };

    /// Знайти ресурс у розпакованому (`payload(in:for:)`), хоч би як його
    /// запакували: з теками-обгортками чи без, файл під своїм ім'ям чи
    /// безіменний «.SQLite3» MyBible, модуль «Цитати з Біблії» текою чи самими файлами.
    public static Payload? PayloadIn(string staging, ResourceItem item)
    {
        var all = EBibleVPL.EnumerateAll(staging)
            .Where(path => !Path.GetRelativePath(staging, path).Split(Path.DirectorySeparatorChar).Any(Skip.Contains))
            .ToList();
        var wanted = item.FileName.ToLowerInvariant();
        var extension = FileExtensions.FirstOrDefault(ext => wanted.EndsWith("." + ext, StringComparison.Ordinal));
        if (extension != null)
        {
            var files = all.Where(path => !Directory.Exists(path)).ToList();
            if (files.FirstOrDefault(path => SwiftPath.LastComponent(path).ToLowerInvariant() == wanted) is { } exact)
                return new Payload(PayloadKind.Item, exact);
            var sameKind = files.Where(path =>
            {
                var name = SwiftPath.LastComponent(path).ToLowerInvariant();
                return name.EndsWith("." + extension, StringComparison.Ordinal) || name == "." + extension;
            }).ToList();
            // «UKJV.bbl.mybible» — теж «.mybible»: беремо, лише коли такий один.
            return sameKind.Count == 1 ? new Payload(PayloadKind.Item, sameKind[0]) : null;
        }
        // Тека модуля «Цитата з Біблії»: там, де лежить bibleqt.ini, — найближча до верху.
        var inis = all.Where(path => SwiftPath.LastComponent(path).ToLowerInvariant() == "bibleqt.ini")
            .OrderBy(path => path.Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries).Length)
            .ToList();
        if (inis.Count > 0)
        {
            var folder = SwiftPath.Parent(inis[0]);
            return SwiftPath.Standardized(folder) == SwiftPath.Standardized(staging)
                ? new Payload(PayloadKind.Files, folder)
                : new Payload(PayloadKind.Item, folder);
        }
        // Інше — одна тека чи один файл на верхньому рівні.
        var top = SwiftPath.Contents(staging, skipsHidden: false).Where(path => !Skip.Contains(SwiftPath.LastComponent(path))).ToList();
        return top.Count == 1 ? new Payload(PayloadKind.Item, top[0]) : null;
    }

    /// Перший файл з потрібним ім'ям (або просто перший) із zip-а в пам'яті.
    internal static byte[]? UnzipFirst(byte[] data, string wanted)
    {
        try
        {
            using var archive = new ZipArchive(new MemoryStream(data), ZipArchiveMode.Read);
            var files = archive.Entries.Where(entry => !entry.FullName.EndsWith('/') && !IsMacOSX(entry.FullName)).ToList();
            var file = files.FirstOrDefault(entry => entry.Name == wanted) ?? files.FirstOrDefault();
            if (file == null) return null;
            using var stream = file.Open();
            using var output = new MemoryStream();
            stream.CopyTo(output);
            return output.ToArray();
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static bool IsMacOSX(string entryName) => entryName.Split('/').Contains("__MACOSX");

    /// Розпакувати архів у теку (`ditto -x -k`): службову теку macOS
    /// `__MACOSX` ditto не розпаковує — тут так само.
    internal static void Unzip(string zip, string destination)
    {
        using var archive = ZipFile.OpenRead(zip);
        // Порожній архів (лише кінець каталогу) ditto не приймає: «Incorrect pkzip signature».
        if (archive.Entries.Count == 0) throw new InvalidDataException("порожній архів");
        var root = Path.GetFullPath(destination) + Path.DirectorySeparatorChar;
        foreach (var entry in archive.Entries)
        {
            if (IsMacOSX(entry.FullName)) continue;
            var target = Path.GetFullPath(Path.Combine(destination, entry.FullName.Replace('/', Path.DirectorySeparatorChar)));
            if (!target.StartsWith(root, StringComparison.Ordinal)) continue;
            if (entry.FullName.EndsWith('/'))
            {
                Directory.CreateDirectory(target);
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            entry.ExtractToFile(target, overwrite: true);
        }
    }

    // ── Установлення ────────────────────────────────────────────────────────

    public readonly record struct Progress(ResourceItem Item, int Index, int Total, double? Fraction);
    // Fraction — частка завантаження цього ресурсу, 0…1; null — розмір невідомий.

    public sealed class Outcome
    {
        public List<ResourceItem> Installed { get; } = new();
        public List<(ResourceItem Item, string Reason)> Failures { get; } = new();
    }

    /// Завантажити й поставити вибране, по черзі. `progress` і `completion`
    /// приходять у фоні — кому треба головний потік, той сам перейде.
    public void Install(IReadOnlyList<ResourceItem> items, Action<Progress> progress, Action<Outcome> completion) =>
        Task.Run(async () => completion(await InstallAsync(items, progress).ConfigureAwait(false)));

    /// Те саме як завдання: кінець — коли все поставлено.
    public async Task<Outcome> InstallAsync(IReadOnlyList<ResourceItem> items, Action<Progress>? progress = null)
    {
        await Task.Yield();
        var outcome = new Outcome();
        var ledger = ResourceLedger.Load();
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            progress?.Invoke(new Progress(item, index, items.Count, 0));
            string? zip = null;
            ResourceError? failure = null;
            // Посилання, якого не розібрати, — теж спроба завантаження, що не
            // вдалася (macOS 14+ приймає в `URL(string:)` майже будь-який рядок,
            // і відмову дає вже сам сеанс).
            try
            {
                if (ParseUrl(item.Url) is not { } url) throw ResourceError.Network(item.Url);
                zip = await Download(url, fraction => progress?.Invoke(new Progress(item, index, items.Count, fraction))).ConfigureAwait(false);
            }
            catch (ResourceError error)
            {
                failure = error;
            }
            // Кінець завантаження (і вдалого, і ні) — смужка до кінця.
            progress?.Invoke(new Progress(item, index, items.Count, 1));
            if (failure != null || zip == null)
            {
                outcome.Failures.Add((item, (failure ?? ResourceError.Network("")).Message));
                continue;
            }
            try
            {
                if (Place(zip, item) is { } error) outcome.Failures.Add((item, error.Message));
                else
                {
                    ledger.Installed[item.Id] = item.Version;
                    ledger.Save();
                    outcome.Installed.Add(item);
                }
            }
            finally
            {
                try { File.Delete(zip); } catch { }
            }
        }
        return outcome;
    }

    /// Завантажити zip у тимчасовий файл: хід — у частках, коли сервер сказав розмір.
    private static async Task<string> Download(Uri url, Action<double?> progress)
    {
        var kept = Path.Combine(Path.GetTempPath(), "slovo-resource-" + Guid.NewGuid().ToString().ToUpperInvariant() + ".zip");
        try
        {
            Stream source;
            long expected;
            HttpResponseMessage? response = null;
            if (url.IsFile)
            {
                source = File.OpenRead(url.LocalPath);
                expected = source.Length;
            }
            else
            {
                response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
                var status = (int)response.StatusCode;
                if (status != 200)
                {
                    response.Dispose();
                    throw ResourceError.Network(OurWords.T("сервер ответил %s", status.ToString(System.Globalization.CultureInfo.InvariantCulture)));
                }
                expected = response.Content.Headers.ContentLength ?? -1;
                source = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
            }
            using (response)
            await using (source)
            await using (var output = File.Create(kept))
            {
                var buffer = new byte[1 << 16];
                long written = 0;
                int read;
                while ((read = await source.ReadAsync(buffer).ConfigureAwait(false)) > 0)
                {
                    await output.WriteAsync(buffer.AsMemory(0, read)).ConfigureAwait(false);
                    written += read;
                    progress(expected > 0 ? (double)written / expected : null);
                }
            }
            return kept;
        }
        catch (ResourceError)
        {
            try { File.Delete(kept); } catch { }
            throw;
        }
        catch (Exception error)
        {
            try { File.Delete(kept); } catch { }
            throw ResourceError.Network(error.Message);
        }
    }

    /// `URL(string:)`: лише повне посилання, без пробілів.
    private static Uri? ParseUrl(string text) =>
        Uri.TryCreate(text, UriKind.Absolute, out var url) && !text.Any(char.IsWhiteSpace) ? url : null;

    /// Розпакувати й покласти на місце: переклад і пісенник — у теку
    /// модулів (стара версія прибирається), фони/шаблони/шрифти/сторінки —
    /// у корінь даних, поверх наявних.
    private ResourceError? Place(string zip, ResourceItem item)
    {
        // Пісенник SoftProjector може прийти й голим .sps, не zip-ом.
        if (item.Id.StartsWith("sp:", StringComparison.Ordinal) && item.Url.ToLowerInvariant().EndsWith(".sps", StringComparison.Ordinal))
            return PlaceSoftProjector(zip, item);
        var staging = Path.Combine(Path.GetTempPath(), "slovo-unpack-" + Guid.NewGuid().ToString().ToUpperInvariant());
        try
        {
            try { Directory.CreateDirectory(staging); }
            catch (Exception error) { return ResourceError.Unpack(error.Message); }
            try { Unzip(zip, staging); }
            catch (Exception error) { return ResourceError.Unpack(error.Message); }

            // Приховані файли не пропускаємо: у zip-і MyBible модуль лежить як
            // «.SQLite3» — без імені. Відкидаємо лише службове macOS.
            var unpacked = SwiftPath.Contents(staging, skipsHidden: false)
                .Where(path => !Skip.Contains(SwiftPath.LastComponent(path))).ToList();
            var destination = Layout.Destination(item);
            if (item.Id.StartsWith("eb:", StringComparison.Ordinal))
            {
                // eBible.org: «вірш на рядок» → модуль MyBible.
                if (EBibleVPL.FindText(staging) is not { } text) return ResourceError.Unpack(OurWords.T("в архиве нет модуля"));
                var code = item.Id[3..];
                try
                {
                    EBibleVPL.Convert(text, destination, new EBibleVPL.Description(
                        item.Title, code.ToUpperInvariant(), item.Language ?? "", item.Subtitle + " · eBible.org", false));
                }
                catch (Exception error)
                {
                    return ResourceError.Place(error.Message);
                }
                return null;
            }
            if (item.Id.StartsWith("sp:", StringComparison.Ordinal))
            {
                var sps = EBibleVPL.EnumerateAll(staging).FirstOrDefault(path => SwiftPath.Extension(path).ToLowerInvariant() == "sps");
                if (sps == null) return ResourceError.Unpack(OurWords.T("в архиве нет модуля"));
                return PlaceSoftProjector(sps, item);
            }
            try
            {
                switch (item.Kind)
                {
                    case ResourceKind.Bible:
                    case ResourceKind.Songbook:
                    {
                        // Що саме класти — шукаємо, а не беремо «єдине, що є»: у 0.8
                        // файл пісенника лежав у zip-і всередині теки «Modules/», і
                        // на диск лягала ТЕКА з іменем пісенника (власник: «пише
                        // завершено, а фізично не скачується»).
                        if (PayloadIn(staging, item) is not { } found) return ResourceError.Unpack(OurWords.T("в архиве нет модуля"));
                        Directory.CreateDirectory(SwiftPath.Parent(destination));
                        RemoveItem(destination);
                        if (found.Kind == PayloadKind.Item)
                        {
                            MoveItem(found.Path, destination);
                        }
                        else
                        {
                            Directory.CreateDirectory(destination);
                            foreach (var file in SwiftPath.Contents(found.Path, skipsHidden: false))
                            {
                                if (Skip.Contains(SwiftPath.LastComponent(file))) continue;
                                MoveItem(file, Path.Combine(destination, SwiftPath.LastComponent(file)));
                            }
                        }
                        // Пісенник старої програми — одразу у свій формат, старий двійник геть.
                        if (item.Kind == ResourceKind.Songbook)
                        {
                            var stem = SwiftPath.DeletingExtension(destination);
                            var own = stem + "." + SongBookJSON.PathExtension;
                            if (SwiftPath.Extension(destination).ToLowerInvariant() == "vbm")
                            {
                                var book = SongBook.FromFile(destination);
                                SongBookJSON.Write(book, own);
                                RemoveItem(destination);
                            }
                            else
                            {
                                var twin = stem + ".vbm";
                                try { if (SwiftPath.Exists(twin)) RemoveItem(twin); } catch { }
                            }
                        }
                        break;
                    }
                    default:
                    {
                        // Тека під власним ім'ям усередині архіву; зливаємо поверх.
                        var source = unpacked.Count == 1 && Directory.Exists(unpacked[0]) ? unpacked[0] : staging;
                        Directory.CreateDirectory(destination);
                        foreach (var file in SwiftPath.Contents(source, skipsHidden: true))
                        {
                            var target = Path.Combine(destination, SwiftPath.LastComponent(file));
                            RemoveItem(target);
                            MoveItem(file, target);
                        }
                        break;
                    }
                }
            }
            catch (Exception error)
            {
                return ResourceError.Place(error.Message);
            }
            return null;
        }
        finally
        {
            try { Directory.Delete(staging, recursive: true); } catch { }
        }
    }

    /// Пісенник SoftProjector (`.sps` будь-якої з трьох версій) → `.songbook`.
    private ResourceError? PlaceSoftProjector(string sps, ResourceItem item)
    {
        var destination = Layout.Destination(item);
        // Розбір упізнає формат за вмістом, а тимчасовий файл завантаження
        // зветься «.zip» — даємо йому справжнє розширення.
        var named = Path.Combine(Path.GetTempPath(), "slovo-sps-" + Guid.NewGuid().ToString().ToUpperInvariant() + ".sps");
        try
        {
            File.Copy(sps, named);
            var book = SongBookImporter.FromSoftProjector(named);
            if (book.Title.Length == 0) book.Title = item.Title;
            Directory.CreateDirectory(SwiftPath.Parent(destination));
            RemoveItem(destination);
            SongBookJSON.Write(book, destination);
            var twin = SwiftPath.DeletingExtension(destination) + ".vbm";
            try { if (SwiftPath.Exists(twin)) RemoveItem(twin); } catch { }
        }
        catch (Exception error)
        {
            return ResourceError.Place(error.Message);
        }
        finally
        {
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            try { File.Delete(named); } catch { }
        }
        return null;
    }

    /// `removeItem(at:)` — і файл, і тека; немає — нічого.
    private static void RemoveItem(string path)
    {
        if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
        else if (File.Exists(path)) File.Delete(path);
    }

    /// `moveItem(at:to:)` — і файл, і тека.
    private static void MoveItem(string from, string to)
    {
        if (Directory.Exists(from)) Directory.Move(from, to);
        else File.Move(from, to);
    }
}

public static class ResourceSources
{
    public static readonly IReadOnlyList<ResourceHub.Source> All =
        [ResourceHub.Source.Slovo, ResourceHub.Source.BibleQuote, ResourceHub.Source.MyBible, ResourceHub.Source.EBible, ResourceHub.Source.SoftProjector];

    public static string RawValue(this ResourceHub.Source source) => source switch
    {
        ResourceHub.Source.Slovo => "slovo",
        ResourceHub.Source.BibleQuote => "bibleQuote",
        ResourceHub.Source.MyBible => "myBible",
        ResourceHub.Source.EBible => "eBible",
        _ => "softProjector",
    };

    /// Що дає джерело. Власник: «не делай путаницу — переводы выбираются
    /// отдельно, песенники отдельно»: вікно ресурсів показує джерела
    /// лише того роду, який вибрано.
    public static IReadOnlySet<ResourceKind> Kinds(this ResourceHub.Source source) => source switch
    {
        ResourceHub.Source.Slovo => new HashSet<ResourceKind>(ResourceKinds.All),
        ResourceHub.Source.SoftProjector => new HashSet<ResourceKind> { ResourceKind.Songbook },
        _ => new HashSet<ResourceKind> { ResourceKind.Bible },
    };
}
