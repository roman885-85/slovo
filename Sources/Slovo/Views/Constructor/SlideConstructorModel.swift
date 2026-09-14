import Combine
import Foundation
import AppKit
import SlovoCore

/// Состояние «Конструктора слайда» (раздел 6.3 руководства).
///
/// Держится отдельно от `AppState` намеренно: конструктор правит шаблон,
/// а не то, что сейчас на проекторе. Пока окно открыто, зал не должен
/// дёргаться от каждого сдвига рамки — правки уходят в файл шаблона только
/// по кнопке «Сохранить», ровно как в оригинале.
@MainActor
final class SlideConstructorModel: ObservableObject {

    /// Рабочая копия шаблона. Всё редактирование идёт по ней, а библиотека
    /// узнаёт об изменениях только при сохранении.
    @Published var preset: SlidePreset {
        didSet { if preset != oldValue { isDirty = true } }
    }
    @Published var selection: UUID?
    /// «Отобразить для:» (RGVariantShow) — сцена 1 (один перевод) или
    /// сцена 2 (два перевода). Панели Параметры и Анимация показывают
    /// набор именно выбранной сцены.
    @Published var scene: SlideScheme.Variant = .single
    @Published private(set) var isDirty = false

    /// «Задержка» (Label13) — пауза между нажатием «Тест анимации» и стартом
    /// показа, в миллисекундах. Это не задержка объекта, она своя у каждого.
    @Published var testDelay: Double = 0
    /// Счётчик прогонов: холст перезапускает анимацию, когда номер меняется.
    @Published private(set) var animationRun = 0

    /// Библиотека — класс, поэтому её правки сами по себе не перерисовывают
    /// окно: после сохранения и удаления шлём `objectWillChange` руками.
    let library: PresetLibrary
    /// Авторские шаблоны из папки `Templates` — их можно взять за основу.
    private(set) var schemes: SchemeLibrary?
    /// Стиль, из которого берутся шрифты для новых объектов: в шаблонах
    /// оригинала шрифтов нет, они живут в `VisioBible.ini`.
    private(set) var baseStyle: SlideStyle

    /// Папка авторского шаблона, из которого пришёл текущий набор объектов, —
    /// в ней лежат картинки украшений, на которые ссылаются объекты.
    private(set) var sourceFolder: URL?

    /// Какая папка шаблона у какой преднастройки.
    ///
    /// Без этой памяти «Сохранить как» и повторный выбор шаблона из списка
    /// обнуляли `sourceFolder`: пропадали и картинки объектов (в `.sch` они
    /// записаны без пути), и миниатюры `scene1.jpg` / `scene2.jpg`.
    private var sourceFolders: [UUID: URL] = [:]

    /// Кому «Разрешить сцену 2» включили руками в этом сеансе.
    ///
    /// Сам по себе второй набор ещё не значит «свои параметры»: он бывает
    /// заведён только ради того, что `Enabled_2` отличается от `Enabled`.
    /// Такой набор совпадает с первым во всём, кроме видимости, и отличить
    /// его от только что включённого (тоже пока копии) больше нечем.
    private var forcedIndependentScenes: Set<UUID> = []

    private var isAttached = false

    init(library: PresetLibrary = PresetLibrary(folder: PresetLibrary.defaultFolder)) {
        self.library = library
        self.schemes = nil
        self.baseStyle = SlideStyle()
        self.preset = SlidePreset.standard(name: OurWords.t("Новый шаблон"), style: SlideStyle())
        self.selection = nil
        self.isDirty = false
    }

    /// Досборка от `AppState`.
    ///
    /// Модель создаётся раньше, чем вид получает окружение, поэтому шаблоны
    /// и стиль подставляются при появлении окна. Второй раз ничего не делаем:
    /// перерисовки случаются часто, а перечитывать библиотеку и терять
    /// незаписанные правки — нет.
    func attach(schemes: SchemeLibrary?, baseStyle: SlideStyle) {
        guard !isAttached else { return }
        isAttached = true
        self.schemes = schemes
        self.baseStyle = baseStyle

        // Пустая папка преднастроек означала бы пустой выпадающий список
        // шаблонов — заполняем её тем же стартовым набором, что и обычно.
        library.seedIfEmpty(from: baseStyle)
        if let first = library.presets(forSongs: false).first { load(first) }
    }

