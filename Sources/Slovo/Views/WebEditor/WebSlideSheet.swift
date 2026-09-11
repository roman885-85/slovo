import Foundation
import SlovoCore

/// Оформление одной открытой страницы: что за ручки у неё есть, какие у них
/// значения и как записать новое, не тронув всего остального.
///
/// Здесь же живёт главное правило редактора, ради которого он и переделан:
/// **панель никогда не хранит значения**. Она каждый раз читает их из текста
/// страницы, а ползунок пишет ровно одну строку обратно в этот же текст.
/// Поэтому правка руками и правка ползунком не могут затереть друг друга:
/// у них один и тот же исходник, и второго мнения ни у кого нет. Правка
/// руками в блоке настроек становится показанием ползунка при следующем же
/// разборе; правка вне блока ползунком не задевается вовсе, потому что при
/// записи мы заменяем только отрезок строки между «двоеточием» и «точкой с
/// запятой» той единственной строки, которая называет нужную переменную.
struct WebSlideSheet {

    /// Каким способом страница хранит оформление.
    enum Dialect: Hashable {
        /// Наша заготовка: собственный блок «Настройки страницы».
        case template
        /// Любая другая страница: блоки `Слово: настройки` и `Слово: привязка`.
        case parameters
    }

    /// В каком состоянии блок настроек.
    enum Block: Hashable {
        case ready
        /// Блока нет, но его можно завести.
        case missing
        /// Блок нельзя трогать: он повреждён или сделан более новой версией.
        case locked(String)
    }

    let dialect: Dialect
    let block: Block
    /// Ручки в том порядке, в каком они объявлены в странице.
    let knobs: [WebSlideKnob]
    /// Значения для показа: своё, а чего нет — по умолчанию.
    let values: [String: String]
    /// Что записано в самой странице, без домысленных умолчаний.
    let stored: [String: String]
    /// Набор общего каталога — им же и записывается обратно.
    let settings: WebSlideSettings
    /// Объявления в блоке, которых нет в каталоге.
    let strangers: [String]
    let placement: WebSlidePlacement
    /// Строка, по которой предпросмотр решает, перезагружаться ли.
    let structureKey: String
    let note: String?
    /// Какие места страницы в ней и правда есть.
    ///
    /// У наших заготовок пусто: там каждая ручка объявлена в самой странице,
    /// и лишней ручке взяться неоткуда. У чужой страницы набор считается по
    /// разметке — им панель гасит ручки, которым в этой странице нечем
    /// распорядиться.
    let roles: Set<WebSlideParameter.Role>

    var canAdjust: Bool {
        if case .ready = block { return true }
        return false
    }

    /// Ручка, которой в этой странице не к чему приложиться.
    ///
    /// Не поломка и не повод прятать ручку: человек должен видеть, что
    /// «Цвет адреса» существует, — и понимать, почему именно здесь он ничего
    /// не даст. Молчаливо мёртвый ползунок хуже: его двигают и винят
    /// редактор.
    func idleReason(_ knob: WebSlideKnob) -> String? {
        guard dialect == .parameters else { return nil }
        guard let parameter = WebSlideParameters.parameter(named: knob.name) else { return nil }
        let role = parameter.role
        if role == .script { return role.missing }
        return roles.contains(role) ? nil : role.missing
    }

    /// Чому ручка робить менше, ніж від неї чекають.
    ///
    /// Це не поломка і не привід її ховати. «Розмір тексту» при увімкненому
    /// підборі — стеля, а не сам розмір: довгий вірш однаково буде ужатий до
    /// того, що влазить. Власник: «размер адрес и размер текста выполняет
    /// изменение только размера адреса» — рівно це й було видно, поки решта
    /// блоків сторінки не йшла за підібраним кеглем, а стояла на своєму.
    func limitNote(_ knob: WebSlideKnob) -> String? {
        guard knob.name == "--sl-size" else { return nil }
        let fit = (values["--sl-fit"] ?? "0").trimmingCharacters(in: .whitespaces).lowercased()
        guard fit == "1" || fit == "true" else { return nil }
        return OurWords.t("Сейчас размер подбирается под длину текста: это верхний предел, "
            + "а не сам размер. Чтобы задавать размер самому, снимите «Подбирать размер под длину текста».")
    }

    /// Значение ручки так, как его показывать.
    func value(_ knob: WebSlideKnob) -> String {
        values[knob.name] ?? ""
    }

    /// Задано ли значение так, что ручка его не понимает.
    func isHandWritten(_ knob: WebSlideKnob) -> Bool {
        guard let raw = stored[knob.name] else { return false }
        return !knob.understands(raw)
    }

    // MARK: - Разбор

