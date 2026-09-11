import AppKit
import SlovoCore

/// 6.1.5 «Пути» на AppKit: папки с фоновыми рисунками, папка для снимков
/// слайда (F11) и режим миникартинок.
///
/// Путь без буквы диска ищется относительно папки с данными программы — как
/// и в оригинале, поэтому в списке остаётся запись вида «BackGrounds\».
@MainActor
final class NativeSettingsPathsTab: NSObject, NativeListSource {

    private let state: AppState
    private let store: SettingsStore
    private let list = NativeTable(detailWidth: 120)
    private let counter = NativeForm.label("")
    private let resolved = NativeForm.label("")
    private var folderField: NSTextField!
    private var selected: Int?

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
        super.init()
        list.source = self
        list.onSelect = { [weak self] _, active, _ in self?.selected = active }
    }

    var page: NSView {
        let view = NativeForm.Page([pictures, screenshots, thumbs])
        refresh()
        return view
    }

    // MARK: (31) (32) (33) Пути для фоновых рисунков

    private var pictures: NativeForm.Group {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 130))
        list.frame = box.bounds
        list.autoresizingMask = [.width, .height]
        box.addSubview(list)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.spacing = 4
        buttons.addArrangedSubview(NativeForm.button("+", hint: state.vbHint("SBAddPath", "Добавить путь...")) {
            [weak self] in self?.addPath()
        })
        buttons.addArrangedSubview(NativeForm.button("−", hint: state.vbHint("SBDelPath", "Удалить путь...")) {
            [weak self] in self?.removePath()
        })
        buttons.addArrangedSubview(NativeForm.button("↳", hint: state.vbHint("SBSubFolder",
                                                     "Искать во вложенных папках (Вкл/Выкл)")) {
            [weak self] in self?.toggleSubfolders()
        })

        return NativeForm.Group(state.vb("Label2", "Пути для фоновых рисунков:"), [
            NativeForm.Row("", stretch: true, [box, buttons]),
            // Считаем по списку, который правят прямо сейчас, а не по уже
            // загруженным фонам: иначе надпись не отзывается на добавленную
            // папку и уверяет, что новых картинок нет.
            NativeForm.Row("", [counter]),
        ])
    }

    // MARK: (34) Папка для снимков экрана слайда

    private var screenshots: NativeForm.Group {
        folderField = NativeForm.text(NativeForm.Tie(get: { [store] in store.settings.screenshotFolder },
                                                     set: { [store, weak self] value in
                                                         store.settings.screenshotFolder = value
                                                         self?.refresh()
                                                     }), width: 380)
        return NativeForm.Group(state.vb("Label20", "Папка для снимков экрана слайда:"), [
            NativeForm.Row("", [
                folderField,
                NativeForm.button(OurWords.t("Выбрать…"), hint: state.vbHint("PngSBAddScreenShotPath", "Выбрать путь...")) {
                    [weak self] in self?.chooseScreenshots()
                },
            ]),
            NativeForm.Row("", [resolved]),
        ])
    }

    // MARK: Режим миникартинок

    private var thumbs: NativeForm.Group {
        NativeForm.Group(state.vb("RGThumbsMode", "Режим миникартинок"), [
            NativeForm.Row("", [
                NativeForm.choice([state.vb("RGThumbsMode->Item0", "Win Thumbs"),
                                   state.vb("RGThumbsMode->Item1", "Встроенный")],
                                  NativeForm.Tie(get: { [store] in
                                      store.settings.options.thumbsMode == .system ? 0 : 1
                                  }, set: { [store] value in
                                      store.settings.options.thumbsMode = value == 0 ? .system : .builtIn
                                  })),
            ]),
        ])
    }

    // MARK: - Действия

    private func addPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = state.vb("TextMessages4", "Выберите каталог фоновых рисунков")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { store.addPicturePath(url) }
        list.reload()
        refresh()
    }

    private func removePath() {
        guard let index = selected, store.settings.picturePaths.indices.contains(index) else { return }
        store.removePicturePath(store.settings.picturePaths[index].id)
        selected = nil
        list.reload()
        refresh()
    }

    private func toggleSubfolders() {
        guard let index = selected, store.settings.picturePaths.indices.contains(index) else { return }
        store.toggleSubfolders(store.settings.picturePaths[index].id)
        list.reload()
    }

    private func chooseScreenshots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = state.vb("TextMessages16", "Выберите папку для сохранения снимков экрана слайда")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setScreenshotFolder(url)
        folderField.stringValue = store.settings.screenshotFolder
        refresh()
    }

    private func refresh() {
        resolved.stringValue = store.resolve(store.settings.screenshotFolder).path
        counter.stringValue = OurWords.t("Найдено изображений: ") + "…"
        // Обход папок — работа с диском, и делать её на главном потоке
        // незачем: окно и без счётчика уже показано.
        Task { [weak self] in
            let count = await SettingsStore.shared.countBackgroundImages()
            self?.counter.stringValue = OurWords.t("Найдено изображений: ") + "\(count)"
        }
    }

    // MARK: - Список

    var rowCount: Int { store.settings.picturePaths.count }

    func row(at index: Int) -> NativeRow {
        let entry = store.settings.picturePaths[index]
        var row = NativeRow()
        row.lead = entry.scansSubfolders ? "↳" : "•"
        row.text = entry.path
        row.detail = FileManager.default.fileExists(atPath: store.resolve(entry.path).path)
            ? "" : state.vb("TextMessages9", "Не найдено")
        return row
    }
}
