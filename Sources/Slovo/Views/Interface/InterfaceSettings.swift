import AppKit
import Combine
import SlovoCore

/// Раздел 7 руководства — «Интерфейс».
///
/// Здесь живут три настройки, которые в оригинале лежат в `VisioBible.ini`:
/// `GuiStyle` (стиль оформления, 7.2), `BooksStyle` (вид окна выбора Книги,
/// кнопки (22)) и `LinesStyle` (вид списка стихов, кнопки (21)). Пункты меню
/// «Интерфейс» N8 «Значки», N9 «Мал. значки», N10 «Список», N11 «Таблица»
/// переключают ровно ту же величину, что и кнопки (22), — просто дают все
/// четыре вида, а кнопки только два крайних.
///
/// Вид списков в оригинале свой у каждого режима, а не один на программу:
/// в `VisioBible.ini` пользователя лежат три независимые пары — `[Bible]`
/// `LinesStyle=0 BooksStyle=0`, `[Text]` `1/1`, `[Songs]` `1/1`. Тому же
/// подчинён и файл перевода: у песенника своя пара кнопок (21) с ключами
/// `SongsPluginFrame->PngSBmanyLines` и `SongsPluginFrame->PngSBOneLine`.
/// Поэтому величины здесь хранятся по режимам, а не одной парой.
///
/// Хранилище общее на всё приложение (`shared`): вид списков нужен и главному
/// окну, и меню, а таскать его через `AppState` нельзя — файл `AppState.swift`
/// общий и правится отдельно.
@MainActor
final class InterfaceSettings: ObservableObject {

    static let shared = InterfaceSettings()

    /// Режим, для которого спрашивают вид списков.
    ///
    /// Значения совпадают с `AppState.WorkMode.rawValue` нарочно: так режим
    /// окна превращается в область настроек одной строкой и без связи с
    /// общим файлом состояния.
    enum ListScope: String, CaseIterable, Identifiable {
        case bible, text, songs
        var id: String { rawValue }

        /// Секция `VisioBible.ini`, откуда берутся стартовые значения.
        var iniSection: String {
            switch self {
            case .bible: return "Bible"
            case .text:  return "Text"
            case .songs: return "Songs"
            }
        }

        /// Приставка к ключу подсказки в файле перевода.
        ///
        /// Кнопки песенника у автора записаны в той же секции `[MainForm]`, но
        /// с приставкой имени вложенной формы:
        /// `SongsPluginFrame->PngSBmanyLines`, `SongsPluginFrame->PngSBOneLine`.
        var hintKeyPrefix: String { self == .songs ? "SongsPluginFrame->" : "" }
    }

    /// Вид окна выбора Книги (2).
    ///
    /// Четыре значения — это ровно четыре пункта меню «Интерфейс» и два
    /// положения кнопок (22): «плиткой» это `.icons`, «списком» это `.list`.
    /// В `VisioBible.ini` величина называется `BooksStyle` и принимает 0 и 1,
    /// поэтому в ini уходят только эти два вида, а «Мал. значки» и «Таблица»
    /// остаются нашими и живут в своих настройках.
    enum BookViewMode: String, CaseIterable, Identifiable {
        case icons, smallIcons, list, table
        var id: String { rawValue }

        /// Ключ подписи в файле перевода оригинала (форма `MainForm`).
        var captionKey: String {
            switch self {
            case .icons:      return "N8"
            case .smallIcons: return "N9"
            case .list:       return "N10"
            case .table:      return "N11"
            }
        }
        var captionFallback: String {
            switch self {
            case .icons:      return OurWords.t("Значки")
            case .smallIcons: return OurWords.t("Мал. значки")
            case .list:       return OurWords.t("Список")
            case .table:      return OurWords.t("Таблица")
            }
        }
        var symbol: String {
            switch self {
            case .icons:      return "square.grid.2x2"
            case .smallIcons: return "square.grid.3x3"
            case .list:       return "list.bullet"
            case .table:      return "tablecells"
            }
        }
    }