    static func read(html: String) -> WebSlideSheet {
        if let region = templateRegion(in: html) {
            return readTemplate(html: html, region: region)
        }
        return readParameters(html: html)
    }

    // MARK: Наша заготовка

    /// Метки блока настроек заготовки. Ищем по словам, а не по всей строке с
    /// чертой: длина черты — украшение, и держаться за неё нельзя.
    /// Ищем неизменные скобки, а не слова подписи: подпись переводится, и
    /// однажды перевод уже спрятал блок разом во всех заготовках. Прежние
    /// русские слова оставлены для страниц, снятых до перевода.
    static let templateStarts = [WebSlideParameters.varsToken, "Настройки страницы"]
    static let templateEnds = [WebSlideParameters.varsEndToken, "Конец настроек"]

    /// Отрезок между метками — только он и переписывается.
    static func templateRegion(in html: String) -> Range<String.Index>? {
        guard let start = WebSlideParameters.markerRange(templateStarts, in: html) else { return nil }
        guard let end = WebSlideParameters.markerRange(templateEnds, in: html,
                                                       range: start.upperBound..<html.endIndex)
        else { return nil }
        return start.upperBound..<end.lowerBound
    }

    private static func readTemplate(html: String, region: Range<String.Index>) -> WebSlideSheet {
        let declared = declarations(in: html[region])
        var knobs: [WebSlideKnob] = []
        var strangers: [String] = []
        for (name, _) in declared {
            if let parameter = WebSlideTemplates.parameter(id: name) {
                knobs.append(WebSlideKnob(parameter))
            } else {
                strangers.append(name)
            }
        }

        var values: [String: String] = [:]
        for (name, value) in declared { values[name] = value }

        var notes: [String] = []
        if !strangers.isEmpty {
            notes.append(OurWords.t("своих переменных в блоке: ") + strangers.joined(separator: ", "))
        }
        // Подсказка нужна только там, где блоков настроек ПРАВДА два. Пока
        // условием было «есть хоть одна метка», она висела всегда: после
        // сведения форматов метку носит каждая заготовка.
        if WebSlideParameters.varsMarkers
            .map({ html.components(separatedBy: $0).count - 1 }).reduce(0, +) > 1 {
            notes.append(OurWords.t("в странице два блока настроек — ползунки правят только свой"))
        }

        let names = Set(declared.map { $0.name })
        let placement = WebSlidePlacement(
            horizontal: names.contains("--sl-anchor-x") ? "--sl-anchor-x" : nil,
            vertical: names.contains("--sl-anchor-y") ? "--sl-anchor-y" : nil)

        let structure = replacing(html, from: region.lowerBound, to: region.upperBound, with: "")

        return WebSlideSheet(dialect: .template,
                             block: .ready,
                             knobs: knobs,
                             values: values,
                             stored: values,
                             settings: WebSlideSettings(declared.map { ($0.name, $0.value) }),
                             strangers: strangers,
                             placement: placement,
                             structureKey: structure,
                             note: notes.isEmpty ? nil : notes.joined(separator: "; "),
                             roles: [])
    }

