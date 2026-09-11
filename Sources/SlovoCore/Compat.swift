import Foundation

/// Сумісність зі старими системами — від macOS 11 Big Sur.
///
/// Компілятор забороняє викликати те, чого в Big Sur немає, і кожне таке
/// місце обходиться гілкою `if #available`. Біда в тому, що на цій машині
/// (нова macOS) стара гілка ніколи не виконується, і її поломка видна
/// лише на чужому старому комп'ютері. Тому в обходу є вимикач:
/// самоперевірка ставить його і ганяє старі гілки тут же.
public enum Compat {
    /// Іти гілками для macOS 11 навіть на новій системі. Ставиться
    /// змінною оточення `SLOVO_PRETEND_BIGSUR=1` або самою перевіркою.
    nonisolated(unsafe) public static var pretendsBigSur =
        ProcessInfo.processInfo.environment["SLOVO_PRETEND_BIGSUR"] == "1"
}
