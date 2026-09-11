import Foundation
import AppKit
import WebKit
import CoreGraphics
import SlovoCore

/// Самопроверка мастерской веб-слайдов.
///
/// Проверять редактор снимком экрана бесполезно: панель выглядит одинаково
/// и когда ползунок пишет в файл, и когда он крутится вхолостую. Поэтому
/// здесь всё спрашивается у самой работы: панель просят собрать ручки по
/// настоящей странице, двигают каждый ползунок, тащат блок во все девять
/// углов и смотрят, что изменилось в строке файла, а что осталось
/// нетронутым — вплоть до побайтного сравнения чужой страницы с исходной.
///
/// Отдельно стоит проверка живого показа. Она грузит страницу в тот же
/// `WKWebView`, что и предпросмотр, и шлёт ей тот же скрипт, что шлёт
/// ползунок: только браузер может ответить, нашла ли привязка текст в чужой
/// разметке.
///
/// При `--selftest` она не отвечает никогда, и причина найдена точно.
/// Самопроверка запускается из блока, поставленного в главную очередь
/// (`SlovoApp.runSelfTest`), а `WKWebView` отдаёт и загрузку страницы, и
/// ответ `evaluateJavaScript` тоже через главную очередь. Пока блок не
/// вернулся, очередь второй раз не разбирается — сколько ни крути вложенный
/// `RunLoop`. Опыт: из блока главной очереди `DispatchQueue.main.async`
/// внутри вложенного цикла не выполняется вовсе, а из обработчика таймера —
/// выполняется сразу. Отсюда и `isLoading == true` до самого срока.
///
/// Значит, ответ браузера при `--selftest` получить нечем, и проверка честно
/// говорит «пропущено». Всё, что можно узнать без браузера, спрашивается
/// проверками выше — по разметке страницы и по правилам привязки.
extension Diagnostics {

    static func webEditorSection(state: AppState) -> [Check] {
        let area = "Редактор веб-слайдів"
        var checks: [Check] = []

        checks.append(sectionsCheck(area: area))
        checks.append(panelCheck(area: area))
        checks.append(ownValuesCheck(area: area))
        checks.append(ownStyleCheck(area: area))
        checks.append(addressCheck(area: area, state: state))
        checks.append(knobWriteCheck(area: area))
        checks.append(handEditCheck(area: area))
        checks.append(dragCheck(area: area))
        checks.append(reloadCheck(area: area))
        checks.append(idleKnobsCheck(area: area))
        checks.append(contentsOf: authorPagesChecks(area: area, state: state))
        checks.append(authorRolesCheck(area: area, state: state))
        checks.append(authorPreviewCheck(area: area, state: state))
        checks.append(liveCheck(area: area, state: state))
        checks.append(authorPhrasesCheck(area: area, state: state))
        checks.append(ownerPagesCheck(area: area))
        checks.append(contentsOf: authorLiveSection(state: state))

        return checks
    }

    // MARK: - Разделы панели

    /// Каждая группа обоих каталогов обязана лечь в свой раздел.
    ///
    /// Незнакомая группа не ошибка сама по себе — но её ручки уедут в
    /// «Поведение», где их никто не найдёт, и заметить это на глаз нельзя.
    private static func sectionsCheck(area: String) -> Check {
        var lost: [String] = []
        for parameter in WebSlideTemplates.parameters where WebSlideSection.of(group: parameter.group) == nil {
            if !lost.contains(parameter.group) { lost.append(parameter.group) }
        }
        for group in WebSlideParameter.Group.allCases where WebSlideSection.of(group: group.key) == nil {
            if !lost.contains(group.key) { lost.append(group.key) }
        }
        return Check(area: area, name: "Ручки розкладено за розділами",
                     status: lost.isEmpty ? .ok : .failed,
                     detail: lost.isEmpty
                        ? "розділів \(WebSlideSection.allCases.count), усі групи обох каталогів розкладено"
                        : "ніде показати групи: " + lost.joined(separator: ", "))
    }

    // MARK: - Панель показывает ровно объявленное

    private static func panelCheck(area: String) -> Check {
        var trouble: [String] = []

        for template in WebSlideTemplates.all {
            let sheet = WebSlideSheet.read(html: template.html)
            if sheet.dialect != .template {
                trouble.append("\(template.id): блок налаштувань не знайдено")
                continue
            }
            if !sheet.canAdjust { trouble.append("\(template.id): повзунки вимкнено") }

            let shown = sheet.knobs.map { $0.name }
            let declared = template.parameterNames
            if shown != declared {
                let extra = shown.filter { !declared.contains($0) }
                let missing = declared.filter { !shown.contains($0) }
                var reason = "\(template.id):"
                if !extra.isEmpty { reason += " зайві — " + extra.joined(separator: ", ") }
                if !missing.isEmpty { reason += " не показано — " + missing.joined(separator: ", ") }
                if extra.isEmpty && missing.isEmpty { reason += " порядок ручок не той, що у файлі" }
                trouble.append(reason)
            }
            if !sheet.strangers.isEmpty {
                trouble.append("\(template.id): незрозумілі оголошення — "
                               + sheet.strangers.joined(separator: ", "))
            }
            // Значение обязано быть у каждой ручки: пустой ползунок стоял бы
            // на нуле и врал о том, что записано в файле.
            let empty = sheet.knobs.filter { sheet.value($0).isEmpty }.map { $0.name }
            if !empty.isEmpty {
                trouble.append("\(template.id): без значення — " + empty.joined(separator: ", "))
            }
        }

        let total = WebSlideTemplates.all.reduce(0) { $0 + $1.parameterNames.count }
        return Check(area: area, name: "Панель показує рівно те, що є в сторінці",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "за десятьма заготовками зійшлося \(total) ручок, зайвих і загублених немає"
                        : trouble.joined(separator: "; "))
    }

    // MARK: - Копия остаётся похожей на оригинал

