import AppKit
import SlovoCore

/// Состояние окна «Перевод интерфейса» (7.1, форма `LocalizeTranslateForm`).
///
/// Слева тексты на языке оригинала, справа поля перевода. «Языком оригинала»
/// в прежней программе служат подписи, вшитые в формы Delphi; у нас их взять неоткуда,
/// поэтому за оригинал принимаем русский перевод автора — самый полный файл в
/// папке `Language`, на котором написана и сама программа. Если русского нет,
/// берём английский, а дальше первый попавшийся.
@MainActor
final class LocalizeTranslateModel: ObservableObject {

    /// Вкладки (11): первая — видимые элементы формы, остальные — тексты
    /// сообщений разных типов.
    enum TextTab: String, CaseIterable, Identifiable {
        case objects, texts, errors
        var id: String { rawValue }
    }

    /// Строка списка (12). `isDone` красит её зелёным или красным.
    struct Row: Identifiable, Hashable {
        let key: String
        let type: String
        let originalCaption: String
        let originalHint: String
        let caption: String
        let hint: String
        let isDone: Bool
        var id: String { key }
    }

    // MARK: - Что правим

    @Published var languageCode: String = "" { didSet { if languageCode != oldValue { loadDraft() } } }
    @Published var displayName: String = ""
    @Published var formName: String = "MainForm" { didSet { selectedKey = nil } }
    @Published var tab: TextTab = .objects { didSet { selectedKey = nil } }
    @Published var onlyUntranslated = false
    @Published var selectedKey: String?
    @Published private(set) var isDirty = false
    @Published private(set) var availableLanguages: [LanguageFile] = []

    private(set) var reference: LanguageFile?
    private var draft: InterfaceLanguageStore.Draft = [:]

    let originals: URL

    init(originals: URL, startingCode: String) {
        self.originals = originals
        reference = InterfaceLanguageStore.language(code: "ru", originals: originals)
            ?? InterfaceLanguageStore.language(code: "en", originals: originals)
            ?? InterfaceLanguageStore.languages(originals: originals).first
        reloadLanguages()
        languageCode = startingCode
        loadDraft()
    }

    func reloadLanguages() {
        availableLanguages = InterfaceLanguageStore.languages(originals: originals)
    }

    /// Название языка, принятого за оригинал: без него непонятно, что за
    /// тексты стоят в левой половине окна.
    var referenceName: String { reference?.displayName ?? "—" }

    // MARK: - Списки

    /// Список окон (5): технические имена форм, как в оригинале.
    var formNames: [String] {
        var names = Set(reference?.forms.keys ?? [:].keys)
        names.formUnion(draft.keys)
        names.remove("_info_")
        names.remove("")
        // Наши подписи — отдельным «окном»: у автора такой формы нет, а
        // переводить их нужно там же, где и его.
        names.insert(OurWords.sectionName)
        return names.sorted()
    }

    /// Выбрана секция наших подписей, а не форма автора.
    var isOurSection: Bool { formName == OurWords.sectionName }

    /// Все ключи выбранного окна (5) — по всем трём вкладкам сразу.
    ///
    /// Кнопки (6) и (7) в оригинале названы «Очистить ВСЕ переводы для окна» и
    /// «Скопировать ВСЕ переводы для окна из оригинальных текстов»: окно, а не
    /// вкладка. Пока они ходили только по видимой вкладке, чтобы очистить окно
    /// целиком, приходилось обойти «Объекты», «Тексты» и «Ошибки» вручную.
    private var allKeysOfForm: [String] {
        var keys = Set((reference?.forms[formName] ?? [:]).keys)
        keys.formUnion((draft[formName] ?? [:]).keys)
        if isOurSection { keys.formUnion(OurWords.russianKeys) }
        return keys.sorted()
    }

