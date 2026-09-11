import AppKit
import Combine
import SlovoCore

/// Состояние модуля «Текст» — раздел 5.2 руководства: заголовок (23),
/// кнопки работы с текстом (24) и сам текст (25).
///
/// Почему отдельный объект, а не поля в `AppState`: `AppState` — общий файл
/// нескольких частей работы, и его нельзя править из этой. Тем же способом
/// сделан `DeskModel` для Плана, Истории и полей быстрого выбора. `AppState`
/// получает отсюда только готовый слайд — через `present`.
///
/// Объект один на программу: модуль в окне один, и его содержимое обязано
/// пережить и переключение вкладок (18), и перезапуск программы.
@MainActor
final class TextModuleModel: ObservableObject {

    static let shared = TextModuleModel()

    // MARK: - Содержимое

    /// Заголовок (23) и текст (25) вместе. Правка сразу пересобирает
    /// предпросмотр: в оригинале набираемый текст виден в окне (12) по ходу
    /// набора, а в зал он уходит только по двойному щелчку, Enter или F5.
    @Published var document = PlainTextDocument() {
        didSet {
            guard document != oldValue else { return }
            // Текст переписали — начинаем показ с первой страницы. Иначе
            // после правки длинного объявления курсор остаётся на странице,
            // которой больше нет, и предпросмотр показывает хвост.
            if document.body != oldValue.body { pageIndex = 0 }
            clampPage()
            refreshPreview()
            scheduleSave()
        }
    }

    /// Какая страница разбитого текста готовится сейчас. Страницы листаются
    /// теми же стрелками (13), что и стихи: «Следующий стих/страница».
    @Published private(set) var pageIndex = 0

    /// Как длинный текст ложится на слайды — «Опции работы» (15) из секции
    /// `[Text]`, а не `[Bible]`: у одного и того же пользователя «Разбивать
    /// на стихи» для Библии включено (`VersSubDivide=1`), а для текста нет.
    @Published var pagination = PlainTextDocument.Pagination() {
        didSet {
            guard pagination != oldValue else { return }
            clampPage()
            refreshPreview()
        }
    }

    /// Счётчик запросов фокуса для поля (25). F6 — «Установить фокус на
    /// Стихи/Текст» (N22). Именно счётчик, а не флаг: повторное нажатие той
    /// же клавиши обязано сработать снова.
    @Published private(set) var focusRequest = 0

    // MARK: - Связь с окном

    /// Куда отдавать собранный слайд: `live == false` — только предпросмотр
    /// (12), `true` — ещё и зал.
    ///
    /// Замыкание, а не прямой вызов `AppState`, по той же причине, по которой
    /// этот объект вообще существует: `slide` и `liveSlide` там закрыты на
    /// запись внутри своего файла, и открыть их можно только вставкой в него.
    /// Пока вставки нет, модуль полностью работает сам с собой — набор,
    /// разбивка, план, — просто ничего не проецирует.
    var present: ((Slide, _ live: Bool) -> Void)?

    /// Окно, из которого идёт показ, — нужно только «Истории» (11).
    ///
    /// Ссылка слабая и единственная: строку истории собирает
    /// `DeskModel.rememberLive(state:)`, а ему нужны режим окна и показанный
    /// слайд. Своего списка модуль не ведёт нарочно — формат строки и файл
    /// `History.ini` принадлежат `DeskModel`, и второй список разошёлся бы с
    /// ним при первой же правке.
    ///
    /// Через `present` это не передать: замыкание ставится в `SlovoApp` и
    /// отдаёт слайд в одну сторону, а `AppState` оттуда сюда не возвращается.
    private weak var host: AppState?

    /// Подключить модуль к окну.
    ///
    /// Зовётся отовсюду, откуда набранный текст вообще может уйти на экран:
    /// с рабочей области (18), из «Библии» по `MICopyToText` и из пункта
    /// плана. Повторный вызов ничего не портит — это одна и та же ссылка.
    func attach(_ state: AppState) { host = state }

    /// Знает ли модуль, куда писать «Историю» (11). Читает самопроверка.
    var isConnectedToHistory: Bool { host != nil }

    private var saveWork: DispatchWorkItem?
    /// Не private: самопроверка смотрит в это же хранилище — не оставила ли
    /// она там свой образец.
    static let storageKey = "textModule.document"

