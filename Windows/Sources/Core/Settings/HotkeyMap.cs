// =============================================================================
//  HotkeyMap.cs — гарячі клавіші й набори `hotkeys.ini` (з Settings/HotkeyMap.swift)
// =============================================================================

using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Одне сполучення клавіш у записі старої програми: `Ctrl+Alt+B`, `F5`, `Esc`.
///
/// Зберігається розібраним, а не рядком: на вкладці «Гарячі клавіші»
/// сполучення ловиться з клавіатури і його треба порівнювати з уже зайнятими,
/// а меню потрібен розкладений за модифікаторами вигляд.
public record struct Hotkey
{
    [JsonInclude, JsonRequired, JsonPropertyName("control")] public bool Control;
    [JsonInclude, JsonRequired, JsonPropertyName("alt")] public bool Alt;
    [JsonInclude, JsonRequired, JsonPropertyName("shift")] public bool Shift;
    /// Основна клавіша в записі оригіналу: `F5`, `Esc`, `B`, `Space`.
    [JsonInclude, JsonRequired, JsonPropertyName("key")] public string Key;

    public Hotkey(bool control = false, bool alt = false, bool shift = false, string key = "")
    {
        Control = control;
        Alt = alt;
        Shift = shift;
        Key = key;
    }

    /// Розбір рядка з `hotkeys.ini` (`init?(text:)`). Порожній рядок — «клавішу
    /// не призначено», і це законний стан: в оригіналі частина функцій без клавіші.
    public static Hotkey? Parse(string text)
    {
        var parts = text.Split('+', StringSplitOptions.RemoveEmptyEntries).Select(part => part.TrimWhitespaces()).ToArray();
        if (parts.Length == 0) return null;

        bool control = false, alt = false, shift = false;
        var key = "";
        foreach (var part in parts)
        {
            switch (part.ToLowerInvariant())
            {
                case "ctrl": case "control": control = true; break;
                case "alt": alt = true; break;
                case "shift": shift = true; break;
                case "": continue;
                default: key = CanonicalKey(part); break;
            }
        }
        if (key.Length == 0) return null;
        return new Hotkey(control, alt, shift, key);
    }

    /// Назад у запис оригіналу — порядок модифікаторів там завжди Ctrl, Alt,
    /// Shift, і файл має лишитися читабельним для старої програми.
    [JsonIgnore]
    public readonly string Text
    {
        get
        {
            var parts = new List<string>();
            if (Control) parts.Add("Ctrl");
            if (Alt) parts.Add("Alt");
            if (Shift) parts.Add("Shift");
            parts.Add(Key);
            return string.Join("+", parts);
        }
    }

    /// Функціональна клавіша: `F5` → 5. Потрібна і меню, і перевірці набору.
    [JsonIgnore]
    public readonly int? FunctionNumber
    {
        get
        {
            if (SwiftText.CharacterCount(Key) < 2 || !Key.StartsWith('F')) return null;
            if (SwiftText.ParseInt(Key[1..]) is not { } number) return null;
            return number is >= 1 and <= 20 ? number : null;
        }
    }

    /// Зводимо написання до того, в якому клавіші записані в `hotkeys.ini`:
    /// літери великі, `esc` → `Esc`, `f5` → `F5`.
    internal static string CanonicalKey(string raw)
    {
        var trimmed = raw.TrimWhitespaces();
        if (SwiftText.CharacterCount(trimmed) == 1) return trimmed.ToUpperInvariant();
        var lower = trimmed.ToLowerInvariant();
        if (lower.StartsWith('f') && SwiftText.ParseInt(lower[1..]) != null) return "F" + lower[1..];
        if (Known.TryGetValue(lower, out var known)) return known;
        var first = SwiftText.PrefixCharacters(trimmed, 1);
        return first.ToUpperInvariant() + trimmed[first.Length..];
    }

    private static readonly Dictionary<string, string> Known = new(StringComparer.Ordinal)
    {
        ["esc"] = "Esc", ["escape"] = "Esc", ["space"] = "Space", ["enter"] = "Enter",
        ["return"] = "Enter", ["tab"] = "Tab", ["backspace"] = "BackSpace",
        ["ins"] = "Ins", ["del"] = "Del", ["home"] = "Home", ["end"] = "End",
        ["pgup"] = "PgUp", ["pgdn"] = "PgDn",
        ["up"] = "Up", ["down"] = "Down", ["left"] = "Left", ["right"] = "Right",
    };
}

