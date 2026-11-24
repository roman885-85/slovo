// =============================================================================
//  Compat.cs — сумісність: зі старими системами (як на Mac) і з поведінкою Swift
// =============================================================================
//  Compat — перенесено з Compat.swift. Решта — спільні дрібниці ядра, без яких
//  перенесення «рядок у рядок» поводилося б інакше, ніж на Mac:
//    SwiftText  — рядки так, як їх розуміє Swift/Foundation (обрізання пробілів,
//                 розбір чисел, згортання регістру й діакритики, «знаки»-графеми,
//                 сортування «як у Finder»);
//    SwiftPath  — шляхи (URL у Swift) рядками;
//    SwiftJson  — JSON того самого вигляду, що пишуть JSONEncoder/JSONDecoder;
//    ValueList  — список, що порівнюється вмістом (масиви Swift — значення).
// =============================================================================

using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Сумісність зі старими системами — на Mac від macOS 11 Big Sur.
///
/// На Mac компілятор забороняє кликати те, чого в Big Sur немає, і кожне таке
/// місце обходиться гілкою `if #available`; самоперевірка ставить вимикач і
/// ганяє старі гілки на новій системі. На Windows таких гілок немає, але
/// вимикач лишено тим самим ключем — перевірки мають однаковий вигляд.
public static class Compat
{
    /// Іти гілками для macOS 11 навіть на новій системі (`SLOVO_PRETEND_BIGSUR=1`).
    public static bool PretendsBigSur { get; set; } =
        Environment.GetEnvironmentVariable("SLOVO_PRETEND_BIGSUR") == "1";
}

/// Рядки так, як їх розуміє Swift/Foundation на Mac.
///
/// Навіщо окремо: у .NET «пробіл», «літера», «без регістру й діакритики»
/// означають трохи інше, ніж у Foundation, і перенесений розбір модулів,
/// пошуку й посилань ішов би іншими шляхами. Тут — рівно поведінка Mac,
/// звірена знак за знаком (таблиці — Compat.Tables.cs).
public static partial class SwiftText
{
    // ── Таблиці (розбираються один раз) ─────────────────────────────────────

    private const byte FlagStripAllBase = 1;     // після такої основи знімається вся діакритика
    private const byte FlagStripAllMark = 2;     // позначка, що знімається після «латинської» основи
    private const byte FlagStripCommonMark = 4;  // позначка, що знімається після будь-якої незмінної основи
    private const byte FlagExtraLetter = 8;      // літера для Swift, хоч .NET так не вважає
    private const byte FlagExtraNumber = 16;     // число для Swift (китайські цифри)

    private static readonly char[] FoldSingle = new char[65536];
    private static readonly Dictionary<char, string> FoldMulti = new();
    private static readonly byte[] Flags = new byte[65536];

    static SwiftText()
    {
        foreach (var entry in FoldData.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var colon = entry.IndexOf(':');
            var key = (char)Convert.ToInt32(entry[..colon], 16);
            var codes = entry[(colon + 1)..].Split(',');
            if (codes.Length == 1) FoldSingle[key] = (char)Convert.ToInt32(codes[0], 16);
            else FoldMulti[key] = string.Concat(codes.Select(code => (char)Convert.ToInt32(code, 16)));
        }
        Mark(StripAllBaseData, FlagStripAllBase);
        Mark(StripAllMarkData, FlagStripAllMark);
        Mark(StripCommonMarkData, FlagStripCommonMark);
        Mark(ExtraLetterData, FlagExtraLetter);
        Mark(ExtraNumberData, FlagExtraNumber);
    }

    private static void Mark(string ranges, byte flag)
    {
        foreach (var part in ranges.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var dash = part.IndexOf('-');
            var first = Convert.ToInt32(dash < 0 ? part : part[..dash], 16);
            var last = dash < 0 ? first : Convert.ToInt32(part[(dash + 1)..], 16);
            for (var code = first; code <= last; code++) Flags[code] |= flag;
        }
    }

    // ── Класи знаків ────────────────────────────────────────────────────────

    /// `CharacterSet.whitespaces`: пробіли (Zs) і табуляція — без переносів рядка.
    public static bool IsBlank(char c) =>
        c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    /// `Character.isWhitespace` (і `CharacterSet.whitespacesAndNewlines`).
    public static bool IsWhitespace(char c) => char.IsWhiteSpace(c);