    private init() {
        // Объявление, набранное до служения, не должно пропадать при
        // перезапуске — так же, как не пропадает несохранённый план.
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let restored = try? JSONDecoder().decode(PlainTextDocument.self, from: data) {
            document = restored
        }
        // Разбивку берём из настроек пользователя сразу: без этого действовали
        // зашитые в код 21×6, и у другого человека длинный текст лёг бы на
        // слайды не так, как он настроил в оригинале.
        loadSettings()
    }

    // MARK: - Настройки оригинала

    /// Читает `[Text]` из `VisioBible.ini`. Стиль нужен только для оценки
    /// ёмкости страницы: поля и интерлиньяж берём те же, которыми слайд и
    /// будет нарисован.
    func applySettings(config: IniSettings?, style: SlideStyle? = nil) {
        guard let config else { return }
        pagination = PlainTextDocument.Pagination(config: config, section: "Text", style: style)
    }

    /// Знайти файл умовчань програми й застосувати з нього секцію `[Text]`.
    ///
    /// Своїм ходом, а не через спільний файл: розбивка потрібна модулю ще до
    /// того, як вікно намальовано, а файл налаштувань — півтори сотні рядків,
    /// читати їх у головному потоці не дорожче, ніж прочитати `UserDefaults`.
    /// Повертає шлях до прочитаного файла — його показує самоперевірка.
    @discardableResult
    func loadSettings() -> String? {
        guard let url = IniSettings.locateConfig(),
              let config = try? IniSettings(fileAt: url) else { return nil }
        // Ёмкость страницы считаем по стилю самого режима «Текст»: у него свои
        // поля и свой интерлиньяж, и по библейским вышло бы другое число строк.
        applySettings(config: config, style: SlideStyle(config: config, section: "Text", dataRoot: nil))
        configPath = url.path
        return url.path
    }

    /// Из какого файла взята разбивка — для самопроверки.
    private(set) var configPath: String?

    /// Оформление слайдов режима «Текст». В `[Text]` свой шаблон
    /// (`DefaultScheme=Info default`), свой фон, свои цвета и контур —
    /// это не библейский стиль с другим текстом.
    func slideStyle(config: IniSettings?, dataRoot: URL?) -> SlideStyle? {
        guard let config else { return nil }
        return SlideStyle(config: config, section: "Text", dataRoot: dataRoot)
    }

    // MARK: - Страницы

    /// Готовые слайды набранного текста. Пустой документ не даёт ни одного.
    var slides: [Slide] { document.slides(pagination) }

    var pageCount: Int { document.pageCount(pagination) }

    /// Слайд, который сейчас готов к показу.
    var currentSlide: Slide {
        document.slide(atPage: pageIndex, pagination)
    }

    /// Перелистывание страниц стрелками (13). Возвращает `true`, если шаг
    /// сделан: на краю набора вызывающий может решить, что делать дальше, —
    /// в режиме «Библия» стрелка на последнем стихе уходит в следующую главу,
    /// а у текста уходить некуда.
    @discardableResult
    func step(by delta: Int, live: Bool) -> Bool {
        let count = pageCount
        guard count > 0 else { return false }
        let next = pageIndex + delta
        guard next >= 0, next < count else { return false }
        pageIndex = next
        publish(live: live)
        return true
    }

    func selectPage(_ index: Int, live: Bool) {
        guard pageCount > 0 else { return }
        pageIndex = min(max(index, 0), pageCount - 1)
        publish(live: live)
    }

    /// Ответ на стрелку (13.1/13.2) в режиме «Текст».
    ///
    /// `true` значит «клавиша наша»: шаг сделан или мы упёрлись в край набора.
    /// Край тоже забираем себе — иначе стрелка ушла бы библейскому списку, тот
    /// перевёл бы стих и подменил предпросмотр местом Писания, хотя на экране
    /// открыта вкладка «Текст». `false` возвращаем, только когда показывать
    /// нечего: поле пустое, и пусть работает обычный путь.
    @discardableResult
    func handleStep(by delta: Int, live: Bool) -> Bool {
        guard pageCount > 0 else { return false }
        step(by: delta, live: live)
        return true
    }

    // MARK: - Показ

    /// Enter и F5 — вывести подготовленное в зал.
    func show() { publish(live: true) }

    /// То же, но с ответом «было что показывать».
    ///
    /// Нужна там, где показ общий на все режимы: в режиме «Текст» с пустым
    /// полем Enter не должен гасить зал чёрным слайдом — пусть работает
    /// обычный библейский путь.
    @discardableResult
    func showIfReady() -> Bool {
        guard pageCount > 0 else { return false }
        publish(live: true)
        return true
    }

    /// Пересобрать предпросмотр, ничего не меняя в зале.
    func refreshPreview() { publish(live: false) }