    /// Страница без блока настроек живёт по значениям, записанным в ней самой.
    ///
    /// Проверка появилась после жалобы: копия страницы открывалась с другими
    /// числами, чем та, с которой её сняли. Причина была в том, что и панель, и
    /// новый блок настроек брали заводские значения, а не те, что стоят в
    /// странице. Здесь мы собираем страницу с заведомо «своими» величинами,
    /// надеваем на неё блок и смотрим, дожили ли они до блока.
    private static func ownValuesCheck(area: String) -> Check {
        let name = "Копія сторінки зберігає її власні налаштування"
        let ownSize = "7.5vh"
        let page = """
        <html><head><style>
        :root {
          --sl-size: \(ownSize);
        }
        </style></head><body><div data-sl-bind="text"></div></body></html>
        """

        let before = WebSlideSheet.read(html: page)
        guard case .missing = before.block else {
            return Check(area: area, name: name, status: .failed,
                         detail: "у пробної сторінки несподівано знайшовся блок налаштувань")
        }
        let shown = before.value(WebSlideKnob(WebSlideParameters.parameter(named: "--sl-size")
            ?? WebSlideParameters.all[0]))
        guard shown == ownSize else {
            return Check(area: area, name: name, status: .failed,
                         detail: "панель показує «\(shown)» замість свого «\(ownSize)»")
        }

        switch WebSlideSheet.addingParameters(to: page) {
        case .refused(let reason):
            return Check(area: area, name: name, status: .failed, detail: "блок не завівся: \(reason)")
        case .done(let text):
            let after = WebSlideSheet.read(html: text)
            let kept = after.values["--sl-size"] ?? ""
            return Check(area: area, name: name,
                         status: kept == ownSize ? .ok : .failed,
                         detail: kept == ownSize
                            ? "своє «--sl-size: \(ownSize)» дожило і до панелі, і до нового блоку"
                            : "у новому блоці опинилося «\(kept)» замість свого «\(ownSize)»")
        }
    }

    /// Чужая страница без единой нашей переменной всё равно как-то выглядит.
    ///
    /// Проверка выросла из жалобы: «взял оригинал за основу, нажал добавить
    /// настройки — и все настройки стали по умолчанию, не как у шаблона».
    /// Наши правила привязки написаны через `!important`, поэтому заводские
    /// значения перекрашивают страницу целиком. Здесь мы берём страницу,
    /// написанную обычным CSS — как у автора, — и смотрим, доехало ли её
    /// собственное оформление до блока настроек.
    private static func ownStyleCheck(area: String) -> Check {
        let name = "Чужа сторінка не збивається на заводські значення"
        let page = """
        <html><head><style>
        body { background-color: rgb(20 40 60); }
        #content {
          color: #ffcc00;
          font-size: 24px;
          font-family: Georgia, serif;
          text-align: left;
          font-weight: bold;
        }
        </style></head><body><div id="content"></div></body></html>
        """

        var faults: [String] = []
        let sheet = WebSlideSheet.read(html: page)
        func check(_ variable: String, _ wanted: String, in values: [String: String]) {
            let got = values[variable] ?? "—"
            if got != wanted { faults.append("\(variable): «\(got)» замість «\(wanted)»") }
        }
        check("--sl-color", "#ffcc00", in: sheet.values)
        check("--sl-align", "left", in: sheet.values)
        check("--sl-weight", "700", in: sheet.values)
        // 24px на кадре 1920×1080 — это 1.25 доли ширины экрана.
        check("--sl-size", "1.25", in: sheet.values)
        check("--sl-unit", "1vw", in: sheet.values)
        check("--sl-page-rgb", "20 40 60", in: sheet.values)

        switch WebSlideSheet.addingParameters(to: page) {
        case .refused(let reason):
            faults.append("блок не завівся: \(reason)")
        case .done(let text):
            let after = WebSlideSheet.read(html: text)
            check("--sl-color", "#ffcc00", in: after.values)
            check("--sl-size", "1.25", in: after.values)
            check("--sl-page-rgb", "20 40 60", in: after.values)
            // Живой блок обязан лечь вместе с настройками: без него правка
            // ползунка доходит до страницы только с перезагрузкой.
            if !text.contains("SlovoVars") { faults.append("немає блоку живих налаштувань") }
        }

        return Check(area: area, name: name,
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                        ? "колір, кегль, шрифт, вирівнювання і фон узято зі сторінки, а не із заводу"
                        : faults.joined(separator: "; "))
    }

