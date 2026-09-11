import Foundation

/// Збір фонових малюнків за списком тек вкладки «Шляхи» (6.1.5, елементи
/// (31) (32) (33)).
///
/// Посібник: «На цій вкладці налаштовується список тек, з яких
/// беруться фонові малюнки для слайда». Отже, джерело — саме список, а не
/// одна зашита тека: в оператора фони часто лежать на зовнішньому диску поруч із
/// відео, і другий рядок списку зобов'язаний давати нові картинки.
///
/// Кнопка `SBSubFolder` (33) перемикає у вибраного рядка ознаку «шукати у
/// вкладених теках» — тому обхід у кожного рядка свій, а не спільний.
public enum BackgroundLibrary {

    /// Розширення, які вміє відкрити `NSImage`. Список закритий навмисно:
    /// у теці з фонами лежать ще й `.ini`, і мінікартинки `thumbs`.
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "bmp", "tif", "tiff", "heic", "gif", "webp",
    ]

    /// Тека за умовчанням — та сама, що лежить поруч із модулями в
    /// поставці. Потрібна, коли список шляхів порожній: без неї після першого
    /// запуску без файла умовчань фонів не було б зовсім.
    public static let defaultFolderName = "BackGrounds"

    /// Розгорнути запис списку в справжній шлях.
    ///
    /// Оригінал пише шляхи всередині своєї теки коротко і зі зворотними скісними
    /// («BackGrounds\»), а зовнішні — повністю («Z:\Fon\» або, у нас,
    /// «/Volumes/...»). Відрізняємо одне від одного за початковою скісною.
    public static func resolve(_ path: String, dataRoot: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let unix = path.replacingOccurrences(of: "\\", with: "/")
        return dataRoot.appendingPathComponent(unix)
    }

    /// Усі картинки з перелічених тек, без повторів і в зрозумілому
    /// людині порядку.
    ///
    /// Порядок: спершу теки в тому порядку, в якому вони стоять у списку (це
    /// порядок, який оператор сам задав кнопками), усередині теки — за ім'ям
    /// файлу «як у Finder».
    public static func images(paths: [PicturePathEntry], dataRoot: URL) -> [URL] {
        let folders: [(URL, Bool)] = paths.isEmpty
            ? [(dataRoot.appendingPathComponent(defaultFolderName), false)]
            : paths.map { (resolve($0.path, dataRoot: dataRoot), $0.scansSubfolders) }

        var result: [URL] = []
        var seen: Set<String> = []
        for (folder, deep) in folders {
            for file in images(in: folder, deep: deep) where seen.insert(file.path).inserted {
                result.append(file)
            }
        }
        return result
    }

    /// Картинки однієї теки. Вкладені теки обходяться лише на вимогу:
    /// в оператора в корені фонів може лежати вся медіатека, і безумовний
    /// обхід підвісив би відкриття бібліотеки.
    public static func images(in folder: URL, deep: Bool) -> [URL] {
        let manager = FileManager.default
        var found: [URL] = []

        if deep {
            let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            guard let walker = manager.enumerator(at: folder,
                                                  includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: options) else { return [] }
            for case let url as URL in walker {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard !isDirectory, imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                found.append(url)
            }
        } else {
            let files = (try? manager.contentsOfDirectory(at: folder,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? []
            found = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        }

        return found.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Скільки картинок дасть список — для напису під ним на вкладці «Шляхи».
    /// Рахуємо за списком, який зараз правлять, а не за вже завантаженим у
    /// програму: інакше напис не міняється від правок і вводить в оману.
    public static func count(paths: [PicturePathEntry], dataRoot: URL) -> Int {
        images(paths: paths, dataRoot: dataRoot).count
    }
}
