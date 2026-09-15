import AppKit
import CoreGraphics
import SlovoCore

/// Дозволи macOS: перевірка при запуску і вікно «Дозволи macOS».
///
/// Самого дозволу перевірка не дає і не забирає — це робить лише людина в
/// «Системних параметрах». Тут перевіряється, що програма бачить стан
/// правильно, вікно показує кожен дозвіл і кнопку до його розділу, а у
/// вкладці «Екран» при браку дозволу є кнопка до цього вікна.
extension Diagnostics {

    static func permissionsSection(state: AppState) -> [Check] {
        let area = "Дозволи"
        var checks: [Check] = []
        let permissions = SystemPermissions.shared
        var answered = false
        permissions.refresh { answered = true }
        wait(untilTrue: { answered }, seconds: 6)
        let screen = permissions.statuses[.screenRecording]
        let screenOK = screen == (CGPreflightScreenCaptureAccess() ? .granted : .missing)
        let network = permissions.statuses[.localNetwork]
        let networkOK = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
            ? network != nil && network != .notNeeded : network == .notNeeded
        let firewall = permissions.statuses[.firewall]
        let globalState = SystemPermissions.firewallStatus(bundlePath: Bundle.main.bundleURL.path)
        func text(_ status: SystemPermission.Status?) -> String {
            switch status {
            case .granted?: return "дозволено"
            case .missing?: return "НЕМАЄ"
            case .notNeeded?: return "не потрібен"
            case .unknown?: return "невідомо"
            case nil: return "не перевірено"
            }
        }
        checks.append(Check(area: area, name: "Програма бачить стан дозволів",
                            status: answered && screenOK && networkOK && firewall == globalState ? .ok : .failed,
                            detail: "відповідь за 6 с: \(answered ? "так" : "НІ"); запис екрана — \(text(screen)); "
                                + "локальна мережа — \(text(network)); брандмауер — \(text(firewall))"
                                + "; брак: \(permissions.missing.map(\.rawValue).joined(separator: ", ").isEmpty ? "нічого" : permissions.missing.map(\.rawValue).joined(separator: ", "))"))

        // Вікно: кожен дозвіл має рядок зі станом і розділ параметрів.
        let window = NativePermissionsWindow.shared
        NativePermissionsWindow.open()
        wait(untilTrue: { window.isShown }, seconds: 2)
        wait(untilTrue: { false }, seconds: 1)
        var faults: [String] = []
        for permission in SystemPermission.allCases {
            if window.statusTextForCheck(permission).isEmpty { faults.append("\(permission.rawValue): стан порожній") }
            if permission.settingsURL == nil { faults.append("\(permission.rawValue): немає адреси параметрів") }
        }
        let shown = window.isShown
        _ = window.snapshotForCheck(to: "slovo-дозволи.png")
        window.close()
        let menu = SlovoMenu.entries(for: .help, state: state).contains { $0.title == OurWords.t("Разрешения macOS…") }
        checks.append(Check(area: area, name: "Вікно «Дозволи macOS» і пункт меню",
                            status: shown && faults.isEmpty && menu ? .ok : .failed,
                            detail: "вікно відкрилося: \(shown ? "так" : "ні"); пункт у «Довідці»: \(menu ? "є" : "НЕМАЄ"); "
                                + (faults.isEmpty ? "у кожного дозволу стан і розділ параметрів: "
                                    + SystemPermission.allCases.map { "\($0.rawValue) «\(window.statusTextForCheck($0))»" }.joined(separator: ", ")
                                   : faults.joined(separator: "; "))))

        checks.append(updateNoticeCheck(state: state))
        checks.append(Check(area: area, name: "Перевірка дозволів під час запуску ввімкнена",
                            status: NativePermissionsWindow.checksOnLaunch ? .ok : .warning,
                            detail: NativePermissionsWindow.checksOnLaunch
                                ? "вікно з'явиться при запуску, якщо чогось бракує (у самоперевірці — ні)"
                                : "вимкнено людиною у вікні дозволів"))
        return checks
    }

    /// Власник: «уведомления о новой версии приходят тогда, когда я сам
    /// запускаю обновление вручную». Перевіряємо: знайдена нова версія одразу
    /// ставить кнопку «Оновлення» у верхньому рядку, пропозиція — не
    /// модальна (перевірка йде далі, поки вікно на екрані), «Пізніше» кнопку
    /// не прибирає, а GitHub питають частіше, ніж раз на 12 годин.
    static func updateNoticeCheck(state: AppState) -> Check {
        let area = "Дозволи"
        let name = "Про нову версію видно без ручної перевірки"
        let wasAvailable = AppUpdater.available
        defer { AppUpdater.setAvailable(wasAvailable) }
        let tabs = NativeModeTabs(state: state)
        tabs.frame = NSRect(x: 0, y: 0, width: 1200, height: 30)
        let fake = AppUpdater.Release(version: "9.99", tag: "v9.99", page: "", notes: "Перевірка", zip: nil, size: 0)
        AppUpdater.setAvailable(nil)
        tabs.layoutSubtreeIfNeeded()
        let hiddenBefore = tabs.updateButton.isHidden
        AppUpdater.setAvailable(fake)
        tabs.layoutSubtreeIfNeeded()
        let shownAfter = !tabs.updateButton.isHidden && tabs.updateButton.title.contains("9.99")
            && tabs.updateButton.frame.width > 20
        var answered: Bool?
        UpdateOfferPanel.show(release: fake, current: AppUpdater.currentVersion, notes: "Перевірка") { answered = $0 }
        let nonModal = UpdateOfferPanel.isShown   // сюди дійшли, поки вікно на екрані
        UpdateOfferPanel.finish(false)
        let stays = !tabs.updateButton.isHidden
        let often = AppUpdater.quietInterval <= 3600
        let ok = hiddenBefore && shownAfter && nonModal && answered == false && stays && often
        return Check(area: area, name: name, status: ok ? .ok : .failed,
                     detail: "без нової версії кнопки нема: \(hiddenBefore ? "так" : "ні"); знайдено 9.99 — кнопка «\(tabs.updateButton.title)»: \(shownAfter ? "так" : "ні"); "
                        + "пропозиція не блокує програму: \(nonModal ? "так" : "ні"); після «Пізніше» кнопка лишається: \(stays ? "так" : "ні"); "
                        + "GitHub питають кожні \(Int(AppUpdater.quietInterval / 60)) хв і при поверненні до програми")
    }
}