    /// `Character.isNewline`: \n, \r, \v, \f, U+0085, U+2028, U+2029.
    public static bool IsNewline(char c) =>
        c is '\n' or '\r' or '\u000B' or '\u000C' or '\u0085' || c == (char)0x2028 || c == (char)0x2029;

    /// `Character.isLetter` — властивість Alphabetic: літери, римські цифри,
    /// а також огласовки івриту, арабські харакати тощо.
    public static bool IsLetter(char c)
    {
        if (char.IsLetter(c) || (Flags[c] & FlagExtraLetter) != 0) return true;
        return CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.LetterNumber;
    }

    /// `Character.isNumber`: цифри, дроби, римські й китайські числа.
    public static bool IsNumber(char c) => char.IsNumber(c) || (Flags[c] & FlagExtraNumber) != 0;

    /// Позначка, що прилипає до попереднього знака (у Swift вони — один `Character`).
    public static bool IsMark(char c)
    {
        var category = CharUnicodeInfo.GetUnicodeCategory(c);
        return category is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark
            or UnicodeCategory.EnclosingMark;
    }

    /// Клас «знака» Swift за його першим скалярем (так рахує сам Swift).
    public static bool IsLetter(string character) => FirstScalar(character, IsLetter, Rune.IsLetter);
    public static bool IsNumber(string character) => FirstScalar(character, IsNumber, Rune.IsNumber);
    public static bool IsWhitespace(string character) => FirstScalar(character, IsWhitespace, Rune.IsWhiteSpace);

    /// `Character.isPunctuation`: перший скаляр — розділовий знак (P*).
    public static bool IsPunctuation(string character) => FirstScalar(character, char.IsPunctuation, Rune.IsPunctuation);

    /// `Character.isUppercase`: один скаляр — властивість Unicode «Uppercase»
    /// (Lu і Other_Uppercase: римські цифри, літери в колі); кілька — «не
    /// міняється від верхнього регістру, але міняється від нижнього».
    public static bool IsUppercase(string character)
    {
        if (string.IsNullOrEmpty(character)) return false;
        var single = character.Length == 1
                     || (character.Length == 2 && char.IsHighSurrogate(character[0]) && char.IsLowSurrogate(character[1]));
        if (single)
        {
            var rune = Rune.GetRuneAt(character, 0);
            if (Rune.GetUnicodeCategory(rune) == UnicodeCategory.UppercaseLetter) return true;
            var value = rune.Value;
            if (value is >= 0x2160 and <= 0x216F or >= 0x24B6 and <= 0x24CF
                or >= 0x1F130 and <= 0x1F149 or >= 0x1F150 and <= 0x1F169 or >= 0x1F170 and <= 0x1F189)
                return true;
        }
        return character.ToUpperInvariant() == character && character.ToLowerInvariant() != character;
    }

    private static bool FirstScalar(string character, Func<char, bool> bmp, Func<Rune, bool> wide)
    {
        if (string.IsNullOrEmpty(character)) return false;
        if (char.IsHighSurrogate(character[0]) && Rune.TryGetRuneAt(character, 0, out var rune)) return wide(rune);
        return bmp(character[0]);
    }

    // ── Обрізання й розбиття ────────────────────────────────────────────────

    /// `trimmingCharacters(in: .whitespaces)`.
    public static string TrimWhitespaces(this string text)
    {
        var start = 0;
        var end = text.Length;
        while (start < end && IsBlank(text[start])) start++;
        while (end > start && IsBlank(text[end - 1])) end--;
        return start == 0 && end == text.Length ? text : text[start..end];
    }

    /// `trimmingCharacters(in: .whitespacesAndNewlines)`.
    public static string TrimWhitespacesAndNewlines(this string text) => text.Trim();

    /// `trimmingCharacters(in:)` з довільним набором.
    public static string TrimWhere(this string text, Func<char, bool> inSet)
    {
        var start = 0;
        var end = text.Length;
        while (start < end && inSet(text[start])) start++;
        while (end > start && inSet(text[end - 1])) end--;
        return text[start..end];
    }

    /// `trimmingCharacters(in: CharacterSet(charactersIn: …))`.
    public static string TrimCharacters(this string text, string set) => text.Trim(set.ToCharArray());

