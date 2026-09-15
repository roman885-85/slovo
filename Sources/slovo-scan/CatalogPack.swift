import Foundation
import CryptoKit
import SlovoCore

/// Зібрати ресурси для GitHub: із теки даних програми (`Contents/Resources/app`)
/// — по zip-у на модуль, пісенник, фони, шаблони, шрифти, веб-сторінки — і
/// `catalog.json` до них. Власник: «все пакеты и переводы, картинки и другие
/// ресурсы что есть выложить отдельно на гитхаб».
///
///     slovo-scan --catalog <тека app> <тека виходу> <адреса файлів>
///
/// Zip-и — `ditto -c -k --keepParent`, тож розпаковка в теку модулів чи в
/// корінь даних кладе теку під її власним ім'ям.
/// Ім'я файла для GitHub: лише латиниця, цифри, крапка, дефіс; решта —
/// дефісом, а щоб «Філ» і «Фил» не злилися — хвіст зі стійкого хешу імені.
func asciiSlug(_ name: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    var slug = String(name.map { allowed.contains($0) ? $0 : "-" })
    while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
    slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    var hash: UInt32 = 2_166_136_261
    for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
    let tail = String(format: "%06x", hash & 0xFFFFFF)
    return (slug.isEmpty ? "res" : slug) + "-" + tail
}

