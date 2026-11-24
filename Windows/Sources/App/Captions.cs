// =============================================================================
//  Captions.cs — підписи інтерфейсу
// =============================================================================
//  Підписи беруться з тих самих місць, що на Mac: наш словник (OurWords —
//  російський текст як ключ, переклад українською/англійською) і файли
//  перекладу автора (`Language/*.lng`, форма MainForm). Поки ядро
//  перекладів не під'єднано, видно запасний текст.
// =============================================================================

namespace Slovo.App;

public static class Captions
{
    /// Переклад нашого підпису (ключ — російський текст, як у Mac-коді).
    public static Func<string, string> Translate = text => text;
    /// Підпис елемента форми автора: (ключ, форма, запасний) → текст.
    public static Func<string, string, string, string> FormCaption = (key, form, fallback) => Translate(fallback);
    /// Підказка елемента форми автора (у кнопок автора весь текст буває в підказці).
    public static Func<string, string, string?> FormHint = (key, form) => null;

    public static string T(string text) => Translate(text);
    public static string T(string text, params object[] args)
    {
        var s = Translate(text);
        // У Mac-коді підстановки — `%s`/`%d`.
        foreach (var a in args)
        {
            var i = s.IndexOf("%s", StringComparison.Ordinal);
            var j = s.IndexOf("%d", StringComparison.Ordinal);
            var k = i < 0 ? j : j < 0 ? i : Math.Min(i, j);
            if (k < 0) break;
            s = s[..k] + a + s[(k + 2)..];
        }
        return s;
    }

    /// Підпис форми MainForm (як `NativeTopCaptions.caption` на Mac).
    public static string Caption(string key, string fallback) => FormCaption(key, "MainForm", fallback);
    public static string MainHint(string key, string fallback) => FormHint(key, "MainForm") ?? T(fallback);
}
