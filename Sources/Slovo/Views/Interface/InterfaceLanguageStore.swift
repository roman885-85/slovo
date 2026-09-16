import AppKit
import SlovoCore

/// Хранилище переводов интерфейса для окна «Перевод интерфейса» (7.1).
///
/// Главное правило: файлы `Language/*.lng` в папке VisioBible мы только
/// читаем. Рядом стоит рабочая программа, служение может пройти и в ней, и
/// испортить ей подписи нашей правкой нельзя. Поэтому изменённый перевод
/// уходит в свою папку, а программа читает объединённый список: где есть наш
/// файл — берётся наш, остальное как было.
///
/// Объединение сделано отдельной папкой со ссылками, а не списком файлов,
/// потому что `LanguageCatalog` из SlovoCore умеет читать ровно одну папку.
@MainActor
enum InterfaceLanguageStore {

    /// Наши переводы. Папка данных VisioBible для записи не годится: она
    /// может лежать внутри бандла программы или на диске только для чтения.
    static var userDirectory: URL {
        DataHome.folder.appendingPathComponent("Language")
    }

    /// Папка-склейка: ссылки на оригиналы плюс ссылки на наши файлы.
    private static var stagedDirectory: URL {
        DataHome.supportFolder.appendingPathComponent("LanguageMerged")
    }

    // MARK: - Список переводов

    /// Все переводы: оригинальные и наши. Наш файл с тем же кодом вытесняет
    /// оригинальный — это и есть «правка перевода».
    static func languages(originals: URL) -> [LanguageFile] {
        var byCode: [String: LanguageFile] = [:]
        for file in read(directory: originals) { byCode[file.code.lowercased()] = file }
        for file in read(directory: userDirectory) { byCode[file.code.lowercased()] = file }
        return byCode.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func language(code: String, originals: URL) -> LanguageFile? {
        languages(originals: originals).first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    /// Перевод, который правил пользователь, — только такой можно удалить.
    static func isUserOwned(code: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(code: code).path)
    }

    static func fileURL(code: String) -> URL {
        userDirectory.appendingPathComponent("\(code).lng")
    }

    private static func read(directory: URL) -> [LanguageFile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "lng" }
            .compactMap { try? LanguageFile(fileAt: $0) }
    }

    // MARK: - Папка, из которой читает программа

    /// Пересобрать папку-склейку и вернуть её. Если своих переводов нет,
    /// возвращаем оригинальную папку — лишних сущностей не заводим.
    @discardableResult
    static func mergedDirectory(originals: URL) -> URL {
        let manager = FileManager.default
        let mine = read(directory: userDirectory).map { $0.code.lowercased() }
        guard !mine.isEmpty else {
            // Своих переводов не осталось (последний удалили в окне 7.1) —
            // убираем и склейку. Иначе в ней навсегда повисла бы ссылка на
            // удалённый файл, и список языков показывал бы пустую строку.
            try? manager.removeItem(at: stagedDirectory)
            return originals
        }

        try? manager.removeItem(at: stagedDirectory)
        guard (try? manager.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)) != nil else {
            return originals
        }