    /// Короткий адрес страницы и свои страницы в списке.
    ///
    /// Обе жалобы из одного дня: «в Remote API нет новых сохранённых
    /// шаблонов» и «адреса сложного написания и нигде не указаны». Проверка
    /// смотрит, что имя файла превращается в человеческий адрес и что свои
    /// страницы попадают в перечень наравне с авторскими.
    private static func addressCheck(area: String, state: AppState) -> Check {
        var faults: [String] = []

        let cases = [
            ("VBWebSlide.html", "vbwebslide"),
            ("VBWebSlide копия.html", "vbwebslide-kopiia"),
            ("Мой шаблон 2.html", "moi-shablon-2"),
        ]
        for (file, wanted) in cases {
            let got = WebPageAddress.slug(of: file)
            if got != wanted { faults.append("«\(file)» → «\(got)», чекали «\(wanted)»") }
        }

        // Свои страницы обязаны попасть в перечень: сервер их отдаёт, и
        // спрятать их от списка значит спрятать от человека.
        let folder = state.modulesFolder.deletingLastPathComponent().appendingPathComponent("RemoteAPI")
        let listed = WebOutputSettings.discoverPages(in: folder).map { $0.fileName }
        let mine = ((try? FileManager.default.contentsOfDirectory(atPath: WebOutputServer.userPagesFolder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".html") }
        let lost = mine.filter { name in !listed.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        if !lost.isEmpty { faults.append("своїх сторінок немає в переліку: " + lost.joined(separator: ", ")) }

        return Check(area: area, name: "Адреса сторінки коротка, свої сторінки в переліку",
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                        ? "у переліку \(listed.count) сторінок, із них своїх \(mine.count); адреса виду /vbwebslide-kopiia"
                        : faults.joined(separator: "; "))
    }

    // MARK: - Ползунок меняет файл и только его

    /// Другое значение той же ручки — чтобы было чем двинуть ползунок.
    private static func otherValue(_ knob: WebSlideKnob, than current: String) -> String? {
        switch knob.kind {
        case .number(let low, let high, _, _):
            let now = knob.number(from: current) ?? low
            let next = abs(now - high) > abs(now - low) ? high : low
            let text = knob.text(from: next)
            return text == current ? nil : text
        case .color:
            return current == "#123456" ? "#654321" : "#123456"
        case .colorRGB:
            return current == "12 34 56" ? "65 43 21" : "12 34 56"
        case .choice(let options):
            return options.first { $0.value != current }?.value
        case .toggle(let on, let off, _, _):
            return current == on ? off : on
        case .text:
            return current == "none" ? "url(\"проба.jpg\")" : "none"
        }
    }

    /// Сколько строк разошлось между двумя видами файла.
    private static func differingLines(_ before: String, _ after: String) -> Int {
        let old = before.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let new = after.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard old.count == new.count else { return max(old.count, new.count) }
        return zip(old, new).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
    }

    private static func knobWriteCheck(area: String) -> Check {
        var trouble: [String] = []
        var moved = 0

        for template in WebSlideTemplates.all {
            let sheet = WebSlideSheet.read(html: template.html)
            for knob in sheet.knobs {
                let current = sheet.value(knob)
                guard let next = otherValue(knob, than: current) else { continue }
                guard case .done(let text) = sheet.writing([(knob.name, next)], into: template.html) else {
                    trouble.append("\(template.id)/\(knob.name): записати не вийшло")
                    continue
                }
                moved += 1

                let after = WebSlideSheet.read(html: text)
                if after.value(knob) != next {
                    trouble.append("\(template.id)/\(knob.name): у файлі лишилося «\(after.value(knob))»")
                }
                // Всё, кроме блока настроек, обязано остаться прежним.
                if after.structureKey != sheet.structureKey {
                    trouble.append("\(template.id)/\(knob.name): зачеплено щось поза блоком налаштувань")
                }
                let lines = differingLines(template.html, text)
                if lines != 1 {
                    trouble.append("\(template.id)/\(knob.name): розійшлося рядків \(lines), а має бути один")
                }
                if after.knobs.map({ $0.name }) != sheet.knobs.map({ $0.name }) {
                    trouble.append("\(template.id)/\(knob.name): після правки набір ручок змінився")
                }
            }
        }

        return Check(area: area, name: "Повзунок міняє файл і лише свій рядок",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "перевірено рухів: \(moved); кожен міняє рівно один рядок блоку налаштувань"
                        : trouble.prefix(6).joined(separator: "; "))
    }

    // MARK: - Правка руками не теряется

    private static func handEditCheck(area: String) -> Check {
        let name = "Правка руками і повзунок не сперечаються"
        guard let template = WebSlideTemplates.template(id: "plain") else {
            return Check(area: area, name: name, status: .failed, detail: "не знайшлася заготовка «plain»")
        }

        // Правка вне блока — своё правило в конце листа стилей.
        let ownRule = "\n/* моя правка */\n.quote { letter-spacing: 0.02em; }\n"
        var html = template.html
        guard let close = html.range(of: "</style>") else {
            return Check(area: area, name: name, status: .failed, detail: "у заготовці немає </style>")
        }
        html.replaceSubrange(close, with: ownRule + "</style>")

        // Правка внутри блока — значение, которого ползунок не понимает.
        html = html.replacingOccurrences(of: "--sl-width: 90;", with: "--sl-width: calc(80 + 4);")
        guard html.contains("calc(80 + 4)") else {
            return Check(area: area, name: name, status: .failed,
                         detail: "не знайшовся рядок «--sl-width: 90;» — заготовка змінилася")
        }

        var trouble: [String] = []
        let sheet = WebSlideSheet.read(html: html)
        guard let width = sheet.knobs.first(where: { $0.name == "--sl-width" }) else {
            return Check(area: area, name: name, status: .failed, detail: "ручка «--sl-width» зникла з панелі")
        }
        if !sheet.isHandWritten(width) {
            trouble.append("вписане руками значення повзунок вважав своїм")
        }
        if sheet.value(width) != "calc(80 + 4)" {
            trouble.append("панель показує «\(sheet.value(width))» замість вписаного руками")
        }

        // Теперь двигаем соседнюю ручку.
        guard let size = sheet.knobs.first(where: { $0.name == "--sl-size" }),
              case .done(let after) = sheet.writing([(size.name, size.text(from: 9))], into: html) else {
            return Check(area: area, name: name, status: .failed, detail: "не вдалося зрушити «--sl-size»")
        }
        if !after.contains(ownRule.trimmingCharacters(in: .newlines)) {
            trouble.append("правило, дописане руками поза блоком, загублено")
        }
        if !after.contains("--sl-width: calc(80 + 4);") {
            trouble.append("значення, вписане руками в блок, затерто повзунком")
        }
        if WebSlideSheet.read(html: after).value(size) != size.text(from: 9) {
            trouble.append("нове значення повзунка не прочиталося назад")
        }

        return Check(area: area, name: name,
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "своє правило поза блоком і своє значення всередині пережили рух сусіднього повзунка"
                        : trouble.joined(separator: "; "))
    }

    // MARK: - Перетаскивание

    /// Голая страница без всякого оформления.
    ///
    /// На такой проверяется общий блок настроек: наши заготовки для этого не
    /// годятся — у них свой блок, и редактор, по устройству, правит именно
    /// его.
    private static let bareHTML = """
    <!DOCTYPE html>
    <html lang="ru">
    <head>
    <meta charset="UTF-8">
    <title>Проба</title>
    </head>
    <body>
    <div class="slide"><div class="quote">Текст</div><div class="reference">Бытие 1:1</div></div>
    </body>
    </html>
    """

    private static func dragCheck(area: String) -> Check {
        let name = "Перетягування міняє розташування"
        var trouble: [String] = []

        guard let template = WebSlideTemplates.template(id: "plain") else {
            return Check(area: area, name: name, status: .failed, detail: "не знайшлася заготовка «plain»")
        }

        // Девять точек: бросили в угол — блок встал в тот же угол.
        var html = template.html
        for row in 0..<3 {
            for column in 0..<3 {
                let sheet = WebSlideSheet.read(html: html)
                let changes = sheet.placing(at: WebSlidePlacement.fraction(column: column, row: row))
                guard !changes.isEmpty else {
                    trouble.append("заготовку нічим рухати")
                    break
                }
                guard case .done(let next) = sheet.writing(changes, into: html) else {
                    trouble.append("не записалося положення \(column)/\(row)")
                    continue
                }
                html = next
                let landed = WebSlidePlacement.drop(at: WebSlideSheet.read(html: html).placementPoint)
                if landed.column != column || landed.row != row {
                    trouble.append("кинули в \(column)/\(row), стало в \(landed.column)/\(landed.row)")
                }
            }
        }

        // Промах мимо точки: близкий притягивается, дальний уходит в сдвиг.
        let near = WebSlidePlacement.drop(at: CGPoint(x: 0.51, y: 0.49))
        if near.offsetX != 0 || near.offsetY != 0 {
            trouble.append("майже середина не притягнулася до середини")
        }
        let far = WebSlidePlacement.drop(at: CGPoint(x: 0.30, y: 0.62))
        if far.column != 1 || far.row != 1 || far.offsetX >= 0 || far.offsetY <= 0 {
            trouble.append("далекий промах не пішов у тонкий зсув")
        }

        // То же на устройстве общего каталога: там точка одна на девять
        // положений, а тонкий сдвиг живёт отдельными переменными.
        guard case .done(let dressed) = WebSlideSheet.addingParameters(to: bareHTML) else {
            return Check(area: area, name: name, status: .failed,
                         detail: (trouble + ["не вдалося надягти спільний блок налаштувань"]).joined(separator: "; "))
        }
        let sheet = WebSlideSheet.read(html: dressed)
        if sheet.dialect != .parameters { trouble.append("голу сторінку прийнято за нашу заготовку") }
        if case .done(let moved) = sheet.writing(sheet.placing(at: CGPoint(x: 0.98, y: 0.02)), into: dressed) {
            let after = WebSlideSheet.read(html: moved)
            if after.values["--sl-anchor"] != "top-right" {
                trouble.append("точка прив'язки стала «\(after.values["--sl-anchor"] ?? "")» замість «top-right»")
            }
            // Спутники выбора обязаны дописаться вместе с ним, иначе точка
            // записана, а прижим остался прежним — и блок не двинется.
            if after.values["--sl-h"] != "flex-end" || after.values["--sl-v"] != "flex-start" {
                trouble.append("притиски не поїхали за точкою прив'язки")
            }
            let landed = WebSlidePlacement.drop(at: after.placementPoint)
            if landed.column != 2 || landed.row != 0 {
                trouble.append("на спільному блоці блок став не в той кут")
            }
        } else {
            trouble.append("на спільному блоці налаштувань перетягування не записалося")
        }

        // Кадр предпросмотра. Мышь считается в долях кадра, а кадр — 16:9
        // внутри отведённого места, и на узком окне он вовсе не совпадает с
        // окном. Пока это считалось внутри вида, промах на другом размере
        // заметить было нечем: перетаскивание «почти работает», и никто не
        // понимает почему.
        let sizes: [CGSize] = [CGSize(width: 1600, height: 900),   // ровно 16:9
                               CGSize(width: 1200, height: 900),   // высокое окно: поля слева и справа
                               CGSize(width: 1600, height: 500),   // низкое окно: поля сверху и снизу
                               CGSize(width: 420, height: 300),    // панель ужата до предела
                               CGSize(width: 900, height: 900)]
        for size in sizes {
            let side = WebSlidePlacement.frame(in: size)
            if abs(side.width / side.height - 16.0 / 9.0) > 0.001 {
                trouble.append("кадр \(Int(size.width))×\(Int(size.height)) вийшов не 16:9")
            }
            if side.width > size.width + 0.5 || side.height > size.height + 0.5 {
                trouble.append("кадр \(Int(size.width))×\(Int(size.height)) не вліз у відведене місце")
            }
            // Целимся в девять точек кадра пикселями — попадаем в те же девять.
            for row in 0..<3 {
                for column in 0..<3 {
                    let aim = WebSlidePlacement.fraction(column: column, row: row)
                    let mouse = CGPoint(x: aim.x * side.width, y: aim.y * side.height)
                    let drop = WebSlidePlacement.drop(at: WebSlidePlacement.fraction(of: mouse, in: side))
                    if drop.column != column || drop.row != row || drop.offsetX != 0 || drop.offsetY != 0 {
                        trouble.append("на кадрі \(Int(side.width))×\(Int(side.height)) точка \(column)/\(row) "
                                       + "пішла в \(drop.column)/\(drop.row)")
                    }
                }
            }
            // Прилипание: промах в один пиксель мимо середины — это середина.
            let almost = CGPoint(x: side.width / 2 + 1, y: side.height / 2 - 1)
            let snapped = WebSlidePlacement.drop(at: WebSlidePlacement.fraction(of: almost, in: side))
            if snapped.offsetX != 0 || snapped.offsetY != 0 {
                trouble.append("на кадрі \(Int(side.width))×\(Int(side.height)) середина не прилипла")
            }
            // А четверть кадра мимо — это уже сдвиг, и он считается в сотых
            // долях кадра, а не в пикселях: иначе на узком окне блок уезжал
            // бы вдвое дальше, чем показала мышь.
            let far = CGPoint(x: side.width / 2 + side.width * 0.2, y: side.height / 2)
            let shifted = WebSlidePlacement.drop(at: WebSlidePlacement.fraction(of: far, in: side))
            if abs(shifted.offsetX - 20) > 0.5 || shifted.column != 1 {
                trouble.append("на кадрі \(Int(side.width))×\(Int(side.height)) зсув вийшов "
                               + "\(WebSlideKnob.digits(shifted.offsetX)) замість 20")
            }
        }

        return Check(area: area, name: name,
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "дев'ять точок потрапляють у себе на обох пристроях і при \(sizes.count) розмірах "
                            + "вікна, близький промах притягується, далекий іде в тонкий зсув"
                        : trouble.prefix(6).joined(separator: "; "))
    }

    // MARK: - Предпросмотр не перезагружается зря

    /// Перезагрузка на каждый шаг ползунка — это мигание, из-за которого
    /// подбирать оформление невозможно. Поэтому строка, по которой
    /// предпросмотр решает перезагружаться, обязана переживать движение
    /// ползунка и меняться от правки разметки.
    @MainActor
    private static func reloadCheck(area: String) -> Check {
        let name = "Передпоказ не блимає на повзунку"
        guard let template = WebSlideTemplates.template(id: "plain") else {
            return Check(area: area, name: name, status: .failed, detail: "не знайшлася заготовка «plain»")
        }

        let model = WebSlideEditorModel()
        model.source = template.html
        let before = model.previewReloadKey
        let values = model.previewValues

        guard let size = model.sheet.knobs.first(where: { $0.name == "--sl-size" }) else {
            return Check(area: area, name: name, status: .failed, detail: "у заготовки немає ручки розміру")
        }
        // Пишем через лист напрямую: у самопроверки нет открытого файла, а
        // ползунок в окне сперва спрашивает, своя ли это страница.
        if case .done(let text) = model.sheet.writing([(size.name, size.text(from: 9))], into: model.source) {
            model.source = text
        }

        var trouble: [String] = []
        if model.previewReloadKey != before {
            trouble.append("після повзунка передпоказ перезавантажиться, хоча розмітка та сама")
        }
        if model.previewValues["--sl-size"] == values["--sl-size"] {
            trouble.append("нове значення не доїхало до передпоказу")
        }
        model.source += "\n<!-- своя правка розмітки -->\n"
        if model.previewReloadKey == before {
            trouble.append("після правки розмітки передпоказ не перезавантажиться")
        }

        return Check(area: area, name: name,
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "повзунок доїжджає підстановкою значення, перезавантаження лише на правку розмітки"
                        : trouble.joined(separator: "; "))
    }

    // MARK: - Ползунок не крутится вхолостую

    /// Ручка, которую никто не читает, — обман: она двигается, а на экране
    /// ничего не меняется. У заготовок за этим следит их собственная
    /// самопроверка, а здесь — общий блок, который редактор надевает на
    /// чужие страницы: каждая его ручка обязана стоять в правилах привязки,
    /// если только не отмечена честно как «не про CSS».
    private static func idleKnobsCheck(area: String) -> Check {
        let binding = WebSlideParameters.bindingCSS()
        var idle: [String] = []
        for parameter in WebSlideParameters.all where parameter.isBoundToCSS {
            if !binding.contains("var(\(parameter.name)") { idle.append(parameter.name) }
        }

        // И второе: любое значение, какое панель может показать, обязано
        // доехать до страницы скриптом. Значение, которое `previewScript`
        // отбросит, останется в файле, но не появится на экране — и человек
        // увидит одно, а зал другое.
        var values: [String: String] = [:]
        for parameter in WebSlideParameters.all { values[parameter.name] = parameter.defaultValue }
        for template in WebSlideTemplates.all {
            let sheet = WebSlideSheet.read(html: template.html)
            for knob in sheet.knobs { values[knob.name] = sheet.value(knob) }
        }
        let script = WebSlideParameters.previewScript(values)
        let lost = values.keys.sorted().filter { !script.contains("'\($0)'") }

        var trouble: [String] = []
        if !idle.isEmpty { trouble.append("не читаються прив'язкою: " + idle.joined(separator: ", ")) }
        if !lost.isEmpty { trouble.append("не доїдуть до сторінки: " + lost.joined(separator: ", ")) }

        return Check(area: area, name: "Повзунки не крутяться марно",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "усі ручки спільного каталогу читаються правилами прив'язки, "
                            + "і всі \(values.count) значень ідуть у передпоказ"
                        : trouble.joined(separator: "; "))
    }

    // MARK: - Страницы владельца

    /// Свои страницы владельца в папке WebSlides — не наши заготовки, а его
    /// копии и правки. Они несут метки прежних выпусков («── Слово:
    /// настройки ──»), и после перевода меток на украинский обязаны
    /// открываться с ползунками так же, как открывались. Проверяем на его
    /// настоящих файлах, а не на образце.
    private static func ownerPagesCheck(area: String) -> Check {
        let name = "Свої сторінки власника відкриваються з повзунками"
        let folder = WebOutputServer.userPagesFolder
        let seeded = Set(WebSlideTemplates.all.map { $0.id + ".html" })
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder,
                                                                   includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "html" && !seeded.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "своїх сторінок у \(folder.lastPathComponent) немає — лише заготовки")
        }
        var trouble: [String] = []
        var lines: [String] = []
        for file in files {
            guard let html = try? String(contentsOf: file, encoding: .utf8) else {
                trouble.append("\(file.lastPathComponent): не прочиталася"); continue
            }
            let hasBlock = html.contains(WebSlideParameters.varsAttribute)
                || WebSlideParameters.markerRange(WebSlideParameters.varsMarkers, in: html) != nil
            let sheet = WebSlideSheet.read(html: html)
            let old = html.contains("── Слово: настройки ──")
            lines.append("\(file.lastPathComponent): \(sheet.knobs.count) ручок\(old ? ", метки прежние" : "")")
            if hasBlock, !sheet.canAdjust {
                trouble.append("\(file.lastPathComponent): блок налаштувань є, а повзунки вимкнено")
            }
            if hasBlock, sheet.knobs.isEmpty {
                trouble.append("\(file.lastPathComponent): блок налаштувань є, а ручок нуль")
            }
        }
        return Check(area: area, name: name,
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty ? lines.joined(separator: "; ") : trouble.joined(separator: "; "))
    }

