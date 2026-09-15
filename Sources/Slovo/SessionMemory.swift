import Foundation

/// Пам'ять списків між запусками — і її захист від самоперевірки.
///
/// Список показу, список плеєра і фонограма записуються в пам'ять на кожну
/// зміну (`ShowModel.remember`, `MediaPlayerModel.rememberPlaylist`,
/// `BackingTrackPlayer.remember`). А самоперевірка працює з тими самими
/// робочими місцями, що й людина: відкриває пробні файли, закриває показ,
/// чистить список плеєра. 2026-09-10 повний прогін так і стер список
/// картинок власника — кожна правка перевірки слухняно лягала в пам'ять.
///
/// Тому захист подвійний. Поки йде перевірка, пам'ять не пише нічого. А
/// навколо будь-якого прогону перевірок усі ці ключі знімаються і
/// повертаються як були — навіть якщо щось проскочить повз заборону.
///
/// Історію й План, які живуть у файлах, а не в цих ключах, так само
/// знімає і повертає `DeskModel.keepingJournals`.
enum SessionMemory {

    /// Ключі, під якими лежать списки людини.
    static let keys = ["showPictureFiles", "showPresentationFiles", "mediaPlaylist", "backingTrackFile", "backingPlaylist"]

    /// Поки `true`, пам'ять списків не пише. Ставить самоперевірка.
    nonisolated(unsafe) static var isSuspended = false

    nonisolated(unsafe) private static var depth = 0

    /// Виконати перевірки, не зачепивши пам'яті людини. Вкладені виклики
    /// (розділ «усе» зсередини `runNamed`) захищаються один раз, зовнішнім.
    static func protect<T>(_ body: () -> T) -> T {
        depth += 1
        if depth > 1 {
            defer { depth -= 1 }
            return body()
        }
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let wasSuspended = isSuspended
        isSuspended = true
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            isSuspended = wasSuspended
            depth -= 1
        }
        return body()
    }
}
