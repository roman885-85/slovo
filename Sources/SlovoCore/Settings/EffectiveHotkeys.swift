import Foundation

/// Розкладка гарячих клавіш, за якою програма працює просто зараз
/// (вкладка «Гарячі клавіші», 6.1.6).
///
/// Навіщо окреме місце. Вкладка вміє все: зловити сполучення з клавіатури,
/// сказати, ким воно зайняте, повернути розкладку поставки (35), зберегти свій
/// набір (37) і видалити його (38). Але ті, хто ловить клавіші, читали розкладку
/// самі й лише з `hotkeys.ini` — тобто переназначити клавішу у
/// вікні «Параметри» було не можна: натиснув «Ок», а F5 як і раніше та сама. Тут
/// розкладка одна на всю програму, і міняє її лише «Ок».
///
/// Значення за умовчанням — поставкова розкладка, як і було: поки людина
/// нічого не міняла, програма поводиться як звикли на служінні.
///
/// Словник тримаємо готовим, а не перезбираємо на кожне звертання: `matches`
/// кличеться на кожне натискання клавіші, і розбір `hotkeys.ini` у цьому місці
/// підвісив би введення.
@MainActor
public enum EffectiveHotkeys {

    /// Функції, яких у старих наборах (`VB Version 2.2`) ще немає. Без них
    /// клавіш просто не буде, тому те, чого бракує, беремо з поставки 2.4.
    private static let alwaysPresent = ["ShowMediaPlayer", "MediaPlayerPlayPause"]

    /// Готова розкладка: ключ функції з `hotkeys.ini` → сполучення.
    private static var cached: [String: Hotkey] = EffectiveHotkeys.fromFile()
    /// Звідки її взято — лише для звіту самоперевірки.
    private static var origin = "hotkeys.ini програми"

    /// Розкладка, за якою зараз працюють перехоплювачі клавіш.
    public static var layout: [String: Hotkey] { cached }

    /// Сполучення однієї функції — `EffectiveHotkeys.hotkey("ShowSlide")`.
    public static func hotkey(_ action: String) -> Hotkey? { cached[action] }

    /// Людський опис джерела для звіту самоперевірки.
    public static var source: String { origin }

    /// Прийняти розкладку з вікна «Параметри». Кличеться по «Ок» і один раз при
    /// запуску — «Скасувати» сюди не заходить, тому відкочувати нічого.
    ///
    /// Повертає `true`, якщо розкладка справді змінилася: за цією
    /// ж ознакою розсилається сповіщення, а перехоплювачі, що читають `layout`
    /// на кожне натискання, підхоплюють її і без нього.
    @discardableResult
    public static func adopt(sets: HotkeySets, setName: String) -> Bool {
        let chosen = setName.isEmpty ? (sets.preferredSetName ?? "") : setName
        var layout = sets.hotkeys(inSet: chosen)
        fillGaps(&layout)
        guard layout != cached else { return false }
        cached = layout
        origin = chosen.isEmpty ? OurWords.t("окно «Параметры»") : OurWords.t("набор «%s» окна «Параметры»", "\(chosen)")
        NotificationCenter.default.post(name: .slovoHotkeysChanged, object: nil)
        return true
    }

    // MARK: -

    private static func fromFile() -> [String: Hotkey] {
        let sets = HotkeySets.load()
        var layout = sets.hotkeys(inSet: sets.preferredSetName ?? "")
        fillGaps(&layout)
        return layout
    }

    private static func fillGaps(_ layout: inout [String: Hotkey]) {
        let fallback = HotkeySets.factoryDefault
        let defaults = fallback.hotkeys(inSet: fallback.preferredSetName ?? "")
        for name in alwaysPresent where layout[name] == nil {
            layout[name] = defaults[name]
        }
    }
}

public extension Notification.Name {
    /// Розкладка клавіш змінилася по «Ок» у вікні «Параметри».
    static let slovoHotkeysChanged = Notification.Name("SlovoHotkeysChanged")
}