/// Функція, якій можна призначити клавішу.
///
/// Склад і порядок — ті самі, що на вкладці «Гарячі клавіші» оригіналу:
/// `IniKey` — ключ у `hotkeys.ini`, `CaptionKey` — підпис із форми
/// `SettingsForm` файла перекладу. Власних формулювань тут немає.
public readonly record struct HotkeyAction(string IniKey, string CaptionKey, string Fallback)
{
    public string Id => IniKey;

    /// Порядок — той, у якому функції стоять у двох стовпцях форми оригіналу,
    /// а не порядок номерів Label21…Label51 (автор нумерував мітки не в тому
    /// порядку, в якому розставив їх на формі). За ним же `Serialized()`
    /// розкладає рядки в `hotkeys.ini`, який читають очима.
    public static readonly IReadOnlyList<HotkeyAction> All =
    [
        new("ShowSlide",            "Label21", "Показать слайд:"),
        new("HideSlide",            "Label22", "Скрыть слайд:"),
        new("Search",               "Label24", "Поиск:"),
        new("FastInput",            "Label23", "Быстр. выбор:"),
        new("Plan",                 "Label27", "Фокус на План:"),
        new("MainWin",              "Label25", "Фокус на Стихи/Текст:"),
        new("ScreenShot",           "Label26", "Снимок экрана:"),
        new("FastSearchWindow",     "Label28", "Результ. поиска:"),
        new("ShowBackGrOnSlide",    "Label29", "Общий Фон:"),
        new("FastInputBook",        "Label31", "Быстрый выбор Книги/Песни:"),
        new("FastInputChapter",     "Label32", "Быстрый выбор Главы:"),
        new("FastInputVers",        "Label33", "Быстрый выбор Стиха или части Песни:"),
        new("ShowBlackScreen",      "Label44", "Затемнение экрана:"),
        new("ShowBlankSlide",       "Label45", "Показ. пустой слайд:"),
        new("ShowMediaPlayer",      "Label47", "Открыть Медиаплеер:"),
        new("MediaPlayerPlayPause", "Label48", "Медиаплеер Воспр./Пауза:"),
        new("OpenCommonBG",         "Label49", "Выбрать Общий фон:"),
        new("OpenSlideBG",          "Label50", "Выбрать фон Слайда:"),
        new("ReactionOnCtrlE",      "Label51", "Режим редакт./просмотр:"),
    ];
}

/// Уміст `hotkeys.ini`: кілька іменованих наборів клавіш.
///
/// Файл оригіналу — це не одна розкладка, а історія: `[VB Version 2.2]`,
/// `[VB Version 2.3]`, `[VB Version 2.4]`. Випадний список (36) на вкладці
/// «Гарячі клавіші» показує саме їх, тому читаємо всі.
public sealed class HotkeySets : IEquatable<HotkeySets>
{
    /// Імена в тому порядку, в якому секції йдуть у файлі.
    [JsonInclude, JsonRequired, JsonPropertyName("order")]
    public List<string> Order { get; private set; }

    /// Ім'я набору → (ключ функції → запис сполучення).
    [JsonInclude, JsonRequired, JsonPropertyName("sets")]
    public Dictionary<string, Dictionary<string, string>> Sets { get; private set; }

    [JsonConstructor]
    public HotkeySets()
    {
        Order = new List<string>();
        Sets = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
    }

    public HotkeySets(IEnumerable<string> order, IDictionary<string, Dictionary<string, string>> sets)
    {
        Order = order.ToList();
        Sets = sets.ToDictionary(pair => pair.Key,
                                 pair => new Dictionary<string, string>(pair.Value, StringComparer.Ordinal),
                                 StringComparer.Ordinal);
    }