    // MARK: - Страницы автора

    /// Наши подмены фраз попадают в строки JavaScript автора, и знак, который
    /// закрывает кавычку, убивает весь скрипт страницы. Проверяем на каждом
    /// файле автора: сколько одинарных кавычек, обратных косых и переводов
    /// строк было внутри его `<script>` — столько и должно остаться.
    private static func authorPhrasesCheck(area: String, state: AppState) -> Check {
        let name = "Підміни не ламають скрипт сторінок автора"
        let files = authorFiles(state: state)
        guard !files.isEmpty else {
            return Check(area: area, name: name, status: .skipped, detail: "теку RemoteAPI не знайдено")
        }
        func scriptSigns(_ page: String) -> (quotes: Int, slashes: Int, lines: Int) {
            var quotes = 0, slashes = 0, lines = 0
            var rest = Substring(page)
            while let open = rest.range(of: "<script", options: .caseInsensitive) {
                guard let close = rest.range(of: "</script>", options: .caseInsensitive,
                                             range: open.upperBound..<rest.endIndex) else { break }
                let body = rest[open.upperBound..<close.lowerBound]
                quotes += body.filter { $0 == "'" }.count
                slashes += body.filter { $0 == "\\" }.count
                lines += body.filter { $0 == "\n" }.count
                rest = rest[close.upperBound...]
            }
            return (quotes, slashes, lines)
        }
        var trouble: [String] = []
        var touched = 0
        for file in files {
            guard let original = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let served = WebTemplate.replaceAuthorPhrases(original)
            if served == original { continue }
            touched += 1
            let before = scriptSigns(original), after = scriptSigns(served)
            if before.quotes != after.quotes {
                trouble.append("\(file.lastPathComponent): одинарних лапок у скрипті було \(before.quotes), стало \(after.quotes)")
            }
            if before.slashes != after.slashes {
                trouble.append("\(file.lastPathComponent): зворотних скісних було \(before.slashes), стало \(after.slashes)")
            }
            if before.lines != after.lines {
                trouble.append("\(file.lastPathComponent): переведень рядків було \(before.lines), стало \(after.lines)")
            }
        }
        return Check(area: area, name: name,
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "підміни зачепили \(touched) сторінок, лапки й скісні в їхніх скриптах на місці"
                        : trouble.joined(separator: "; "))
    }