    /// `split(whereSeparator: \.isNewline)` — порожні шматки відкидаються.
    public static string[] SplitLines(this string text)
    {
        var lines = new List<string>();
        var start = 0;
        for (var index = 0; index <= text.Length; index++)
        {
            if (index < text.Length && !IsNewline(text[index])) continue;
            if (index > start) lines.Add(text[start..index]);
            start = index + 1;
        }
        return lines.ToArray();
    }

    /// `components(separatedBy: .newlines)` — порожні шматки лишаються
    /// (\r\n тут — дві межі, як і в Foundation).
    public static string[] ComponentsSeparatedByNewlines(this string text)
    {
        var parts = new List<string>();
        var start = 0;
        for (var index = 0; index < text.Length; index++)
        {
            if (!IsNewline(text[index])) continue;
            parts.Add(text[start..index]);
            start = index + 1;
        }
        parts.Add(text[start..]);
        return parts.ToArray();
    }

    // ── Числа ───────────────────────────────────────────────────────────────

    /// `Int(String)` Swift: необов'язковий знак і цифри ASCII, без пробілів.
    public static int? ParseInt(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        return long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value)
               && value is >= int.MinValue and <= int.MaxValue
            ? (int)value
            : null;
    }

    /// `Double(String)` Swift: без пробілів по краях; «inf», «nan» — теж числа.
    public static double? ParseDouble(string? text)
    {
        if (string.IsNullOrEmpty(text)) return null;
        if (char.IsWhiteSpace(text[0]) || char.IsWhiteSpace(text[^1])) return null;
        var lower = text.ToLowerInvariant();
        var sign = lower.StartsWith('-') ? -1.0 : 1.0;
        var body = lower.TrimStart('+', '-');
        if (body is "inf" or "infinity") return sign * double.PositiveInfinity;
        if (body == "nan") return double.NaN;
        return double.TryParse(text, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint
                                     | NumberStyles.AllowExponent, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;
    }

    // ── «Знаки» Swift (графеми) ─────────────────────────────────────────────

    /// `Array(string)`: розбивка на графеми, як `Character` у Swift.
    public static string[] Characters(string text)
    {
        var result = new List<string>(text.Length);
        var index = 0;
        while (index < text.Length)
        {
            var length = StringInfo.GetNextTextElementLength(text, index);
            if (length <= 0) length = 1;
            result.Add(text.Substring(index, length));
            index += length;
        }
        return result.ToArray();
    }

    /// `string.count` — число графем.
    public static int CharacterCount(string text)
    {
        var count = 0;
        var index = 0;
        while (index < text.Length)
        {
            var length = StringInfo.GetNextTextElementLength(text, index);
            index += length <= 0 ? 1 : length;
            count++;
        }
        return count;
    }

    /// Зсув (у знаках UTF-16), на якому закінчуються перші `count` графем.
    public static int CharacterOffset(string text, int count)
    {
        var index = 0;
        for (var taken = 0; taken < count && index < text.Length; taken++)
        {
            var length = StringInfo.GetNextTextElementLength(text, index);
            index += length <= 0 ? 1 : length;
        }
        return index;
    }

    /// `String(text.prefix(n))` — перші n графем.
    public static string PrefixCharacters(string text, int count) => text[..CharacterOffset(text, count)];

    /// `text.hasPrefix(prefix)` Swift: «знаки» порівнюються як знаки (складене
    /// і розкладене «š» — одне), і збіг мусить кінчатися на межі знака.
    public static bool HasPrefix(string text, string prefix)
    {
        if (prefix.Length == 0) return true;
        if (text.StartsWith(prefix, StringComparison.Ordinal) && IsCharacterBoundary(text, prefix.Length)) return true;
        var composedText = text.Normalize(NormalizationForm.FormC);
        var composedPrefix = prefix.Normalize(NormalizationForm.FormC);
        return composedText.StartsWith(composedPrefix, StringComparison.Ordinal)
               && IsCharacterBoundary(composedText, composedPrefix.Length);
    }

    /// Чи стоїть зсув на межі «знаків» Swift (графем).
    public static bool IsCharacterBoundary(string text, int offset)
    {
        if (offset <= 0 || offset >= text.Length) return true;
        var index = 0;
        while (index < offset)
        {
            var length = StringInfo.GetNextTextElementLength(text, index);
            index += length <= 0 ? 1 : length;
        }
        return index == offset;
    }

    /// `String(text.dropFirst(n))`.
    public static string DropFirstCharacters(string text, int count) => text[CharacterOffset(text, count)..];

    // ── Згортання регістру й діакритики ─────────────────────────────────────

    /// `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`.
    ///
    /// Не «нижній регістр без позначок» .NET, а рівно Foundation: «й» → «и»,
    /// «ї» → «і», «ё» → «е», «ß» → «ss», «ﬁ» → «fi»; наголос після кирилиці
    /// знімається, а огласовки після літер івриту — лишаються.
    public static string Fold(string text) => Fold(text, null);

    /// `folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)`:
    /// те саме, що `Fold`, плюс повноширинні й напівширинні форми («Ａ» → «a»,
    /// «ｶ» → «カ») — таблиця знята з macOS.
    public static string FoldIgnoringWidth(string text)
    {
        StringBuilder? widened = null;
        for (var index = 0; index < text.Length; index++)
        {
            var c = text[index];
            if (c < '\uFF01' || c > '\uFFEE' || !WidthFold.Value.TryGetValue(c, out var replacement))
            {
                widened?.Append(c);
                continue;
            }
            widened ??= new StringBuilder(text, 0, index, text.Length);
            widened.Append(replacement);
        }
        return Fold(widened?.ToString() ?? text);
    }

    private static readonly Lazy<Dictionary<char, string>> WidthFold = new(() =>
    {
        var map = new Dictionary<char, string>();
        foreach (var entry in WidthFoldData.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var colon = entry.IndexOf(':');
            var key = (char)Convert.ToInt32(entry[..colon], 16);
            map[key] = string.Concat(entry[(colon + 1)..].Split(',').Select(code => (char)Convert.ToInt32(code, 16)));
        }
        return map;
    });

    /// Згортання з картою: для кожного знака результату — графема-джерело.
    internal static string Fold(string text, FoldMap? map)
    {
        var output = new StringBuilder(text.Length);
        var index = 0;
        while (index < text.Length)
        {
            var clusterStart = index;
            var before = output.Length;
            string folded;
            int baseLength;
            if (char.IsHighSurrogate(text[index]) && index + 1 < text.Length && char.IsLowSurrogate(text[index + 1]))
            {
                var rune = new Rune(text[index], text[index + 1]);
                folded = Rune.ToLowerInvariant(rune).ToString();
                baseLength = 2;
            }
            else
            {
                folded = FoldChar(text[index]);
                baseLength = 1;
            }
            output.Append(folded);
            index += baseLength;

            // Позначки після основи — та сама графема. Що з них зняти, вирішує основа.
            var first = folded.Length > 0 ? folded[0] : text[clusterStart];
            var changed = baseLength == 1 ? folded.Length != 1 || folded[0] != text[clusterStart] : false;
            var mode = (Flags[first] & FlagStripAllBase) != 0 ? FlagStripAllMark
                : changed ? (byte)0 : FlagStripCommonMark;
            while (index < text.Length && IsMark(text[index]))
            {
                var mark = text[index];
                if (mode == 0 || (Flags[mark] & mode) == 0) output.Append(FoldChar(mark));
                index++;
            }
            map?.Add(clusterStart, index, output.Length - before);
        }
        return output.ToString();
    }

    private static string FoldChar(char c)
    {
        var single = FoldSingle[c];
        if (single != '\0') return single.ToString();
        return FoldMulti.TryGetValue(c, out var multi) ? multi : c.ToString();
    }

    /// Карта згорнутого рядка: звідки взявся кожен його знак.
    internal sealed class FoldMap
    {
        public readonly List<int> Start = new();      // початок графеми-джерела
        public readonly List<int> End = new();        // кінець графеми-джерела
        public readonly List<bool> First = new();     // перший знак своєї графеми
        public readonly List<bool> Last = new();      // останній знак своєї графеми

        public void Add(int start, int end, int count)
        {
            for (var i = 0; i < count; i++)
            {
                Start.Add(start);
                End.Add(end);
                First.Add(i == 0);
                Last.Add(i == count - 1);
            }
        }
    }

    /// `text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: from..<end)`.
    ///
    /// Межі — у знаках UTF-16 вихідного рядка. Збіг мусить починатися й
    /// закінчуватися на межі графем: «s» не знаходиться всередині «ß» (= «ss»),
    /// а «е» знаходить «ё» цілком.
    public static (int Start, int End)? RangeOfFolded(string text, string needle, int from = 0)
    {
        var all = FoldedSearch.Prepare(text);
        return all.Find(Fold(needle), from);
    }

    /// Підготовлений до пошуку рядок: згорнута копія і карта назад.
    public sealed class FoldedSearch
    {
        private readonly string folded;
        private readonly FoldMap map;

        private FoldedSearch(string folded, FoldMap map)
        {
            this.folded = folded;
            this.map = map;
        }

        public static FoldedSearch Prepare(string text)
        {
            var map = new FoldMap();
            var folded = Fold(text, map);
            return new FoldedSearch(folded, map);
        }

        /// Перший збіг уже згорнутої голки, що починається не раніше `from`.
        public (int Start, int End)? Find(string foldedNeedle, int from)
        {
            if (foldedNeedle.Length == 0) return null;
            var position = 0;
            while (position < map.Start.Count && map.Start[position] < from) position++;
            while (position <= folded.Length - foldedNeedle.Length)
            {
                var hit = folded.IndexOf(foldedNeedle, position, StringComparison.Ordinal);
                if (hit < 0) return null;
                var last = hit + foldedNeedle.Length - 1;
                if (map.First[hit] && map.Last[last]) return (map.Start[hit], map.End[last]);
                position = hit + 1;
            }
            return null;
        }
    }

    // ── Порівняння ──────────────────────────────────────────────────────────

    /// `localizedStandardCompare` — порядок «як у Finder»: без регістру, числа за величиною.
    public static int LocalizedStandardCompare(string left, string right)
    {
        var compare = CultureInfo.CurrentCulture.CompareInfo;
        var result = compare.Compare(left, right,
            CompareOptions.IgnoreCase | CompareOptions.IgnoreWidth | CompareOptions.NumericOrdering);
        if (result != 0) return result;
        // `.forcedOrdering` Foundation: рядки, рівні без регістру, однаково
        // впорядковуються — мала літера раніше великої («К тебе» перед «К Тебе»),
        // як у Finder. Звірено на 3400 назвах пісенника.
        result = compare.Compare(left, right, CompareOptions.IgnoreWidth | CompareOptions.NumericOrdering);
        return result != 0 ? result : string.CompareOrdinal(left, right);
    }

    /// Порівнювач для сортування «як у Finder».
    public static readonly IComparer<string> StandardOrder =
        Comparer<string>.Create(LocalizedStandardCompare);

    /// `caseInsensitiveCompare(…) == .orderedSame`.
    public static bool SameIgnoringCase(string left, string right) =>
        string.Equals(left, right, StringComparison.OrdinalIgnoreCase);

    /// Рядки рівні так, як їх рівняє Swift: «й» складене і розкладене — одне й те саме.
    public static bool Same(string left, string right) =>
        string.Equals(left, right, StringComparison.Ordinal)
        || string.Equals(left.Normalize(NormalizationForm.FormC), right.Normalize(NormalizationForm.FormC),
                         StringComparison.Ordinal);
}

