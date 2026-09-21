import AppKit
import Combine
import SlovoCore

// Майстер імпорту — розділ 4.2 посібника в частині даних.
//
// В оригіналі це «Перший запуск»: вибір мови (4.1) і майстер перенесення
// налаштувань із попередньої версії (4.2). У «Слові» окремого першого
// запуску немає: мова за умовчанням — українська, налаштування — з файла
// умовчань у пакеті. Майстер залишився як інструмент і кличеться з меню:
// джерелом може бути тека з даними старої програми, будь-яка тека з даними або
// архів `.zip`, а переносяться тільки дані — модулі й пісенники, шаблони
// слайда, фонові зображення. Сторінки йдуть у порядку автора: 4.2.1 вибір
// джерела, 4.2.2 модулі, 4.2.3 шаблони, 4.2.4 фони, 4.2.6 завершення;
// сторінки налаштувань (4.2.5) немає навмисно.

// MARK: - Подписи формы

extension AppState {
    /// Подпись элемента формы `ImportFromOldVersForm` из файла перевода
    /// автора. Запасной текст — его же русская формулировка.
    func imp(_ key: String, _ fallback: String) -> String {
        text(key, form: "ImportFromOldVersForm", default: fallback)
    }

    func impHint(_ key: String, _ fallback: String) -> String {
        language?.hint(key, form: "ImportFromOldVersForm") ?? OurWords.t(fallback)
    }

}

// MARK: - Флаг остановки поиска

/// Кнопка «Остановить» (PBBStopSearch) должна доходить до обхода дисков,
/// который идёт в фоновом потоке. Обычный `Bool` тут читается и пишется из
/// разных потоков, поэтому маленький замок.
private final class ImportStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool {
        lock.lock(); defer { lock.unlock() }
        return raised
    }

    func raise() { lock.lock(); raised = true; lock.unlock() }
    func lower() { lock.lock(); raised = false; lock.unlock() }
}

// MARK: - Модель мастера

@MainActor
final class ImportWizardModel: ObservableObject {

    /// Сторінки за підрозділами 4.2 — без 4.2.5 «налаштування».
    enum Page: Int, CaseIterable {
        case intro      // 4.2
        case versions   // 4.2.1
        case modules    // 4.2.2
        case templates  // 4.2.3
        case images     // 4.2.4
        case summary    // 4.2.6
    }

    @Published var page: Page = .intro

    // 4.2.1
    @Published private(set) var sources: [ImportSource] = []
    @Published var selectedSourceID: String?
    @Published private(set) var isSearching = false
    @Published private(set) var searchStatus = ""
    @Published var problem: String?

    // 4.2.2–4.2.4
    @Published private(set) var isScanning = false
    @Published var modules: [ImportItem] = []
    @Published var templates: [ImportItem] = []
    @Published var images: [ImportItem] = []

    // 4.2.6
    @Published private(set) var isRunning = false
    @Published private(set) var runProgress = 0.0
    @Published private(set) var runStatus = ""
    @Published private(set) var outcome: ImportOutcome?

    /// Куди розкладаємо.
    @Published private(set) var destination: ImportDestination

    private let stopFlag = ImportStopFlag()
    private var scannedSourceID: String?

    init(destination: ImportDestination) {
        self.destination = destination
        sources = ModuleImporter.installedVersions()
        selectedSourceID = sources.first?.id
    }

    /// Справжнє призначення відоме лише зі стану програми, а його в `init`
    /// виду ще немає. Міняємо, поки опис не побудовано: після нього всі рядки
    /// вже пораховано відносно старого призначення.
    func adopt(destination: ImportDestination) {
        guard scannedSourceID == nil, outcome == nil else { return }
        if self.destination != destination { self.destination = destination }
    }

    var selectedSource: ImportSource? {
        sources.first { $0.id == selectedSourceID }
    }

    // MARK: Переходы

    var canGoBack: Bool { page != .intro && !isRunning }

