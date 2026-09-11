import Foundation

/// Строка списка модулей — колонки те же, что у `LVBiblesPath` оригинала:
/// Название · Сокращ. · Индекс · Путь.
struct SettingsModuleRow: Identifiable, Hashable {
    let id: String
    let name: String
    let title: String
    let shortName: String
    let hasIndex: Bool
    let isEnabled: Bool
    let isSongBook: Bool
    /// Модуль-файл базы (MyBible или MySword), а не папка «Цитаты из Библии».
    let isDatabase: Bool
    let path: String
}