/// Відсоткове кодування так, як його робить Foundation.
public static class SwiftUrl
{
    /// `CharacterSet.urlPathAllowed` (знято з macOS): лише ASCII, без «:», «?», «#», «%».
    public const string PathAllowed = "!$&'()*+,-./0123456789;=@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~";

    /// `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed[.subtracting(except)])`:
    /// усе поза набором — байтами UTF-8 «%XX» великими літерами.
    public static string AddingPercentEncodingForPath(string text, string except = "")
    {
        var output = new StringBuilder(text.Length);
        Span<byte> bytes = stackalloc byte[4];
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value < 128 && PathAllowed.Contains((char)rune.Value) && !except.Contains((char)rune.Value))
            {
                output.Append((char)rune.Value);
                continue;
            }
            var count = rune.EncodeToUtf8(bytes);
            for (var i = 0; i < count; i++) output.Append('%').Append(bytes[i].ToString("X2"));
        }
        return output.ToString();
    }

    /// `removingPercentEncoding`: null, якщо «%» без двох шістнадцяткових цифр
    /// або розкодовані байти — не UTF-8.
    public static string? RemovingPercentEncoding(string text)
    {
        if (!text.Contains('%')) return text;
        var bytes = new List<byte>(text.Length);
        var raw = Encoding.UTF8.GetBytes(text);
        for (var i = 0; i < raw.Length; i++)
        {
            if (raw[i] != (byte)'%')
            {
                bytes.Add(raw[i]);
                continue;
            }
            if (i + 2 >= raw.Length || !Uri.IsHexDigit((char)raw[i + 1]) || !Uri.IsHexDigit((char)raw[i + 2])) return null;
            bytes.Add(Convert.ToByte(Encoding.ASCII.GetString(raw, i + 1, 2), 16));
            i += 2;
        }
        return CodePage.TryDecode(bytes.ToArray(), CodePage.Utf8);
    }
}

