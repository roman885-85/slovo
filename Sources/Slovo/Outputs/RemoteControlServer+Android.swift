import Foundation
import Network
import SlovoCore

/// Програми для Android усередині «Слова».
///
/// Власник: «все программы apk должны быть встроены в основную программу и
/// иметь возможность сохранить с программы на компьютер или при веб входе
/// скачать на текущее устройство или установить, если устройство
/// совместимо». Збірка кладе обидва пакети в `Contents/Resources/Android`
/// разом з `apps.json` (версії — з самих пакетів); сторінка в браузері
/// бере звідси список і файли.
extension RemoteControlServer {

    struct AndroidApp {
        /// «phone» або «tablet» — так і в адресі завантаження.
        let id: String
        let file: String
        let title: String
        /// Ім'я файла при завантаженні — латиницею: кирилицю в імені
        /// завантаження старі Android перекручують.
        let download: String
        let version: String
        let minSdk: Int

        /// «Android 5 і новіші» — з рівня API.
        var minAndroid: String {
            let table = [21: "5", 22: "5.1", 23: "6", 24: "7", 25: "7.1", 26: "8", 27: "8.1", 28: "9",
                         29: "10", 30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16"]
            return table[minSdk] ?? "API \(minSdk)"
        }
    }

    /// Де лежать пакети: у пакеті програми, а в налагоджувальній збірці —
    /// у теках вихідників поруч.
    static var androidFolder: URL? {
        if let inside = Bundle.main.resourceURL?.appendingPathComponent("Android", isDirectory: true),
           FileManager.default.fileExists(atPath: inside.path) { return inside }
        return nil
    }

    static var androidApps: [AndroidApp] {
        var info: [String: [String: Any]] = [:]
        if let folder = androidFolder,
           let data = try? Data(contentsOf: folder.appendingPathComponent("apps.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            info = json
        }
        func app(_ id: String, file: String, title: String, download: String, minSdk: Int) -> AndroidApp {
            let entry = info[id] ?? [:]
            let sdk = (entry["minSdk"] as? NSNumber)?.intValue ?? 0
            return AndroidApp(id: id, file: file, title: title, download: download,
                              version: entry["version"] as? String ?? "",
                              minSdk: sdk > 0 ? sdk : minSdk)
        }
        return [
            app("tablet", file: "Планшет Слова.apk", title: "Планшет Слова", download: "Slovo-Tablet.apk", minSdk: 21),
            app("phone", file: "Пульт Слова.apk", title: "Пульт Слова", download: "Slovo-Remote.apk", minSdk: 23),
        ]
    }

    /// Файл пакета — або `nil`, якщо його в цій збірці немає.
    static func androidFile(_ app: AndroidApp) -> URL? {
        let fileManager = FileManager.default
        if let folder = androidFolder {
            let url = folder.appendingPathComponent(app.file)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        // Налагоджувальна збірка: пакети лежать у теках Пульт і Планшет.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = app.id == "tablet" ? "Планшет" : "Пульт"
        let url = sources.appendingPathComponent(folder).appendingPathComponent(app.file)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    static func androidAppsJSON() -> [String: Any] {
        ["apps": androidApps.compactMap { app -> [String: Any]? in
            guard let url = androidFile(app) else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? 0
            return ["id": app.id, "title": app.title, "version": app.version, "minSdk": app.minSdk,
                    "minAndroid": app.minAndroid, "size": size, "url": "/download/\(app.id).apk"]
        }]
    }

    /// Віддати пакет браузеру як завантаження — на Android браузер одразу
    /// запропонує встановити.
    func serveAndroidApp(_ path: String, on connection: NWConnection) {
        let id = String(path.dropFirst("/download/".count)).replacingOccurrences(of: ".apk", with: "")
        guard let app = Self.androidApps.first(where: { $0.id == id }),
              let url = Self.androidFile(app), let data = try? Data(contentsOf: url) else {
            respond(connection, 404, ["error": OurWords.t("нет такого файла")])
            return
        }
        respondData(connection, 200, data, contentType: "application/vnd.android.package-archive",
                    headers: ["Content-Disposition": "attachment; filename=\"\(app.download)\""])
    }
}