    /// `init(text:)`.
    public static HotkeySets FromText(string text)
    {
        var order = new List<string>();
        var sets = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        var current = "";

        foreach (var rawLine in text.SplitLines())
        {
            var line = rawLine.TrimWhitespaces();
            if (line.Length == 0 || line.StartsWith(';')) continue;
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                current = line[1..^1];
                if (!sets.ContainsKey(current))
                {
                    order.Add(current);
                    sets[current] = new Dictionary<string, string>(StringComparer.Ordinal);
                }
                continue;
            }
            var eq = line.IndexOf('=');
            if (current.Length == 0 || eq < 0) continue;
            // Регістр ключів тут зберігаємо: назад у файл вони мають лягти
            // так само, як їх пише стара програма.
            var key = line[..eq].TrimWhitespaces();
            var value = line[(eq + 1)..].TrimWhitespaces();
            if (sets.TryGetValue(current, out var set)) set[key] = value;
        }
        return new HotkeySets(order, sets);
    }

    /// `init(fileAt:)` — кидає виняток, якщо файла не прочитати.
    public static HotkeySets FromFile(string path)
    {
        var data = File.ReadAllBytes(path);
        var declared = CodePage.IsValidUtf8(data) ? CodePage.Utf8 : null;
        return FromText(CodePage.Decode(data, declared));
    }

    /// Набір, який треба показати при відкритті: останній у файлі — він же
    /// найновіший, і саме за ним працює свіжа версія оригіналу.
    [JsonIgnore]
    public string? PreferredSetName => Order.Count > 0 ? Order[^1] : null;

    public Dictionary<string, Hotkey> Hotkeys(string inSet)
    {
        var result = new Dictionary<string, Hotkey>(StringComparer.Ordinal);
        if (!Sets.TryGetValue(inSet, out var set)) return result;
        foreach (var (key, value) in set)
        {
            if (Hotkey.Parse(value) is { } hotkey) result[key] = hotkey;
        }
        return result;
    }

    public void Replace(string setNamed, IReadOnlyDictionary<string, Hotkey> hotkeys)
    {
        if (!Sets.ContainsKey(setNamed)) Order.Add(setNamed);
        Sets[setNamed] = hotkeys.ToDictionary(pair => pair.Key, pair => pair.Value.Text, StringComparer.Ordinal);
    }

    public void Remove(string setNamed)
    {
        Sets.Remove(setNamed);
        Order.RemoveAll(name => name == setNamed);
    }

    /// Запис у форматі оригіналу — щоб файл лишився придатним і для нього.
    public string Serialized()
    {
        var lines = new List<string>();
        foreach (var name in Order)
        {
            lines.Add($"[{name}]");
            Sets.TryGetValue(name, out var set);
            set ??= new Dictionary<string, string>();
            // Порядок рядків — як на вкладці налаштувань: файл читають очима.
            foreach (var action in HotkeyAction.All)
            {
                if (set.TryGetValue(action.IniKey, out var value)) lines.Add($"{action.IniKey}={value}");
            }
            foreach (var (key, value) in set.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                if (HotkeyAction.All.Any(action => action.IniKey == key)) continue;
                lines.Add($"{key}={value}");
            }
            lines.Add("");
        }
        return string.Join("\n", lines);
    }

    /// Розкладка поставки старої програми V2.5 — на випадок, коли файла поруч немає
    /// і кнопці (35) «За умовчанням» нема на що спертися. Щоразу нова копія:
    /// у Swift це значення, і правка копії не має торкатися поставки.
    public static HotkeySets FactoryDefault => new(
        ["VB Version 2.4"],
        new Dictionary<string, Dictionary<string, string>>
        {
            ["VB Version 2.4"] = new()
            {
                ["ShowSlide"] = "F5",
                ["HideSlide"] = "Esc",
                ["Search"] = "F3",
                ["FastInput"] = "F4",
                ["Plan"] = "F2",
                ["MainWin"] = "F6",
                ["ScreenShot"] = "F11",
                ["FastSearchWindow"] = "Ctrl+F3",
                ["ShowBackGrOnSlide"] = "Ctrl+F9",
                ["FastInputBook"] = "F7",
                ["FastInputChapter"] = "F8",
                ["FastInputVers"] = "F9",
                ["ShowBlackScreen"] = "F12",
                ["ShowBlankSlide"] = "Ctrl+F5",
                ["ShowMediaPlayer"] = "Ctrl+M",
                ["MediaPlayerPlayPause"] = "Ctrl+P",
                ["OpenCommonBG"] = "Ctrl+B",
                ["OpenSlideBG"] = "Ctrl+Alt+B",
                ["ReactionOnCtrlE"] = "Ctrl+E",
            },
        });

    /// `hotkeys.ini` лежить поруч із файлом налаштувань програми — у тій
    /// самій теці, що й `Slovo.ini`: особистій або в умовчаннях програми.
    public static string? LocateFile()
    {
        if (IniSettings.LocateConfig() is not { } ini) return null;
        var path = Path.Combine(SwiftPath.Parent(ini), "hotkeys.ini");
        return SwiftPath.Exists(path) ? path : null;
    }

    /// Набори з файла програми, а якщо його немає — поставкова розкладка.
    public static HotkeySets Load()
    {
        if (LocateFile() is not { } path) return FactoryDefault;
        try
        {
            var loaded = FromFile(path);
            return loaded.Order.Count == 0 ? FactoryDefault : loaded;
        }
        catch
        {
            return FactoryDefault;
        }
    }

    /// Глибока копія (у Swift — звичайне присвоєння значення).
    public HotkeySets Copy() => new(Order, Sets);

    public bool Equals(HotkeySets? other)
    {
        if (other is null) return false;
        if (!Order.SequenceEqual(other.Order) || Sets.Count != other.Sets.Count) return false;
        foreach (var (name, set) in Sets)
        {
            if (!other.Sets.TryGetValue(name, out var theirs) || set.Count != theirs.Count) return false;
            foreach (var (key, value) in set)
                if (!theirs.TryGetValue(key, out var their) || their != value) return false;
        }
        return true;
    }

    public override bool Equals(object? obj) => obj is HotkeySets other && Equals(other);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var name in Order) hash.Add(name);
        return hash.ToHashCode();
    }
}
