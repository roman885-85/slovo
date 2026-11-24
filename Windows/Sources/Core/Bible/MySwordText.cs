// =============================================================================
//  MySwordText.cs — вірш MySword (GBF) → текст (з Bible/MySwordText.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Перетворення вірша MySword на текст для показу.
///
/// Розмітка тут не HTML, а GBF у дусі theWord: закривальний тег відрізняється
/// від відкривального лише регістром літер після першої — `<TS>` … `<Ts>`,
/// `<FI>` … `<Fi>`, — а скісної риски немає зовсім. Тому спільний
/// `HTMLText.Plain` тут не годиться. Звідси свій лінійний прохід.
public static class MySwordText
{
    /// Парний тег, у якого викидається і вміст.
    private enum Pair
    {
        Footnote,          // <RF>…<Rf> — примітка перекладача
        Heading,           // <TS>…<Ts> — заголовок розділу всередині вірша
        Transliteration,   // <X>…<x> — латинський запис слова підрядника
    }

    private static Pair? Opening(string name)
    {
        if (name == "RF") return Pair.Footnote;
        if (name == "X") return Pair.Transliteration;
        if (name.StartsWith("TS", StringComparison.Ordinal) && name[2..].All(SwiftText.IsNumber)) return Pair.Heading;
        return null;
    }

    private static bool Closes(Pair pair, string name) => pair switch
    {
        Pair.Footnote => name == "Rf",
        Pair.Transliteration => name == "x",
        _ => name.StartsWith("Ts", StringComparison.Ordinal) && name[2..].All(SwiftText.IsNumber),
    };

    /// Ліворуч від викинутого тега пробіл не потрібен: слово ще не почалося.
    private static readonly HashSet<char> OpeningChars = ['(', '[', '«', '„', ' ', '"', '\''];
    /// Праворуч від викинутого тега пробіл не потрібен: далі розділовий знак.
    private static readonly HashSet<char> ClosingChars =
        [',', '.', ';', ':', '!', '?', ')', ']', '»', '…', '—', '-', ' ', '"', '\''];

    public static string Plain(string raw)
    {
        var output = new StringBuilder(raw.Length);
        var index = 0;
        Pair? skipUntil = null;

        while (index < raw.Length)
        {
            var ch = raw[index];
            if (ch != '<')
            {
                if (skipUntil == null) output.Append(ch);
                index++;
                continue;
            }

            var close = raw.IndexOf('>', index);
            if (close < 0)
            {
                // Незакрита дужка в кінці — далі розмітки вже немає.
                if (skipUntil == null) output.Append(raw, index, raw.Length - index);
                break;
            }

            var name = TagName(raw, index + 1, close);
            index = close + 1;

            if (skipUntil is { } pair)
            {
                if (Closes(pair, name)) skipUntil = null;
                continue;
            }
            if (Opening(name) is { } opening)
            {
                skipUntil = opening;
                continue;
            }
            // `<D>` ділить префікс і корінь УСЕРЕДИНІ одного єврейського слова.
            if (name == "D") continue;

            // Усі інші теги викидаємо, вміст лишаємо. Пробіл на місце тега
            // ставимо лише там, де інакше злиплися б два слова.
            if (output.Length > 0 && index < raw.Length)
            {
                var left = output[^1];
                var right = raw[index];
                if (!OpeningChars.Contains(left) && !ClosingChars.Contains(right)) output.Append(' ');
            }
        }

        // Незакритий парний тег решту вірша вже з'їв — так і треба: втратити
        // хвіст краще, ніж показати виноску як слова Писання.
        return HTMLText.CondensedWhitespace(HTMLText.DecodeEntities(output.ToString()));
    }

    /// Ім'я тега — до першого пробілу або скісної риски, регістр не чіпаємо.
    private static string TagName(string raw, int start, int end)
    {
        var stop = start;
        while (stop < end && raw[stop] != ' ' && raw[stop] != '\t' && raw[stop] != '\n' && raw[stop] != '/') stop++;
        return raw[start..stop];
    }
}