    var canGoNext: Bool {
        guard !isRunning, !isScanning else { return false }
        switch page {
        case .intro:   return true
        case .versions: return selectedSource != nil
        case .summary: return false
        default:       return true
        }
    }

    func goNext() {
        guard canGoNext, let index = Page.allCases.firstIndex(of: page),
              index + 1 < Page.allCases.count else { return }
        page = Page.allCases[index + 1]
        // Опись строится один раз на источник и только когда до неё дошли:
        // на странице выбора версии она была бы выброшена при первом же
        // перещёлкивании строки списка.
        if page == .modules { loadInventory() }
    }

    func goBack() {
        guard canGoBack, let index = Page.allCases.firstIndex(of: page), index > 0 else { return }
        page = Page.allCases[index - 1]
    }

    // MARK: 4.2.1 Источники

    /// «Выбрать папку с предыдущей версией» (PBBSelectFolderPortableVers) —
    /// и то же окно принимает архив `.zip` или файл модуля.
    ///
    /// Язык передаём снаружи: текст отказа берётся из файла перевода автора
    /// (ErrorMessages0/1/2 формы `ImportFromOldVersForm`), а какой перевод
    /// выбран — знает только состояние программы.
    func addChosen(_ url: URL, language: LanguageFile?) {
        do {
            let source = try ModuleImporter.source(at: url, existing: sources)
            sources.append(source)
            selectedSourceID = source.id
            problem = nil
        } catch {
            problem = ImportProblem.text(for: error, language: language)
        }
    }

    /// «Найти другие версии автоматически» (PBBFindPortableVers).
    func searchAllDisks() {
        guard !isSearching else { return }
        isSearching = true
        searchStatus = ""
        stopFlag.lower()

        let flag = stopFlag
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Обход зовёт `progress` на каждой папке — это тысячи вызовов в
            // секунду. Без прореживания главный поток захлёбывается на одной
            // только перерисовке строки состояния.
            var lastPost = Date.distantPast
            _ = ModuleImporter.searchAllDisks(
                shouldStop: { flag.isRaised },
                progress: { path in
                    guard Date().timeIntervalSince(lastPost) > 0.1 else { return }
                    lastPost = Date()
                    DispatchQueue.main.async { self?.searchStatus = path }
                },
                found: { source in
                    DispatchQueue.main.async { self?.merge(source) }
                })
            DispatchQueue.main.async {
                self?.isSearching = false
                self?.searchStatus = ""
            }
        }
    }

    /// «Остановить» (PBBStopSearch).
    func stopSearch() { stopFlag.raise() }

    private func merge(_ source: ImportSource) {
        guard !sources.contains(where: { $0.id == source.id }) else { return }
        sources.append(source)
        if selectedSourceID == nil { selectedSourceID = source.id }
    }

    // MARK: 4.2.2–4.2.4 Опись

    func loadInventory() {
        guard let source = selectedSource else { return }
        guard scannedSourceID != source.id else { return }
        isScanning = true

        let destination = self.destination
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let inventory = ModuleImporter.inventory(of: source, destination: destination)
            DispatchQueue.main.async {
                guard let self else { return }
                self.modules = inventory.modules
                self.templates = inventory.templates
                self.images = inventory.images
                self.scannedSourceID = source.id
                self.isScanning = false
            }
        }
    }

    func items(on page: Page) -> [ImportItem] {
        switch page {
        case .modules:   return modules
        case .templates: return templates
        case .images:    return images
        default:         return []
        }
    }

    /// Галочка строки.
    func setSelected(_ id: String, on page: Page, to value: Bool) {
        func apply(_ list: inout [ImportItem]) {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].isSelected = value
        }
        switch page {
        case .modules:   apply(&modules)
        case .templates: apply(&templates)
        case .images:    apply(&images)
        default:         break
        }
    }

    /// PSBSel* / PSBUnSel* — «Выделить все …» и «Снять выделение со всех …».
    func setAll(on page: Page, to value: Bool) {
        func apply(_ list: inout [ImportItem]) {
            for index in list.indices { list[index].isSelected = value }
        }
        switch page {
        case .modules:   apply(&modules)
        case .templates: apply(&templates)
        case .images:    apply(&images)
        default:         break
        }
    }

    // MARK: 4.2.6 Импорт

    var plannedInventory: ImportInventory? {
        guard let source = selectedSource else { return nil }
        return ImportInventory(source: source, modules: modules, templates: templates,
                               images: images)
    }

    var plannedCount: Int { plannedInventory?.selected.count ?? 0 }

    /// «Импортировать» (PBBImport).
    func run() {
        guard let inventory = plannedInventory, !isRunning else { return }
        isRunning = true
        runProgress = 0
        runStatus = ""
        outcome = nil

        let destination = self.destination
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ModuleImporter.run(inventory, destination: destination) { title, value in
                DispatchQueue.main.async {
                    self?.runStatus = title
                    self?.runProgress = value
                }
            }
            DispatchQueue.main.async {
                self?.runStatus = ""
                self?.runProgress = 1
                self?.outcome = result
                self?.isRunning = false
            }
        }
    }
}