    /// Ключи текущей формы и вкладки.
    private var keysForCurrentTab: [String] {
        var keys = Set((reference?.forms[formName] ?? [:]).keys)
        keys.formUnion((draft[formName] ?? [:]).keys)
        // Наши подписи все «объекты»: сообщений и ошибок среди них не
        // различить по имени ключа — ключ и есть сама строка.
        if isOurSection { return tab == .objects ? keys.union(OurWords.russianKeys).sorted() : [] }

        let filtered = keys.filter { key in
            switch tab {
            case .objects: return !key.hasPrefix("TextMessages") && !key.hasPrefix("ErrorMessages")
            case .texts:   return key.hasPrefix("TextMessages")
            case .errors:  return key.hasPrefix("ErrorMessages")
            }
        }
        // Сообщения нумерованные — сортируем по номеру, иначе 10 встаёт
        // между 1 и 2 и найти нужное сообщение глазами невозможно.
        if tab == .objects { return filtered.sorted() }
        return filtered.sorted { number(in: $0) < number(in: $1) }
    }

    private func number(in key: String) -> Int {
        Int(key.drop { !$0.isNumber }) ?? 0
    }

    var rows: [Row] {
        if isOurSection {
            // Оригинал — сама русская строка; перевод — правка человека, а
            // без неё то, что зашито в словарь для этого языка.
            let code = languageCode
            return keysForCurrentTab.compactMap { key in
                let mine = draft[formName]?[key]
                let shown = (mine?.caption).flatMap { $0.isEmpty ? nil : $0 }
                    ?? OurWords.builtIn(key, language: code) ?? ""
                let row = Row(key: key, type: OurWords.t("Подпись «Слова»"),
                              originalCaption: key, originalHint: "",
                              caption: shown, hint: "",
                              isDone: !shown.isEmpty)
                if onlyUntranslated && row.isDone { return nil }
                return row
            }
        }
        return keysForCurrentTab.compactMap { key in
            let source = reference?.entry(key, form: formName)
            let mine = draft[formName]?[key]
            let row = Row(key: key,
                          type: Self.objectType(for: key),
                          originalCaption: source?.caption ?? "",
                          originalHint: source?.hint ?? "",
                          caption: mine?.caption ?? "",
                          hint: mine?.hint ?? "",
                          isDone: Self.isDone(source: source, mine: mine))
            if onlyUntranslated && row.isDone { return nil }
            return row
        }
    }

    var selectedRow: Row? { rows.first { $0.key == selectedKey } }

    /// «Зелёная строка — перевод завершён, красная — нет». Перевод завершён,
    /// когда переведено всё, что вообще есть в оригинале: пустую подсказку
    /// переводить не требуется, и красить такую строку красной было бы враньём.
    private static func isDone(source: LanguageFile.Entry?, mine: InterfaceLanguageStore.TextPair?) -> Bool {
        let needsCaption = !(source?.caption ?? "").isEmpty
        let needsHint = !(source?.hint ?? "").isEmpty
        if !needsCaption && !needsHint { return true }
        if needsCaption && (mine?.caption ?? "").isEmpty { return false }
        if needsHint && (mine?.hint ?? "").isEmpty { return false }
        return true
    }

