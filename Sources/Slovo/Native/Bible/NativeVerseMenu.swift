import Foundation
import SlovoCore

/// Пункти контекстного меню списку віршів (5.1.4) — у тому порядку, в якому
/// вони стоять на знімку до розділу: «Додати в План», роздільник,
/// «Скопіювати у вкладку "Текст"», «Скопіювати в буфер обміну».
///
/// Порядок винесено в перелік, а не лишено розсипом пунктів, щоб його
/// можна було прочитати самоперевіркою: за абеткою ключів його не
/// відновити — у `ru.lng` вони просто відсортовані (MIAddToPlan,
/// MICopyToClipboard, MICopyToText), і меню з файла не випливає.
///
/// Жив цей перелік усередині списку віршів на SwiftUI. Список видалено разом із
/// колишнім вікном, а меню лишилося: його будує `NativeVerseRows`.
enum VerseMenuEntry: String, CaseIterable {
    case addToPlan = "MIAddToPlan"
    case copyToText = "MICopyToText"
    case copyToClipboard = "MICopyToClipboard"

    var fallback: String {
        switch self {
        case .addToPlan:       return OurWords.t("Добавить в План")
        case .copyToText:      return OurWords.t("Скопировать во вкладку «Текст»")
        case .copyToClipboard: return OurWords.t("Скопировать в буфер обмена (Ctrl + C)")
        }
    }

    /// Роздільник на знімку рівно один — одразу після «Додати в План».
    var isFollowedByDivider: Bool { self == .addToPlan }
}
