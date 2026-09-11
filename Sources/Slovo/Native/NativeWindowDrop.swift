import AppKit
import SlovoCore

/// Перетаскивание файлов в окно программы.
///
/// На служении файл чаще всего уже лежит на столе: фотография, презентация,
/// фильм. Заставлять человека искать его в окне выбора — лишний шаг там, где
/// счёт идёт на секунды. Поэтому окно принимает файл как есть и само решает,
/// какой вкладке он принадлежит.
///
/// Разбор по расширению, а не по типу из системы: тип файлу может быть не
/// присвоен вовсе, а расширение есть всегда — и списки расширений у нас уже
/// написаны для окон выбора.
@MainActor
final class NativeWindowDrop {

    static let shared = NativeWindowDrop()

    private weak var state: AppState?

    func install(state: AppState, in view: NSView) {
        self.state = state
        view.registerForDraggedTypes([.fileURL])
    }

    /// Кому принадлежит брошенное.
    enum Target: Equatable {
        case pictures([URL])
        case presentation(URL)
        case media(URL)
        case nothing
    }

    /// Разбор — отдельной функцией без окон и мыши: её проверяет
    /// самопроверка, а подделать перетаскивание в проверке нечем.
    static func route(_ urls: [URL],
                      isFolder: (URL) -> Bool = { url in
                          var isDirectory: ObjCBool = false
                          FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                          return isDirectory.boolValue
                      },
                      playable: (URL) -> Bool) -> Target {
        // Презентация старше картинок: если бросили и то и другое, показывать
        // человек собирался презентацию — картинки в ней и так внутри.
        if let slides = urls.first(where: {
            ShowModel.Kind.presentation.extensions.contains($0.pathExtension.lowercased())
        }) {
            return .presentation(slides)
        }
        // Папку с картинками бросают целиком — так же, как выбирают в окне.
        let pictures = urls.filter {
            ShowModel.Kind.pictures.extensions.contains($0.pathExtension.lowercased()) || isFolder($0)
        }
        if !pictures.isEmpty { return .pictures(pictures) }
        // Всё прочее — плееру: он сам разберёт, играется это или нет.
        if let media = urls.first(where: playable) { return .media(media) }
        return .nothing
    }

    /// Принять брошенное. `false` — среди файлов нет ничего нашего.
    @discardableResult
    func accept(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true])
                        as? [URL]) ?? []
        return accept(urls: urls)
    }

    /// То же самое, но от готового списка файлов.
    ///
    /// Отдельным входом, чтобы самопроверка проходила весь путь до вкладки:
    /// подделать `NSDraggingInfo` нечем, а «разбор верный» и «файл дошёл до
    /// вкладки» — разные вещи. Владелец жаловался именно на второе:
    /// «презентация не добавляется перетягиванием в окно».
    @discardableResult
    func accept(urls: [URL]) -> Bool {
        guard let state, !urls.isEmpty else { return false }

        switch Self.route(urls, playable: { state.media.filters.accepts($0) }) {
        case .presentation(let url):
            NativeShowWorkspace.presentation.open([url])
            state.mode = .presentation
            return true
        case .pictures(let urls):
            NativeShowWorkspace.pictures.open(urls)
            state.mode = .pictures
            return true
        case .media(let url):
            state.media.open(url)
            state.mode = .media
            return true
        case .nothing:
            return false
        }
    }

    /// Что показать курсору. Копирование, а не перемещение: файл остаётся
    /// на месте, программа его только читает.
    func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
            ? .copy : []
    }
}
