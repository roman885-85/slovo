// =============================================================================
//  JournalFile.cs — файл-журнал оригіналу: History.ini, PlanDef.ini, плани
//  (з Journal/JournalFile.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Файл-журнал оригіналу: `History.ini`, `PlanDef.ini` і збережені плани
/// з теки `Plans`.
///
/// Формат один на всіх і, попри розширення `.ini`, це розмітка:
///
///     &lt;JournalFile&gt;
///       &lt;Journal Name="Bible"&gt;
///         &lt;Item Caption="Быт.- В начале сотворил Бог небо и землю."
///               Reference="Быт." Quote="1. В начале…" Class="0" Book="0" …/&gt;
///       &lt;/Journal&gt;
///       &lt;Journal Name="Text"/&gt;
///       &lt;Journal Name="Songs"/&gt;
///     &lt;/JournalFile&gt;
///
/// Журналів рівно три і завжди всі три, навіть порожні. Розбір навмисно свій,
/// а не XML-бібліотеки: файл пише чужа програма, і одна незакрита дужка або
/// неекранований `&amp;` не мають коштувати користувачеві всієї історії. Тут
/// незрозумілий шматок просто пропускається.
public sealed class JournalFile : IEquatable<JournalFile>
{
    /// Вкладка модулів (18), якій належить журнал.
    public enum Section { Bible, Text, Songs }

    /// Один `&lt;Item …/&gt;`. Порядок атрибутів зберігаємо: файл читають очима.
    public sealed class Item : IEquatable<Item>
    {
        private readonly List<string> keys = new();
        private readonly Dictionary<string, string> values = new(StringComparer.Ordinal);

        public IReadOnlyList<string> Keys => keys;

        public Item() { }

        public Item(IEnumerable<(string Key, string Value)> pairs)
        {
            foreach (var (key, value) in pairs) this[key] = value;
        }

        public string? this[string key]
        {
            get => values.TryGetValue(key, out var value) ? value : null;
            set
            {
                if (value == null)
                {
                    keys.RemoveAll(existing => existing == key);
                    values.Remove(key);
                    return;
                }
                if (!values.ContainsKey(key)) keys.Add(key);
                values[key] = value;
            }
        }

        public string String(string key, string fallback = "") => values.TryGetValue(key, out var value) ? value : fallback;

        public int? Int(string key) =>
            values.TryGetValue(key, out var raw) ? SwiftText.ParseInt(raw.TrimWhitespaces()) : null;

        public bool IsEmpty => keys.Count == 0;

        public Item Copy() => new(keys.Select(key => (key, values[key])));

        public bool Equals(Item? other) =>
            other is not null && keys.SequenceEqual(other.keys)
            && keys.All(key => other.values.TryGetValue(key, out var value) && value == values[key]);

        public override bool Equals(object? obj) => obj is Item other && Equals(other);
        public override int GetHashCode() => keys.Count;
    }

    /// Сире значення секції в файлі.
    public static string RawValue(Section section) => section switch
    {
        Section.Bible => "Bible",
        Section.Text => "Text",
        _ => "Songs",
    };

    /// `Section(rawValue:)`.
    public static Section? SectionFromRaw(string raw) => raw switch
    {
        "Bible" => Section.Bible,
        "Text" => Section.Text,
        "Songs" => Section.Songs,
        _ => null,
    };

    private static readonly Section[] AllSections = [Section.Bible, Section.Text, Section.Songs];

    /// Пункти за журналами. Порядок усередині журналу — порядок у файлі.
    public Dictionary<Section, List<Item>> Items { get; } = new();

    public JournalFile() { }

    [System.Runtime.CompilerServices.IndexerName("Journal")]
    public List<Item> this[Section section]
    {
        get => Items.TryGetValue(section, out var list) ? list : new List<Item>();
        set => Items[section] = value;
    }

    public bool IsEmpty => AllSections.All(section => this[section].Count == 0);

    public int TotalCount => AllSections.Sum(section => this[section].Count);

    // ── Читання ─────────────────────────────────────────────────────────────

