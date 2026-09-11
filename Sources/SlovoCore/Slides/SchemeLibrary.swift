import Foundation

/// Тека `Templates` оригіналу: список шаблонів, їхні фони й мініатюри.
///
/// Влаштована вона так: поруч із файлом `<Ім'я>.sch` лежить однойменна тека з
/// усіма картинками цього шаблону — фон, лінії, панелі — і підтека `thumbs`
/// з готовими прев'ю `scene1.jpg` (один переклад) і `scene2.jpg` (два).
/// Саме на такий розклад розрахований і сам `VisioBible.ini`, де шлях до фону
/// записано як `Templates\SpringFade\spring_fon 2.jpg`.
public struct SchemeLibrary: Sendable {

    /// Висота слайда, під яку в оригіналі підбирали обведення й тінь.
    /// Справжнє значення лежить у `[OutScreen] height`; 600 — те саме
    /// умовчання, що й у `SlideStyle.init(config:section:dataRoot:)`.
    public static let defaultDesignHeight: Double = 600

    public struct Template: Sendable, Hashable, Identifiable {
        public let name: String
        public let fileURL: URL
        public let folderURL: URL
        public let scheme: SlideScheme
        public let backgroundURL: URL?
        public let singleThumbnailURL: URL?
        public let dualThumbnailURL: URL?
        /// Уміст теки шаблону — щоб шукати картинки без звертання до диска.
        let files: [String]

        public var id: String { name }

        public func thumbnailURL(_ variant: SlideScheme.Variant = .single) -> URL? {
            variant == .single ? singleThumbnailURL : dualThumbnailURL
        }

        /// Шлях до картинки шаблону (`Image` / `ImageMask` будь-якого елемента).
        public func imageURL(named name: String?) -> URL? {
            guard let name, !name.isEmpty else { return nil }
            return SchemeLibrary.resolve(name, in: folderURL, files: files)
        }
    }

    public let root: URL
    public let templates: [Template]
    /// Що не вдалося прочитати: ім'я файла -> причина. Один битий шаблон не
    /// має забирати із собою всю теку.
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

    /// `dataRoot` — тека застосунку VisioBible, та сама, що в `Modules`.
    public init(dataRoot: URL, designHeight: Double = SchemeLibrary.defaultDesignHeight) {
        self.init(templatesRoot: dataRoot.appendingPathComponent("Templates", isDirectory: true),
                  designHeight: designHeight)
    }

    /// Висоту слайда, під яку рахувалися пікселі обведення, беремо з ini.
    public init(dataRoot: URL, config: IniSettings?) {
        let height = config.flatMap { $0.int("height", in: "OutScreen") }.map(Double.init)
        self.init(dataRoot: dataRoot, designHeight: max(height ?? SchemeLibrary.defaultDesignHeight, 1))
    }

    // MARK: - Пошук

    public var names: [String] { templates.map(\.name) }

    public var isEmpty: Bool { templates.isEmpty }

    /// Ім'я шаблону приходить з ini (`DefaultScheme=SpringFade`), тому
    /// порівнюємо без урахування регістру — Windows його не розрізняє.
    public func template(named name: String) -> Template? {
        templates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? templates.first { $0.scheme.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public subscript(name: String) -> Template? { template(named: name) }

    // MARK: - Переведення в стиль слайда

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

    // MARK: - Файли

    /// Шукає файл за ім'ям із шаблону.
    ///
    /// Імена в `.sch` писалися на Windows: регістр там не важливий, роздільник —
    /// зворотна скісна риска, а кирилиця могла лягти в іншій нормалізації Unicode,
    /// ніж на диску в нас. Пряме звертання зазвичай спрацьовує, але якщо ні —
    /// звіряємося зі списком теки вже вручну.
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
