// =============================================================================
//  Lang.cs — мова інтерфейсу
// =============================================================================
//  Як на планшеті: українська, коли мова Windows українська чи російська,
//  англійська — за будь-якої іншої; вибір людини (Авто / Українська /
//  English) запам'ятовується. Рядок пишеться парою прямо в коді: так переклад
//  видно поруч з оригіналом, і розійтися їм нема де.
// =============================================================================

using System.Globalization;

namespace Propovidnyk;

public static class Lang
{
    /// "auto", "uk" чи "en" — те, що вибрала людина.
    public static string Choice { get; set; } = "auto";

    public static bool IsUkrainian
    {
        get
        {
            if (Choice == "uk") return true;
            if (Choice == "en") return false;
            var system = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
            return system is "uk" or "ru";
        }
    }

    public static string T(string uk, string en) => IsUkrainian ? uk : en;

    public static string F(string uk, string en, params object[] values) =>
        string.Format(CultureInfo.InvariantCulture, T(uk, en), values);
}