    public static JournalFile Read(string path)
    {
        var data = File.ReadAllBytes(path);
        // Файл пише Windows-програма: там трапляється і UTF-8 з міткою
        // порядку байтів, і «кодова сторінка» без неї.
        return Parse(CodePage.Decode(data, null));
    }

    /// Чи схожий вміст на журнал. Потрібно «Завантажити план»: там в одній
    /// теці можуть лежати і файли оригіналу, і наші.
    public static bool LooksLikeJournal(string text) =>
        text.Contains("<VisioBibleJournal", StringComparison.OrdinalIgnoreCase);

    public static JournalFile Parse(string text)
    {
        var journal = new JournalFile();
        foreach (var section in AllSections) journal.Items[section] = new List<Item>();

        Section? current = null;
        var scanner = 0;

        while (true)
        {
            var open = text.IndexOf('<', scanner);
            if (open < 0) break;
            var close = text.IndexOf('>', open + 1);
            if (close < 0) break;
            var body = text[(open + 1)..close];
            scanner = close + 1;

            var trimmed = body.TrimWhitespacesAndNewlines();
            if (trimmed.Length == 0) continue;

            if (trimmed.StartsWith('/'))
            {
                // Закривальний тег. Журнал закрився — далі пункти нічиї.
                if (trimmed[1..].TrimWhitespaces().ToLowerInvariant() == "journal") current = null;
                continue;
            }
            // Коментарі, оголошення XML та інша службова розмітка.
            if (trimmed.StartsWith('?') || trimmed.StartsWith('!')) continue;

            var nameEnd = 0;
            while (nameEnd < trimmed.Length && !char.IsWhiteSpace(trimmed[nameEnd]) && trimmed[nameEnd] != '/') nameEnd++;
            var name = trimmed[..nameEnd].ToLowerInvariant();
            var item = new Item(Attributes(trimmed));
            var selfClosing = trimmed.EndsWith('/');

            switch (name)
            {
                case "journal":
                    current = SectionFromRaw(item.String("Name"));
                    // `<Journal Name="Text"/>` — порожній журнал, він же і закрився.
                    if (selfClosing) current = null;
                    break;
                case "item":
                    if (current is not { } section || item.IsEmpty) continue;
                    journal.Items[section].Add(item);
                    break;
            }
        }
        return journal;
    }

    /// Пари `Ім'я="значення"` з тіла тега.
    private static List<(string, string)> Attributes(string tag)
    {
        var result = new List<(string, string)>();
        var index = 0;

        while (index < tag.Length)
        {
            // Ім'я атрибута — до знака рівності.
            var equals = tag.IndexOf('=', index);
            if (equals < 0) break;
            var rawName = tag[index..equals].TrimWhere(c => char.IsWhiteSpace(c) || c == '/');
            // Ім'я тега стоїть перед першим атрибутом і в нього не потрапляє:
            // «Item Caption=…» — беремо останнє слово перед «=».
            var words = rawName.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            var name = words.Length > 0 ? words[^1] : "";

            var value = equals + 1;
            if (value >= tag.Length) break;
            // Значення може стояти і в подвійних, і в одинарних лапках.
            var quote = tag[value];
            if (quote != '"' && quote != '\'')
            {
                index = value;
                continue;
            }
            value += 1;
            var end = tag.IndexOf(quote, value);
            if (end < 0) break;

            if (name.Length > 0) result.Add((name, Unescape(tag[value..end])));
            index = end + 1;
        }
        return result;
    }

    // ── Запис ───────────────────────────────────────────────────────────────

    /// Той самий вигляд, що у файлів оригіналу: два пробіли на журнал, чотири на
    /// пункт, порожній журнал — самозакривним тегом.
    public string Xml()
    {
        var lines = new List<string> { "<VisioBibleJournal>" };
        foreach (var section in AllSections)
        {
            var list = this[section];
            if (list.Count == 0)
            {
                lines.Add($"  <Journal Name=\"{RawValue(section)}\"/>");
                continue;
            }
            lines.Add($"  <Journal Name=\"{RawValue(section)}\">");
            foreach (var item in list)
            {
                var pairs = item.Keys.Select(key => $"{key}=\"{Escape(item.String(key))}\"");
                lines.Add($"    <Item {string.Join(" ", pairs)}/>");
            }
            lines.Add("  </Journal>");
        }
        lines.Add("</VisioBibleJournal>");
        return string.Join("\n", lines) + "\n";
    }

