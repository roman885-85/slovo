import AppKit
import Combine
import SlovoCore

/// Перекладач з мови `SongEditorModel` і `AppState` на мову приводів.
///
/// Влаштований так само, як сито Біблії, і з тієї самої причини: в обох спостережуваних
/// один спільний `objectWillChange` на всі поля разом, і пустити його прямо у вікно
/// значить повернутися до «щось змінилося, перезберіть усе». Тут знімається
/// знімок із півтора десятка скалярів, звіряється з колишнім, і назовні йдуть
/// лише справжні приводи.
///
/// Окреме сито, а не спільне з Біблією, навмисно: збірник живе своїм життям
/// (у нього є правки, що не лягли на диск), і звіряти його поля в чужому знімку
/// означало б, що зміна вірша перечитує список пісень.
@MainActor
final class NativeSongBridge {

    private(set) weak var state: AppState?
    private(set) weak var model: SongEditorModel?
    private var watchers: [AnyCancellable] = []
    private var scheduled = false
    private var snapshot = Snapshot()
    /// Панель інструментів, вкладки і поля вводу: своїх приводів у них немає —
    /// перелік `Signals.Kind` закритий і спільний на все вікно.
    private var chromeWatchers: [() -> Void] = []

    /// Скільки звірок пройшло марно і скільки послало приводи. Читає
    /// самоперевірка: за цими двома числами видно, працює сито чи ні.
    private(set) var idleSyncs = 0
    private(set) var sendingSyncs = 0

    func start(state: AppState, model: SongEditorModel) {
        guard self.model !== model else { return }
        self.state = state
        self.model = model
        watchers.removeAll()
        // Перший знімок мовчки: вікно тільки будується, розсилати нічому.
        snapshot = Snapshot(state: state, model: model)
        watch(state.objectWillChange)
        watch(model.objectWillChange)
        watch(SettingsStore.shared.objectWillChange)
    }

    private func watch(_ publisher: ObservableObjectPublisher) {
        watchers.append(publisher.sink { [weak self] _ in self?.schedule() })
    }

    /// Відкласти звірку до кінця поточного проходу циклу подій.
    ///
    /// `RunLoop.main.perform`, а не черга: він спрацьовує в тому самому проході,
    /// яким прийшло натискання, і обов'язково до малювання — отже вікно
    /// правиться в тому самому кадрі.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.sync()
        }
    }

    /// Звірити і розіслати. Кличуть одразу після своєї ж правки — тоді списки
    /// стають на місце в тому самому виклику, що й клацання.
    func sync() {
        guard let state, let model else { return }
        let fresh = Snapshot(state: state, model: model)
        var kinds: [Signals.Kind] = []
        fresh.differences(from: snapshot, into: &kinds)
        snapshot = fresh

        if kinds.isEmpty {
            idleSyncs += 1
        } else {
            sendingSyncs += 1
            Signals.shared.batch {
                for kind in kinds { Signals.shared.send(kind) }
            }
        }
        for body in chromeWatchers { body() }
    }

    /// Підписатися на все, у чого свого приводу немає: режим правки, ознака
    /// «змінений», склад вкладок, вміст полів швидкого вибору.
    func watchChrome(_ body: @escaping () -> Void) {
        chromeWatchers.append(body)
    }

    // MARK: - Знімок

    @MainActor
    private struct Snapshot {
        var mode: AppState.WorkMode = .bible
        var bookID = ""
        var stateBookID = ""
        var revision = 0
        var isEditing = false
        var isModified = false
        var groupIndex = -1
        var songIndex = -1
        /// Пісня в `AppState`: її ставлять План та «Історія», нічого не
        /// знаючи про вікно, — і вкладка зобов'язана піти за нею.
        var stateSong = -1
        var partIndex = -1
        var statePart = -1
        var songQuery = ""
        var showsCatalogNumber = false
        var songCount = 0
        var groupCount = 0
        var bookCount = 0
        var fontSize: Double = 13
        var languageRevision = 0
        var titleFormat = SongTitleFormat()
        var sheet = ""

        init() {}

        init(state: AppState, model: SongEditorModel) {
            mode = state.mode
            bookID = model.bookID
            stateBookID = state.songBookID
            revision = model.revision
            isEditing = model.isEditing
            isModified = model.isModified
            groupIndex = model.groupIndex ?? -1
            songIndex = model.songIndex ?? -1
            stateSong = state.songIndex ?? -1
            partIndex = model.partIndex ?? -1
            statePart = state.songPartIndex ?? -1
            songQuery = model.songQuery
            showsCatalogNumber = model.showsCatalogNumber
            songCount = model.book?.songs.count ?? 0
            groupCount = model.book?.groups.count ?? 0
            bookCount = state.songBooks.count
            fontSize = state.listFontSize
            languageRevision = state.menuRevision
            titleFormat = state.songTitleFormat
            sheet = model.sheet?.id ?? ""
        }

        /// Чим цей знімок відрізняється від колишнього — у приводах.
        func differences(from old: Snapshot, into kinds: inout [Signals.Kind]) {
            if mode != old.mode { kinds.append(.mode) }
            // Склад списку пісень випливає зі збірника і числа правок; самі
            // пісні перебирати нема чого.
            if bookID != old.bookID || revision != old.revision
                || songCount != old.songCount || bookCount != old.bookCount
                || groupCount != old.groupCount || stateBookID != old.stateBookID {
                kinds.append(.songBook)
            }
            if groupIndex != old.groupIndex || songQuery != old.songQuery
                || showsCatalogNumber != old.showsCatalogNumber
                || titleFormat != old.titleFormat {
                kinds.append(.songFilter)
            }
            // Пісню міняє не лише список: пункт Плану пише в `AppState`, і
            // доти вкладка цього не помічала — список стояв на старій пісні,
            // а стрілка потім листала її, а не ту, що в залі (скрин власника:
            // «в плане выбрана одна песня, а в окне программы не та»).
            if songIndex != old.songIndex || stateSong != old.stateSong { kinds.append(.songSelection) }
            if partIndex != old.partIndex || statePart != old.statePart {
                kinds.append(.songPart)
            }
            if fontSize != old.fontSize { kinds.append(.listFontSize) }
            if languageRevision != old.languageRevision { kinds.append(.language) }
            // Відкрите вікно правки міняє лише написи на панелях, але вікно
            // має дізнатися про нього, щоб кнопки погасли.
            if isEditing != old.isEditing || isModified != old.isModified
                || sheet != old.sheet {
                kinds.append(.listKind)
            }
        }
    }
}