// MARK: - Окно мастера

/// Майстер живе в окремому вікні, а не аркушем над головним.
///
/// Обхід усіх дисків і перенесення сотні модулів ідуть хвилинами, і весь цей
/// час аркуш тримав би головне вікно заблокованим. Вікно одне на програму й
/// переживає закриття, щоб випадково закритий майстер відкривався там же,
/// де його залишили. Сам собою майстер не з'являється — тільки з меню.
@MainActor
enum ImportWizardWindow {

    private static var controller: NSWindowController?

    static func show(state: AppState) {
        if let window = controller?.window {
            // Випадково закритий майстер відкривається там, де його лишили.
            // Але після перенесення лишати нічого: опис джерел пораховано до
            // нього, і з меню відкривалося старе зведення з кнопкою
            // «Імпортувати» (0.85, перевірка скачаної збірки).
            if (window.contentView as? NativeImportWizard)?.hasFinishedImport == true {
                window.orderOut(nil)
                controller = nil
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
        }

        // Пока библиотека открывается, мастеру нечем работать: опись строится
        // по нашим модулям, а список языков (4.1) ещё пуст. У автора на этот
        // случай заготовлено своё сообщение — ErrorMessages24.
        guard !state.isLoadingLibrary else {
            let alert = NSAlert()
            alert.messageText = state.imp("ErrorMessages3", "Ошибка")
            alert.informativeText = state.text(
                "ErrorMessages24",
                default: "Для открытия мастера импорта настроек необходимо дождаться полной загрузки всех модулей")
            alert.addButton(withTitle: state.imp("PBBClose", "Закрыть"))
            alert.runModal()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)

        window.title = OurWords.t("Импорт модулей, шаблонов и фонов")
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ImportWizardWindow")
        window.minSize = NSSize(width: 820, height: 560)

        // Призначення підставляється, коли вид стане у вікно: `AppState`
        // знає його, а модель заводиться раніше.
        let model = ImportWizardModel(destination: .applicationLibrary)
        window.contentView = NativeImportWizard(
            state: state, model: model,
            onClose: { [weak window] in window?.performClose(nil) })
        window.center()

        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Куда мастер раскладывает перенесённое.
    ///
    /// По умолчанию — папка данных, с которой программа работает прямо
    /// сейчас: тогда импортированный модуль появляется в списке переводов
    /// сразу. Но если это чужие данные (обёртка прежней программы, бутылка
    /// CrossOver, собственный бандл), писать туда нельзя, и переносим в
    /// личную папку программы.
    static func destination(for state: AppState) -> ImportDestination {
        let current = ImportDestination(dataRoot: state.modulesFolder.deletingLastPathComponent())
        return current.isSafeToWrite ? current : .applicationLibrary
    }
}