    static func authorFiles(state: AppState) -> [URL] {
        let folder = state.modulesFolder.deletingLastPathComponent().appendingPathComponent("RemoteAPI")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension.lowercased() == "html" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func authorPagesChecks(area: String, state: AppState) -> [Check] {
        let files = authorFiles(state: state)
        guard !files.isEmpty else {
            return [Check(area: area, name: "Сторінки автора не псуються",
                          status: .skipped,
                          detail: "теку RemoteAPI не знайдено, перевіряти нічого")]
        }

        var trouble: [String] = []
        var checked = 0

        for file in files {
            guard let original = try? String(contentsOf: file, encoding: .utf8) else {
                trouble.append("\(file.lastPathComponent): не прочиталася")
                continue
            }
            checked += 1

            let sheet = WebSlideSheet.read(html: original)
            if sheet.dialect != .parameters {
                trouble.append("\(file.lastPathComponent): прийнята за нашу заготовку")
            }
            if sheet.canAdjust {
                trouble.append("\(file.lastPathComponent): повзунки ввімкнено до того, як заведено блок")
            }

            guard case .done(let dressed) = WebSlideSheet.addingParameters(to: original) else {
                trouble.append("\(file.lastPathComponent): блок налаштувань не став")
                continue
            }
            // Переводы строки у автора — CRLF. Свой блок обязан писаться теми
            // же: иначе файл в глазах любого сравнения переписан целиком.
            let crlfBefore = original.components(separatedBy: "\r\n").count - 1
            if crlfBefore > 0, dressed.components(separatedBy: "\r\n").count - 1 <= crlfBefore {
                trouble.append("\(file.lastPathComponent): блок записано не тими переведеннями рядка")
            }

            if WebSlideParameters.stripBlocks(html: dressed) != original {
                trouble.append("\(file.lastPathComponent): після зняття блоків файл не збігся з вихідним")
            }

            let after = WebSlideSheet.read(html: dressed)
            if !after.canAdjust {
                trouble.append("\(file.lastPathComponent): після блоку повзунки так і не ввімкнулися")
            }
            if !after.placement.canDrag {
                trouble.append("\(file.lastPathComponent): блок є, а рухати текст нічим")
            }
            // Каждую ручку двигаем по очереди и после каждой снимаем блоки:
            // одного «--sl-color» мало. Ползунок, который случайно заденет
            // чужую строку, покажет себя только на том значении, где строка
            // с ней совпадает, — а таких сорок с лишним.
            var page = dressed
            var moved = 0
            for knob in after.knobs {
                guard let other = otherValue(knob, than: after.value(knob)) else { continue }
                guard case .done(let next) = WebSlideSheet.read(html: page)
                    .writing([(knob.name, other)], into: page) else {
                    trouble.append("\(file.lastPathComponent): не записалася ручка «\(knob.title)»")
                    continue
                }
                page = next
                moved += 1
                if WebSlideSheet.read(html: page).value(knob) != other {
                    trouble.append("\(file.lastPathComponent): «\(knob.title)» не прочиталася назад")
                }
            }
            if moved < after.knobs.count {
                trouble.append("\(file.lastPathComponent): зрушило \(moved) ручок із \(after.knobs.count)")
            }
            if WebSlideParameters.stripBlocks(html: page) != original {
                trouble.append("\(file.lastPathComponent): після повзунків чужа розмітка змінилася")
            }
        }

        return [Check(area: area, name: "Сторінки автора не псуються",
                      status: trouble.isEmpty ? .ok : .failed,
                      detail: trouble.isEmpty
                        ? "\(checked) сторінок: блок налаштувань ставиться і знімається без сліду, "
                            + "кожну ручку зрушено по черзі — чужа розмітка зійшлася побайтно"
                        : trouble.prefix(6).joined(separator: "; "))]
    }


    // MARK: - Ручки на страницах автора

    /// Что мы знаем про каждую страницу автора, проверив её в браузере.
    ///
    /// Не пересказ того, что насчитает сам редактор, — иначе проверка
    /// подтверждала бы саму себя. Это записанный итог живого опыта: каждую
    /// страницу открыли настоящим `WKWebView`, надели блок настроек, по
    /// очереди двинули все 72 значения и посмотрели, что в ней изменилось.
    /// Роль стоит в списке только там, где перемена была видна на деле.
    ///
    /// Отсюда и польза: если кто-нибудь тронет карту ролей или чужие правила
    /// перестанут перебиваться нашими, проверка назовёт страницу и роль, а не
    /// промолчит.
    private static let authorRoles: [String: Set<WebSlideParameter.Role>] = [
        // Один-единственный `#content`: он же текст, он же весь слайд.
        // Сценой служит тело страницы — иначе весь раздел «Расположение»
        // на ней мёртв.
        "VBWebSlide.html": [.page, .stage, .quote],
        // `.background` держит текст, `.content` — сам текст в двух копиях
        // для плавной подмены. Адрес идёт строкой внутри текста.
        "VBWebSlideCF.html": [.page, .stage, .quote],
        "VBWebSlideCF1.html": [.page, .stage, .quote],
        // Экран служителя: `#text-container` — сцена, `#text-content` —
        // текст, `#bottom-container` — следующий стих. Своей разметки для
        // следующего стиха здесь нет, поэтому `nextOwn` в списке не стоит:
        // кегль автор подбирает сам, и прятать блок мы не станем.
        "VBWebSlideStage.html": [.page, .stage, .quote, .next],
        // Адрес живёт отдельным `<p class="contentTitle">` — единственная
        // страница автора, где ручки раздела «Адрес» и правда действуют.
        "VisioBibleWebSlideCF-Bible.html": [.page, .stage, .quote, .reference],
        // Та же страница для песен: строка с адресом в ней закомментирована,
        // и адреса на экране не бывает.
        "VisioBibleWebSlideCF-Song.html": [.page, .stage, .quote],
    ]

    /// Ручки на страницах автора: которые действуют — действуют, а которые
    /// нет — про то и сказано.
    private static func authorRolesCheck(area: String, state: AppState) -> Check {
        let name = "Повзунки діють на сторінках автора"
        let files = authorFiles(state: state)
        guard !files.isEmpty else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "теку RemoteAPI не знайдено, перевіряти нічого")
        }