/// Шляхи — у Swift це `URL`, тут рядки (System.IO.Path).
public static class SwiftPath
{
    /// `fileExists(atPath:)` — і файл, і тека.
    public static bool Exists(string path) => File.Exists(path) || Directory.Exists(path);

    public static bool IsDirectory(string path) => Directory.Exists(path);

    /// `appendingPathComponent` для хвоста з «/» усередині.
    public static string Append(string folder, string tail)
    {
        if (tail.Length == 0) return folder;
        var native = tail.Replace('/', Path.DirectorySeparatorChar);
        return Path.Combine(folder, native.TrimStart(Path.DirectorySeparatorChar));
    }

    /// `lastPathComponent`.
    public static string LastComponent(string path)
    {
        var trimmed = path.TrimEnd('/', Path.DirectorySeparatorChar);
        return trimmed.Length == 0 ? path : Path.GetFileName(trimmed);
    }

    /// `deletingLastPathComponent()`.
    public static string Parent(string path)
    {
        var trimmed = path.TrimEnd('/', Path.DirectorySeparatorChar);
        return Path.GetDirectoryName(trimmed) ?? trimmed;
    }

    /// `pathExtension` — без крапки, порожньо, якщо немає.
    public static string Extension(string path)
    {
        var name = LastComponent(path);
        var dot = name.LastIndexOf('.');
        return dot <= 0 ? "" : name[(dot + 1)..];
    }

