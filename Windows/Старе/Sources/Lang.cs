// =============================================================================
//  Lang.cs — мова інтерфейсу
// =============================================================================
//  Як у «Проповіднику» й на планшеті: українська, коли мова Windows українська
//  чи російська, англійська — за будь-якої іншої; вибір людини (Авто /
//  Українська / English) запам'ятовується. Рядок пишеться парою прямо в
//  коді: так переклад видно поруч з оригіналом, і розійтися їм нема де.
// =============================================================================

using System;
using System.Globalization;

namespace Slovo;

public static class Lang
{
    /// "auto", "uk" чи "en" — те, що вибрала людина.
    public static string Choice { get; set; } = "auto";

    /// Мова змінилася — вікна перебудовують підписи.
    public static event Action? Changed;

    public static void Apply(string choice)
    {
        Choice = choice;
        Changed?.Invoke();
    }

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

    public static string Code => IsUkrainian ? "uk" : "en";

    public static string T(string uk, string en) => IsUkrainian ? uk : en;

    public static string F(string uk, string en, params object[] values) =>
        string.Format(CultureInfo.InvariantCulture, T(uk, en), values);
}