    /// Колонка «Тип» в списке (12).
    ///
    /// В Delphi там стоит класс контрола (`TLabel`, `TSpeedButton`…), а у нас
    /// его негде взять — форм оригинала мы не видим, только файл перевода.
    /// Зато имена ключей у автора выдержаны в единой системе, и по префиксу
    /// тип восстанавливается однозначно.
    static func objectType(for key: String) -> String {
        if key.contains("->Column") { return OurWords.t("Колонка списка") }
        if key.contains("->Item") { return OurWords.t("Пункт списка") }
        if key.hasSuffix("Form") || key.hasSuffix("Frame") || key.hasSuffix("Box") { return OurWords.t("Окно") }
        if key.hasPrefix("TextMessages") { return OurWords.t("Сообщение") }
        if key.hasPrefix("ErrorMessages") { return OurWords.t("Сообщение об ошибке") }
        if key.hasPrefix("MI") { return OurWords.t("Пункт меню") }
        if key.hasPrefix("N"), key.dropFirst().allSatisfy(\.isNumber), key.count > 1 { return OurWords.t("Пункт меню") }
        if key.hasPrefix("GroupBox") || key.hasPrefix("GB") { return OurWords.t("Группа") }
        if key.hasPrefix("TabSheet") || key.hasPrefix("TS") { return OurWords.t("Вкладка") }
        if key.hasPrefix("RG") { return OurWords.t("Переключатели") }
        if key.hasPrefix("CB") { return OurWords.t("Флажок / список") }
        if key.hasPrefix("Label") || key.hasPrefix("LV") { return OurWords.t("Надпись") }
        if key.hasPrefix("Panel") { return OurWords.t("Панель") }
        if key.hasPrefix("PngSpeedButton") || key.hasPrefix("PngSB") || key.hasPrefix("PSB")
            || key.hasPrefix("JvgSB") || key.hasPrefix("SB") || key.hasPrefix("TB")
            || key.hasPrefix("BB") || key.hasPrefix("PBB") { return OurWords.t("Кнопка") }
        if key.hasPrefix("E"), key.count > 1, key.dropFirst().first?.isUppercase == true { return OurWords.t("Поле ввода") }
        if key.hasPrefix("L"), key.count > 1, key.dropFirst().first?.isUppercase == true { return OurWords.t("Надпись") }
        return OurWords.t("Элемент")
    }

    // MARK: - Правка

    func setCaption(_ text: String, key: String) {
        let old = draft[formName]?[key]
        put(InterfaceLanguageStore.TextPair(caption: text, hint: old?.hint), key: key)
    }

    func setHint(_ text: String, key: String) {
        let old = draft[formName]?[key]
        put(InterfaceLanguageStore.TextPair(caption: old?.caption ?? "", hint: text), key: key)
    }

    private func put(_ entry: InterfaceLanguageStore.TextPair, key: String) {
        draft[formName, default: [:]][key] = entry
        isDirty = true
        objectWillChange.send()
    }

    /// (15) Очистить перевод выбранного элемента.
    func clearSelected() {
        guard let key = selectedKey else { return }
        put(InterfaceLanguageStore.TextPair(caption: ""), key: key)
    }

    /// (16) Скопировать оригинальные тексты в поля перевода.
    func copySelectedFromOriginal() {
        guard let key = selectedKey else { return }
        if isOurSection {
            put(InterfaceLanguageStore.TextPair(caption: key), key: key)
            return
        }
        guard let source = reference?.entry(key, form: formName) else { return }
        put(InterfaceLanguageStore.TextPair(source), key: key)
    }

    /// (6) Очистить ВСЕ переводы для выбранного окна — по всему окну, а не по
    /// открытой вкладке.
    func clearForm() {
        for key in allKeysOfForm {
            draft[formName, default: [:]][key] = InterfaceLanguageStore.TextPair(caption: "")
        }
        isDirty = true
        objectWillChange.send()
    }

    /// (7) Скопировать все тексты языка оригинала в текущий перевод — тоже по
    /// всему окну.
    func copyFormFromOriginal() {
        for key in allKeysOfForm {
            if isOurSection {
                draft[formName, default: [:]][key] = InterfaceLanguageStore.TextPair(caption: key)
                continue
            }
            guard let source = reference?.entry(key, form: formName) else { continue }
            draft[formName, default: [:]][key] = InterfaceLanguageStore.TextPair(source)
        }
        isDirty = true
        objectWillChange.send()
    }

    // MARK: - Поиск по колонкам, кнопки PngSpeedButton1…12

    /// Колонки списка (12), по которым ищут парами кнопок.
    enum Column { case object, type, originalCaption, originalHint, caption, hint }

    private func value(_ row: Row, _ column: Column) -> String {
        switch column {
        case .object:          return row.key
        case .type:            return row.type
        case .originalCaption: return row.originalCaption
        case .originalHint:    return row.originalHint
        case .caption:         return row.caption
        case .hint:            return row.hint
        }
    }