func runCatalogPack(app: URL, out: URL, base: String) -> Int32 {
    let fm = FileManager.default
    try? fm.createDirectory(at: out, withIntermediateDirectories: true)
    let stamp: String = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }()
    var items: [ResourceItem] = []
    var failures: [String] = []

    /// Версія ресурсу — початок SHA-256 його zip-а: не змінився вміст — та
    /// сама версія, і програма не пропонує «оновлення» того самого.
    func digest(of name: String) -> String {
        guard let data = try? Data(contentsOf: out.appendingPathComponent(name + ".zip")) else { return stamp }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    func zip(_ source: URL, as name: String) -> Int64? {
        let target = out.appendingPathComponent(name + ".zip")
        try? fm.removeItem(at: target)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // Без розширених атрибутів і ресурсних гілок — щоб той самий вміст
        // давав той самий zip. `--keepParent` — лише для тек: для файла він
        // кладе в архів його батьківську теку («Modules/pv3055.songbook»), і
        // програма 0.8 ставила пісенник ТЕКОЮ.
        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        process.arguments = ["-c", "-k"] + (isFolder ? ["--keepParent"] : [])
            + ["--norsrc", "--noextattr", "--noqtn", "--noacl", source.path, target.path]
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0,
              let size = (try? fm.attributesOfItem(atPath: target.path))?[.size] as? Int64 else { return nil }
        return size
    }
    func link(_ name: String) -> String {
        let escaped = (name + ".zip").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name + ".zip"
        return base.hasSuffix("/") ? base + escaped : base + "/" + escaped
    }

    // Модулі й пісенники.
    let modules = app.appendingPathComponent("Modules")
    let entries = ((try? fm.contentsOfDirectory(at: modules, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? [])
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    for entry in entries {
        let name = entry.lastPathComponent
        let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        var kind: ResourceItem.Kind
        var title = name, subtitle = ""
        var language: String?
        if isDirectory {
            guard let module = try? BibleModule(directory: entry) else { failures.append("\(name): не модуль"); continue }
            kind = .bible
            title = module.info.name.isEmpty ? name : module.info.name
            subtitle = [module.info.shortName, module.info.language ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            language = languageCode(declared: module.info.language, sample: title + " " + textSample(of: module))
        } else {
            switch entry.pathExtension.lowercased() {
            case "songbook", "vbm":
                guard let book = try? SongBook(fileAt: entry) else { failures.append("\(name): не пісенник"); continue }
                kind = .songbook
                title = book.title.isEmpty ? name : book.title
                let lyrics = book.songs.prefix(12).flatMap { $0.parts.map(\.text) }.joined(separator: " ")
                language = languageCode(declared: nil, sample: title + " " + lyrics)
                subtitle = "\(book.songs.count) " + OurWords.t("песен") + (book.shortName.isEmpty ? "" : " · " + book.shortName)
            case "sqlite3", "sqlite":
                guard let module = try? MyBibleModule(fileAt: entry) else { continue }
                kind = .bible
                title = module.info.name.isEmpty ? name : module.info.name
                subtitle = module.info.shortName
                language = languageCode(declared: module.info.language, sample: title + " " + textSample(of: module))
            case "mybible":
                guard MySwordModule.isBibleModuleName(name), let module = try? MySwordModule(fileAt: entry) else { continue }
                kind = .bible
                title = module.info.name.isEmpty ? name : module.info.name
                subtitle = module.info.shortName
                language = languageCode(declared: module.info.language, sample: title + " " + textSample(of: module))
            default:
                continue
            }
        }
        let stem = isDirectory ? name : entry.deletingPathExtension().lastPathComponent
        let zipName = (kind == .songbook ? "songbook-" : "module-") + asciiSlug(stem)
        guard let size = zip(entry, as: zipName) else { failures.append("\(name): zip не зібрався"); continue }
        // Пісенник упізнається за основою імені: «pv3055.vbm» і «pv3055.songbook»
        // — той самий ресурс, і перехід на свій формат не робить із нього новий.
        items.append(ResourceItem(id: kind == .songbook ? "songbook:" + stem : "bible:" + name, kind: kind,
                                  title: title, subtitle: subtitle, size: size, version: digest(of: zipName),
                                  url: link(zipName), fileName: name, language: language))
        print("  \(kind.rawValue)  \(name)  \(size / 1024) КБ")
    }

    // Фони, шаблони, шрифти, веб-сторінки — одним zip-ом кожне.
    let bundles: [(String, ResourceItem.Kind, String, String)] = [
        ("BackGrounds", .backgrounds, "Фони слайдів", "картинки для підкладки слайда"),
        ("Templates", .templates, "Шаблони слайдів VisioBible", "авторські схеми .sch з картинками"),
        ("Fonts", .fonts, "Шрифти", "шрифти для шаблонів"),
        ("RemoteAPI", .web, "Сторінки веб-слайдів", "сторінки для виводу в браузер"),
    ]
    for (folder, kind, title, subtitle) in bundles {
        let source = app.appendingPathComponent(folder)
        guard fm.fileExists(atPath: source.path) else { continue }
        guard let size = zip(source, as: folder) else { failures.append("\(folder): zip не зібрався"); continue }
        items.append(ResourceItem(id: kind.rawValue, kind: kind, title: title, subtitle: subtitle,
                                  size: size, version: digest(of: folder), url: link(folder), fileName: folder))
        print("  \(kind.rawValue)  \(folder)  \(size / 1024) КБ")
    }

    let catalog = ResourceCatalog(updated: stamp, items: items)
    do {
        try catalog.encoded().write(to: out.appendingPathComponent("catalog.json"))
    } catch {
        print("catalog.json не записався: \(error)"); return 1
    }
    print("каталог: \(items.count) ресурсів, \(failures.count) пропущено" + (failures.isEmpty ? "" : ": " + failures.joined(separator: "; ")))
    return 0
}


// MARK: - Мова ресурсу

/// Кілька віршів першого розділу — за ними впізнається мова, коли в модулі
/// її не вказано.
func textSample(of module: TextModule) -> String {
    guard let book = module.books.first(where: { $0.index >= 40 }) ?? module.books.first,
          let chapter = (try? module.chapters(ofBook: book))?.first else { return "" }
    return chapter.verses.prefix(20).map(\.text).joined(separator: " ")
}

/// Код мови для пошуку у вікні ресурсів («uk», «ru», «en»).
///
/// У своєму каталозі мови не було зовсім, і пошук «uk» знаходив два
/// переклади з п'ятдесяти шести (0.87). Вказану в модулі мову беремо першою;
/// інакше — за літерами, яких немає в сусідніх абетках.
func languageCode(declared: String?, sample: String) -> String? {
    if let raw = declared?.trimmingCharacters(in: .whitespaces).lowercased(), raw.count >= 2 {
        let code = String(raw.prefix(2))
        let aliases = ["ua": "uk", "by": "be"]
        if code.allSatisfy({ $0.isASCII && $0.isLetter }) { return aliases[code] ?? code }
    }
    let text = sample.lowercased()
    func has(_ letters: String) -> Bool { text.contains { letters.contains($0) } }
    let scalars = text.unicodeScalars
    // Назви, за якими мову видно одразу, — надійніше за літери зразка:
    // грецький Новий Завет із транслітерацією, естонська з «ä» тощо.
    let named: [(String, String)] = [("greek", "el"), ("греческ", "el"), ("textus receptus", "el"),
                                     ("estonian", "et"), ("romanian", "ro"), ("cornilescu", "ro"),
                                     ("reina-valera", "es"), ("santa biblia", "es"), ("o‘zbek", "uz"),
                                     ("o'zbek", "uz"), ("muqaddas", "uz"), ("injil", "uz")]
    for (word, code) in named where text.contains(word) { return code }
    if scalars.contains(where: { (0x0530...0x058F).contains($0.value) }) { return "hy" }
    if scalars.contains(where: { (0x0590...0x05FF).contains($0.value) }) { return "he" }
    if scalars.contains(where: { (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value) }) { return "el" }
    let cyrillic = scalars.filter { (0x0400...0x04FF).contains($0.value) }.count
    let latin = scalars.filter { ("a"..."z").contains(Character($0)) }.count
    if cyrillic > latin {
        if has("әұһ") { return "kk" }
        if has("өүң") { return "ky" }
        if has("қғҳ") { return "uz" }
        if has("ў") { return has("і") ? "be" : "uz" }
        if has("їєґ") { return "uk" }
        if has("і") && !has("ыэъ") { return "uk" }
        return "ru"
    }
    guard latin > 0 else { return nil }
    if has("șşțţăâî") { return "ro" }
    if has("ñ¿¡") { return "es" }
    if has("õ") { return "et" }
    if has("ėųūį") { return "lt" }
    if has("ąęłńśźż") { return "pl" }
    if has("äöüß") { return "de" }
    return "en"
}
