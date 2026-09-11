import AppKit
import SlovoCore

/// Списки, зібрані до служіння, переживають закриття програми.
///
/// Власник: «после закрытия программы все добавленные презентации,
/// минусовки, картинки и т.д. не сохраняются — не остаются в программе
/// после перезапуска, все панели пустые».
///
/// Перевіряти це знімком безглуздо: панель виглядає однаково і коли список
/// збережено, і коли ні. Тому тут заводиться нова модель — така сама, як
/// після запуску програми, — і питається, чи повернувся до неї список.
///
/// Пам'ять самої людини при цьому недоторкана: перевірка запам'ятовує
/// значення ключів, кладе свої, а наприкінці повертає як було.
extension Diagnostics {

    static func sessionSection(state: AppState) -> [Check] {
        let area = "Пам'ять"
        var checks: [Check] = []
        checks.append(showMemoryCheck(area: area, state: state))
        checks.append(playlistMemoryCheck(area: area, state: state))
        return checks
    }

    /// Картинки і презентації.
    private static func showMemoryCheck(area: String, state: AppState) -> Check {
        let name = "Список показу повертається після запуску"
        // Тут пам'ять і перевіряється — заборону знімаємо лише на цю
        // перевірку; ключ людини і так знімається й повертається нижче.
        let wasSuspended = SessionMemory.isSuspended
        SessionMemory.isSuspended = false
        defer { SessionMemory.isSuspended = wasSuspended }
        let defaults = UserDefaults.standard
        let key = "showPictureFiles"
        let was = defaults.stringArray(forKey: key)
        defer {
            if let was { defaults.set(was, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        // Пробні файли заводимо свої і тут же прибираємо: чіпати папки
        // людини заради перевірки нема потреби, а неіснуючі файли модель
        // пропускає навмисно — на них перевірка нічого б не довела.
        let temporary = FileManager.default.temporaryDirectory
        let pictures = ["slovo-проба-1.png", "slovo-проба-2.png"].map { temporary.appendingPathComponent($0) }
        for file in pictures { FileManager.default.createFile(atPath: file.path, contents: Data([0x89, 0x50])) }
        defer { for file in pictures { try? FileManager.default.removeItem(at: file) } }

        // 1. Модель, яка пам'ятає, кладе відкрите в пам'ять.
        let first = ShowModel(kind: .pictures)
        first.remembers = true
        first.open(pictures)
        let opened = first.decks.count
        let stored = defaults.stringArray(forKey: key)?.count ?? 0

        // 2. Нова модель — така сама, як після запуску — бере список звідти.
        let second = ShowModel(kind: .pictures)
        second.remembers = true
        second.restore()
        let restored = second.decks.count

        // 3. Модель без пам'яті (такі заводить самоперевірка) не пише нічого.
        let plain = ShowModel(kind: .pictures)
        plain.open(Array(pictures.prefix(1)))
        let afterPlain = defaults.stringArray(forKey: key)?.count ?? 0

        var faults: [String] = []
        if opened == 0 { return Check(area: area, name: name, status: .skipped, detail: "проба не відкрилася") }
        if stored != opened { faults.append("відкрито \(opened), у пам'яті \(stored)") }
        if restored != opened { faults.append("після запуску повернулося \(restored) із \(opened)") }
        if afterPlain != stored { faults.append("модель без пам'яті переписала список людини") }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                        + "відкрито \(opened), у пам'яті \(stored), повернулося \(restored)")
    }

    /// Список плеєра: фільми і фонограми, які набирають до служіння.
    private static func playlistMemoryCheck(area: String, state: AppState) -> Check {
        let name = "Список плеєра повертається після запуску"
        let wasSuspended = SessionMemory.isSuspended
        SessionMemory.isSuspended = false
        defer { SessionMemory.isSuspended = wasSuspended }
        let defaults = UserDefaults.standard
        let key = "mediaPlaylist"
        let was = defaults.stringArray(forKey: key)
        defer {
            if let was { defaults.set(was, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("slovo-проба.mp3")
        FileManager.default.createFile(atPath: sample.path, contents: Data([0x49, 0x44]))
        defer { try? FileManager.default.removeItem(at: sample) }
        defaults.set([sample.path], forKey: key)

        let player = MediaPlayerModel()
        player.remembersPlaylist = true
        player.restorePlaylist()
        let restored = player.playlist.count

        // Плеєр без пам'яті список не бере й не пише.
        let plain = MediaPlayerModel()
        plain.restorePlaylist()
        let plainCount = plain.playlist.count

        var faults: [String] = []
        if restored != 1 { faults.append("у пам'яті був 1 файл, повернулося \(restored)") }
        if plainCount != 0 { faults.append("плеєр без пам'яті взяв чужий список") }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                        + "повернулося \(restored), у плеєра без пам'яті \(plainCount)")
    }
}
