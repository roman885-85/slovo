import AppKit
import SlovoCore

/// Перетягування файлів у вікно програми.
///
/// На служінні файл найчастіше вже лежить на столі: фотографія, презентація,
/// фільм. Змушувати людину шукати його у вікні вибору — зайвий крок там, де
/// рахунок іде на секунди. Тому вікно приймає файл як є і саме вирішує,
/// якій вкладці він належить.
///
/// Розбір за розширенням, а не за типом від системи: тип файлові може бути не
/// присвоєно зовсім, а розширення є завжди — і списки розширень у нас уже
/// написано для вікон вибору.
@MainActor
final class NativeWindowDrop {

    static let shared = NativeWindowDrop()

    private weak var state: AppState?

    func install(state: AppState, in view: NSView) {
        self.state = state
        view.registerForDraggedTypes([.fileURL])
    }

    /// Кому належить кинуте.
    enum Target: Equatable {
        case pictures([URL])
        case presentation(URL)
        case media(URL)
        case nothing
    }

    /// Розбір — окремою функцією без вікон і миші: її перевіряє
    /// самоперевірка, а підробити перетягування в перевірці нічим.
    static func route(_ urls: [URL],
                      isFolder: (URL) -> Bool = { url in
                          var isDirectory: ObjCBool = false
                          FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                          return isDirectory.boolValue
                      },
                      playable: (URL) -> Bool) -> Target {
        // Презентація старша за картинки: якщо кинули і те, і те, показувати
        // людина збиралася презентацію — картинки в ній і так усередині.
        if let slides = urls.first(where: {
            ShowModel.Kind.presentation.extensions.contains($0.pathExtension.lowercased())
        }) {
            return .presentation(slides)
        }
        // Теку з картинками кидають цілком — так само, як вибирають у вікні.
        let pictures = urls.filter {
            ShowModel.Kind.pictures.extensions.contains($0.pathExtension.lowercased()) || isFolder($0)
        }
        if !pictures.isEmpty { return .pictures(pictures) }
        // Усе інше — плеєрові: він сам розбере, грається це чи ні.
        if let media = urls.first(where: playable) { return .media(media) }
        return .nothing
    }

    /// Прийняти кинуте. `false` — серед файлів немає нічого нашого.
    @discardableResult
    func accept(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true])
                        as? [URL]) ?? []
        return accept(urls: urls)
    }

    /// Те саме, але від готового списку файлів.
    ///
    /// Окремим входом, щоб самоперевірка проходила весь шлях до вкладки:
    /// підробити `NSDraggingInfo` нічим, а «розбір правильний» і «файл дійшов до
    /// вкладки» — різні речі. Власник скаржився саме на друге:
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

    /// Що показати курсору. Копіювання, а не переміщення: файл лишається
    /// на місці, програма його тільки читає.
    func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
            ? .copy : []
    }
}