    /// Отдать собранный слайд наружу.
    ///
    /// Показ в зал — это ещё и строка «Истории» (11): «в историю заносятся
    /// адреса всех стихов, которые были ПЕРВЫМИ ПОКАЗАНЫ в окне слайда»
    /// (5.1.11), а на рисунке к 5.2 объявление «Дорогие! - Настройтесь на …»
    /// стоит и в Плане (10), и в Истории. Предпросмотр историю не трогает.
    private func publish(live: Bool) {
        present?(currentSlide, live)
        guard live else { return }
        rememberShown()
    }

    /// Показанное в зале — в «Историю» (11).
    ///
    /// Запись делает `DeskModel`: у него формат строки, ограничение списка и
    /// файл `History.ini`. Двух строк на одно объявление не будет, даже если
    /// ту же запись сделает и `AppState` из своего `present(_:live:)`: строки
    /// сравниваются по `HistoryRecord.identity`, и такую же подряд список не
    /// заводит.
    ///
    /// Режим проверяем нарочно: в чужом режиме `rememberLive` собрал бы из
    /// нашего слайда запись вида «место Писания» и испортил бы историю.
    private func rememberShown() {
        guard let host, host.mode == .text else { return }
        DeskModel.shared.rememberLive(state: host)
    }

    private func clampPage() {
        let count = pageCount
        pageIndex = count > 0 ? min(pageIndex, count - 1) : 0
    }

    // MARK: - Кнопки работы с текстом (24)

    /// `SBClearText` — «Очистить текст». Руководство (5.2.2) требует чистить
    /// оба поля сразу: и текст (25), и заголовок (23).
    func clear() {
        document.clear()
        pageIndex = 0
    }

    /// `SBAddTextToPlan` — «Добавить в план».
    ///
    /// В план уходит копия набранного, а не ссылка: ссылаться не на что —
    /// объявление нигде, кроме этого поля, не хранится.
    func addToPlan() {
        guard !document.isEmpty else { return }
        DeskModel.shared.addToPlan([PlanItem.text(document)])
    }

    // MARK: - Приём текста из модуля «Библия»

    /// Пункт контекстного меню списка стихов `MICopyToText` —
    /// «Скопировать во вкладку "Текст"».
    ///
    /// Берём не сами стихи, а уже собранный предпросмотр: там ровно то, что
    /// выделено в списке (4), с номерами стихов или без — как настроено, — и
    /// с адресом, собранным по правилам вкладки «Слайд». Пересобирать это
    /// заново значило бы получить другой текст, чем видит оператор.
    func receive(from state: AppState, mode: PlainTextDocument.Reception = .replace) {
        // Отсюда текст попадает в модуль впервые, ещё до того как человек
        // откроет вкладку (18), — заодно запоминаем окно для «Истории» (11).
        attach(state)
        let prepared = state.slide
        guard !prepared.mainText.isEmpty || !prepared.reference.isEmpty else { return }
        receive(reference: prepared.reference, text: prepared.mainText, mode: mode)
    }

    func receive(reference: String, text: String,
                 mode: PlainTextDocument.Reception = .replace) {
        document.receive(reference: reference, text: text, mode: mode)
        pageIndex = 0
        refreshPreview()
    }

    /// Пункт плана «Текст» подан на экран — щелчок по нему делает то же, что
    /// двойной щелчок по стиху.
    func activate(_ text: PlainTextDocument, state: AppState) {
        // Режим переключаем до показа: строку «Истории» (11) собирают по
        // режиму окна, и в чужом режиме объявление записалось бы как место
        // Писания.
        attach(state)
        state.mode = .text
        document = text
        pageIndex = 0
        show()
    }

    // MARK: - Фокус

    /// F6 в режиме «Текст» ставит курсор в поле текста (25).
    func focusBody() { focusRequest += 1 }

    // MARK: - Сохранение между запусками

    /// Пишем с задержкой: набор идёт по букве, а файл настроек не должен
    /// переписываться на каждое нажатие клавиши.
    /// Пока идёт самопроверка, набранное не сохраняем.
    ///
    /// Проверка кладёт в модуль свой образец и возвращает текст владельца на
    /// место, но отложенная запись успевала унести образец в настройки — и
    /// владелец находил во вкладке «Текст» чужое «Настройтесь на служение».
    /// Теперь на время проверки запись выключена вовсе: в настройках остаётся
    /// то, что там было.
    var savesToSettings = true

    private func scheduleSave() {
        saveWork?.cancel()
        guard savesToSettings else { return }
        let snapshot = document
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