    /// Строки «--имя: значение;» по порядку.
    private static func declarations(in text: Substring) -> [(name: String, value: String)] {
        var result: [(String, String)] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--"), let colon = trimmed.firstIndex(of: ":") else { continue }
            guard let semicolon = trimmed[colon...].firstIndex(of: ";") else { continue }
            let name = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)..<semicolon])
                .trimmingCharacters(in: .whitespaces)
            guard WebSlideParameters.isVariableName(name), !value.isEmpty else { continue }
            if let already = result.firstIndex(where: { $0.0 == name }) {
                result[already] = (name, value)
            } else {
                result.append((name, value))
            }
        }
        return result
    }

    // MARK: Общий каталог

    private static func readParameters(html: String) -> WebSlideSheet {
        let document = WebSlideParameters.parse(html: html)

        // Блока настроек в странице может не быть, но какие-то значения в ней
        // всё равно записаны. Показывать вместо них заводские нечестно: человек
        // видит одни числа, а страница живёт по другим — и первое же движение
        // ползунка сдвигает её всю. Поэтому, когда блока нет, читаем то, что
        // страница объявляет сама.
        var settings = document.settings
        if case .missing = document.block {
            // Сперва переводим собственное оформление страницы, потом кладём
            // поверх явно объявленные ею переменные: явное всегда точнее
            // перевода.
            var own = WebSlideParameters.inferred(from: html)
            let explicit = WebSlideParameters.declared(in: html)
            for name in explicit.names {
                if let value = explicit[name] { own.set(name, value) }
            }
            for name in settings.names {
                if let value = settings[name] { own.set(name, value) }
            }
            settings = own
        }

        var knobs: [WebSlideKnob] = []
        var values: [String: String] = [:]
        var stored: [String: String] = [:]
        for parameter in WebSlideParameters.all where parameter.showsInPanel {
            knobs.append(WebSlideKnob(parameter))
        }
        for parameter in WebSlideParameters.all {
            values[parameter.name] = settings.value(parameter)
            if let own = settings[parameter.name] { stored[parameter.name] = own }
        }
        for name in settings.unknownNames {
            if let own = settings[name] { stored[name] = own; values[name] = own }
        }

        let block: Block
        switch document.block {
        case .damaged(let reason):
            block = .locked(OurWords.t("блок настроек повреждён: %s", reason))
        case .missing:
            block = .missing
        case .present(let version, _):
            block = version > WebSlideParameters.version
                ? .locked(OurWords.t("страницу настраивала более новая версия программы"))
                : .ready
        }

        // Точку привязки даём только там, где наш блок привязки и правда
        // работает: без него ползунок бы двигал переменную, которую никто не
        // читает, и человек решил бы, что перетаскивание сломано.
        let placement = document.hasBinding
            ? WebSlidePlacement(anchor: "--sl-anchor",
                                offsetX: "--sl-offset-x",
                                offsetY: "--sl-offset-y")
            : .none

        return WebSlideSheet(dialect: .parameters,
                             block: block,
                             knobs: knobs,
                             values: values,
                             stored: stored,
                             settings: document.settings,
                             strangers: document.settings.unknownNames,
                             placement: placement,
                             structureKey: WebSlideParameters.structure(html: html),
                             note: document.note,
                             roles: WebSlideParameters.RoleSelectors.standard.present(in: html))
    }

    // MARK: - Запись

    enum Outcome {
        case done(String)
        case refused(String)
    }

    /// Записать новые значения в страницу.
    ///
    /// Порядок важен: сперва проверяем все значения и только потом трогаем
    /// строку. Половина записанной пачки — это страница, которую человек не
    /// заказывал, и откатить её ему нечем.
    func writing(_ changes: [(name: String, value: String)], into html: String) -> Outcome {
        guard canAdjust else {
            return .refused(OurWords.t("Ползунки выключены: ") + (note ?? OurWords.t("блок настроек не в порядке")) + ".")
        }
        for change in changes where !WebSlideParameters.isWritable(change.value) {
            let title = knobs.first { $0.name == change.name }?.title ?? change.name
            return .refused(OurWords.t("Значение «%s» записать нельзя: в нём есть знак, "
                                       + "который оборвал бы правило и сломал страницу.", title))
        }

        switch dialect {
        case .template:
            var result = html
            for change in changes {
                guard let next = Self.writeTemplate(html: result, name: change.name, value: change.value) else {
                    return .refused(OurWords.t("В блоке настроек нет строки «%s», "
                                               + "а дописать её некуда: блок повреждён.", change.name))
                }
                result = next
            }
            return .done(result)

        case .parameters:
            var next = settings
            for change in changes {
                if let parameter = WebSlideParameters.parameter(named: change.name) {
                    next.choose(parameter, value: change.value)
                } else {
                    next.set(change.name, change.value)
                }
            }
            switch WebSlideParameters.write(html: html, settings: next) {
            case .written(let text): return .done(text)
            case .refused(let reason): return .refused(reason)
            }
        }
    }

    /// Заменить значение одной переменной в блоке заготовки.
    ///
    /// Меняется ровно отрезок между двоеточием и точкой с запятой. Ни отступ,
    /// ни выравнивающие пробелы, ни подпись в конце строки не трогаются —
    /// человек, открывший файл после ползунка, должен увидеть свой файл, а не
    /// переписанный набело.
    static func writeTemplate(html: String, name: String, value: String) -> String? {
        guard let region = templateRegion(in: html) else { return nil }
        let block = html[region]

        var search = block.startIndex
        while let hit = block.range(of: name, range: search..<block.endIndex) {
            search = hit.upperBound
            // Имя должно стоять в начале строки и обрываться двоеточием:
            // иначе мы нашли «--sl-ref» внутри «--sl-ref-scale».
            let before = block[block.startIndex..<hit.lowerBound]
            let lineHead = before.reversed().prefix { !$0.isNewline }
            guard lineHead.allSatisfy({ $0 == " " || $0 == "\t" }) else { continue }

            var cursor = hit.upperBound
            while cursor < block.endIndex, block[cursor] == " " { cursor = block.index(after: cursor) }
            guard cursor < block.endIndex, block[cursor] == ":" else { continue }
            let valueStart = block.index(after: cursor)
            guard let semicolon = block[valueStart...].firstIndex(of: ";") else { continue }
            return replacing(html, from: valueStart, to: semicolon, with: " " + value)
        }

        // Строки нет — дописываем перед закрывающей скобкой правила.
        guard let brace = block.range(of: "}", options: .backwards) else { return nil }
        return replacing(html, from: brace.lowerBound, to: brace.upperBound,
                         with: "  \(name): \(value);\n}")
    }

    /// Замена по расстоянию от начала, а не по готовым границам.
    ///
    /// Держать границы, взятые в одной строке, и прикладывать их к другой —
    /// та самая тихая ошибка, из-за которой правка попадает на пару букв
    /// мимо. Считаем расстояние и заводим границы заново.
    private static func replacing(_ html: String,
                                  from low: String.Index,
                                  to high: String.Index,
                                  with text: String) -> String {
        let start = html.distance(from: html.startIndex, to: low)
        let end = html.distance(from: html.startIndex, to: high)
        var result = html
        let range = result.index(result.startIndex, offsetBy: start)
            ..< result.index(result.startIndex, offsetBy: end)
        result.replaceSubrange(range, with: text)
        return result
    }

    // MARK: - Завести блок настроек

    /// Надеть на страницу общий блок настроек — с этого начинается настройка
    /// чужой страницы.
    static func addingParameters(to html: String, seed: WebSlideSettings? = nil) -> Outcome {
        // Начинаем не с заводских значений, а с того, чем страница живёт
        // сейчас: блок надевается поверх её собственного оформления, и
        // заводские числа сдвинули бы страницу разом. Заводскими добираем
        // только то, чего в ней нет вовсе.
        // Что страница задаёт сама. Лучший ответ даёт браузер — он приходит
        // готовым в `seed`; если его нет, разбираем лист стилей сами.
        var known = seed ?? WebSlideParameters.inferred(from: html)
        let explicit = WebSlideParameters.declared(in: html)
        for name in explicit.names {
            if let value = explicit[name] { known.set(name, value) }
        }
        let own = known.applyingDefaults()
        switch WebSlideParameters.write(html: html, settings: own) {
        case .written(let text): return .done(text)
        case .refused(let reason): return .refused(reason)
        }
    }

    /// Переписать повреждённый блок заново — только по кнопке и только с
    /// предупреждением: содержимое блока при этом теряется.
    static func repairing(_ html: String) -> Outcome {
        let document = WebSlideParameters.parse(html: html)
        let settings = document.settings.isEmpty ? WebSlideParameters.defaults : document.settings
        switch WebSlideParameters.repair(html: html, settings: settings) {
        case .written(let text): return .done(text)
        case .refused(let reason): return .refused(reason)
        }
    }

    // MARK: - Перетаскивание

    /// Что записать, если блок отпустили в этой точке кадра.
    ///
    /// Возвращает пустой список, когда тащить нечем: страница без точки
    /// привязки двигать нельзя, и делать вид, что можно, нечестно.
    func placing(at point: CGPoint) -> [(name: String, value: String)] {
        guard placement.canDrag else { return [] }
        let drop = WebSlidePlacement.drop(at: point)
        var changes: [(String, String)] = []

        if let horizontal = placement.horizontal, let vertical = placement.vertical {
            changes.append((horizontal, WebSlidePlacement.flexValues[drop.column]))
            changes.append((vertical, WebSlidePlacement.flexValues[drop.row]))
        }
        if let anchor = placement.anchor {
            changes.append((anchor, WebSlidePlacement.anchorValue(column: drop.column, row: drop.row)))
        }
        if let offsetX = placement.offsetX, knobs.contains(where: { $0.name == offsetX }) {
            changes.append((offsetX, WebSlideKnob.digits(drop.offsetX)))
        }
        if let offsetY = placement.offsetY, knobs.contains(where: { $0.name == offsetY }) {
            changes.append((offsetY, WebSlideKnob.digits(drop.offsetY)))
        }
        return changes
    }

    /// Где блок стоит сейчас — от этой точки считается перетаскивание.
    var placementPoint: CGPoint {
        var column = 1
        var row = 1
        if let horizontal = placement.horizontal, let vertical = placement.vertical {
            column = WebSlidePlacement.column(ofFlex: values[horizontal] ?? "center")
            row = WebSlidePlacement.column(ofFlex: values[vertical] ?? "center")
        }
        if let anchor = placement.anchor {
            let place = WebSlidePlacement.place(ofAnchor: values[anchor] ?? "center-center")
            column = place.column
            row = place.row
        }
        var point = WebSlidePlacement.fraction(column: column, row: row)
        if let offsetX = placement.offsetX, let raw = values[offsetX], let number = Double(raw) {
            point.x += number / 100
        }
        if let offsetY = placement.offsetY, let raw = values[offsetY], let number = Double(raw) {
            point.y += number / 100
        }
        return point
    }
}
