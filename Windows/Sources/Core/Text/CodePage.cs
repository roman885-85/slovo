// =============================================================================
//  CodePage.cs — кодування модулів BibleQuote (з Text/CodePage.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Кодування, якими користуються модулі BibleQuote.
///
/// Модуль або прямо оголошує `DefaultEncoding = utf-8`, або не оголошує
/// нічого — і тоді єдина підказка це `DesiredFontCharset`, номер
/// windows-кодування шрифту, яким модуль малювався в Delphi.
public static class CodePage
{
    static CodePage()
    {
        // CP1251/CP1250 та інші однобайтові — у .NET лише через цього постачальника.
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    }

    /// Зареєструвати однобайтові кодування Windows (досить одного разу).
    public static void Register() { }

    /// Windows charset id (той, що лежить у `DesiredFontCharset`) → кодова сторінка.
    private static readonly Dictionary<int, int> CharsetMap = new()
    {
        [0] = 1252,    // ANSI_CHARSET — windows-1252
        [161] = 1253,  // грецька
        [162] = 1254,  // турецька
        [163] = 1258,  // в'єтнамська
        [177] = 1255,  // іврит
        [178] = 1256,  // арабська
        [186] = 1257,  // балтійська
        [204] = 1251,  // кирилиця
        [238] = 1250,  // центральноєвропейська
    };

    /// Байти, яких у кодовій сторінці немає. Foundation на таких байтах
    /// відмовляється декодувати весь файл (і розбір іде далі запасними
    /// кодуваннями), а .NET тихо ставить керівні знаки C1. Списки зняті з
    /// macOS (`String(data:encoding:)` для кожного байта); решта байтів обох
    /// систем збігається повністю.
    private static readonly Dictionary<int, byte[]> Undefined = new()
    {
        [1250] = [0x81, 0x83, 0x88, 0x90, 0x98],
        [1251] = [0x98],
        [1252] = [0x81, 0x8D, 0x8F, 0x90, 0x9D],
        [1253] = [0x81, 0x88, 0x8A, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x98, 0x9A, 0x9C, 0x9D, 0x9E, 0x9F, 0xAA, 0xD2, 0xFF],
        [1254] = [0x81, 0x8D, 0x8E, 0x8F, 0x90, 0x9D, 0x9E],
        [1255] = [0x81, 0x8A, 0x8C, 0x8D, 0x8E, 0x8F, 0x90, 0x9A, 0x9C, 0x9D, 0x9E, 0x9F, 0xCA, 0xD9, 0xDA, 0xDB,
                  0xDC, 0xDD, 0xDE, 0xDF, 0xFB, 0xFC, 0xFF],
        [1256] = [0x8A, 0x8F, 0x98, 0x9A, 0x9F, 0xAA, 0xC0, 0xFF],
        [1257] = [0xA1, 0xA5],
        [1258] = [0x81, 0x8A, 0x8D, 0x8E, 0x8F, 0x90, 0x9A, 0x9D, 0x9E],
    };

    /// UTF-8 суворий: недійсні послідовності — відмова, як `String(data:encoding: .utf8)`.
    public static readonly Encoding Utf8 = new UTF8Encoding(false, true);

    /// UTF-16 у розумінні Foundation: мітка порядку байтів, без неї — старший байт першим.
    public static readonly Encoding Utf16 = new UnicodeEncoding(true, true, true);

    public static Encoding WindowsCP1251 => Encoding.GetEncoding(1251);
    public static Encoding WindowsCP1252 => Encoding.GetEncoding(1252);

    public static Encoding? EncodingForCharset(int charset) =>
        CharsetMap.TryGetValue(charset, out var page) ? Encoding.GetEncoding(page) : null;

    /// `String(data: data, encoding: encoding)` — `null`, якщо Foundation відмовився б.
    public static string? TryDecode(byte[] data, Encoding encoding)
    {
        try
        {
            if (encoding.CodePage == 65001) return Utf8.GetString(data);
            if (encoding.CodePage is 1200 or 1201) return DecodeUtf16(data);
            if (Undefined.TryGetValue(encoding.CodePage, out var holes) && data.AsSpan().IndexOfAny(holes) >= 0)
                return null;
            var strict = Encoding.GetEncoding(encoding.CodePage, EncoderFallback.ExceptionFallback,
                                              DecoderFallback.ExceptionFallback);
            return strict.GetString(data);
        }
        catch (DecoderFallbackException)
        {
            return null;
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    private static string? DecodeUtf16(byte[] data)
    {
        if (data.Length % 2 != 0) return null;
        if (data.Length >= 2 && data[0] == 0xFF && data[1] == 0xFE)
            return new UnicodeEncoding(false, false, true).GetString(data, 2, data.Length - 2);
        if (data.Length >= 2 && data[0] == 0xFE && data[1] == 0xFF)
            return new UnicodeEncoding(true, false, true).GetString(data, 2, data.Length - 2);
        return new UnicodeEncoding(true, false, true).GetString(data);
    }

    /// Чи читається файл строго як UTF-8 (`String(data: data, encoding: .utf8) != nil`).
    public static bool IsValidUtf8(byte[] data) => TryDecode(data, Utf8) != null;

    /// Декодує файл, пробуючи оголошене кодування, потім розумні запасні.
    ///
    /// Порядок не випадковий: суворий UTF-8 відсікає себе сам — байт 0xD0 без
    /// продовження в CP1251-тексті розвалить декодування, і ми чесно
    /// провалимося далі на однобайтове кодування, а не отримаємо кашу.
    public static string Decode(byte[] data, Encoding? declared)
    {
        var candidates = new List<Encoding>();
        if (declared != null) candidates.Add(declared);
        candidates.Add(Utf8);
        candidates.Add(WindowsCP1251);
        candidates.Add(WindowsCP1252);

        foreach (var encoding in candidates)
        {
            var text = TryDecode(data, encoding);
            if (!string.IsNullOrEmpty(text)) return StripBOM(text);
        }
        // Останній рубіж: UTF-8 із заміною зламаних байтів — він не вміє падати.
        return StripBOM(Encoding.UTF8.GetString(data));
    }

    /// Розбирає значення `DefaultEncoding` (`utf-8`, `windows-1251`, `cp1251`…).
    public static Encoding? EncodingForName(string raw)
    {
        var name = raw.TrimWhitespacesAndNewlines().ToLowerInvariant();
        switch (name)
        {
            case "utf-8": case "utf8": return Utf8;
            case "utf-16": case "utf16": return Utf16;
            case "windows-1250": case "cp1250": return EncodingForCharset(238);
            case "windows-1251": case "cp1251": return WindowsCP1251;
            case "windows-1252": case "cp1252": return WindowsCP1252;
            case "windows-1253": case "cp1253": return EncodingForCharset(161);
            case "windows-1255": case "cp1255": return EncodingForCharset(177);
            case "windows-1257": case "cp1257": return EncodingForCharset(186);
            default:
                // На Mac — CFStringConvertIANACharSetNameToEncoding: будь-яке ім'я IANA.
                try { return Encoding.GetEncoding(name); }
                catch { return null; }
        }
    }

    private static string StripBOM(string text) => text.StartsWith((char)0xFEFF) ? text[1..] : text;
}
