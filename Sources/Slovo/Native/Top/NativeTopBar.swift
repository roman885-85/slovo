import AppKit
import SlovoCore

/// Верх нового окна: полоса меню и вкладки режима с ползунком.
///
/// Одна точка входа нарочно: части окна ставятся вместе и один раз, а не
/// каждая своим вызовом из разных мест. Второй вызов ничего не делает —
/// повторно поднимать полосу меню незачем.
@MainActor
enum NativeTop {

    private(set) static var menuBar: NativeMenuBar?
    private(set) static var modeTabs: NativeModeTabs?

    /// Поставить верх окна. Зовётся сразу после того, как поднято новое окно.
    ///
    /// Полосы меню внутри окна больше нет. Меню у программы одно — в строке
    /// macOS, на своём привычном месте; два меню с одним составом только
    /// сбивали, и одно из них вечно отставало от другого. Опись пунктов
    /// (`SlovoMenu`) осталась общей, показывает её теперь система.
    static func install(state: AppState) {
        guard modeTabs == nil else { return }

        let tabs = NativeModeTabs(state: state)
        NativeMainWindowController.shared.install(tabs, in: .modeTabs)
        modeTabs = tabs

        NativeSettingsSheet.install(state: state)
        if NativeTopBench.isWanted { NativeTopBench.start(state: state) }
    }
}

/// Окно «Параметры».
///
/// Внутри главного окна лежит только AppKit — и должен лежать только он.
/// Раньше там жил вид размером в точку: он держал лист «Параметры». Такой
/// сосед незаметен, пока не приходится искать, отчего окно рисуется наполовину,
/// — поэтому «Параметры» теперь поднимаются своим окном, а главное окно
/// целиком своё.
///
/// Признак открытости здесь свой, а не `state.isSettingsOpen`: иначе тот же
/// признак поднял бы вторые «Параметры», и «Отмена» одних отменила бы
/// записанное другими.
@MainActor
enum NativeSettingsSheet {

    /// Признак открытости. На него смотрит замер.
    final class Flag {
        var isOpen = false
    }

    static let flag = Flag()
    private static weak var known: AppState?

    /// Запомнить состояние. Ничего в главное окно не кладётся.
    static func install(state: AppState) { known = state }

    /// Открыть «Параметры» своим окном.
    static func open() {
        guard let state = known else { return }
        flag.isOpen = true
        NativeSettingsWindow.shared.show(state: state)
    }

    /// Закрыть — для замера и самопроверки.
    static func close() {
        flag.isOpen = false
        NativeSettingsWindow.shared.close()
    }
}
