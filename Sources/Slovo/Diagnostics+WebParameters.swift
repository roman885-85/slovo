import Foundation
import SlovoCore

/// Самопроверка оформления веб-слайда ползунками.
///
/// Проверять тут есть что, и проверять надо по живым файлам. Обещание модели
/// звучит так: запись настроек не меняет в чужой странице ни одного байта,
/// кроме двух наших блоков. Проверить это на глаз нельзя — расхождение в один
/// перевод строки не видно ни в редакторе, ни в браузере, а всплывёт оно
/// тогда, когда владелец обнаружит, что программа переписала ему страницы
/// автора. Поэтому все проверки ниже гоняют настоящие файлы из `RemoteAPI`
/// и сверяют результат побайтно.
///
/// Файлы автора здесь только читаются. Запись идёт в строку в памяти.
extension Diagnostics {

    static func webParametersSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        checks.append(webCatalogue())
        checks.append(webImplications())
        checks.append(webBindingCSS())
        checks.append(contentsOf: webOurTemplates())
        checks.append(contentsOf: webAuthorPages(state: state))
        checks.append(webUnknownKept())
        checks.append(webTolerantParse())
        checks.append(webDamagedBlock())
        checks.append(webUnsafeValue())
        checks.append(webHandEdits())
        checks.append(webLivePreview())
        return checks
    }

    // MARK: - Каталог

    private static func webCatalogue() -> Check {
        let all = WebSlideParameters.all
        var trouble: [String] = []

        var seen = Set<String>()
        for parameter in all {
            if !seen.insert(parameter.name).inserted { trouble.append("ім'я повторюється: \(parameter.name)") }
            if !parameter.name.hasPrefix("--sl-") { trouble.append("не наше ім'я: \(parameter.name)") }
            if !WebSlideParameters.isVariableName(parameter.name) { trouble.append("негодяще ім'я: \(parameter.name)") }
            if parameter.title.isEmpty { trouble.append("немає підпису в \(parameter.name)") }
            if !parameter.isValid(parameter.defaultValue) {
                trouble.append("значення за умовчанням не розбирається: \(parameter.name) = \(parameter.defaultValue)")
            }
        }

        // Числовое значение обязано пережить дорогу «текст → число → текст»:
        // на ней держится каждый ползунок.
        for parameter in all {
            guard let number = parameter.number(from: parameter.defaultValue) else { continue }
            let back = parameter.text(from: number)
            if back != parameter.defaultValue {
                trouble.append("\(parameter.name): \(parameter.defaultValue) → \(number) → \(back)")
            }
        }

        let shown = all.filter(\.showsInPanel).count
        return Check(area: "Веб-оформлення", name: "Каталог параметрів",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "параметрів \(all.count), у панелі \(shown), розділів \(WebSlideParameter.Group.allCases.count); "
                          + "усі значення за умовчанням розбираються і пишуться назад тими самими літерами"
                        : trouble.prefix(4).joined(separator: "; "))
    }

    /// Спутники: выбор «адрес справа внизу» дописывает две переменные, и обе
    /// обязаны существовать и принимать это значение.
    private static func webImplications() -> Check {
        var trouble: [String] = []
        var covered = 0
        for parameter in WebSlideParameters.all {
            guard case .choice(let options) = parameter.kind else { continue }
            for option in options {
                if !parameter.isValid(option.value) {
                    trouble.append("\(parameter.name): пункт «\(option.title)» сам собі негодящий")
                }
                for (name, value) in option.implies {
                    covered += 1
                    guard let companion = WebSlideParameters.parameter(named: name) else {
                        trouble.append("\(parameter.name) → \(name): такої змінної немає")
                        continue
                    }
                    if !companion.isValid(value) {
                        trouble.append("\(parameter.name) → \(name) = \(value): значення негодяще")
                    }
                }
            }
        }

        // И вживую: выбрать пункт и убедиться, что спутники доехали.
        var settings = WebSlideParameters.defaults
        if let place = WebSlideParameters.parameter(named: "--sl-ref-place") {
            settings.choose(place, value: "bottom-right")
            if settings["--sl-ref-self"] != "flex-end" || settings["--sl-ref-order"] != "2" {
                trouble.append("вибір «праворуч унизу» не виставив супутників")
            }
        }

        return Check(area: "Веб-оформлення", name: "Змінні-супутники",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "зв'язок \(covered), усі ведуть до наявних змінних і годящими значеннями"
                        : trouble.prefix(4).joined(separator: "; "))
    }

    /// Каждый параметр, который обещан как «чистый CSS», обязан быть в блоке
    /// привязки. Иначе ползунок будет двигаться, а на экране ничего.
    private static func webBindingCSS() -> Check {
        let css = WebSlideParameters.bindingCSS()
        var missing: [String] = []
        var bound = 0
        for parameter in WebSlideParameters.all where parameter.isBoundToCSS {
            // Переменная может стоять и с запасным значением —
            // `var(--sl-size, 6)`: связка обязана работать и в странице, где
            // записана одна ручка из шестидесяти.
            if css.contains("var(\(parameter.name))") || css.contains("var(\(parameter.name),") {
                bound += 1
            } else {
                missing.append(parameter.name)
            }
        }

        // Псевдонимы старых имён: без них шесть наших заготовок перестанут
        // слушаться ползунков, хотя ни одной ошибки видно не будет.
        let aliases = ["--text:", "--accent:", "--size:", "--background:", "--dim:"]
        let lostAliases = aliases.filter { !css.contains($0) }

        // Тело блока значений обязано разбираться обратно целиком.
        let root = WebSlideParameters.rootCSS(WebSlideParameters.defaults)
        let lines = root.split(whereSeparator: \.isNewline).filter { $0.contains("--sl-") }.count

        var trouble = missing.map { "немає прив'язки: \($0)" }
        trouble += lostAliases.map { "загублено псевдонім \($0)" }
        if lines != WebSlideParameters.all.count {
            trouble.append("у :root \(lines) рядків замість \(WebSlideParameters.all.count)")
        }

        return Check(area: "Веб-оформлення", name: "Готовий CSS",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "прив'язано \(bound) змінних, псевдоніми старих імен на місці, "
                          + "у блоці значень \(lines) рядків"
                        : trouble.prefix(4).joined(separator: "; "))
    }

    // MARK: - Круговой прогон

    /// Что должно сойтись после «разобрать → записать → разобрать».
    ///
    /// `ownBlocks` — правда для наших заготовок: у них помеченный блок
    /// настроек напечатан сразу, ещё до всякой записи. Сравнивать их с
    /// исходником побайтно после снятия блоков нельзя — снятый блок и есть
    /// разница. Проверяем то, что и обещано: кроме блоков не изменилось
    /// ничего, а значит две страницы без блоков обязаны совпасть.
    private static func webRoundTrip(_ html: String, ownBlocks: Bool = false) -> String? {
        let before = WebSlideParameters.parse(html: html)
        guard before.hasHead else { return "у сторінці немає </head>" }

        let wanted = before.settings.applyingDefaults()
        guard case .written(let once) = WebSlideParameters.write(html: html, settings: wanted) else {
            return "запис відхилено"
        }

        let after = WebSlideParameters.parse(html: once)
        guard case .present = after.block else { return "після запису блок не читається" }
        if after.settings != wanted { return "значення розійшлися при зворотному розборі" }

        guard case .written(let twice) = WebSlideParameters.write(html: once, settings: after.settings) else {
            return "повторний запис відхилено"
        }
        if twice != once { return "другий запис змінив файл" }

        if WebSlideParameters.newline(of: once) != WebSlideParameters.newline(of: html) {
            return "переведення рядка у файлі змінилися"
        }

        // Главное: снять наши блоки и сверить с исходником побайтно.
        let stripped = WebSlideParameters.stripBlocks(html: once)
        let origin = ownBlocks ? WebSlideParameters.stripBlocks(html: html) : html
        if Data(stripped.utf8) != Data(origin.utf8) {
            return "розмітка поза блоками змінилася (\(Data(stripped.utf8).count) байт проти \(Data(origin.utf8).count))"
        }
        return nil
    }

    private static func webOurTemplates() -> [Check] {
        var trouble: [String] = []
        for template in WebSlideTemplates.all {
            if let reason = webRoundTrip(template.html, ownBlocks: true) {
                trouble.append("\(template.id): \(reason)")
            }
        }
        return [Check(area: "Веб-оформлення", name: "Круговий прогін, наші заготовки",
                      status: trouble.isEmpty ? .ok : .failed,
                      detail: trouble.isEmpty
                        ? "заготовок \(WebSlideTemplates.all.count), у кожної блок завівся, "
                          + "прочитався назад і знявся без сліду"
                        : trouble.joined(separator: "; "))]
    }

    private static func webAuthorPages(state: AppState) -> [Check] {
        let folder = state.modulesFolder.deletingLastPathComponent()
            .appendingPathComponent("RemoteAPI")
        let files = webPages(in: folder)
        guard !files.isEmpty else {
            return [Check(area: "Веб-оформлення", name: "Круговий прогін, сторінки автора",
                          status: .skipped,
                          detail: "теку \(folder.path) не знайдено — перевіряти нічого")]
        }

        var trouble: [String] = []
        var crlf = 0
        var withBlock = 0
        var unreadable = 0
        for file in files {
            guard let raw = try? Data(contentsOf: file),
                  let html = String(data: raw, encoding: .utf8) else {
                unreadable += 1
                continue
            }
            // Прогон идёт по строке в памяти; файл автора не открывается на
            // запись ни на мгновение.
            if WebSlideParameters.newline(of: html) == "\r\n" { crlf += 1 }
            if case .present = WebSlideParameters.parse(html: html).block { withBlock += 1 }
            if let reason = webRoundTrip(html) {
                trouble.append("\(file.lastPathComponent): \(reason)")
            }
        }

        let byteCheck = Check(area: "Веб-оформлення", name: "Круговий прогін, сторінки автора",
                              status: trouble.isEmpty ? .ok : .failed,
                              detail: trouble.isEmpty
                                ? "сторінок \(files.count), із них із переведеннями CRLF \(crlf); "
                                  + "після запису і зняття блоку кожна збіглася з вихідною побайтно"
                                : trouble.joined(separator: "; "))

        let stateCheck = Check(area: "Веб-оформлення", name: "Налаштування в сторінках автора",
                               status: unreadable == 0 ? .ok : .warning,
                               detail: "своїх блоків у них \(withBlock) — "
                                   + "їх і не має бути, сторінок автора ми не правимо; "
                                   + (unreadable == 0 ? "усі \(files.count) прочиталися"
                                                      : "не прочиталося \(unreadable)"))
        return [byteCheck, stateCheck]
    }

    private static func webPages(in folder: URL) -> [URL] {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: folder,
                                              includingPropertiesForKeys: nil,
                                              options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "html" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    // MARK: - Терпимость разбора

    /// Настройка от более новой версии обязана вернуться в файл дословно.
    private static func webUnknownKept() -> Check {
        let stranger = "--sl-glow-2026"
        let value = "0.7"
        guard let page = WebSlideTemplates.all.first,
              case .written(let first) = WebSlideParameters.write(html: page.html,
                                                                  settings: WebSlideParameters.defaults) else {
            return Check(area: "Веб-оформлення", name: "Налаштування від іншої версії",
                         status: .failed, detail: "не вдалося завести блок")
        }
        // Дописываем чужую строку прямо В БЛОК, как это сделала бы новая
        // версия. Искать якорь надо ПОСЛЕ метки блока: в самой заготовке
        // «--sl-size:» встречается и раньше, и проверка клала чужую строку
        // вне блока — а потом сама же удивлялась, что та не сохранилась.
        var doctored = first
        guard let blockStart = doctored.range(of: WebSlideParameters.varsMarker),
              let anchor = doctored.range(of: "--sl-size:", range: blockStart.upperBound..<doctored.endIndex) else {
            return Check(area: "Веб-оформлення", name: "Налаштування від іншої версії",
                         status: .failed, detail: "у блоці немає рядка --sl-size")
        }
        doctored.replaceSubrange(anchor, with: "\(stranger): \(value);\n  --sl-size:")

        let parsed = WebSlideParameters.parse(html: doctored)
        let kept = parsed.settings[stranger]
        guard case .written(let rewritten) = WebSlideParameters.write(html: doctored,
                                                                      settings: parsed.settings) else {
            return Check(area: "Веб-оформлення", name: "Налаштування від іншої версії",
                         status: .failed, detail: "запис відхилено")
        }
        let again = WebSlideParameters.parse(html: rewritten)
        let survived = again.settings[stranger] == value
        let listed = again.settings.unknownNames.contains(stranger)

        return Check(area: "Веб-оформлення", name: "Налаштування від іншої версії",
                     status: survived && listed ? .ok : .failed,
                     detail: survived && listed
                        ? "чужий рядок «\(stranger): \(value);» пережив запис і показаний окремо"
                        : "прочитано \(kept ?? "ничего"), після запису \(again.settings[stranger] ?? "потеряно")")
    }

    /// Разбор обязан терпеть всё: лишние пробелы, комментарии, пустой блок.
    private static func webTolerantParse() -> Check {
        let page = """
        <html><head>
        <style data-slovo="vars">
        /* \(WebSlideParameters.varsMarker) v1 ── */
        :root {
            --sl-size   :   7.5 ;
          /* строка ниже нарочно без точки с запятой — её надо пропустить */
          --sl-color #ff0000
          --sl-align: justify;
          что-то совсем постороннее
          --sl-плохая-строка: значение; лишнее
        }
        /* \(WebSlideParameters.varsEndMarker) */
        </style>
        </head><body></body></html>
        """
        let parsed = WebSlideParameters.parse(html: page)
        var trouble: [String] = []
        if parsed.settings["--sl-size"] != "7.5" { trouble.append("не зрозумів «--sl-size   :   7.5 ;»") }
        if parsed.settings["--sl-align"] != "justify" { trouble.append("не зрозумів --sl-align") }
        if parsed.settings["--sl-color"] != nil { trouble.append("прийняв рядок без двокрапки") }
        if parsed.settings["--sl-плохая-строка"] != nil { trouble.append("прийняв рядок зі сміттям після крапки з комою") }

        // Пустой блок и полное отсутствие блока — не ошибка, а два состояния.
        let empty = WebSlideParameters.parse(html: "<html><head><style data-slovo=\"vars\"></style></head></html>")
        if case .present = empty.block {} else { trouble.append("порожній блок не визнано") }
        if !empty.settings.isEmpty { trouble.append("у порожньому блоці щось знайшлося") }

        let none = WebSlideParameters.parse(html: "<html><head></head><body>привет</body></html>")
        if case .missing = none.block {} else { trouble.append("відсутність блоку не визнано") }
        if !none.isAdjustable { trouble.append("сторінку без блоку оголосили непридатною") }

        let headless = WebSlideParameters.parse(html: "просто текст, не страница")
        if headless.isAdjustable { trouble.append("уривок без </head> визнали придатним") }

        return Check(area: "Веб-оформлення", name: "Терпимість розбору",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "зайві пробіли, коментарі й сміття пропущено; порожній блок, "
                          + "відсутність блоку й уривок сторінки розрізняються"
                        : trouble.joined(separator: "; "))
    }

    /// Повреждённый блок: запись запрещена, но «переписать заново» работает.
    private static func webDamagedBlock() -> Check {
        let broken = """
        <html><head>
        <style data-slovo="vars">
        /* \(WebSlideParameters.varsMarker) v1 ── */
        :root { --sl-size: 9; }
        </head><body></body></html>
        """
        let parsed = WebSlideParameters.parse(html: broken)
        var trouble: [String] = []
        guard case .damaged = parsed.block else {
            return Check(area: "Веб-оформлення", name: "Пошкоджений блок",
                         status: .failed, detail: "розірваний блок визнали цілим")
        }
        if parsed.isAdjustable { trouble.append("повзунки не вимкнулися") }
        if case .refused = WebSlideParameters.write(html: broken, settings: WebSlideParameters.defaults) {} else {
            trouble.append("запис у пошкоджений блок не відхилено")
        }
        guard case .written(let fixed) = WebSlideParameters.repair(html: broken,
                                                                   settings: WebSlideParameters.defaults) else {
            trouble.append("«переписати заново» не спрацювало")
            return Check(area: "Веб-оформлення", name: "Пошкоджений блок",
                         status: .failed, detail: trouble.joined(separator: "; "))
        }
        if case .present = WebSlideParameters.parse(html: fixed).block {} else {
            trouble.append("після переписування блок досі не читається")
        }
        if !fixed.contains("</body></html>") { trouble.append("переписування з'їло кінець сторінки") }

        return Check(area: "Веб-оформлення", name: "Пошкоджений блок",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "розрив помічено, запис відхилено, «переписати заново» повернуло блок у стрій"
                        : trouble.joined(separator: "; "))
    }

    /// Значение, которое оборвало бы правило, до файла доходить не должно.
    private static func webUnsafeValue() -> Check {
        let attacks = [
            "url(\"a\"); } body { display: none",
            "red</style><script>alert(1)</script>",
            "red /* хвост",
            "",
        ]
        var passed = 0
        for attack in attacks {
            var settings = WebSlideParameters.defaults
            settings.set("--sl-color", attack)
            if case .refused = WebSlideParameters.write(html: WebSlideTemplates.all[0].html,
                                                        settings: settings) { passed += 1 }
        }
        // А обычный адрес с двоеточием и вопросительным знаком — пройти обязан.
        let fine = WebSlideParameters.isWritable("url(\"https://example.org/фон.jpg?v=2\")")

        return Check(area: "Веб-оформлення", name: "Небезпечні значення",
                     status: passed == attacks.count && fine ? .ok : .failed,
                     detail: passed == attacks.count && fine
                        ? "відхилено \(passed) із \(attacks.count) негодящих значень, "
                          + "звичайне посилання з https:// пропущено"
                        : "відхилено лише \(passed) із \(attacks.count); посилання пропущено: \(fine)")
    }

    /// Правка `--sl-*` руками вне блока: заметить и сказать, а не переносить.
    private static func webHandEdits() -> Check {
        guard case .written(let page) = WebSlideParameters.write(html: WebSlideTemplates.all[0].html,
                                                                 settings: WebSlideParameters.defaults) else {
            return Check(area: "Веб-оформлення", name: "Правка поза блоком",
                         status: .failed, detail: "не вдалося завести блок")
        }
        let doctored = page.replacingOccurrences(of: "</head>",
                                                 with: "<style>:root{--sl-size: 12;}</style>\n</head>")
        let parsed = WebSlideParameters.parse(html: doctored)
        let noticed = parsed.outsideNames.contains("--sl-size")
        let untouched = parsed.settings["--sl-size"] == "6"

        // На чистой странице ложных срабатываний быть не должно: блок
        // привязки полон `var(--sl-…)`, и они не правка.
        let clean = WebSlideParameters.parse(html: page).outsideNames.isEmpty

        // И то же самое по всем десяти заготовкам, как они напечатаны.
        //
        // Это и была та ложная тревога, ради которой сводили формат: пока
        // заготовки печатали свой безымянный `:root`, разбор не узнавал в нём
        // блока и записывал все три-четыре десятка их собственных значений в
        // «правлено руками». Заготовка, у которой хоть одно объявление
        // `--sl-…` вышло за пределы блока, сюда и попадёт.
        var strayed: [String] = []
        for template in WebSlideTemplates.all {
            let outside = WebSlideParameters.parse(html: template.html).outsideNames
            if !outside.isEmpty {
                strayed.append("\(template.id): " + outside.joined(separator: ", "))
            }
        }

        let good = noticed && untouched && clean && strayed.isEmpty
        return Check(area: "Веб-оформлення", name: "Правка поза блоком",
                     status: good ? .ok : .failed,
                     detail: good
                        ? "чуже оголошення --sl-size помічено й названо, саме не зачеплено; "
                          + "ні на незайманій сторінці, ні в десяти заготовок хибних знахідок немає"
                        : (strayed.isEmpty
                           ? "помічено: \(noticed), блок не зачеплено: \(untouched), без хибних: \(clean)"
                           : "у заготовок оголошено поза блоком — " + strayed.joined(separator: "; ")))
    }

    /// Живой предпросмотр: в страницу уходит только то, что изменилось.
    private static func webLivePreview() -> Check {
        let before = WebSlideParameters.defaults
        var after = before
        after.set("--sl-size", "9.4")
        after.set("--sl-plate-opacity", "0.42")

        let changes = after.changes(since: before)
        let script = WebSlideParameters.previewScript(changes)

        var trouble: [String] = []
        if changes.count != 2 { trouble.append("змін нараховано \(changes.count) замість двох") }
        if !script.contains("s.setProperty('--sl-size','9.4');") { trouble.append("у скрипті немає нового кегля") }
        if script.contains("--sl-color") { trouble.append("у скрипт потрапило незмінене") }

        // Разметка без значений — по ней предпросмотр решает, перезагружаться
        // ли. Двинули ползунок — она обязана остаться прежней.
        guard case .written(let page) = WebSlideParameters.write(html: WebSlideTemplates.all[0].html,
                                                                 settings: before),
              case .written(let moved) = WebSlideParameters.write(html: page, settings: after) else {
            return Check(area: "Веб-оформлення", name: "Живий передпоказ",
                         status: .failed, detail: "не вдалося записати налаштування")
        }
        if WebSlideParameters.structure(html: page) != WebSlideParameters.structure(html: moved) {
            trouble.append("рух повзунка змінив розмітку — передпоказ блиматиме")
        }
        if page == moved { trouble.append("рух повзунка нічого не записав") }

        // Кавычка в имени файла фона не должна оборвать строку скрипта.
        let quoted = WebSlideParameters.previewScript(["--sl-bg-image": "url(\"a'b.jpg\")"])
        if !quoted.contains("\\'") { trouble.append("лапку в значенні не заекрановано") }

        return Check(area: "Веб-оформлення", name: "Живий передпоказ",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                        ? "у сторінку йдуть лише змінені значення, розмітка при цьому та сама — "
                          + "перезавантажувати нічого"
                        : trouble.joined(separator: "; "))
    }
}