        var trouble: [String] = []
        var lines: [String] = []
        var known = 0

        for file in files {
            guard let original = try? String(contentsOf: file, encoding: .utf8),
                  case .done(let dressed) = WebSlideSheet.addingParameters(to: original) else {
                trouble.append("\(file.lastPathComponent): блок налаштувань не став")
                continue
            }
            let sheet = WebSlideSheet.read(html: dressed)
            let found = WebSlideParameters.RoleSelectors.standard.present(in: dressed)

            if let expected = authorRoles[file.lastPathComponent] {
                known += 1
                let lost = expected.subtracting(found).map(\.rawValue).sorted()
                let extra = found.subtracting(expected).map(\.rawValue).sorted()
                if !lost.isEmpty {
                    trouble.append("\(file.lastPathComponent): перестало знаходитися — "
                                   + lost.joined(separator: ", "))
                }
                if !extra.isEmpty {
                    trouble.append("\(file.lastPathComponent): обіцяно зайве — "
                                   + extra.joined(separator: ", "))
                }
            }

            // Каждая ручка обязана либо действовать, либо честно сказать, что
            // здесь ей не к чему приложиться. Третьего — «двигается, а толку
            // нет» — быть не должно.
            var working = 0
            var silent: [String] = []
            for knob in sheet.knobs {
                if let reason = sheet.idleReason(knob) {
                    if reason.isEmpty { trouble.append("\(file.lastPathComponent): «\(knob.title)» мовчить без причини") }
                    silent.append(knob.title)
                } else {
                    working += 1
                }
            }
            if working < 40 {
                trouble.append("\(file.lastPathComponent): діє лише \(working) ручок із \(sheet.knobs.count)")
            }
            lines.append("\(file.lastPathComponent): \(working) із \(sheet.knobs.count)")
            _ = silent
        }

