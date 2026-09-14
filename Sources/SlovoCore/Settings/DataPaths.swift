import Foundation

/// Знайти файл даних, на який показує застарілий шлях.
///
/// Налаштування й шаблони пам'ятають картинки ПОВНИМ шляхом: фон слайда —
/// «/Users/…/Desktop/Слово.app/Contents/Resources/app/BackGrounds/Black.jpg»,
/// картинки шаблонів — «/Users/…/Desktop/Слово/Слово.app/…/Templates/Autumn/…».
/// Перенесли програму, поставили збірку «лише програма» з ресурсами в
/// Application Support — і фони пропали, хоч самі файли на місці (власник:
/// «фонові картинки взяти з повної програми… додати відсутні»). Тут шлях
/// переводиться на поточні корені даних за хвостом після
/// `Contents/Resources/app/`, `Application Support/Slovo/` чи після теки
/// даних (`BackGrounds/`, `Templates/`…).
public enum DataPaths {

    /// Корені даних, у яких шукати: тека даних програми (батько теки модулів).
    /// Ставить `AppState`, коли тека модулів відома.
    public nonisolated(unsafe) static var roots: [URL] = []

    private static let folders = ["BackGrounds", "Templates", "Fonts", "RemoteAPI", "Plans", "WebSlides", "Presets"]

    /// Шлях, що існує: сам або переведений на поточні корені; `nil` — нема ніде.
    public static func existing(_ path: String) -> String? {
        let fm = FileManager.default
        guard !path.isEmpty else { return nil }
        if fm.fileExists(atPath: path) { return path }
        let cleaned = path.replacingOccurrences(of: "\\", with: "/")
        var tails: [String] = []
        for marker in ["/Contents/Resources/app/", "/Application Support/Slovo/"] {
            if let range = cleaned.range(of: marker, options: .backwards) {
                tails.append(String(cleaned[range.upperBound...]))
            }
        }
        for folder in folders {
            if let range = cleaned.range(of: "/" + folder + "/", options: [.backwards, .caseInsensitive]) {
                tails.append(folder + "/" + String(cleaned[range.upperBound...]))
            }
        }
        if !cleaned.hasPrefix("/") { tails.append(cleaned) }
        var bases = roots
        bases.append(DataHome.folder)
        bases.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/app"))
        for tail in tails where !tail.isEmpty {
            for base in bases {
                let candidate = base.appendingPathComponent(tail).path
                if fm.fileExists(atPath: candidate) { return candidate }
            }
        }
        return nil
    }
}
