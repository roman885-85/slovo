import AppKit
import SlovoCore

/// Робоча область «Біблія» цілком: чотири колонки, смуга перекладів і вікно
/// результатів пошуку.
///
/// Усі три частини живуть постійно, з першого показу вікна і до виходу. Натискання
/// міняє вміст одного списку; жоден із чотирьох видів не будується
/// заново, і розкладка вікна не перераховується зовсім.
@MainActor
final class NativeBibleWorkspace {

    static let shared = NativeBibleWorkspace()

    private weak var state: AppState?
    private var columns: NativeColumnsView?
    private var panes: [NativeLabelledPane] = []
    /// Стовпці. Не `private`: самоперевірка міряє, чи вміщається в рядок
    /// текст після зміни вигляду списків і кегля.
    private(set) var bookColumn: NativeBookColumn?
    private(set) var chapterColumn: NativeChapterColumn?
    private(set) var verseColumn: NativeVerseColumn?
    /// Смуга перекладів (7). Не `private`: у режимі пісень на її місці
    /// стають закладки Пісенників, і просить про це пісенник.
    private(set) var strip: NativeTranslationStripView?
    /// Вікно результатів пошуку (5). Не `private`: самоперевірка рахує його
    /// рядки, щоб відрізнити «знайшлося» від «знайшлося і показано».
    private(set) var results: NativeSearchResultsPane?
    private var tokens: [Signals.Token] = []

    private init() {}

    /// Зібрати частини і покласти їх у вікно.
    ///
    /// Кличуть один раз, одразу після того, як вікно піднялося. Другий виклик
    /// нічого не робить: частини постійні, перезбирати їх нічим і нема чого.
    func attach(state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        NativeBibleBridge.shared.start(state: state)

        let bible = buildWorkspace(state: state)
        let strip = NativeTranslationStripView(state: state)
        let results = NativeSearchResultsPane(state: state)
        self.strip = strip
        self.results = results

        let controller = NativeMainWindowController.shared
        controller.install(strip, in: .translationStrip)
        controller.install(results, in: .searchResults)
        if state.mode == .bible { controller.install(bible, in: .workspace) }

        // Робоча область спільна на три режими: своє в неї кладе той, чий
        // режим вибрано. Ми займаємо її, лише коли вибрано Біблію.
        tokens.append(Signals.shared.subscribe(.mode) { [weak self] in
            guard let self, let state = self.state, state.mode == .bible,
                  let columns = self.columns else { return }
            NativeMainWindowController.shared.install(columns, in: .workspace)
        })
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            self?.applyCaptions()
        })
        // Частини, яких за умовчанням не видно, вікно показує за приводом
        // `.layout` — посилати його має той, хто міняє `DeskModel`.
        NativeBibleBridge.shared.watchDesk { [weak self] in self?.syncDesk() }
    }

    /// Вигляд робочої області — якщо його знадобиться поставити у вікно ззовні.
    var workspaceView: NSView? { columns }

    /// Список віршів — його читає замір.
    var verseList: NativeList? { verseColumn?.verseList }

    // MARK: - Збирання

    private func buildWorkspace(state: AppState) -> NSView {
        let bookClass = NativeBookClassColumn(state: state)
        let book = NativeBookColumn(state: state)
        let chapter = NativeChapterColumn(state: state)
        let verse = NativeVerseColumn(state: state)
        bookColumn = book
        chapterColumn = chapter
        verseColumn = verse

        let panes = [bookClass, book, chapter, verse].map { content -> NativeLabelledPane in
            let pane = NativeLabelledPane()
            pane.install(content)
            return pane
        }
        self.panes = panes

        let columns = NativeColumnsView()
        columns.install([
            .init(view: panes[0], minWidth: 96, idealWidth: 112, maxWidth: 150),
            .init(view: panes[1], minWidth: 200, idealWidth: 270, maxWidth: 380),
            .init(view: panes[2], minWidth: 54, idealWidth: 72, maxWidth: 110),
            .init(view: panes[3], minWidth: 320, idealWidth: 320, maxWidth: 0),
        ])
        self.columns = columns
        applyCaptions()
        return columns
    }

    /// Підписи колонок — із файла перекладу автора: `Label9`, `Label8`,
    /// `Label1`, `Label3` форми `MainForm`.
    private func applyCaptions() {
        guard let state, panes.count == 4 else { return }
        panes[0].caption = state.text("Label9", default: "Класс:")
        panes[1].caption = state.text("Label8", default: "Книга:")
        panes[2].caption = state.text("Label1", default: "Глава:")
        panes[3].caption = state.text("Label3", default: "Стих:")
    }

    // MARK: - Фокус полів швидкого вибору (6)

    private var lastQuickFocus: DeskModel.QuickField?

    /// Поля доганяють `DeskModel`: вміст могли поміняти план, історія або
    /// пісенник, а фокус — клавіші F7, F8, F9 і Tab, які ловить спільний
    /// монітор, що нічого не знає про наші поля.
    private func syncDesk() {
        let desk = DeskModel.shared
        bookColumn?.quick.text = desk.bookQuery
        chapterColumn?.quick.text = desk.chapterQuery
        verseColumn?.quick.text = desk.verseQuery
        applyQuickFocus()
    }

    private func applyQuickFocus() {
        // Та сама позначка фокуса — у пісень для їхніх полів. Поки відкрито не
        // Біблію, свої поля не чіпаємо: інакше курсор тікав би з поля пісні.
        guard state?.mode == .bible else { return }
        let wanted = DeskModel.shared.quickFocus
        guard wanted != lastQuickFocus else { return }
        lastQuickFocus = wanted
        switch wanted {
        case .book:    bookColumn?.quick.focus()
        case .chapter: chapterColumn?.quick.focus()
        case .verse:   verseColumn?.quick.focus()
        case nil:      break
        }
    }
}