    public void Write(string path)
    {
        var folder = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(folder)) Directory.CreateDirectory(folder);
        SwiftPath.WriteAtomically(path, new UTF8Encoding(false).GetBytes(Xml()));
    }

    // ── Екранування ─────────────────────────────────────────────────────────

    /// Заміна по «знаках» Swift: знак із прилиплою позначкою і пара \r\n — це
    /// один знак, і в сутність він не перетворюється (рівно як на Mac).
    internal static string Escape(string value)
    {
        var result = new StringBuilder(value.Length);
        var index = 0;
        while (index < value.Length)
        {
            var next = index + 1;
            if (value[index] == '\r' && next < value.Length && value[next] == '\n') next++;
            while (next < value.Length && SwiftText.IsMark(value[next])) next++;
            if (next - index > 1)
            {
                result.Append(value, index, next - index);
                index = next;
                continue;
            }
            switch (value[index])
            {
                case '&': result.Append("&amp;"); break;
                case '<': result.Append("&lt;"); break;
                case '>': result.Append("&gt;"); break;
                case '"': result.Append("&quot;"); break;
                case '\'': result.Append("&apos;"); break;
                // Перенос рядка всередині значення атрибута читається по-різному
                // в різних розбирачах — пишемо його числом, так надійніше.
                case '\n': result.Append("&#10;"); break;
                case '\r': result.Append("&#13;"); break;
                default: result.Append(value[index]); break;
            }
            index = next;
        }
        return result.ToString();
    }

    internal static string Unescape(string value)
    {
        if (!value.Contains('&')) return value;
        var result = new StringBuilder(value.Length);
        var index = 0;

        while (index < value.Length)
        {
            var semicolon = value[index] == '&' ? value.IndexOf(';', index) : -1;
            if (semicolon < 0 || semicolon - index > 10)
            {
                result.Append(value[index]);
                index++;
                continue;
            }
            var entity = value[(index + 1)..semicolon];
            switch (entity.ToLowerInvariant())
            {
                case "amp": result.Append('&'); break;
                case "lt": result.Append('<'); break;
                case "gt": result.Append('>'); break;
                case "quot": result.Append('"'); break;
                case "apos": result.Append('\''); break;
                default:
                    if (entity.StartsWith('#') && CharacterCode(entity[1..]) is { } code
                        && code <= 0x10FFFF && (code < 0xD800 || code > 0xDFFF))
                    {
                        result.Append(char.ConvertFromUtf32((int)code));
                    }
                    else
                    {
                        // Незрозумілий запис — лишаємо як є: краще показати
                        // «&nbsp;» у рядку, ніж втратити шматок тексту.
                        result.Append(value, index, semicolon - index + 1);
                    }
                    break;
            }
            index = semicolon + 1;
        }
        return result.ToString();
    }

    private static uint? CharacterCode(string digits)
    {
        if (digits.StartsWith('x') || digits.StartsWith('X')) return HTMLText.ParseUInt32(digits[1..], 16);
        return HTMLText.ParseUInt32(digits, 10);
    }

    /// Глибока копія (у Swift — присвоєння значення).
    public JournalFile Copy()
    {
        var copy = new JournalFile();
        foreach (var (section, list) in Items) copy.Items[section] = list.Select(item => item.Copy()).ToList();
        return copy;
    }

    public bool Equals(JournalFile? other) =>
        other is not null && AllSections.All(section => this[section].SequenceEqual(other[section]));

    public override bool Equals(object? obj) => obj is JournalFile other && Equals(other);
    public override int GetHashCode() => TotalCount;
}