    /// `deletingPathExtension()`.
    public static string DeletingExtension(string path)
    {
        var name = LastComponent(path);
        var dot = name.LastIndexOf('.');
        if (dot <= 0) return path;
        var parent = Path.GetDirectoryName(path.TrimEnd('/', Path.DirectorySeparatorChar));
        var stem = name[..dot];
        return string.IsNullOrEmpty(parent) ? stem : Path.Combine(parent, stem);
    }

    /// `standardizedFileURL.path`.
    public static string Standardized(string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            return full.Length > 1 ? full.TrimEnd('/', Path.DirectorySeparatorChar) : full;
        }
        catch
        {
            return path;
        }
    }

    /// Шлях повний? На Mac — початкова «/». На Windows додаються «C:/…» і «//сервер».
    public static bool IsAbsolute(string unixLike) =>
        unixLike.StartsWith('/')
        || (unixLike.Length >= 3 && char.IsAsciiLetter(unixLike[0]) && unixLike[1] == ':' && (unixLike[2] == '/' || unixLike[2] == '\\'))
        || unixLike.StartsWith(@"\\", StringComparison.Ordinal);

    /// `contentsOfDirectory(…, options: [.skipsHiddenFiles])` — повні шляхи.
    public static string[] Contents(string folder, bool skipsHidden)
    {
        try
        {
            var entries = Directory.EnumerateFileSystemEntries(folder);
            if (skipsHidden) entries = entries.Where(path => !IsHidden(path));
            return entries.ToArray();
        }
        catch
        {
            return Array.Empty<string>();
        }
    }

    /// `contentsOfDirectory(atPath:)` — лише імена, приховані теж.
    public static string[]? Names(string folder)
    {
        try
        {
            return Directory.EnumerateFileSystemEntries(folder).Select(Path.GetFileName).Select(n => n!).ToArray();
        }
        catch
        {
            return null;
        }
    }

    /// Прихований файл: ім'я з крапки (як на Mac) або позначка Windows.
    public static bool IsHidden(string path)
    {
        if (LastComponent(path).StartsWith('.')) return true;
        try
        {
            return (File.GetAttributes(path) & FileAttributes.Hidden) != 0;
        }
        catch
        {
            return false;
        }
    }

    /// `write(to:options: .atomic)` — через тимчасовий файл поруч.
    public static void WriteAtomically(string path, byte[] data)
    {
        var folder = Path.GetDirectoryName(Path.GetFullPath(path)) ?? ".";
        var temporary = Path.Combine(folder, "." + Path.GetFileName(path) + "." + Guid.NewGuid().ToString("N") + ".tmp");
        File.WriteAllBytes(temporary, data);
        try
        {
            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            try { File.Delete(temporary); } catch { }
            throw;
        }
    }
}

