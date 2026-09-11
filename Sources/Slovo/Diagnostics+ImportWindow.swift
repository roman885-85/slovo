import AppKit
import SlovoCore

/// Самопроверка двух окон, переписанных с SwiftUI на AppKit: мастера импорта
/// (4.2) и конструктора слайда (6.3).
///
/// Проверки собирают настоящие виды и заставляют их разложиться, а не смотрят
/// на модель. Ловушку «написано, но не подключено» мы проходили не раз: окно
/// строилось, а список в нём оставался пустым, и увидеть это можно было
/// только глазами. Теперь окно ещё и снимается в картинку — её видно из
/// `~/Library/Logs`.
extension Diagnostics {

    static func importWindowSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        let area = "Майстер імпорту"

        // Источник делаем свой, во временной папке: чужие данные мастер не
        // трогает даже на чтение, а проверять надо на непустой описи.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-мастер-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let made = makeImportFixture(at: temp)

        guard made, let source = try? ModuleImporter.source(at: temp) else {
            return [Check(area: area, name: "Майстер імпорту зібрано (4.2)", status: .skipped,
                          detail: "не вдалося зібрати тимчасове джерело в \(temp.path)")]
        }

        let destination = ImportDestination(dataRoot: temp.appendingPathComponent("куди"))
        let model = ImportWizardModel(destination: destination)
        model.addChosen(temp, language: state.language)

        // Опись строим сами и на месте: в окне она считается в фоне, а
        // самопроверка ждать не умеет.
        let inventory = ModuleImporter.inventory(of: source, destination: destination)
        model.modules = inventory.modules
        model.templates = inventory.templates
        model.images = inventory.images

        let wizard = NativeImportWizard(state: state, model: model, onClose: {})
        // Вид должен стоять в окне: без окна у него нет ни слоя, ни задника,
        // и снимок выходит пустым — первый раз так и вышло, а проверка при
        // этом бодро писала «снимки лежат там-то».
        let stand = bench(for: wizard, size: NSSize(width: 940, height: 660))

        var faults: [String] = []
        var seen: [String] = []
        for page in ImportWizardModel.Page.allCases {
            model.page = page
            wizard.refresh()
            wizard.layoutSubtreeIfNeeded()
            guard let view = wizard.view(of: page) else {
                faults.append("\(name(of: page)): сторінки немає")
                continue
            }
            if view.subviews.isEmpty { faults.append("\(name(of: page)): сторінка порожня") }
            if view.bounds.width < 100 || view.bounds.height < 100 {
                faults.append("\(name(of: page)): сторінку не розкладено")
            }
            seen.append(name(of: page))
            if !snapshot(wizard, to: "slovo-мастер-\(name(of: page)).png") {
                faults.append("\(name(of: page)): знімок не записався")
            }
        }

        // Списки 4.2.1–4.2.5 должны показывать ровно то, что в описи: пустой
        // список при непустой описи — как раз та беда, которую видно только
        // глазами.
        model.page = .versions
        wizard.refresh()
        if let versions = wizard.view(of: .versions) as? ImportVersionsPage,
           versions.shownRows != model.sources.count {
            faults.append("версії: рядків \(versions.shownRows), джерел \(model.sources.count)")
        }
        for page in [ImportWizardModel.Page.modules, .templates, .images] {
            model.page = page
            wizard.refresh()
            guard let list = wizard.view(of: page) as? ImportListPage else {
                faults.append("\(name(of: page)): не список")
                continue
            }
            let wanted = model.items(on: page).count
            if list.shownRows != wanted {
                faults.append("\(name(of: page)): рядків \(list.shownRows), в описі \(wanted)")
            }
        }

        checks.append(Check(area: area, name: "Майстер імпорту зібрано (4.2)",
                            status: faults.isEmpty ? .ok : .failed,
                            detail: faults.isEmpty
                                ? "сторінки: \(seen.joined(separator: ", ")); опис — модулів "
                                    + "\(inventory.modules.count), шаблонів \(inventory.templates.count), "
                                    + "зображень \(inventory.images.count); знімки в ~/Library/Logs/slovo-мастер-*.png"
                                : faults.joined(separator: "; ")))

