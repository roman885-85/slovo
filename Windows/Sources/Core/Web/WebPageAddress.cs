// =============================================================================
//  WebPageAddress.cs — адреси веб-сторінок (з SlovoCore/Web/WebPageAddress.swift)
// =============================================================================
//  Ім'я файла сторінки стає адресою: кирилиця латиницею за правилами
//  закордонного паспорта, решта — дефісом; порожнє — «page».
// =============================================================================

namespace Slovo.Core;

public static class WebPageAddress
{
    public static string Slug(string fileName)
    {
        var stem = SwiftPath.DeletingExtension(fileName);
        var result = new System.Text.StringBuilder();
        var lastWasDash = false;
        foreach (var character in stem.ToLowerInvariant())
        {
            if (Letters.TryGetValue(character, out var latin))
            {
                result.Append(latin);
                lastWasDash = false;
            }
            else if (character < 128 && char.IsLetterOrDigit(character))
            {
                result.Append(character);
                lastWasDash = false;
            }
            else if (!lastWasDash && result.Length > 0)
            {
                result.Append('-');
                lastWasDash = true;
            }
        }
        while (result.Length > 0 && result[^1] == '-') result.Length--;
        return result.Length == 0 ? "page" : result.ToString();
    }

    public static string Url(string host, int port, string fileName) => $"http://{host}:{port}/{Slug(fileName)}";

    /// Домашня сторінка зі списком.
    public static string Home(string host, int port) => $"http://{host}:{port}/";

    static readonly Dictionary<char, string> Letters = new()
    {
        ['а'] = "a", ['б'] = "b", ['в'] = "v", ['г'] = "g", ['ґ'] = "g", ['д'] = "d", ['е'] = "e",
        ['ё'] = "e", ['є'] = "ie", ['ж'] = "zh", ['з'] = "z", ['и'] = "i", ['і'] = "i", ['ї'] = "i",
        ['й'] = "i", ['к'] = "k", ['л'] = "l", ['м'] = "m", ['н'] = "n", ['о'] = "o", ['п'] = "p",
        ['р'] = "r", ['с'] = "s", ['т'] = "t", ['у'] = "u", ['ф'] = "f", ['х'] = "kh", ['ц'] = "ts",
        ['ч'] = "ch", ['ш'] = "sh", ['щ'] = "shch", ['ъ'] = "", ['ы'] = "y", ['ь'] = "", ['э'] = "e",
        ['ю'] = "iu", ['я'] = "ia", ['ў'] = "u",
    };
}