/// Список, що порівнюється вмістом: масив Swift — значення, а `List<T>` — посилання.
public sealed class ValueList<T> : List<T>, IEquatable<ValueList<T>>
{
    public ValueList() { }
    public ValueList(IEnumerable<T> items) : base(items) { }

    public bool Equals(ValueList<T>? other) => other is not null && this.SequenceEqual(other);
    public override bool Equals(object? obj) => obj is ValueList<T> other && Equals(other);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var item in this) hash.Add(item);
        return hash.ToHashCode();
    }
}

/// JSON того самого вигляду, що пишуть `JSONEncoder`/`JSONDecoder` на Mac.
///
/// Читання суворе, як у Swift: обов'язкове поле, якого немає, або чуже значення
/// перелічення — помилка цілого файла (а не тихе «за умовчанням»). Запис —
/// `"ключ" : значення` з двома пробілами відступу (`.prettyPrinted`), за
/// потреби з відсортованими ключами (`.sortedKeys`), і «/» як «\/».
public static class SwiftJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        RespectNullableAnnotations = true,
        RespectRequiredConstructorParameters = true,
        NumberHandling = JsonNumberHandling.Strict,
        ReadCommentHandling = JsonCommentHandling.Disallow,
        AllowTrailingCommas = false,
        IncludeFields = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        Converters = { new SwiftUuidConverter() },
    };

    /// `JSONEncoder().encode(value)` рядком.
    public static string Encode<T>(T value, bool pretty = false, bool sortedKeys = false, bool escapeSlashes = true) =>
        Write(JsonSerializer.SerializeToNode(value, Options), pretty, sortedKeys, escapeSlashes);

    public static byte[] EncodeBytes<T>(T value, bool pretty = false, bool sortedKeys = false, bool escapeSlashes = true) =>
        new UTF8Encoding(false).GetBytes(Encode(value, pretty, sortedKeys, escapeSlashes));

    /// `JSONDecoder().decode(T.self, from: data)` — кидає виняток, як `try`.
    public static T Decode<T>(byte[] data) =>
        JsonSerializer.Deserialize<T>(data, Options) ?? throw new JsonException("null");

    /// `try? JSONDecoder().decode(…)`.
    public static T? TryDecode<T>(byte[] data) where T : class
    {
        try { return Decode<T>(data); }
        catch { return null; }
    }

    /// Запис дерева JSON у вигляді Foundation.
    public static string Write(JsonNode? node, bool pretty, bool sortedKeys, bool escapeSlashes = true)
    {
        var output = new StringBuilder();
        WriteNode(output, node, 0, pretty, sortedKeys, escapeSlashes);
        return output.ToString();
    }

    private static void WriteNode(StringBuilder output, JsonNode? node, int indent, bool pretty, bool sorted, bool slashes)
    {
        switch (node)
        {
            case null:
                output.Append("null");
                return;
            case JsonObject obj:
            {
                var members = obj.ToList();
                if (sorted) members.Sort((a, b) => KeyOrder(a.Key, b.Key));
                if (members.Count == 0)
                {
                    output.Append(pretty ? "{\n\n" + new string(' ', indent) + "}" : "{}");
                    return;
                }
                output.Append(pretty ? "{\n" : "{");
                for (var i = 0; i < members.Count; i++)
                {
                    if (i > 0) output.Append(pretty ? ",\n" : ",");
                    if (pretty) output.Append(' ', indent + 2);
                    WriteString(output, members[i].Key, slashes);
                    output.Append(pretty ? " : " : ":");
                    WriteNode(output, members[i].Value, indent + 2, pretty, sorted, slashes);
                }
                if (pretty) output.Append('\n').Append(' ', indent);
                output.Append('}');
                return;
            }
            case JsonArray array:
            {
                if (array.Count == 0)
                {
                    output.Append(pretty ? "[\n\n" + new string(' ', indent) + "]" : "[]");
                    return;
                }
                output.Append(pretty ? "[\n" : "[");
                for (var i = 0; i < array.Count; i++)
                {
                    if (i > 0) output.Append(pretty ? ",\n" : ",");
                    if (pretty) output.Append(' ', indent + 2);
                    WriteNode(output, array[i], indent + 2, pretty, sorted, slashes);
                }
                if (pretty) output.Append('\n').Append(' ', indent);
                output.Append(']');
                return;
            }
            default:
            {
                var kind = node.GetValueKind();
                switch (kind)
                {
                    case JsonValueKind.String:
                        WriteString(output, node.GetValue<string>(), slashes);
                        return;
                    case JsonValueKind.Number:
                        output.Append(Number(node.ToJsonString()));
                        return;
                    case JsonValueKind.True:
                        output.Append("true");
                        return;
                    case JsonValueKind.False:
                        output.Append("false");
                        return;
                    default:
                        output.Append("null");
                        return;
                }
            }
        }
    }

    /// Число так, як його пише Foundation: ціле — без крапки, дробове — найкоротше.
    private static string Number(string raw)
    {
        if (raw.IndexOfAny(['.', 'e', 'E']) < 0) return raw;
        if (!double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) return raw;
        if (Math.Floor(value) == value && Math.Abs(value) < 1e15)
            return ((long)value).ToString(CultureInfo.InvariantCulture);
        return value.ToString("R", CultureInfo.InvariantCulture).Replace("E", "e");
    }

    private static void WriteString(StringBuilder output, string text, bool slashes)
    {
        output.Append('"');
        foreach (var c in text)
        {
            switch (c)
            {
                case '"': output.Append("\\\""); break;
                case '\\': output.Append("\\\\"); break;
                case '/': output.Append(slashes ? "\\/" : "/"); break;
                case '\n': output.Append("\\n"); break;
                case '\r': output.Append("\\r"); break;
                case '\t': output.Append("\\t"); break;
                case '\b': output.Append("\\b"); break;
                case '\f': output.Append("\\f"); break;
                default:
                    if (c < 0x20) output.Append("\\u").Append(((int)c).ToString("x4"));
                    else output.Append(c);
                    break;
            }
        }
        output.Append('"');
    }

    /// Порядок ключів `.sortedKeys`: побайтово, з урахуванням регістру
    /// («EnableParamsVariant» раніше за «Enabled») — звірено з виводом macOS.
    private static int KeyOrder(string left, string right) => string.CompareOrdinal(left, right);
}