        // Ссылки, а не копии: оригиналы могут обновиться вместе с VisioBible,
        // и копия бы тихо устарела.
        let originalFiles = (try? manager.contentsOfDirectory(at: originals,
                                                              includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles])) ?? []
        for file in originalFiles where file.pathExtension.lowercased() == "lng" {
            let code = file.deletingPathExtension().lastPathComponent.lowercased()
            guard !mine.contains(code) else { continue }
            try? manager.createSymbolicLink(at: stagedDirectory.appendingPathComponent(file.lastPathComponent),
                                            withDestinationURL: file)
        }
        for code in mine {
            let file = fileURL(code: code)
            try? manager.createSymbolicLink(at: stagedDirectory.appendingPathComponent("\(code).lng"),
                                            withDestinationURL: file)
        }
        return stagedDirectory
    }

    /// Сообщить программе, что набор переводов изменился.
    ///
    /// Через уведомление, а не прямым вызовом: каталог переводов держит
    /// `AppState`, поле закрыто на запись, и лезть в него из окна перевода
    /// значило бы связать окно с внутренностями главного состояния. Подписку
    /// добавляет вставка из `integration`; пока её нет, правка подхватится при
    /// следующем запуске — сам файл уже на месте.
    static func announceChange(originals: URL) {
        mergedDirectory(originals: originals)
        NotificationCenter.default.post(name: .slovoInterfaceLanguagesChanged, object: nil)
    }

    // MARK: - Флаги

    /// Флажок перевода — `Language/xx.png` оригинала, 16×16.
    static func flag(code: String, originals: URL) -> NSImage? {
        let candidates = [userDirectory.appendingPathComponent("\(code).png"),
                          originals.appendingPathComponent("\(code).png")]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = ImageCache.image(atPath: url.path) { return image }
        }
        return nil
    }

    // MARK: - Запись

    /// Пара «подпись + подсказка» в правке.
    ///
    /// Своя, а не `LanguageFile.Entry`: у той поля только для чтения и нет
    /// открытого инициализатора — она описывает прочитанный файл, а не черновик.
    struct TextPair: Hashable {
        var caption: String
        var hint: String?

        init(caption: String, hint: String? = nil) {
            self.caption = caption
            self.hint = (hint?.isEmpty ?? true) ? nil : hint
        }

        init(_ entry: LanguageFile.Entry) {
            self.init(caption: entry.caption, hint: entry.hint)
        }
    }

    typealias Draft = [String: [String: TextPair]]

    /// Прочитанный перевод целиком, в виде черновика.
    static func draft(of file: LanguageFile) -> Draft {
        var draft: Draft = [:]
        for (form, entries) in file.forms where form != "_info_" {
            draft[form] = entries.mapValues(TextPair.init)
        }
        return draft
    }

    static func write(draft: Draft, code: String, displayName: String) throws {
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let text = serialize(draft: draft, displayName: displayName)
        // BOM и UTF-8 — как в файлах оригинала: их же читает и сам VisioBible,
        // если человек решит положить наш перевод рядом с его.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        try data.write(to: fileURL(code: code), options: .atomic)
    }

    static func delete(code: String) throws {
        try FileManager.default.removeItem(at: fileURL(code: code))
    }

    /// Сборка `.lng`: секция `[_info_]` с названием языка, дальше по секции на
    /// форму. Строки в порядке имён — так же, как в файлах автора.
    static func serialize(draft: Draft, displayName: String) -> String {
        var lines: [String] = ["[_info_]", "lang=\(escape(displayName))", ""]

        for form in draft.keys.sorted() where form != "_info_" && !form.isEmpty {
            guard let entries = draft[form], !entries.isEmpty else { continue }
            lines.append("[\(form)]")
            for key in entries.keys.sorted() {
                guard let entry = entries[key] else { continue }
                lines.append("\(key)=\(value(for: entry))")
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    /// «подпись,подсказка». Обе части всегда в `~…~`: так не теряются краевые
    /// пробелы и запятые внутри текста — ровно за этим тильды и введены.
    private static func value(for entry: TextPair) -> String {
        let caption = entry.caption.isEmpty ? "" : "~\(escape(entry.caption))~"
        guard let hint = entry.hint, !hint.isEmpty else { return caption }
        return "\(caption),~\(escape(hint))~"
    }

    private static func escape(_ text: String) -> String {
        text
            // `&` в формате — акселератор Windows, литерал пишется удвоением.
            .replacingOccurrences(of: "&", with: "&&")
            // Тильда — разделитель, а способа её экранировать формат не даёт.
            .replacingOccurrences(of: "~", with: "-")
            // Перевод строки в файлах автора записан двумя знаками «\n».
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

extension Notification.Name {
    /// Свой перевод интерфейса создан, изменён или удалён.
    static let slovoInterfaceLanguagesChanged = Notification.Name("slovo.interfaceLanguagesChanged")
}