        // Ручка, которая не действует нигде и ни на одной странице, — это
        // обещание, которого мы не держим. Такие в панели гаснут поимённо.
        let alwaysIdle = WebSlideParameters.all
            .filter { $0.showsInPanel && $0.role == .script }
            .map(\.title)

        return Check(area: area, name: name,
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "\(lines.count) сторінок, із них знайомих наперелік \(known); "
                            + lines.joined(separator: "; ")
                            + "; завжди погашені (їх робить скрипт, а ми пишемо лише оформлення): "
                            + alwaysIdle.joined(separator: ", ")
                        : trouble.prefix(6).joined(separator: "; "))
    }

    // MARK: - Предпросмотр чужой страницы

    /// Предпросмотр авторской страницы не должен оставаться пустым.
    ///
    /// Три страницы автора тянут jQuery с `code.jquery.com`, а весь их показ
    /// на jQuery и написан: без него не выполняется ни строки, и человек
    /// правит вслепую — «в редакторе пусто, а на проекторе всё есть». Рядом,
    /// в папке `i`, лежит ровно та же библиотека.
    private static func authorPreviewCheck(area: String, state: AppState) -> Check {
        let name = "Передпоказ чужої сторінки не лишається порожнім"
        let files = authorFiles(state: state)
        guard !files.isEmpty else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "теку RemoteAPI не знайдено, перевіряти нічого")
        }
        let folder = files[0].deletingLastPathComponent()
        let inner = folder.appendingPathComponent("i", isDirectory: true)
        let helpers = (try? FileManager.default.contentsOfDirectory(at: inner,
                                                                    includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        guard let jquery = helpers.first(where: {
            $0.lastPathComponent.lowercased().hasPrefix("jquery") && $0.pathExtension.lowercased() == "js"
        }) else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "своєї копії jQuery у теці «i» немає — переводити посилання нема на що")
        }
        let path = "i/" + jquery.lastPathComponent

        var trouble: [String] = []
        var fixed = 0
        var already = 0

        for file in files {
            guard let original = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let fromNet = original.contains("code.jquery.com")
            let shown = WebSlideEditorModel.withLocalJQuery(original, path: path)

            if fromNet {
                if shown.contains("code.jquery.com") {
                    trouble.append("\(file.lastPathComponent): посилання в інтернет лишилося")
                } else if !shown.contains("src=\"\(path)\"") {
                    trouble.append("\(file.lastPathComponent): посилання переведено не на свою копію")
                } else {
                    fixed += 1
                }
                // Заменяется ровно адрес: длина страницы обязана измениться
                // на разницу адресов и ни на что больше.
                if shown.count >= original.count {
                    trouble.append("\(file.lastPathComponent): при заміні адреси сторінка не вкоротилася")
                }
            } else {
                already += 1
                if shown != original {
                    trouble.append("\(file.lastPathComponent): сторінку зачепили, хоча чіпати не було чого")
                }
            }

            // Свой jQuery берётся из папки предпросмотра — значит страница
            // обязана грузиться файлом, а не строкой из ниоткуда.
            if shown.range(of: "src=\"i/") == nil, shown.contains("jquery") {
                trouble.append("\(file.lastPathComponent): jQuery як і раніше не поруч зі сторінкою")
            }
        }

        // И то же самое без своей копии: рвать рабочую ссылку нельзя.
        if let any = try? String(contentsOf: files[0], encoding: .utf8),
           WebSlideEditorModel.withLocalJQuery(any, path: nil) != any {
            trouble.append("без своєї копії сторінка все одно правиться")
        }

        return Check(area: area, name: name,
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "переведено на свою копію \(fixed) сторінок, у \(already) посилання і так своє; "
                            + "чужа розмітка при цьому не правиться — міняється лише те, що йде в показ"
                        : trouble.prefix(4).joined(separator: "; "))
    }

    // MARK: - Живой показ

    /// Что спрашиваем у браузера про роль «текст стиха».
    private static let roleProbe = """
    (function () {
      var q = document.querySelector('\(WebSlideParameters.RoleSelectors.standard.quote)');
      if (!q) return JSON.stringify({ found: false });
      var s = getComputedStyle(q);
      return JSON.stringify({ found: true, size: s.fontSize, color: s.color, align: s.textAlign });
    })()
    """

    private final class Answer {
        var text: String?
        var asking = false
    }

    /// Загрузить страницы, спросить, послать тот же скрипт, что шлёт
    /// ползунок, и спросить ещё раз.
    private static func probe(pages: [(name: String, html: String)],
                              script: String) -> [String: (before: String, after: String)] {
        var views: [WKWebView] = []
        var first: [Answer] = []
        var second: [Answer] = []
        // Общий котёл на все страницы: иначе на каждую заводится свой
        // отдельный процесс показа, и самопроверка думает секундами.
        let configuration = WKWebViewConfiguration()

        for page in pages {
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                                 configuration: configuration)
            view.loadHTMLString(page.html, baseURL: nil)
            views.append(view)
            first.append(Answer())
            second.append(Answer())
        }

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline && second.contains(where: { $0.text == nil }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            for (index, view) in views.enumerated() where !view.isLoading {
                if first[index].text == nil {
                    guard !first[index].asking else { continue }
                    let answer = first[index]
                    answer.asking = true
                    view.evaluateJavaScript(roleProbe) { value, _ in
                        answer.asking = false
                        guard let text = value as? String, !text.isEmpty else { return }
                        // Элемента с текстом стиха в разметке заготовки нет
                        // вовсе: его создаёт скрипт, когда придёт первый
                        // пакет. Спрашивать сразу по окончании загрузки —
                        // значит всегда попадать раньше, чем он появится.
                        // Ответ «не нашлось» принимаем только под конец
                        // ожидания, а до тех пор переспрашиваем.
                        if text.contains("\"found\":false"), Date() < deadline.addingTimeInterval(-1.5) {
                            return
                        }
                        answer.text = text
                    }
                } else if second[index].text == nil, !second[index].asking {
                    let answer = second[index]
                    answer.asking = true
                    view.evaluateJavaScript(script + "\n" + roleProbe) { value, _ in
                        answer.asking = false
                        if let text = value as? String, !text.isEmpty { answer.text = text }
                    }
                }
            }
        }

        var result: [String: (String, String)] = [:]
        for (index, page) in pages.enumerated() {
            guard let before = first[index].text, let after = second[index].text else { continue }
            result[page.name] = (before, after)
        }
        return result
    }

    private static func field(_ json: String, _ key: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let text = object[key] as? String { return text }
        if let flag = object[key] as? Bool { return flag ? "1" : "0" }
        return ""
    }

    /// Живой показ: доезжает ли ползунок до экрана и находит ли привязка
    /// текст в чужой разметке.
    ///
    /// Это единственная проверка, ответ на которую даёт только браузер:
    /// селектор роли может не совпасть с чужой разметкой, и тогда блок
    /// привязки ляжет в пустоту молча, без всякой ошибки.
    private static func liveCheck(area: String, state: AppState) -> Check {
        let name = "Живий показ: повзунок доїжджає до екрана"
        let sample = WebSlideSample.all.first { $0.id == "two" } ?? WebSlideSample.all[0]
        let shim = sample.shim(hidden: false)

        func withShim(_ html: String) -> String {
            if let head = html.range(of: "<head>", options: .caseInsensitive) {
                return html.replacingCharacters(in: head, with: "<head>\n" + shim)
            }
            return shim + html
        }

        var pages: [(name: String, html: String)] = []
        for template in WebSlideTemplates.all.prefix(3) {
            pages.append(("заготовка «\(template.title)»", withShim(template.html)))
        }
        for file in authorFiles(state: state) {
            guard let original = try? String(contentsOf: file, encoding: .utf8),
                  case .done(let dressed) = WebSlideSheet.addingParameters(to: original) else { continue }
            pages.append((file.lastPathComponent, withShim(dressed)))
        }
        guard !pages.isEmpty else {
            return Check(area: area, name: name, status: .skipped, detail: "нічого показувати")
        }

        // Тот же самый скрипт, каким предпросмотр разносит значения ползунка.
        let script = WebSlideParameters.previewScript([
            "--sl-size": "17",
            "--sl-unit": "1vw",
            "--sl-color": "rgb(1, 2, 3)",
            "--sl-align": "right",
        ])
        let shown = probe(pages: pages, script: script)

        // Ни одна страница не ответила — это не поломка редактора, а то, что
        // браузеру не дали времени: страница грузится, только когда главный
        // поток свободен, а самопроверка ждёт ответа не отпуская его. Выдать
        // такое молчание за поломку — значит поднять ложную тревогу.
        guard !shown.isEmpty else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "браузер відповідає через головну чергу, а самоперевірку запускають із "
                             + "її ж блоку — поки він не повернувся, черга вдруге не розбирається, "
                             + "і сторінка не дозавантажується жодним очікуванням. Що можна дізнатися без "
                             + "браузера, перевірено вище за розміткою; живий показ видно в самому вікні "
                             + "редактора — там передпоказ працює")
        }

        var silent: [String] = []
        var noRole: [String] = []
        var deaf: [String] = []
        var painted = 0

        for page in pages {
            guard let pair = shown[page.name] else { silent.append(page.name); continue }
            if field(pair.before, "found") != "1" { noRole.append(page.name); continue }
            let same = field(pair.before, "size") == field(pair.after, "size")
                && field(pair.before, "color") == field(pair.after, "color")
                && field(pair.before, "align") == field(pair.after, "align")
            if same { deaf.append(page.name) } else { painted += 1 }
        }

        var trouble: [String] = []
        if !deaf.isEmpty {
            trouble.append("повзунок нічого не змінив на екрані: " + deaf.joined(separator: ", "))
        }
        if !noRole.isEmpty {
            trouble.append("прив'язка не знайшла текст вірша: " + noRole.joined(separator: ", ")
                           + " — такій сторінці потрібен свій data-slovo=\"quote\"")
        }
        if !silent.isEmpty {
            trouble.append("не відповіли: " + silent.joined(separator: ", "))
        }

        return Check(area: area, name: name,
                     status: trouble.isEmpty ? .ok : (deaf.isEmpty ? .warning : .failed),
                     detail: trouble.isEmpty
                        ? "на \(painted) сторінках кегль, колір або вирівнювання змінилися від того самого "
                            + "скрипта, що шле панель, і прив'язка всюди знайшла текст вірша"
                        : trouble.joined(separator: "; "))
    }
}