        // Галочка строки доходит до модели: без этого «Отметить всё» и сам
        // перенос работали бы каждый со своим списком. Берём ту страницу, где
        // в описи вообще что-то есть: модулей во временном источнике нет.
        let pageWithItems = [ImportWizardModel.Page.modules, .templates, .images]
            .first { !model.items(on: $0).isEmpty }
        if let page = pageWithItems, let first = model.items(on: page).first {
            let was = first.isSelected
            model.setSelected(first.id, on: page, to: !was)
            let now = model.items(on: page).first?.isSelected
            model.setSelected(first.id, on: page, to: was)
            checks.append(Check(area: area, name: "Галочка опису доходить до моделі",
                                status: now == !was ? .ok : .failed,
                                detail: now == !was
                                    ? "\(name(of: page)), «\(first.title)»: "
                                        + "\(was ? "знята" : "поставлена") і повернуто"
                                    : "рядок «\(first.title)» не змінився"))
        }

        stand.orderOut(nil)
        checks.append(contentsOf: constructorWindowChecks(state: state))
        return checks
    }

    /// Конструктор слайда: окно собирается и список объектов не пуст.
    private static func constructorWindowChecks(state: AppState) -> [Check] {
        let area = "Конструктор"
        let view = NativeSlideConstructor(state: state, onClose: {})
        let stand = bench(for: view, size: NSSize(width: 1240, height: 760))
        defer { stand.orderOut(nil) }

        var faults: [String] = []
        if view.subviews.count < 5 { faults.append("частин вікна \(view.subviews.count)") }
        if view.listedObjects == 0 { faults.append("список об'єктів порожній") }
        if !snapshot(view, to: "slovo-конструктор.png") { faults.append("знімок не записався") }

        return [Check(area: area, name: "Вікно конструктора зібрано (6.3)",
                      status: faults.isEmpty ? .ok : .failed,
                      detail: faults.isEmpty
                          ? "об'єктів у списку \(view.listedObjects); знімок у "
                              + "~/Library/Logs/slovo-конструктор.png"
                          : faults.joined(separator: "; "))]
    }

    /// Окно-подставка: вид рисуется только тогда, когда он в окне. Окно
    /// заводится за краем экрана и человеку не показывается.
    static func bench(for view: NSView, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return window
    }

    /// Снимок вида в файл. Возвращает, записался ли он: молчаливая неудача
    /// превратила бы проверку в обещание.
    static func snapshot(_ view: NSView, to name: String) -> Bool {
        guard view.bounds.width > 1, view.bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        let path = NSString(string: "~/Library/Logs/\(name)").expandingTildeInPath
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    /// Временный источник: папка шаблонов, фоновое изображение и файл
    /// настроек — по одному на каждую страницу описи.
    private static func makeImportFixture(at root: URL) -> Bool {
        let manager = FileManager.default
        do {
            for folder in ["Templates", "BackGrounds"] {
                try manager.createDirectory(at: root.appendingPathComponent(folder),
                                            withIntermediateDirectories: true)
            }
            let scheme = root.appendingPathComponent("Templates/Проверка.sch")
            try "[Scheme]\nName=Проверка\n".write(to: scheme, atomically: true, encoding: .utf8)

            let picture = root.appendingPathComponent("BackGrounds/фон.png")
            let image = NSImage(size: NSSize(width: 8, height: 8))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return false }
            try png.write(to: picture)

            let ini = root.appendingPathComponent("VisioBible.ini")
            try "[options]\nFullScreen=1\n[mediaplayer]\nVolume=80\n"
                .write(to: ini, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func name(of page: ImportWizardModel.Page) -> String {
        switch page {
        case .intro:     return "вступна"
        case .versions:  return "версії"
        case .modules:   return "модулі"
        case .templates: return "шаблони"
        case .images:    return "зображення"
        case .summary:   return "зведення"
        }
    }
}
