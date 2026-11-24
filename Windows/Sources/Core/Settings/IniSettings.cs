// =============================================================================
//  IniSettings.cs — налаштування у форматі ini (з Settings/IniSettings.swift)
// =============================================================================

namespace Slovo.Core;

/// Читання налаштувань у форматі ini — тому самому, що й у старій програмі.
///
/// Сенс не в сумісності заради сумісності: у файлі вже зібрано шрифти,
/// кольори, обведення, таймінги й порядок перекладів, вивірені на
/// проекторі. Переносити це руками — втратити половину налаштувань.
public sealed class IniSettings
{
    private readonly Dictionary<string, Dictionary<string, string>> sections = new(StringComparer.Ordinal);

    /// Секція → (ключ у нижньому регістрі → значення).
    public IReadOnlyDictionary<string, Dictionary<string, string>> Sections => sections;

    /// `init(text:)`.
    public IniSettings(string text) => Parse(text);

    /// `init(fileAt:)` — кидає виняток, якщо файла не прочитати.
    public static IniSettings FromFile(string path)
    {
        var data = File.ReadAllBytes(path);
        // Файл пишеться Delphi в UTF-8 із BOM, але старі збірки клали CP1251.
        var declared = CodePage.IsValidUtf8(data) ? CodePage.Utf8 : null;
        return new IniSettings(CodePage.Decode(data, declared));
    }

    private void Parse(string text)
    {
        var current = "";
        foreach (var rawLine in text.SplitLines())
        {
            var line = rawLine.TrimWhitespaces();
            if (line.Length == 0 || line.StartsWith(';')) continue;

            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                current = line[1..^1];
                if (!sections.ContainsKey(current)) sections[current] = new Dictionary<string, string>(StringComparer.Ordinal);
                continue;
            }
            var eq = line.IndexOf('=');
            if (eq < 0) continue;
            var key = line[..eq].TrimWhitespaces();
            var value = line[(eq + 1)..].TrimWhitespaces();
            if (!sections.TryGetValue(current, out var section))
            {
                section = new Dictionary<string, string>(StringComparer.Ordinal);
                sections[current] = section;
            }
            section[key.ToLowerInvariant()] = value;
        }
    }

    // ── Доступ до значень ───────────────────────────────────────────────────

    public string? String(string key, string section) =>
        sections.TryGetValue(section, out var values) && values.TryGetValue(key.ToLowerInvariant(), out var value)
            ? value
            : null;

    public int? Int(string key, string section) => SwiftText.ParseInt(String(key, section));

    public bool? Bool(string key, string section) => Int(key, section) is { } raw ? raw != 0 : null;

    /// Delphi пише дробові числа з комою — `2,70000004768372`.
    public double? Double(string key, string section) =>
        String(key, section) is { } raw ? SwiftText.ParseDouble(raw.Replace(",", ".")) : null;

    /// `TColor` у Delphi — це `0x00BBGGRR`, порядок каналів зворотний до звичного.
    public SlideStyle.RGBA? Color(string key, string section)
    {
        if (Int(key, section) is not { } raw || raw < 0) return null;
        return new SlideStyle.RGBA((raw & 0xFF) / 255.0,
                                   ((raw >> 8) & 0xFF) / 255.0,
                                   ((raw >> 16) & 0xFF) / 255.0);
    }

    /// Модулі з `[BiblePath]`: рядки виду `0="Modules\rst+\"|1`,
    /// де хвіст після `|` — ознака ввімкненості.
    ///
    /// Порядок і ввімкненість повертаємо разом: в оригіналі це одне
    /// налаштування. Вимкнений модуль лишається в бібліотеці, але не займає вкладки.
    public List<(string Name, bool IsEnabled)> ModuleEntries()
    {
        if (!sections.TryGetValue("BiblePath", out var paths)) return new List<(string, bool)>();
        var entries = new List<(int Index, string Name, bool Enabled)>();
        foreach (var (key, value) in paths.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (SwiftText.ParseInt(key) is not { } index) continue;
            var parts = value.Split('|', 2);
            var path = parts[0];
            var enabled = parts.Length <= 1 || parts[1].TrimWhitespaces() != "0";
            var cleaned = path.TrimCharacters("\" \\");
            var pieces = cleaned.Split('\\', StringSplitOptions.RemoveEmptyEntries);
            if (pieces.Length == 0) continue;
            entries.Add((index, pieces[^1], enabled));
        }
        return entries.OrderBy(entry => entry.Index).Select(entry => (entry.Name, entry.Enabled)).ToList();
    }

    public List<string> ModuleOrder() => ModuleEntries().Select(entry => entry.Name).ToList();

    /// Ім'я власного файла налаштувань. Формат — той самий ini, у якому
    /// розкладено секції `[Bible]`, `[OutScreen]`, `[BiblePath]`.
    public const string ConfigFileName = "Slovo.ini";

    /// Де файл може лежати, за спаданням пріоритету.
    ///
    /// Спершу особиста тека програми: туди можна покласти свою копію й
    /// підправити значення без пересборки. Потім умовчання самої програми
    /// (на Mac — у пакеті, на Windows — вшиті в .exe і розпаковані, див.
    /// `DataHome.BundleData`): з ними програма стартує на новому комп'ютері.
    /// Файлів установленої старої програми програма не шукає.
    public static IReadOnlyList<string> ConfigCandidates =>
    [
        Path.Combine(DataHome.Folder, ConfigFileName),
        Path.Combine(DataHome.BundleData, ConfigFileName),
    ];

    /// Файл налаштувань, який читає програма, або `null`, якщо його немає
    /// в жодному зі своїх місць — тоді діють значення, зашиті в код.
    public static string? LocateConfig() => ConfigCandidates.FirstOrDefault(SwiftPath.Exists);
}
