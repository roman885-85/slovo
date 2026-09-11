import Foundation
import SlovoCore

/// Заготовки для Библии и песен — готовыми страницами.
///
/// Владелец просил «10 шаблонов для Библии и 10 для песен» и ждал их в
/// списке веб-слайдов, а не в диалоге «Новая из заготовки». Поэтому при
/// включении веб-слайдов недостающие страницы создаются файлами в папке
/// своих страниц и попадают в список «Web слайды» — на начальную страницу
/// сервера и в редактор. Файл — по короткому имени заготовки (латиницей: в
/// адресе так надёжнее), название в списке — на языке интерфейса.
///
/// Посев одноразовый: удалённая владельцем страница не возвращается —
/// имена посеянных заготовок помнит файл рядом.
@MainActor
enum WebSlideSeeder {
    static let prefixes = ["bible-", "song-"]

    private static var markerURL: URL {
        WebOutputServer.userPagesFolder.appendingPathComponent(".seeded-templates")
    }

    /// Возвращает число созданных страниц.
    @discardableResult
    static func seed(store: SettingsStore) -> Int {
        let folder = WebOutputServer.userPagesFolder
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Метка: имя заготовки и отпечаток того, что мы записали. Если файл
        // на диске всё ещё наш (отпечаток совпал), а заготовка изменилась —
        // переписываем: владелец увидел старые непрозрачные страницы после
        // того, как заготовки стали наложением. Правленную владельцем
        // страницу не трогаем.
        var recorded: [String: String] = [:]
        for line in (try? String(contentsOf: markerURL, encoding: .utf8))?.split(separator: "\n") ?? [] {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if let id = parts.first { recorded[id] = parts.count > 1 ? parts[1] : "" }
        }
        var seeded = Set(recorded.keys)
        var created = 0
        var entries = store.settings.webSlides
        for template in WebSlideTemplates.all where prefixes.contains(where: { template.id.hasPrefix($0) }) {
            let fileName = template.id + ".html"
            let file = folder.appendingPathComponent(fileName)
            let fresh = template.html
            let freshHash = Self.hash(fresh)
            if !seeded.contains(template.id), !manager.fileExists(atPath: file.path) {
                guard (try? fresh.write(to: file, atomically: true, encoding: .utf8)) != nil else { continue }
                created += 1
            } else if manager.fileExists(atPath: file.path),
                      let onDisk = try? String(contentsOf: file, encoding: .utf8) {
                let diskHash = Self.hash(onDisk)
                // Каркас страницы (стили, разметка, скрипт) обновляем всегда,
                // а настройки владельца переносим в него как есть: заготовка
                // меняется вместе с программой, а его правки ручек — его.
                if diskHash != freshHash,
                   WebSlideParameters.markerRange(WebSlideParameters.varsMarkers, in: onDisk) != nil {
                    let updated = WebSlideParameters.carryOverSettings(from: onDisk, into: fresh)
                    if updated != onDisk { _ = try? updated.write(to: file, atomically: true, encoding: .utf8) }
                }
            }
            recorded[template.id] = freshHash
            seeded.insert(template.id)
            if manager.fileExists(atPath: file.path) {
                let fresh = WebSlideEntry(name: OurWords.t(template.title), fileName: fileName,
                                          details: OurWords.t(template.purpose))
                if let at = entries.firstIndex(where: { $0.fileName.caseInsensitiveCompare(fileName) == .orderedSame }) {
                    // Подпись в списке тоже обновляем: она рассказывает, что
                    // страница делает, и устаревала вместе с заготовкой.
                    if entries[at].details != fresh.details { entries[at] = fresh }
                } else {
                    entries.append(fresh)
                }
            }
            // Своя страница наложения — тоже в списке.
            if !entries.contains(where: { $0.fileName.caseInsensitiveCompare("slovo-slide-overlay.html") == .orderedSame }) {
                entries.append(WebSlideEntry(name: OurWords.t("Слайд поверх видео"),
                                             fileName: "slovo-slide-overlay.html",
                                             details: OurWords.t("Слайд поверх видео: без фона, только текст")))
            }
        }
        try? seeded.sorted().map { "\($0) \(recorded[$0] ?? "")" }.joined(separator: "\n")
            .write(to: markerURL, atomically: true, encoding: .utf8)
        if entries != store.settings.webSlides {
            store.settings.webSlides = entries
            if !store.isEditing { store.save() }
        }
        return created
    }

    /// Отпечаток текста: короткий, устойчивый, без криптографии.
    private static func hash(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Сколько посеянных страниц лежит на месте — для самопроверки.
    static func presentCount() -> Int {
        let folder = WebOutputServer.userPagesFolder
        return WebSlideTemplates.all.filter { template in
            prefixes.contains { template.id.hasPrefix($0) }
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent(template.id + ".html").path)
        }.count
    }
}