    /// «Искать следующий / предыдущий …».
    ///
    /// Ищем ближайшую строку, у которой в этой колонке есть непустое значение,
    /// отличное от текущего. На колонке «Объект» это обычный шаг по списку
    /// (имена уникальны), на «Типе» — переход к следующему типу, на колонках
    /// текстов — к следующему непустому тексту. Ровно то, что обещают подсказки.
    func step(_ column: Column, forward: Bool) {
        let list = rows
        guard !list.isEmpty else { return }
        let start = list.firstIndex { $0.key == selectedKey } ?? (forward ? -1 : list.count)
        let current = (start >= 0 && start < list.count) ? value(list[start], column) : ""

        let order = forward ? Array((start + 1)..<list.count) : Array(0..<max(start, 0)).reversed()
        for index in order {
            let candidate = value(list[index], column)
            guard !candidate.isEmpty, candidate != current else { continue }
            selectedKey = list[index].key
            return
        }
        NSSound.beep()
    }

    // MARK: - Файл

    private func loadDraft() {
        guard !languageCode.isEmpty else { return }
        let file = InterfaceLanguageStore.language(code: languageCode, originals: originals)
        draft = file.map(InterfaceLanguageStore.draft(of:)) ?? [:]
        displayName = file?.displayName ?? languageCode
        isDirty = false
        selectedKey = nil
    }

    /// (1) Сохранить перевод в свой файл `.lng`.
    @discardableResult
    func save() -> Bool {
        guard !languageCode.isEmpty else { return false }
        do {
            try InterfaceLanguageStore.write(draft: draft, code: languageCode, displayName: displayName)
            isDirty = false
            reloadLanguages()
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = OurWords.t("Не удалось сохранить перевод")
            alert.runModal()
            return false
        }
    }

    /// (3) Добавить новый перевод интерфейса.
    func addTranslation(name: String, code: String, copyOriginal: Bool) {
        var fresh: InterfaceLanguageStore.Draft = [:]
        if copyOriginal, let reference {
            fresh = InterfaceLanguageStore.draft(of: reference)
        }
        try? InterfaceLanguageStore.write(draft: fresh, code: code, displayName: name)
        reloadLanguages()
        languageCode = code
    }

    // MARK: - (4) Удаление перевода

    /// Какой язык сейчас выбран в главном окне программы.
    ///
    /// Ставит его вид при открытии и при каждой смене языка: модель про
    /// `AppState` ничего не знает нарочно, но без этого сведения отказ (4)
    /// не построить.
    var activeLanguageCode: String = ""

    /// Почему перевод удалить нельзя.
    enum DeleteRefusal {
        /// Он выбран языком интерфейса прямо сейчас — TextMessages12 автора.
        case inUse
        /// Это файл из папки прежней программы: чужую установку на запись не трогаем.
        case notOurs
    }

    /// Можно ли удалить выбранный сейчас перевод.
    ///
    /// Два отказа, и они разные. Первый — авторский: удалять перевод, который
    /// сейчас показан в окне, нельзя, потому что программе после этого не с чем
    /// работать, а `AppState.language` продолжал бы указывать на исчезнувший
    /// файл. Второй — наш: оригинальные `Language/*.lng` рядом с работающим
    /// прежняя программа мы только читаем.
    ///
    /// Вынесено отдельно и ничего не меняет: так отказ можно показать до
    /// вопроса «Удалить перевод?» и так его может прочитать самопроверка, не
    /// удаляя при этом ни одного файла.
    func deleteRefusal() -> DeleteRefusal? {
        if !activeLanguageCode.isEmpty,
           languageCode.caseInsensitiveCompare(activeLanguageCode) == .orderedSame {
            return .inUse
        }
        guard InterfaceLanguageStore.isUserOwned(code: languageCode) else { return .notOurs }
        return nil
    }

    /// (4) Удалить выбранный перевод.
    func deleteTranslation() -> DeleteRefusal? {
        if let refusal = deleteRefusal() { return refusal }

        try? InterfaceLanguageStore.delete(code: languageCode)
        reloadLanguages()
        languageCode = availableLanguages.first?.code ?? ""
        return nil
    }
}
