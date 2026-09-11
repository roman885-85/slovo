import AppKit
import SlovoCore

/// Верх нового вікна: смуга меню й вкладки режиму з повзунком.
///
/// Одна точка входу навмисно: частини вікна ставляться разом і один раз, а не
/// кожна своїм викликом із різних місць. Другий виклик нічого не робить —
/// удруге піднімати смугу меню нема чого.
@MainActor
enum NativeTop {

    private(set) static var menuBar: NativeMenuBar?
    private(set) static var modeTabs: NativeModeTabs?

    /// Поставити верх вікна. Викликається одразу після того, як піднято нове вікно.
    ///
    /// Смуги меню всередині вікна більше немає. Меню в програми одне — у рядку
    /// macOS, на своєму звичному місці; два меню з однаковим складом тільки
    /// збивали, і одне з них вічно відставало від другого. Опис пунктів
    /// (`SlovoMenu`) лишився спільним, показує його тепер система.
    static func install(state: AppState) {
        guard modeTabs == nil else { return }

        let tabs = NativeModeTabs(state: state)
        NativeMainWindowController.shared.install(tabs, in: .modeTabs)
        modeTabs = tabs

        NativeSettingsSheet.install(state: state)
        if NativeTopBench.isWanted { NativeTopBench.start(state: state) }
    }
}

/// Вікно «Параметри».
///
/// Усередині головного вікна лежить тільки AppKit — і має лежати тільки він.
/// Раніше там жив вид розміром у точку: він тримав аркуш «Параметри». Такий
/// сусід непомітний, доки не доводиться шукати, чому вікно малюється наполовину,
/// — тому «Параметри» тепер піднімаються своїм вікном, а головне вікно
/// цілком своє.
///
/// Ознака відкритості тут своя, а не `state.isSettingsOpen`: інакше та сама
/// ознака підняла б другі «Параметри», і «Скасувати» одних скасувало б
/// записане іншими.
@MainActor
enum NativeSettingsSheet {

    /// Ознака відкритості. На неї дивиться замір.
    final class Flag {
        var isOpen = false
    }

    static let flag = Flag()
    private static weak var known: AppState?

    /// Запам'ятати стан. Нічого в головне вікно не кладеться.
    static func install(state: AppState) { known = state }

    /// Відкрити «Параметри» своїм вікном.
    static func open() {
        guard let state = known else { return }
        flag.isOpen = true
        NativeSettingsWindow.shared.show(state: state)
    }

    /// Закрити — для заміру й самоперевірки.
    static func close() {
        flag.isOpen = false
        NativeSettingsWindow.shared.close()
    }
}