    /// Відкрити редактор Біблії або пісень: шаблон, що стоїть у залі для
    /// цього розділу, інакше перший зі списку розділу, а коли список
    /// порожній — свіжий шаблон розділу. Списки двох редакторів не
    /// перетинаються (власник: «інакше губиться весь сенс двох розділів»).
    func openScope(forSongs: Bool, assigned: SlidePreset?) {
        if let assigned, assigned.forSongs == forSongs, library.presets.contains(where: { $0.id == assigned.id }) {
            load(assigned)
        } else if let first = library.presets(forSongs: forSongs).first {
            load(first)
        } else {
            makeNew(named: OurWords.t(forSongs ? "Песня" : "Новый шаблон"), forSongs: forSongs)
        }
    }

    // MARK: - Выбранный объект

    var selectedObject: SlideObject? {
        guard let selection else { return nil }
        return preset.objects.first { $0.id == selection }
    }

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return preset.objects.firstIndex { $0.id == selection }
    }

    /// Параметры выбранного объекта в текущей сцене.
    var selectedValues: ObjectVariant? {
        selectedObject?.values(in: scene)
    }

    func update(_ object: SlideObject) {
        guard let index = preset.objects.firstIndex(where: { $0.id == object.id }) else { return }
        preset.objects[index] = object
        isDirty = true
    }

    /// Те же две связки, но замыканиями — их берут панели на AppKit.
    ///
    /// Возвращаем `NativeForm.Tie`, а не `Binding`: связка SwiftUI тянула бы
    /// за собой весь движок ради двух замыканий.
    func tie<Value>(_ path: WritableKeyPath<SlideObject, Value>, default fallback: Value) -> NativeForm.Tie<Value> {
        NativeForm.Tie(get: { self.selectedObject?[keyPath: path] ?? fallback },
                       set: { value in
                           guard var object = self.selectedObject else { return }
                           object[keyPath: path] = value
                           self.update(object)
                       })
    }

    func sceneTie<Value>(_ path: WritableKeyPath<ObjectVariant, Value>,
                         default fallback: Value) -> NativeForm.Tie<Value> {
        NativeForm.Tie(get: { self.selectedValues?[keyPath: path] ?? fallback },
                       set: { value in
                           guard let object = self.selectedObject else { return }
                           var values = object.values(in: self.scene)
                           values[keyPath: path] = value
                           self.setSelectedValues(values)
                       })
    }

    /// Записать набор выбранной сцены выбранному объекту.
    ///
    /// Отдельным методом, а не прямо в `SlideObject`, потому что «своя ли у
    /// сцены 2 разметка» знает модель: у только что включённого флажка набор
    /// пока совпадает с первым.
    func setSelectedValues(_ values: ObjectVariant) {
        guard var object = selectedObject else { return }
        object.setValues(values, in: scene, independent: hasIndependentSecondScene(object))
        update(object)
    }

    /// Есть ли у объекта свой набор параметров для сцены 2 — это
    /// `EnableParamsVariant` оригинала, колонка «Сцена 2» в списке и флажок
    /// «Разрешить сцену 2».
    ///
    /// Разная видимость сюда не входит: `Enabled` и `Enabled_2` — отдельные
    /// атрибуты, и в «Beautiful Gold» линия видна только во второй сцене при
    /// `EnableParamsVariant="false"`.
    func hasIndependentSecondScene(_ object: SlideObject) -> Bool {
        guard object.secondVariant != nil else { return false }
        return forcedIndependentScenes.contains(object.id) || object.secondSceneDiffersBeyondVisibility
    }

    /// «Разрешить сцену 2» (CBEnableVariant): пока флажок снят, обе сцены
    /// правятся вместе; как только включён — у сцены 2 появляется свой набор.
    var secondSceneEnabled: NativeForm.Tie<Bool> {
        NativeForm.Tie(
            get: { self.selectedObject.map { self.hasIndependentSecondScene($0) } ?? false },
            set: { value in
                guard var object = self.selectedObject else { return }
                object.setSecondSceneEnabled(value)
                if value {
                    self.forcedIndependentScenes.insert(object.id)
                } else {
                    self.forcedIndependentScenes.remove(object.id)
                }
                self.update(object)
            }
        )
    }

    // MARK: - Видимость по сценам

    /// «Видимость» (Label46) — в каких сценах объект показывается.
    /// В шаблоне это два независимых флага `Enabled` и `Enabled_2`.
    enum Personalization: Int, CaseIterable, Identifiable {
        case allScenes = 0   // PersonalizeText0 «Во всех сценах»
        case firstOnly = 1   // PersonalizeText1 «В 1 сцене»
        case secondOnly = 2  // PersonalizeText2 «Во 2 сцене»

        var id: Int { rawValue }
        var languageKey: String { "PersonalizeText\(rawValue)" }
        var fallbackTitle: String {
            switch self {
            case .allScenes:  return OurWords.t("Во всех сценах")
            case .firstOnly:  return OurWords.t("В 1 сцене")
            case .secondOnly: return OurWords.t("Во 2 сцене")
            }
        }
    }

    var personalization: NativeForm.Tie<Personalization> {
        NativeForm.Tie(
            get: {
                guard let object = self.selectedObject else { return .allScenes }
                let first = object.isVisible
                let second = object.secondSceneIsVisible
                if first && !second { return .firstOnly }
                if !first && second { return .secondOnly }
                return .allScenes
            },
            set: { value in
                switch value {
                case .allScenes:  self.setVisibility(first: true, second: true)
                case .firstOnly:  self.setVisibility(first: true, second: false)
                case .secondOnly: self.setVisibility(first: false, second: true)
                }
            }
        )
    }

    /// Видимость по сценам у выбранного объекта.
    ///
    /// «Разрешить сцену 2» здесь не включается: у автора это независимый
    /// атрибут, и объект с разной видимостью прекрасно живёт при
    /// `EnableParamsVariant="false"`.
    func setVisibility(first: Bool, second: Bool) {
        guard var object = selectedObject else { return }
        object.setVisibility(first: first, second: second)
        tidySecondScene(&object)
        update(object)
    }

    /// Флажок в списке объектов: показан ли объект в той сцене, что сейчас
    /// выбрана в «Отобразить для:». Одного флага на обе сцены не хватает —
    /// тогда строку «видна только во 2-й сцене» нечем отличить от обычной.
    func isEnabled(_ object: SlideObject) -> Bool {
        object.values(in: scene).isVisible
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard var object = preset.objects.first(where: { $0.id == id }) else { return }
        if scene == .dual {
            object.setVisibility(first: object.isVisible, second: enabled)
        } else {
            object.setVisibility(first: enabled, second: object.secondSceneIsVisible)
        }
        tidySecondScene(&object)
        update(object)
    }

    /// Убрать второй набор, если он остался только «ради видимости», а
    /// видимость сцен сравнялась. Набор, включённый человеком вручную,
    /// не трогаем — он должен держаться и без отличий.
    private func tidySecondScene(_ object: inout SlideObject) {
        guard !forcedIndependentScenes.contains(object.id) else { return }
        guard let second = object.secondVariant else { return }
        if !object.secondSceneDiffersBeyondVisibility, second.isVisible == object.isVisible {
            object.secondVariant = nil
        }
    }

    // MARK: - Список объектов

    func add(_ kind: SlideObjectKind) {
        var object = SlideObject(kind: kind, text: textLayer(for: kind))
        object.name = uniqueName(kind.shortTitle)
        // Новый объект кладём во всю ширину и по центру: так его видно сразу,
        // а не приходится искать под краем слайда. Привязка по Y — «Верх»
        // (у автора CBObjAlignY именно с ней и создаётся), а середина
        // получается отступом: вертикаль в шаблоне — один бит, «середины»
        // там нет вовсе.
        let height = kind == .image ? 0.2 : 0.3
        object.frame = ObjectFrame(x: 0, y: (1 - height) / 2, width: 0.9, height: height,
                                   anchorX: .center, anchorY: .top)
        if kind == .staticText { object.staticText = "Текст" }
        preset.objects.append(object)
        selection = object.id
        isDirty = true
    }

    func duplicateSelected() {
        guard let object = selectedObject else { return }
        var copy = object
        copy.id = UUID()
        copy.name = uniqueName(object.name)
        let index = (selectedIndex ?? preset.objects.count - 1) + 1
        preset.objects.insert(copy, at: min(index, preset.objects.count))
        selection = copy.id
        isDirty = true
    }

    func deleteSelected() {
        guard let index = selectedIndex else { return }
        preset.objects.remove(at: index)
        selection = preset.objects.indices.contains(index)
            ? preset.objects[index].id
            : preset.objects.last?.id
        isDirty = true
    }

    /// «Переместить выше/ниже» — порядок в списке задаёт порядок отрисовки.
    func moveSelected(by delta: Int) {
        guard let index = selectedIndex else { return }
        let target = index + delta
        guard preset.objects.indices.contains(target) else { return }
        preset.objects.swapAt(index, target)
        isDirty = true
    }

    // MARK: - Порядок в списке

    /// Список «Объекты слайда» так, как его показывает оригинал.
    ///
    /// В файле шаблона объекты записаны в порядке отрисовки: SpringFade
    /// начинается с линии `UpLine` и заканчивается `MidLine`. А в окне
    /// конструктора та же десятка перечислена ровно наоборот — сверху
    /// `MidLine`, снизу `UpLine`. То есть список идёт от ближнего к зрителю
    /// объекта к дальнему, и «переместить выше» значит «нарисовать позже».
    var listedObjects: [SlideObject] { preset.objects.reversed() }

    /// Номер строки в списке, а не в порядке отрисовки.
    var listedIndex: Int? {
        guard let index = selectedIndex else { return nil }
        return preset.objects.count - 1 - index
    }

    /// Сдвиг по списку: «выше» на экране — позже в отрисовке, отсюда минус.
    func moveSelectedInList(by delta: Int) {
        moveSelected(by: -delta)
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(preset.objects.map(\.name))
        if !taken.contains(base) { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Шрифт нового объекта берём у того слоя стиля, который ему по смыслу
    /// ближе: цитата крупная, адрес мельче и курсивом.
    private func textLayer(for kind: SlideObjectKind) -> SlideStyle.TextLayer {
        switch kind {
        case .quote:          return baseStyle.main
        case .secondaryQuote: return baseStyle.secondary
        case .image:          return baseStyle.reference
        default:              return baseStyle.reference
        }
    }

    // MARK: - Шаблоны

    /// Уход с текущего шаблона — все четыре случая, в которых незаписанные
    /// правки пропали бы безвозвратно.
    ///
    /// Перечислены здесь, а не в виде, ровно ради самопроверки: у автора
    /// вопрос «Шаблон изменен. Сохранить?» один на все четыре, и раньше
    /// создание нового шаблона его молча обходило.
    enum Departure: CaseIterable {
        case switchPreset   // выбор другой преднастройки из списка
        case importScheme   // «взять за основу» авторский шаблон
        case newTemplate    // SBNewSheme «Новый шаблон слайда»
        case close          // BBOk «Закрыть»
    }

    /// Спрашивать ли «Шаблон изменен. Сохранить?» (TextMessages11).
    func asksToSave(before departure: Departure) -> Bool {
        _ = departure   // случай не важен: вопрос один и тот же для всех
        return isDirty
    }

    var presetNames: [SlidePreset] { library.presets }

    func load(_ preset: SlidePreset) {
        self.preset = Self.withOriginalAnchors(preset)
        // Папку шаблона помним по преднастройке: в ней лежат картинки
        // объектов и миниатюры сцен, и терять их при возврате к шаблону
        // из списка незачем.
        self.sourceFolder = sourceFolders[preset.id]
        self.selection = self.preset.objects.first?.id
        self.forcedIndependentScenes = []
        self.isDirty = false
    }

    /// «Новый шаблон слайда» (SBNewSheme, TextMessages12). Для пісень —
    /// розкладка пісні: куплет і назва, без другого перекладу й адреси.
    func makeNew(named name: String, forSongs: Bool = false) {
        var fresh = Self.withOriginalAnchors(forSongs
            ? SlidePreset.song(name: name, style: baseStyle)
            : SlidePreset.standard(name: name, style: baseStyle))
        fresh.background.imagePath = nil
        self.preset = fresh
        self.sourceFolder = nil
        self.selection = fresh.objects.first?.id
        self.forcedIndependentScenes = []
        self.isDirty = true
    }

    /// Взять за основу авторский шаблон из папки `Templates`.
    func importScheme(_ template: SchemeLibrary.Template) {
        let height = schemes?.designHeight ?? SchemeLibrary.defaultDesignHeight
        preset = SlidePreset(template: template, base: baseStyle, designHeight: height)
        sourceFolder = template.folderURL
        sourceFolders[preset.id] = template.folderURL
        selection = preset.objects.first?.id
        forcedIndependentScenes = []
        // Имя совпадает с авторским, но сохранение пойдёт в свою папку —
        // авторские `.sch` мы не переписываем.
        isDirty = true
    }

    /// «Сохранить шаблон» (SBSaveSheme).
    @discardableResult
    func save() -> Bool {
        let ok = library.save(preset)
        if ok {
            isDirty = false
            if let sourceFolder { sourceFolders[preset.id] = sourceFolder }
        }
        objectWillChange.send()
        return ok
    }

    /// «Сохранить шаблон с новым именем» (SBAddSheme).
    @discardableResult
    func saveAs(_ name: String) -> Bool {
        var copy = preset
        copy.id = UUID()          // иначе перезаписался бы прежний файл
        copy.name = name
        let ok = library.save(copy)
        if ok {
            preset = copy
            // Папка авторского шаблона остаётся: картинки объектов лежат
            // именно в ней, и сохранение под новым именем их не переносит.
            if let sourceFolder { sourceFolders[copy.id] = sourceFolder }
            isDirty = false
        }
        objectWillChange.send()
        return ok
    }

    // MARK: - Привязка по вертикали

    /// Пересчёт «Середины» в отступ от верха.
    ///
    /// У автора вертикальная привязка только «Верх» (AlignYObjText0) и «Низ»
    /// (AlignYObjText1) — в `.sch` это один бит поля `Align`. «Середина» в
    /// наших ранних преднастройках была самодеятельностью; выбрасывать её
    /// нельзя, поэтому переводим в равнозначный отступ, и объект остаётся
    /// ровно там же, где стоял.
    static func withOriginalAnchors(_ preset: SlidePreset) -> SlidePreset {
        var preset = preset
        for index in preset.objects.indices {
            preset.objects[index].frame = topAnchored(preset.objects[index].frame)
            if var second = preset.objects[index].secondVariant {
                second.frame = topAnchored(second.frame)
                preset.objects[index].secondVariant = second
            }
        }
        return preset
    }

    private static func topAnchored(_ frame: ObjectFrame) -> ObjectFrame {
        guard frame.anchorY == .middle else { return frame }
        var fixed = frame
        fixed.anchorY = .top
        // От середины до верха ровно (1 - высота) / 2 холста.
        fixed.y = (1 - frame.height) / 2 + frame.y
        return fixed
    }

    /// Уже сохранён ли шаблон с таким именем — для вопроса «Перезаписать?».
    func nameIsTaken(_ name: String) -> Bool {
        library.presets.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// «Удалить шаблон» (SBDelSheme, TextMessages13/14).
    func deleteCurrent() {
        let songs = preset.forSongs
        library.delete(preset)
        // Наступний — з того самого редактора: після видалення шаблону
        // пісень у редакторі пісень не має з'явитися шаблон Біблії.
        if let next = library.presets(forSongs: songs).first {
            load(next)
        } else {
            makeNew(named: OurWords.t(songs ? "Песня" : "Новый шаблон"), forSongs: songs)
        }
        objectWillChange.send()
    }

    // MARK: - Тест анимации

    /// «Тест анимации» (BBAnimation) — прогон появления слайда в окне
    /// предпросмотра, с общей задержкой из ползунка «Задержка».
    func runAnimationTest() {
        animationRun += 1
    }

    // MARK: - Файлы

    /// Где искать картинку объекта: сначала как есть, потом в папке
    /// авторского шаблона — в `.sch` имена записаны без пути.
    func imageURL(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let cleaned = name.replacingOccurrences(of: "\\", with: "/")
        if let found = DataPaths.existing(cleaned) { return URL(fileURLWithPath: found) }
        guard let folder = sourceFolder else { return nil }
        let leaf = cleaned.split(separator: "/").last.map(String.init) ?? cleaned
        let url = folder.appendingPathComponent(leaf)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Готовая миниатюра авторского шаблона для выбранной сцены.
    ///
    /// Оригинал держит их рядом с шаблоном: `thumbs/scene1.jpg` — как ляжет
    /// один перевод, `thumbs/scene2.jpg` — как лягут два. Показываем их
    /// рядом с холстом, чтобы было с чем сверять правки.
    var sourceThumbnailURL: URL? {
        guard let sourceFolder else { return nil }
        let name = scene == .single ? "scene1.jpg" : "scene2.jpg"
        let url = sourceFolder.appendingPathComponent("thumbs").appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Фоны

    /// Где искать фоны для выпадающего списка «Имя файла фона».
    ///
    /// Оригинал складывает их из двух мест: своя папка шаблона (в SpringFade
    /// это `spring_fon 2.jpg`) и «Пути для фоновых рисунков» вкладки «Пути»
    /// (6.1.5) — со своим флажком «Искать во вложенных папках» у каждой
    /// строки. Раньше вторая половина была прописана жёстко, и добавленная
    /// в настройках папка в список не попадала.
    var backgroundFolders: [URL] {
        var folders: [URL] = []
        if let sourceFolder { folders.append(sourceFolder) }
        folders.append(contentsOf: settingsPictureFolders)

        var seen = Set<String>()
        return folders.filter { folder in
            guard FileManager.default.fileExists(atPath: folder.path) else { return false }
            return seen.insert(folder.standardizedFileURL.path).inserted
        }
    }

    /// Готовые картинки для объекта-изображения и его маски (6.3.7).
    ///
    /// Тот же набор папок, что и у фона: у автора `CBImageFile` и
    /// `CBImageMaskFile` — выпадающие списки уже лежащих рядом файлов, а
    /// кнопка обзора нужна только для «произвольных».
    var objectImageFolders: [URL] { backgroundFolders }

    /// Папки из `[PicturePath]`, разобранные один раз за сеанс.
    ///
    /// Обход вложенных папок делать на каждую перерисовку меню нельзя —
    /// выпадающий список строится при любом обновлении формы.
    private var settingsPictureFolders: [URL] {
        if let cached = pictureFoldersCache { return cached }

        let store = SettingsStore.shared
        var folders: [URL] = []
        for entry in store.settings.picturePaths {
            let folder = Self.resolveFolder(entry.path, under: store.dataRoot)
            folders.append(folder)
            if entry.scansSubfolders { folders.append(contentsOf: Self.subfolders(of: folder)) }
        }
        // Пустой список путей не должен оставлять человека вовсе без фонов.
        if folders.isEmpty, let root = schemes?.root {
            folders.append(root.deletingLastPathComponent()
                .appendingPathComponent("BackGrounds", isDirectory: true))
        }
        pictureFoldersCache = folders
        return folders
    }

    private var pictureFoldersCache: [URL]?

    /// В ini пути записаны по-виндовому и почти всегда относительно папки
    /// данных: у владельца это `BackGrounds\`.
    private static func resolveFolder(_ path: String, under root: URL) -> URL {
        let cleaned = path.replacingOccurrences(of: "\\", with: "/")
        if cleaned.hasPrefix("/") { return URL(fileURLWithPath: cleaned, isDirectory: true) }
        return root.appendingPathComponent(cleaned, isDirectory: true)
    }

    private static func subfolders(of folder: URL) -> [URL] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: folder,
                                              includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            found.append(url)
            // Тысячи папок в списке фонов бесполезны, а обход диска заметен.
            if found.count >= 200 { break }
        }
        return found
    }

    /// Картинки в папке. Список папки кэшируется: выпадающее меню строится
    /// при каждой перерисовке формы, а в `BackGrounds` у пользователя лежат
    /// десятки файлов — перечитывать её на каждый чих незачем.
    func images(in folder: URL) -> [URL] {
        if let cached = folderListings[folder.path] { return cached }
        let allowed: Set<String> = ["jpg", "jpeg", "png", "bmp", "tif", "tiff", "gif"]
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { allowed.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let urls = names.map { folder.appendingPathComponent($0) }
        folderListings[folder.path] = urls
        return urls
    }

    private var folderListings: [String: [URL]] = [:]

    /// Диалог выбора картинки: «Импортировать файл изображения» и родня.
    func chooseImageFile(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = OurWords.t("Выбрать")
        panel.message = message
        panel.directoryURL = sourceFolder
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Сцены объекта

extension SlideObject {

    /// Параметры объекта в выбранной сцене.
    ///
    /// В шаблоне оригинала у каждого объекта два набора: обычный и с хвостом
    /// `_2`. Второй применяется, когда на слайде два перевода; если своего
    /// набора нет (`EnableParamsVariant="false"`), сцены совпадают.
    func values(in scene: SlideScheme.Variant) -> ObjectVariant {
        variant(withSecondTranslation: scene == .dual)
    }

    /// `Enabled_2` — видимость во второй сцене. Живёт в наборе-двойнике даже
    /// тогда, когда своих параметров у сцены 2 нет.
    var secondSceneIsVisible: Bool { secondVariant?.isVisible ?? isVisible }

    /// Отличается ли второй набор от первого чем-нибудь, кроме видимости.
    ///
    /// Это и есть `EnableParamsVariant` оригинала: набор, заведённый только
    /// ради разного `Enabled_2`, своим не считается.
    var secondSceneDiffersBeyondVisibility: Bool {
        guard var probe = secondVariant else { return false }
        probe.isVisible = isVisible
        return probe != variant(withSecondTranslation: false)
    }

    /// `independent` — своя ли у сцены 2 разметка. Решает это модель: у
    /// только что включённого флажка набор пока в точности повторяет первый.
    mutating func setValues(_ values: ObjectVariant, in scene: SlideScheme.Variant, independent: Bool) {
        if scene == .dual, independent {
            var updated = values
            // Видимость сцены 2 правится «Видимостью» (Label46), а не этими
            // полями: сюда приходят рамка, прозрачность, выключка и анимация.
            updated.isVisible = secondVariant?.isVisible ?? values.isVisible
            secondVariant = updated
            return
        }

        // Пока независимой сцены 2 нет, правка идёт в общий набор — и вторая
        // сцена меняется вместе с первой, как в оригинале.
        frame = values.frame
        opacity = values.opacity
        alignment = values.alignment
        verticalAlignment = values.verticalAlignment
        shadow = values.shadow
        animation = values.animation
        if scene == .single { isVisible = values.isVisible }

        // Двойник, заведённый ради разной видимости, держим в согласии с
        // первым набором — иначе он «отвердел» бы в свою разметку.
        if let second = secondVariant {
            secondVariant = ObjectVariant(frame: frame, opacity: opacity, isVisible: second.isVisible,
                                          alignment: alignment, verticalAlignment: verticalAlignment,
                                          shadow: shadow, animation: animation)
        }
    }

    mutating func setSecondSceneEnabled(_ enabled: Bool) {
        let secondVisible = secondSceneIsVisible
        if enabled || secondVisible != isVisible {
            // Отдельный набор начинается с копии первого: иначе включение
            // флажка швыряло бы объект в угол значениями по умолчанию.
            // Копию оставляем и при выключенном флажке, если видимость сцен
            // различается: `Enabled_2` больше хранить негде.
            secondVariant = ObjectVariant(frame: frame, opacity: opacity, isVisible: secondVisible,
                                          alignment: alignment, verticalAlignment: verticalAlignment,
                                          shadow: shadow, animation: animation)
        } else {
            secondVariant = nil
        }
    }

    mutating func setVisibility(first: Bool, second: Bool) {
        isVisible = first
        if secondVariant != nil {
            secondVariant?.isVisible = second
        } else if second != first {
            // `Enabled` и `Enabled_2` независимы: разная видимость возможна и
            // без своих параметров сцены 2.
            secondVariant = ObjectVariant(frame: frame, opacity: opacity, isVisible: second,
                                          alignment: alignment, verticalAlignment: verticalAlignment,
                                          shadow: shadow, animation: animation)
        }
    }
}
