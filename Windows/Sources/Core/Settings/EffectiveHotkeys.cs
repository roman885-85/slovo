// =============================================================================
//  EffectiveHotkeys.cs — розкладка, за якою програма працює просто зараз
//  (з Settings/EffectiveHotkeys.swift)
// =============================================================================

namespace Slovo.Core;

/// Розкладка гарячих клавіш, за якою програма працює просто зараз
/// (вкладка «Гарячі клавіші», 6.1.6).
///
/// Розкладка одна на всю програму, і міняє її лише «Ок» у вікні «Параметри».
/// Значення за умовчанням — поставкова розкладка: поки людина нічого не
/// міняла, програма поводиться як звикли на служінні.
///
/// Словник тримаємо готовим, а не перезбираємо на кожне звертання: `Matches`
/// кличеться на кожне натискання клавіші, і розбір `hotkeys.ini` у цьому місці
/// підвісив би введення.
public static class EffectiveHotkeys
{
    /// Функції, яких у старих наборах (`VB Version 2.2`) ще немає. Без них
    /// клавіш просто не буде, тому те, чого бракує, беремо з поставки 2.4.
    private static readonly string[] AlwaysPresent = ["ShowMediaPlayer", "MediaPlayerPlayPause"];

    private static Dictionary<string, Hotkey>? cached;
    /// Звідки її взято — лише для звіту самоперевірки.
    private static string origin = "hotkeys.ini програми";

    private static Dictionary<string, Hotkey> Cached => cached ??= FromFile();

    /// Розкладка клавіш змінилася по «Ок» у вікні «Параметри»
    /// (на Mac — сповіщення `slovoHotkeysChanged`).
    public static event Action? HotkeysChanged;

    /// Розкладка, за якою зараз працюють перехоплювачі клавіш.
    public static IReadOnlyDictionary<string, Hotkey> Layout => Cached;

    /// Сполучення однієї функції — `EffectiveHotkeys.Hotkey("ShowSlide")`.
    public static Hotkey? Hotkey(string action) => Cached.TryGetValue(action, out var hotkey) ? hotkey : null;

    /// Людський опис джерела для звіту самоперевірки.
    public static string Source => origin;

    /// Прийняти розкладку з вікна «Параметри». Кличеться по «Ок» і один раз при
    /// запуску — «Скасувати» сюди не заходить. Повертає `true`, якщо розкладка
    /// справді змінилася: за цією ж ознакою розсилається сповіщення.
    public static bool Adopt(HotkeySets sets, string setName)
    {
        var chosen = setName.Length == 0 ? sets.PreferredSetName ?? "" : setName;
        var layout = sets.Hotkeys(chosen);
        FillGaps(layout);
        if (SameLayout(layout, Cached)) return false;
        cached = layout;
        origin = chosen.Length == 0 ? OurWords.T("окно «Параметры»") : OurWords.T("набор «%s» окна «Параметры»", chosen);
        HotkeysChanged?.Invoke();
        return true;
    }

    private static Dictionary<string, Hotkey> FromFile()
    {
        var sets = HotkeySets.Load();
        var layout = sets.Hotkeys(sets.PreferredSetName ?? "");
        FillGaps(layout);
        return layout;
    }

    private static void FillGaps(Dictionary<string, Hotkey> layout)
    {
        var fallback = HotkeySets.FactoryDefault;
        var defaults = fallback.Hotkeys(fallback.PreferredSetName ?? "");
        foreach (var name in AlwaysPresent)
        {
            if (!layout.ContainsKey(name) && defaults.TryGetValue(name, out var hotkey)) layout[name] = hotkey;
        }
    }

    private static bool SameLayout(IReadOnlyDictionary<string, Hotkey> left, IReadOnlyDictionary<string, Hotkey> right) =>
        left.Count == right.Count
        && left.All(pair => right.TryGetValue(pair.Key, out var other) && other.Equals(pair.Value));
}