/// `UUID` у JSON Swift — рядок ВЕЛИКИМИ літерами («DBA9AB16-2069-…»).
public sealed class SwiftUuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String && Guid.TryParseExact(reader.GetString(), "D", out var value)
            ? value
            : throw new JsonException("UUID: очікувався рядок виду XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX");

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

/// Перелічення з цілим сирим значенням (`enum X: Int, Codable`): у JSON — число,
/// чуже число — помилка, як у Swift.
public sealed class SwiftIntEnumConverter<T> : JsonConverter<T> where T : struct, Enum
{
    public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType != JsonTokenType.Number || !reader.TryGetInt64(out var raw))
            throw new JsonException($"{typeof(T).Name}: очікувалося ціле число");
        var value = (T)Enum.ToObject(typeof(T), raw);
        if (!Enum.IsDefined(value)) throw new JsonException($"{typeof(T).Name}: немає значення {raw}");
        return value;
    }

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(Convert.ToInt64(value, CultureInfo.InvariantCulture));
}

/// Перелічення з рядковим сирим значенням (`enum X: String, Codable`): у JSON —
/// рядок з `[JsonStringEnumMemberName]`, число не приймається.
public sealed class SwiftStringEnumConverter<T> : JsonStringEnumConverter<T> where T : struct, Enum
{
    public SwiftStringEnumConverter() : base(null, allowIntegerValues: false) { }
}
