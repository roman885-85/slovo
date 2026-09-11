import Foundation

/// Хранилище преднастроек и привязка их к выводам.
///
/// Преднастройки лежат обычными JSON-файлами в папке поддержки приложения:
/// их можно скопировать на другой компьютер, положить в общую папку прихода
/// или прислать письмом. Формат намеренно читаемый — чинится текстовым
/// редактором, если что-то пошло не так перед служением.
public final class PresetLibrary {

    public private(set) var presets: [SlidePreset]
    /// Какая преднастройка назначена каждому выводу.
    public private(set) var assignments: [OutputKind: UUID]

    private let folder: URL
    private let assignmentsFile: URL

    public init(folder: URL) {
        self.folder = folder
        self.assignmentsFile = folder.appendingPathComponent("assignments.json")
        self.presets = []
        self.assignments = [:]

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    /// Папка по умолчанию — рядом с остальными данными приложения.
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Slovo/Presets")
    }

    // MARK: - Чтение и запись

    public func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let decoder = JSONDecoder()
        presets = files
            .filter { $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != "assignments.json" }
            .compactMap { url -> SlidePreset? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                // Битый файл не должен ронять запуск: пропускаем и работаем дальше.
                return try? decoder.decode(SlidePreset.self, from: data)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if let data = try? Data(contentsOf: assignmentsFile),
           let raw = try? decoder.decode([String: UUID].self, from: data) {
            assignments = raw.reduce(into: [:]) { result, pair in
                guard let kind = OutputKind(rawValue: pair.key) else { return }
                result[kind] = pair.value
            }
        }
    }

    @discardableResult
    public func save(_ preset: SlidePreset) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(preset) else { return false }

        let url = folder.appendingPathComponent(fileName(for: preset))
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }

        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
            presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return true
    }

    @discardableResult
    public func delete(_ preset: SlidePreset) -> Bool {
        let url = folder.appendingPathComponent(fileName(for: preset))
        try? FileManager.default.removeItem(at: url)
        presets.removeAll { $0.id == preset.id }
        for (kind, id) in assignments where id == preset.id { assignments[kind] = nil }
        persistAssignments()
        return true
    }

    /// Имя файла делаем из имени преднастройки, но идентификатор всё равно
    /// внутри: переименование не создаёт дубликат, а перезапись не путает
    /// две разные преднастройки с похожими названиями.
    private func fileName(for preset: SlidePreset) -> String {
        let safe = preset.name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let stem = safe.isEmpty ? "preset" : safe
        return "\(stem)-\(preset.id.uuidString.prefix(8)).json"
    }

    // MARK: - Привязка к выводам

    public func preset(for kind: OutputKind) -> SlidePreset? {
        guard let id = assignments[kind] else { return nil }
        return presets.first { $0.id == id }
    }

    public func assign(_ preset: SlidePreset, to kind: OutputKind) {
        assignments[kind] = preset.id
        persistAssignments()
    }

    /// Снять свой шаблон с вывода: он вернётся к авторскому.
    public func unassign(_ kind: OutputKind) {
        guard assignments[kind] != nil else { return }
        assignments[kind] = nil
        persistAssignments()
    }

    private func persistAssignments() {
        let raw = assignments.reduce(into: [String: UUID]()) { $0[$1.key.rawValue] = $1.value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(raw) else { return }
        try? data.write(to: assignmentsFile, options: .atomic)
    }

    // MARK: - Первый запуск

    /// Создаёт стартовый набор, если папка пуста, и раздаёт его выводам.
    ///
    /// Отталкиваемся от стиля, уже вычитанного из настроек VisioBible, —
    /// тогда при первом запуске картинка совпадает с привычной, а не
    /// начинается с чужих значений по умолчанию.
    public func seedIfEmpty(from style: SlideStyle) {
        guard presets.isEmpty else { return }

        // Имена — на языке интерфейса при первом запуске; дальше это данные
        // владельца, и переименовывает их он сам в Конструкторе.
        let screen = SlidePreset.standard(name: OurWords.t("Проектор"), style: style)
        let stage = SlidePreset.stage(name: OurWords.t("Экран служителя"), style: style)
        let web = SlidePreset.standard(name: OurWords.t("Web слайды"), style: style)

        for preset in [screen, stage, web] { save(preset) }

        assignments[.screen] = screen.id
        assignments[.preview] = screen.id
        // Трансляции — тот же шаблон, что и залу. Подложку с него снимает
        // правило вывода (`NdiTransparentBackGr`), а не отдельный шаблон:
        // иначе правка в Конструкторе доходит до зала и не доходит до сети.
        assignments[.ndi] = screen.id
        assignments[.stage] = stage.id
        assignments[.web] = web.id
        persistAssignments()
    }
}
