import Foundation

/// Папка `Templates` оригинала: список шаблонов, их фоны и миниатюры.
///
/// Устроена она так: рядом с файлом `<Имя>.sch` лежит одноимённая папка со
/// всеми картинками этого шаблона — фон, линии, панели — и подпапка `thumbs`
/// с готовыми превью `scene1.jpg` (один перевод) и `scene2.jpg` (два).
/// Именно на этот расклад рассчитан и сам `VisioBible.ini`, где путь к фону
/// записан как `Templates\SpringFade\spring_fon 2.jpg`.
public struct SchemeLibrary: Sendable {

    /// Высота слайда, под которую в оригинале подбирали обводку и тень.
    /// Настоящее значение лежит в `[OutScreen] height`; 600 — то же
    /// умолчание, что и в `SlideStyle.init(config:section:dataRoot:)`.
    public static let defaultDesignHeight: Double = 600

    public struct Template: Sendable, Hashable, Identifiable {
        public let name: String
        public let fileURL: URL
        public let folderURL: URL
        public let scheme: SlideScheme
        public let backgroundURL: URL?
        public let singleThumbnailURL: URL?
        public let dualThumbnailURL: URL?
        /// Содержимое папки шаблона — чтобы искать картинки без обращения к диску.
        let files: [String]

        public var id: String { name }

        public func thumbnailURL(_ variant: SlideScheme.Variant = .single) -> URL? {
            variant == .single ? singleThumbnailURL : dualThumbnailURL
        }

        /// Путь к картинке шаблона (`Image` / `ImageMask` любого элемента).
        public func imageURL(named name: String?) -> URL? {
            guard let name, !name.isEmpty else { return nil }
            return SchemeLibrary.resolve(name, in: folderURL, files: files)
        }
    }

    public let root: URL
    public let templates: [Template]
    /// Что не удалось прочитать: имя файла -> причина. Один битый шаблон не
    /// должен уносить с собой всю папку.
    public let failures: [String: String]
    public var designHeight: Double

    public init(templatesRoot: URL, designHeight: Double = SchemeLibrary.defaultDesignHeight) {
        self.root = templatesRoot
        self.designHeight = designHeight

        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(atPath: templatesRoot.path)) ?? []

        var templates: [Template] = []
        var failures: [String: String] = [:]

        for entry in entries where entry.lowercased().hasSuffix(".sch") {
            let fileURL = templatesRoot.appendingPathComponent(entry)
            let name = fileURL.deletingPathExtension().lastPathComponent
            do {
                let scheme = try SchemeParser.scheme(contentsOf: fileURL)
                let folder = templatesRoot.appendingPathComponent(name, isDirectory: true)
                let files = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
                let thumbs = folder.appendingPathComponent("thumbs", isDirectory: true)
                let thumbFiles = (try? manager.contentsOfDirectory(atPath: thumbs.path)) ?? []

                templates.append(Template(
                    name: name,
                    fileURL: fileURL,
                    folderURL: folder,
                    scheme: scheme,
                    backgroundURL: Self.resolve(scheme.backgroundImageName, in: folder, files: files),
                    singleThumbnailURL: Self.resolve("scene1.jpg", in: thumbs, files: thumbFiles),
                    dualThumbnailURL: Self.resolve("scene2.jpg", in: thumbs, files: thumbFiles),
                    files: files))
            } catch {
                failures[entry] = error.localizedDescription
            }
        }

        self.templates = templates.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        self.failures = failures
    }

    /// `dataRoot` — папка приложения VisioBible, та же, что у `Modules`.
    public init(dataRoot: URL, designHeight: Double = SchemeLibrary.defaultDesignHeight) {
        self.init(templatesRoot: dataRoot.appendingPathComponent("Templates", isDirectory: true),
                  designHeight: designHeight)
    }

    /// Высоту слайда, под которую считались пиксели обводки, берём из ini.
    public init(dataRoot: URL, config: IniSettings?) {
        let height = config.flatMap { $0.int("height", in: "OutScreen") }.map(Double.init)
        self.init(dataRoot: dataRoot, designHeight: max(height ?? SchemeLibrary.defaultDesignHeight, 1))
    }

    // MARK: - Поиск

    public var names: [String] { templates.map(\.name) }

    public var isEmpty: Bool { templates.isEmpty }

    /// Имя шаблона приходит из ini (`DefaultScheme=SpringFade`), поэтому
    /// сравниваем без учёта регистра — Windows его не различает.
    public func template(named name: String) -> Template? {
        templates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? templates.first { $0.scheme.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public subscript(name: String) -> Template? { template(named: name) }

    // MARK: - Перевод в стиль слайда

    public func slideStyle(for template: Template,
                           base: SlideStyle = SlideStyle(),
                           variant: SlideScheme.Variant = .single,
                           designHeight: Double? = nil) -> SlideStyle {
        template.scheme.slideStyle(base: base,
                                   designHeight: designHeight ?? self.designHeight,
                                   variant: variant,
                                   backgroundPath: template.backgroundURL?.path)
    }

    public func slideStyle(named name: String,
                           base: SlideStyle = SlideStyle(),
                           variant: SlideScheme.Variant = .single,
                           designHeight: Double? = nil) -> SlideStyle? {
        guard let template = template(named: name) else { return nil }
        return slideStyle(for: template, base: base, variant: variant, designHeight: designHeight)
    }

    // MARK: - Файлы

    /// Ищет файл по имени из шаблона.
    ///
    /// Имена в `.sch` писались на Windows: регистр там не важен, разделитель
    /// обратный слэш, а кириллица могла лечь в другой нормализации Unicode,
    /// чем на диске у нас. Прямое обращение обычно срабатывает, но если нет —
    /// сверяемся со списком папки уже вручную.
    static func resolve(_ name: String, in folder: URL, files: [String]) -> URL? {
        guard !name.isEmpty else { return nil }
        let cleaned = name.replacingOccurrences(of: "\\", with: "/")
        let leaf = cleaned.split(separator: "/").last.map(String.init) ?? cleaned

        let direct = folder.appendingPathComponent(leaf)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        let wanted = leaf.precomposedStringWithCanonicalMapping.lowercased()
        for file in files where file.precomposedStringWithCanonicalMapping.lowercased() == wanted {
            return folder.appendingPathComponent(file)
        }
        return nil
    }
}
