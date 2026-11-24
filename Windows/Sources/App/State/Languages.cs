// =============================================================================
//  Languages.cs — мова інтерфейсу (як AppState.loadLanguages на Mac)
// =============================================================================
//  Підписи — із тих самих місць, що на Mac: наш словник (OurWords: російський
//  текст як ключ → українська вбудована, англійська й німецька — з en.json/
//  de.json) і файли перекладу автора `Language/*.lng` у теці даних (свої правки
//  перекладу — у `Language` теки «Слова», вони витісняють однойменні авторські).
//  Мова за умовчанням — як мова Windows: українська → uk, російська → ru, інша → en.
// =============================================================================

using System.Text.Json;
using Slovo.Core;

namespace Slovo.App;

public static class Languages
{
    public static LanguageCatalog? Catalog { get; private set; }
    public static LanguageFile? Current { get; private set; }
    public static readonly (string Code, string Name)[] BuiltIn = { ("uk", "Українська"), ("ru", "Русский"), ("en", "English"), ("de", "Deutsch") };
    const string LanguageKey = "languageCode";

    static bool _dictionaries;

    public static string SystemDefault()
    {
        var name = System.Globalization.CultureInfo.CurrentUICulture.Name.ToLowerInvariant();
        if (name.StartsWith("uk")) return "uk";
        if (name.StartsWith("ru")) return "ru";
        return "en";
    }

    /// Підняти словники й файли перекладу; вибрати мову.
    public static void Load(string dataRoot)
    {
        _dataRoot = dataRoot;
        if (!_dictionaries)
        {
            _dictionaries = true;
            foreach (var code in new[] { "en", "de" })
            {
                try
                {
                    using var stream = typeof(Languages).Assembly.GetManifestResourceStream(code + ".json");
                    if (stream == null) continue;
                    using var doc = JsonDocument.Parse(stream);
                    if (!doc.RootElement.TryGetProperty("words", out var words)) continue;
                    var table = new Dictionary<string, string>();
                    foreach (var p in words.EnumerateObject()) if (p.Value.ValueKind == JsonValueKind.String) table[p.Name] = p.Value.GetString()!;
                    OurWords.Register(table, code);
                }
                catch (Exception error) { Journal.Say($"словник {code}: {error.Message}"); }
            }
        }

        var languages = new Dictionary<string, LanguageFile>(StringComparer.OrdinalIgnoreCase);
        foreach (var folder in new[] { Path.Combine(dataRoot, "Language"), Path.Combine(DataHome.Folder, "Language") })
        {
            if (!Directory.Exists(folder)) continue;
            foreach (var file in Directory.EnumerateFiles(folder, "*.lng"))
                try { var lf = new LanguageFile(file); languages[lf.Code] = lf; } catch { }
        }
        var wanted = Current?.Code ?? Defaults.String(LanguageKey) ?? SystemDefault();
        if (languages.Count == 0)
        {
            Catalog = null;
            Current = null;
            OurWords.Language = BuiltIn.Any(b => b.Code == wanted) ? wanted : "en";
        }
        else
        {
            var catalogFolder = Path.Combine(dataRoot, "Language");
            Catalog = Directory.Exists(catalogFolder) ? new LanguageCatalog(catalogFolder) : null;
            Current = languages.TryGetValue(wanted, out var hit) ? hit
                    : languages.TryGetValue("uk", out var uk) ? uk : languages.Values.First();
            OurWords.Language = Current.Code;
            ApplyOverrides();
        }
        Wire();
    }

    /// Наші підписи, виправлені у файлі перекладу (розділ [Slovo]).
    static void ApplyOverrides()
    {
        var table = new Dictionary<string, string>();
        if (Current != null && Current.Forms.TryGetValue(OurWords.SectionName, out var section))
            foreach (var (key, entry) in section) table[key] = entry.Caption;
        OurWords.ApplyOverrides(table);
    }

    static void Wire()
    {
        Captions.Translate = OurWords.T;
        Captions.FormCaption = (key, form, fallback) =>
        {
            var spare = OurWords.T(fallback);
            return Current?.Caption(key, form, spare) ?? spare;
        };
        Captions.FormHint = (key, form) => Current?.Hint(key, form) is { Length: > 0 } hint ? hint : null;
    }

    /// Вибрати мову (меню «Language/Мова»).
    public static void Set(string code, string dataRoot)
    {
        Defaults.Set(LanguageKey, code);
        Current = null;
        Load(dataRoot);
        Signals.Shared.Send(Signals.Kind.Language);
    }

    public static string Code => Current?.Code ?? OurWords.Language;

    static string? _dataRoot;
    /// Тека даних, з якої читано переклади (її `Language` — файли оригіналу).
    public static string? DataRoot => _dataRoot;
    static IEnumerable<string> Folders() =>
        new[] { _dataRoot is { } root ? Path.Combine(root, "Language") : null, Path.Combine(DataHome.Folder, "Language") }
            .OfType<string>().Where(Directory.Exists).Distinct();

    /// Файли перекладу: оригіналу й свої (свої перекривають оригінал), за назвою.
    public static List<LanguageFile> Files()
    {
        var byCode = new Dictionary<string, LanguageFile>(StringComparer.OrdinalIgnoreCase);
        foreach (var folder in Folders())
            foreach (var file in Directory.EnumerateFiles(folder, "*.lng"))
                try { var lf = new LanguageFile(file); byCode[lf.Code] = lf; } catch { /* битий файл */ }
        var list = byCode.Values.ToList();
        list.Sort((a, b) => SwiftText.LocalizedStandardCompare(a.DisplayName, b.DisplayName));
        return list;
    }

    /// Прапорець мови — <код>.png поруч із файлом перекладу.
    public static string? Flag(string code) =>
        Folders().Reverse().Select(f => Path.Combine(f, code + ".png")).FirstOrDefault(File.Exists);
}