    /// Вид списка стихов (4), кнопки (21).
    ///
    /// В ini это `LinesStyle`: 0 — многострочный текст (`PngSBmanyLines`),
    /// 1 — текст в одну линию (`PngSBOneLine`). Значения взяты из рабочего
    /// файла настроек: в разделе `[Bible]` стоит 0, а в `[Text]` и `[Songs]`
    /// — 1, что совпадает с тем, как эти списки выглядят в программе.
    enum VerseViewMode: String, CaseIterable, Identifiable {
        case multiline, singleLine
        var id: String { rawValue }

        /// У кнопок (21) в оригинале нет подписи — только подсказка.
        var hintKey: String {
            switch self {
            case .multiline:  return "PngSBmanyLines"
            case .singleLine: return "PngSBOneLine"
            }
        }
        var hintFallback: String {
            switch self {
            case .multiline:  return OurWords.t("Многострочный текст")
            case .singleLine: return OurWords.t("Текст в одну линию")
            }
        }
        var symbol: String {
            switch self {
            case .multiline:  return "rectangle.expand.vertical"
            case .singleLine: return "rectangle.compress.vertical"
            }
        }
    }

    /// Оформление программы — раздел 7.2.
    ///
    /// В оригинале это файлы `Styles/*.vsf` — скины Delphi VCL Styles.
    /// Перенести их нельзя, и дело не в лени: `.vsf` это упакованный набор
    /// растровых деталей окна Windows (рамки, полосы прокрутки, галочки,
    /// заголовки) плюс таблица цветов, которую VCL натягивает поверх своей
    /// собственной отрисовки контролов. На macOS контролы рисует AppKit, у
    /// него другой набор частей и другая геометрия, поэтому подставить туда
    /// картинки из `.vsf` физически некуда — получилась бы не «та же тема», а
    /// пародия на неё с чужими пропорциями и нечитаемым текстом.
    /// Честный аналог того, ради чего эти стили выбирают, — светлое и тёмное
    /// оформление системы, его и даём.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return OurWords.t("По системе")
            case .light:  return OurWords.t("Светлое")
            case .dark:   return OurWords.t("Тёмное")
            }
        }
        var symbol: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light:  return "sun.max"
            case .dark:   return "moon"
            }
        }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light:  return NSAppearance(named: .aqua)
            case .dark:   return NSAppearance(named: .darkAqua)
            }
        }
    }

    // MARK: - Величины

    /// Счётчик правок оформления.
    ///
    /// Нужен видам, которые стоят за барьером `Equatable`: сами настройки
    /// лежат в словарях, сравнивать их в каждом виде было бы и дорого, и
    /// легко забыть. Полоса меню внутри окна по нему и узнаёт, что галочки
    /// в разделе «Интерфейс» пора пересобрать.
    @Published private(set) var revision = 0

    private func bump() { revision &+= 1 }

    /// Вид окна выбора Книги — свой у каждого режима.
    @Published private var bookViews: [ListScope: BookViewMode] = [:] {
        didSet { storeViews(); bump() }
    }
    /// Вид списка стихов / текста — тоже свой у каждого режима.
    @Published private var verseViews: [ListScope: VerseViewMode] = [:] {
        didSet { storeViews(); bump() }
    }

    func bookView(_ scope: ListScope) -> BookViewMode { bookViews[scope] ?? .icons }
    func verseView(_ scope: ListScope) -> VerseViewMode { verseViews[scope] ?? .multiline }

    func setBookView(_ mode: BookViewMode, in scope: ListScope) { bookViews[scope] = mode }
    func setVerseView(_ mode: VerseViewMode, in scope: ListScope) { verseViews[scope] = mode }

    @Published var appearance: Appearance {
        didSet {
            // Оформление под «Память» (N17) не попадает: это не состояние
            // списков, а выбор пользователя, и терять его при выключенной
            // памяти было бы неожиданно.
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
            bump()
        }
    }

    /// N17 «Память» (en: Memory, uk: Пам'ять) в меню «Интерфейс».
    ///
    /// Пункт стоит в одном ряду с четырьмя видами списка, поэтому понимаем
    /// его как «запоминать вид списков между запусками». Когда память
    /// выключена, при следующем старте вид берётся из `VisioBible.ini`, как
    /// при первом запуске.
    @Published var remembersLayout: Bool {
        didSet {
            defaults.set(remembersLayout, forKey: Keys.memory)
            // Включили память — сразу закрепляем то, что видно сейчас,
            // иначе до первого переключения запоминать было бы нечего.
            if remembersLayout { writeViews() }
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static func bookView(_ scope: ListScope) -> String { "interface.bookView.\(scope.rawValue)" }
        static func verseView(_ scope: ListScope) -> String { "interface.verseView.\(scope.rawValue)" }
        static let appearance = "interface.appearance"
        static let memory = "interface.memory"
    }

    private init() {
        let defaults = UserDefaults.standard
        let memory = defaults.object(forKey: Keys.memory) as? Bool ?? true

        // Перший запуск (і будь-який запуск із вимкненою «Пам'яттю») бере
        // вигляд списків із файла умовчань програми — щоб людина побачила
        // те, до чого звикла, а не наш вибір навмання. Секцій три, і вони
        // різні: Біблія — плитка й багаторядковий список, Текст і Пісні —
        // список і текст в один рядок.
        let original = IniSettings.locateConfig().flatMap { try? IniSettings(fileAt: $0) }

        var books: [ListScope: BookViewMode] = [:]
        var verses: [ListScope: VerseViewMode] = [:]
        for scope in ListScope.allCases {
            let iniBooks = original?.int("BooksStyle", in: scope.iniSection) ?? 0
            let iniLines = original?.int("LinesStyle", in: scope.iniSection) ?? 0
            let savedBook = memory ? defaults.string(forKey: Keys.bookView(scope)) : nil
            let savedVerse = memory ? defaults.string(forKey: Keys.verseView(scope)) : nil

            books[scope] = savedBook.flatMap(BookViewMode.init(rawValue:))
                ?? (iniBooks == 1 ? .list : .icons)
            verses[scope] = savedVerse.flatMap(VerseViewMode.init(rawValue:))
                ?? (iniLines == 1 ? .singleLine : .multiline)
        }
        bookViews = books
        verseViews = verses

        appearance = defaults.string(forKey: Keys.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        remembersLayout = memory

        // 7.2: выбранное оформление обязано пережить перезапуск. Раньше
        // `applyAppearance()` звался только из `didSet`, то есть исключительно
        // в ответ на щелчок человека, и при следующем старте окно снова было
        // системным при записанном в настройках «тёмном».
        applyAppearance()
    }

    private func storeViews() {
        guard remembersLayout else { return }
        writeViews()
    }

    private func writeViews() {
        for scope in ListScope.allCases {
            if let mode = bookViews[scope] { defaults.set(mode.rawValue, forKey: Keys.bookView(scope)) }
            if let mode = verseViews[scope] { defaults.set(mode.rawValue, forKey: Keys.verseView(scope)) }
        }
    }

    /// Применить выбранное оформление ко всем окнам программы.
    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    /// Поднять хранилище на старте программы.
    ///
    /// Нужна затем, что `shared` создаётся лениво — при первом обращении из
    /// вида. Пока окно не нарисовано, оформление не применено, и первый кадр
    /// успевает мигнуть системным. Вызов из `SlovoApp.start()` это убирает.
    @discardableResult
    static func start() -> InterfaceSettings {
        let settings = shared
        settings.applyAppearance()
        return settings
    }

    /// Кнопки (22): «плиткой» — «списком». Крайние виды из четырёх.
    ///
    /// В панели (22) оригинала ровно две кнопки — в файле перевода на неё есть
    /// только `PngSBBookFlow` и `PngSBBookOneLine`. «Мал. значки» (N9) и
    /// «Таблица» (N11) — пункты меню «Интерфейс», кнопок у них нет.
    func setBooksFlow(_ flow: Bool, in scope: ListScope) {
        setBookView(flow ? .icons : .list, in: scope)
    }

    func booksAreFlowing(in scope: ListScope) -> Bool {
        let mode = bookView(scope)
        return mode == .icons || mode == .smallIcons
    }

    /// Названия стилей оригинала — чтобы в окне 7.2 было видно, что именно
    /// не переносится, а не просто «список короче, чем был».
    static func originalStyleNames(dataRoot: URL) -> [String] {
        let folder = dataRoot.appendingPathComponent("Styles")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "vsf" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
