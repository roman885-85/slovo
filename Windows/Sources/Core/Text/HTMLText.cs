// =============================================================================
//  HTMLText.cs — фрагмент HTML модуля → чистий текст (з Text/HTMLText.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Перетворення фрагмента HTML з модуля на чистий текст.
///
/// Модулі писалися вручну і роками, тому повноцінний HTML-парсер тут
/// був би і повільнішим, і вередливішим за потрібне: розмітка зводиться до кількох
/// інлайнових тегів. Досить лінійного проходу.
public static class HTMLText
{
    private static readonly HashSet<string> StrongOnly = new(StringComparer.Ordinal) { "s" };

    /// <param name="dropContentOf">теги, у яких викидається і вміст
    /// (так прибираються номери Стронга `&lt;s&gt;7225&lt;/s&gt;`), а не лише самі дужки.</param>
    public static string Plain(string html, IReadOnlySet<string>? dropContentOf = null) =>
        Plain(html, 0, html.Length, dropContentOf ?? StrongOnly);

    /// Те саме для шматка рядка `[start, end)` — без копіювання шматка.
    public static string Plain(string html, int start, int end, IReadOnlySet<string> dropContentOf)
    {
        var output = new StringBuilder(end - start);
        var index = start;
        string? skipUntilCloseOf = null;

        while (index < end)
        {
            var ch = html[index];
            if (ch != '<')
            {
                if (skipUntilCloseOf == null) output.Append(ch);
                index++;
                continue;
            }

            var close = html.IndexOf('>', index, end - index);
            if (close < 0)
            {
                // Незакрита дужка в кінці файла — далі вже немає розмітки.
                if (skipUntilCloseOf == null) output.Append(html, index, end - index);
                break;
            }

            var bodyStart = index + 1;
            var bodyLength = close - bodyStart;
            var name = TagName(html, bodyStart, bodyLength);
            var closing = bodyLength > 0 && html[bodyStart] == '/';
            var selfClosing = bodyLength > 0 && html[close - 1] == '/';

            if (skipUntilCloseOf != null)
            {
                if (closing && name == skipUntilCloseOf) skipUntilCloseOf = null;
            }
            else if (!closing && !selfClosing && dropContentOf.Contains(name))
            {
                skipUntilCloseOf = name;
            }
            else if (IsBreak(name))
            {
                output.Append(' ');
            }

            index = close + 1;
        }

        return CondensedWhitespace(DecodeEntities(output.ToString()).Replace(ZeroWidthSpace, ""));
    }

    private static readonly string ZeroWidthSpace = ((char)0x200B).ToString();

    private static string TagName(string html, int start, int length)
    {
        var position = start;
        var end = start + length;
        if (position < end && html[position] == '/') position++;
        var stop = position;
        while (stop < end && html[stop] != ' ' && html[stop] != '\t' && html[stop] != '/' && html[stop] != '\n') stop++;
        return html[position..stop].ToLowerInvariant();
    }

    private static bool IsBreak(string name) =>
        name is "br" or "p" or "div" or "pb" or "td" or "tr";

    private static readonly Dictionary<string, string> NamedEntities = new(StringComparer.Ordinal)
    {
        ["nbsp"] = ((char)0x00A0).ToString(), ["amp"] = "&", ["lt"] = "<", ["gt"] = ">", ["quot"] = "\"",
        ["apos"] = "'", ["mdash"] = "—", ["ndash"] = "–", ["hellip"] = "…", ["laquo"] = "«", ["raquo"] = "»",
    };

    public static string DecodeEntities(string text)
    {
        if (!text.Contains('&')) return text;
        var output = new StringBuilder(text.Length);

        var index = 0;
        while (index < text.Length)
        {
            if (text[index] != '&')
            {
                output.Append(text[index]);
                index++;
                continue;
            }
            // Крапка з комою — у межах дванадцяти знаків від «&» (сам «&» теж рахується).
            var window = Math.Min(12, text.Length - index);
            var semi = text.IndexOf(';', index, window);
            if (semi < 0)
            {
                output.Append('&');
                index++;
                continue;
            }

            var body = text[(index + 1)..semi];
            if (body.StartsWith('#'))
            {
                var digits = body[1..];
                var scalar = digits.StartsWith('x') || digits.StartsWith('X')
                    ? ParseUInt32(digits[1..], 16)
                    : ParseUInt32(digits, 10);
                if (scalar is { } code && code <= 0x10FFFF && (code < 0xD800 || code > 0xDFFF))
                {
                    output.Append(char.ConvertFromUtf32((int)code));
                    index = semi + 1;
                    continue;
                }
            }
            else if (NamedEntities.TryGetValue(body.ToLowerInvariant(), out var replacement))
            {
                output.Append(replacement);
                index = semi + 1;
                continue;
            }

            output.Append('&');
            index++;
        }
        return output.ToString();
    }

    /// `UInt32(text, radix:)` Swift: необов'язковий «+», далі лише цифри основи.
    internal static uint? ParseUInt32(string text, int radix)
    {
        if (text.StartsWith('+')) text = text[1..];
        if (text.Length == 0) return null;
        ulong value = 0;
        foreach (var c in text)
        {
            int digit;
            if (c is >= '0' and <= '9') digit = c - '0';
            else if (c is >= 'a' and <= 'z') digit = c - 'a' + 10;
            else if (c is >= 'A' and <= 'Z') digit = c - 'A' + 10;
            else return null;
            if (digit >= radix) return null;
            value = value * (ulong)radix + (ulong)digit;
            if (value > uint.MaxValue) return null;
        }
        return (uint)value;
    }

    /// Схлопує будь-які пробільні послідовності в один пробіл (`condensedWhitespace()`).
    ///
    /// Пробільний «знак» Swift — разом із позначками, що до нього прилипли:
    /// вони зникають разом із ним, як і на Mac.
    public static string CondensedWhitespace(string text)
    {
        var output = new StringBuilder(text.Length);
        var lastWasSpace = false;
        var index = 0;
        while (index < text.Length)
        {
            var ch = text[index];
            var next = index + 1;
            while (next < text.Length && SwiftText.IsMark(text[next])) next++;
            if (char.IsWhiteSpace(ch))
            {
                if (!lastWasSpace && output.Length > 0) output.Append(' ');
                lastWasSpace = true;
            }
            else
            {
                output.Append(text, index, next - index);
                lastWasSpace = false;
            }
            index = next;
        }
        var length = output.Length;
        while (length > 0 && output[length - 1] == ' ') length--;
        return output.ToString(0, length);
    }
}
