import Foundation
import AppKit
import WebKit
import SlovoCore

/// Самопроверка заготовок веб-слайдов.
///
/// Проверять страницу глазами бесполезно: она выглядит правильно и с
/// оборванным скриптом, и с ползунком, который ничего не двигает. Поэтому
/// здесь два рода проверок.
///
/// Первый — разбор самой строки HTML: есть ли блок настроек, совпадают ли
/// объявленные в нём ручки со списком, который окно покажет человеку, и
/// правда ли каждая ручка где-то читается. Ручка, которой нет в правилах, —
/// это ползунок, который двигается вхолостую, и заметить такое на глаз
/// нельзя.
///
/// Второй — настоящий показ: каждая заготовка грузится в WKWebView с тем же
/// подменённым соединением, что и предпросмотр в редакторе, и после показа
/// у неё спрашивают, что она нарисовала. Текст берётся живой — тот, что
/// сейчас на слайде программы.
///
/// У второго рода есть условие, без которого он превращается в свою
/// противоположность. Браузер живёт отдельным процессом и отвечает только
/// через главную **очередь**; если самопроверку начал блок этой же очереди,
/// очередь занята нами всё время ожидания, и до браузера не доходит ни
/// одного сообщения. Молчание браузера в этом случае не говорит о
/// заготовках ровно ничего, и выдавать его за поломку нельзя: целый день
/// отчёт называл сломанными десять исправных страниц. Поэтому перед
/// ожиданием в очередь кладётся пустяк, и если он не выполнился, проверки
/// показа честно говорят «пропущено» и объясняют, почему.
extension Diagnostics {

    static func webTemplatesSection(state: AppState) -> [Check] {
        let area = "Веб-слайди"
        var checks: [Check] = []

        let templates = WebSlideTemplates.all
        checks.append(countCheck(area: area, templates: templates))
        checks.append(structureCheck(area: area, templates: templates))
        checks.append(settingsCheck(area: area, templates: templates))
        checks.append(namesCheck(area: area, templates: templates))
        checks.append(usageCheck(area: area, templates: templates))
        checks.append(orderCheck(area: area, templates: templates))
        checks.append(rewriteCheck(area: area, templates: templates))
        checks.append(protocolCheck(area: area, templates: templates))
        checks.append(catalogueCheck(area: area, templates: templates))
        checks.append(contentsOf: liveChecks(area: area, templates: templates, state: state))

        return checks
    }

    // MARK: - Разбор страницы

    /// Блок настроек и всё остальное отдельно: «остальное» — это правила и
    /// скрипт, то есть места, где ручка может пригодиться.
    ///
    /// Блок ищется не по словам заготовки, а тем же разбором, каким его
    /// читает и переписывает мастерская. Пока проверка искала свои слова, она
    /// подтверждала лишь то, что заготовка похожа сама на себя; теперь она
    /// подтверждает, что модель параметров узнаёт блок и вычитывает из него
    /// все значения — то самое, что раньше расходилось.
    private static func split(_ html: String) -> (names: [String], rest: String)? {
        let document = WebSlideParameters.parse(html: html)
        guard case .present = document.block, !document.settings.isEmpty else { return nil }
        // `stripBlocks` снимает и блок значений, и блок привязки. Привязку
        // убираем нарочно: она полна `var(--sl-…)` и подтвердила бы «ручка
        // читается» для чего угодно, даже если сама заготовка её не читает.
        return (document.settings.names, WebSlideParameters.stripBlocks(html: html))
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static func countCheck(area: String, templates: [WebSlideTemplates.Template]) -> Check {
        let ids = templates.map { $0.id }
        // Пять прежних имён обязаны сохраниться: у человека уже могут быть
        // страницы, созданные из них, и разговор о них идёт по имени.
        let kept = ["plain", "picture", "two", "lower", "stage"].filter { ids.contains($0) }
        var trouble: [String] = []
        if templates.count != 40 { trouble.append("їх \(templates.count), а має бути сорок") }
        if Set(ids).count != ids.count { trouble.append("імена повторюються") }
        if kept.count != 5 { trouble.append("загублено колишні імена: "
            + ["plain", "picture", "two", "lower", "stage"].filter { !ids.contains($0) }.joined(separator: ", ")) }
        if !ids.contains("contrast") { trouble.append("немає «contrast» — колишньої «big»") }

        return Check(area: area, name: "Заготовок сорок: десять колишніх, десять для Біблії, десять субтитрів, десять для пісень",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? ids.joined(separator: ", ")
                         : trouble.joined(separator: "; "))
    }

    private static func structureCheck(area: String, templates: [WebSlideTemplates.Template]) -> Check {
        var trouble: [String] = []
        for template in templates {
            let html = template.html
            var notes: [String] = []
            if !html.hasPrefix("<!DOCTYPE html>") { notes.append("немає оголошення типу") }
            for tag in ["<html", "</html>", "<head>", "</head>", "<body>", "</body>", "<title>"]
            where occurrences(of: tag, in: html) != 1 {
                notes.append("тег \(tag) трапляється \(occurrences(of: tag, in: html)) разів")
            }
            if occurrences(of: "<div", in: html) != occurrences(of: "</div>", in: html) {
                notes.append("блоки не закрито: \(occurrences(of: "<div", in: html)) відкрито, "
                             + "\(occurrences(of: "</div>", in: html)) закрито")
            }
            // Тегов оформления теперь два, и это новая правда, а не поломка:
            // свой каркас в безымянном <style> и блок значений с меткой
            // `data-slovo="vars"`, который читает и переписывает мастерская.
            // Третьим к ним встаёт блок привязки — его дописывает редактор
            // тем страницам, у которых своих правил нет; у заготовки они
            // есть, поэтому в самом файле его и не печатаем.
            if occurrences(of: "<style>", in: html) != 1 {
                notes.append("каркас оформлення не в одному безіменному <style>")
            }
            if occurrences(of: "<style data-slovo=\"vars\">", in: html) != 1 {
                notes.append("блок значень із міткою vars не рівно один")
            }
            let styles = occurrences(of: "<style", in: html)
            if styles != occurrences(of: "</style>", in: html) || styles != 2 {
                notes.append("тегів оформлення \(styles), а має бути два: каркас і блок значень")
            }
            if occurrences(of: "<script>", in: html) != 1 || occurrences(of: "</script>", in: html) != 1 {
                notes.append("скрипт не в одному блоці")
            }
            if occurrences(of: "{", in: html) != occurrences(of: "}", in: html) {
                notes.append("фігурні дужки не сходяться")
            }
            if !notes.isEmpty { trouble.append("\(template.id): \(notes.joined(separator: ", "))") }
        }

        return Check(area: area, name: "Сторінки зібрано правильно",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "у всіх десяти сходяться теги, блоки й дужки"
                         : trouble.joined(separator: "; "))
    }

    private static func settingsCheck(area: String, templates: [WebSlideTemplates.Template]) -> Check {
        var trouble: [String] = []
        var counts: [String] = []
        for template in templates {
            guard let parts = split(template.html) else {
                trouble.append("\(template.id): спільний розбір не знайшов у сторінці блоку налаштувань")
                continue
            }
            // Объявлено в файле — и прочитано моделью: это одно и то же число
            // ровно потому, что блок теперь один на всех.
            let announced = template.parameterNames
            if parts.names.count != announced.count {
                trouble.append("\(template.id): у блоці \(announced.count) рядків, "
                               + "а розбір вичитав \(parts.names.count)")
            }
            // Правка руками вне блока — верный признак того, что заготовка
            // печатает значения мимо блока: своих объявлений вне его у неё
            // быть не может.
            let outside = WebSlideParameters.parse(html: template.html).outsideNames
            if !outside.isEmpty {
                trouble.append("\(template.id): поза блоком оголошено — " + outside.joined(separator: ", "))
            }
            counts.append("\(template.id) \(parts.names.count)")
        }

        return Check(area: area, name: "Блок налаштувань на місці",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "спільний розбір читає всі значення, поза блоком не оголошено нічого; "
                           + "ручок у блоках: " + counts.joined(separator: ", ")
                         : trouble.joined(separator: "; "))
    }

    private static func namesCheck(area: String, templates: [WebSlideTemplates.Template]) -> Check {
        var trouble: [String] = []
        for template in templates {
            guard let parts = split(template.html) else { continue }
            let inFile = Set(parts.names)
            let announced = Set(template.parameterNames)
            let extra = inFile.subtracting(announced).sorted()
            let missing = announced.subtracting(inFile).sorted()
            if !extra.isEmpty {
                trouble.append("\(template.id): у файлі є, а вікно не покаже — \(extra.joined(separator: ", "))")
            }
            if !missing.isEmpty {
                trouble.append("\(template.id): вікно покаже, а у файлі немає — \(missing.joined(separator: ", "))")
            }
            let unknown = announced.filter { WebSlideTemplates.parameter(id: $0) == nil }.sorted()
            if !unknown.isEmpty {
                trouble.append("\(template.id): немає опису в \(unknown.joined(separator: ", "))")
            }
        }

        return Check(area: area, name: "Список ручок збігається з файлом",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "вікно покаже рівно ті ручки, що оголошені в сторінці"
                         : trouble.joined(separator: "; "))
    }

    private static func usageCheck(area: String, templates: [WebSlideTemplates.Template]) -> Check {
        var trouble: [String] = []
        for template in templates {
            guard let parts = split(template.html) else { continue }
            // Ручка приносит пользу, если её читают: либо правило оформления
            // через var(--…), либо скрипт по имени.
            let idle = parts.names.filter { name in
                !parts.rest.contains("var(\(name)") && !parts.rest.contains("\"\(name)\"")
            }
            if !idle.isEmpty {
                trouble.append("\(template.id): марно — \(idle.joined(separator: ", "))")
            }
        }

        return Check(area: area, name: "Кожна ручка щось міняє",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "усі оголошені змінні читаються правилами або скриптом"
                         : trouble.joined(separator: "; "))
    }

    /// Порядок тегов оформления в голове страницы.
    ///
    /// Порядок здесь решает молча. Каркас читает значения через `var(--sl-…)`
    /// и сам ничего не объявляет — но стоит кому-нибудь дописать в него
    /// `:root`, и, окажись каркас после блока, он бы перебил блок по каскаду
    /// без единой ошибки: ползунок двигался бы, а на экране ничего.
    /// А ещё ровно перед `</head>` кладёт свой блок сама
    /// `WebSlideParameters.write`, и печатать заготовку иначе значит менять
    /// вид файла на первой же записи.
    private static func orderCheck(area: String, templates: [WebSlideTemplates.Template]) -> Check {
        var trouble: [String] = []
        for template in templates {
            let html = template.html
            guard let frame = html.range(of: "<style>"),
                  let vars = html.range(of: "<style data-slovo=\"vars\">"),
                  let head = html.range(of: "</head>") else {
                trouble.append("\(template.id): не знайшлося каркаса, блоку значень або кінця голови")
                continue
            }
            if frame.lowerBound > vars.lowerBound {
                trouble.append("\(template.id): каркас стоїть після блоку значень")
            }
            if vars.lowerBound > head.lowerBound {
                trouble.append("\(template.id): блок значень винесено за голову сторінки")
            }
            // Между блоком и `</head>` не должно остаться ничего, кроме
            // закрывающего тега и перевода строки: сюда пишет и редактор.
            guard let close = html.range(of: "</style>", range: vars.upperBound..<html.endIndex) else {
                trouble.append("\(template.id): блок значень не закрито")
                continue
            }
            let tail = html[close.upperBound..<head.lowerBound]
            if !tail.allSatisfy({ $0.isWhitespace }) {
                trouble.append("\(template.id): між блоком значень і </head> вклинилося «"
                               + tail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30) + "»")
            }
        }

        return Check(area: area, name: "Блок значень стоїть останнім у голові",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "у всіх десяти спершу каркас, далі блок значень — там само, куди його кладе "
                           + "і сам редактор, тому перший запис не міняє вигляду файлу"
                         : trouble.joined(separator: "; "))
    }

    /// Запись общей моделью не должна плодить второй набор настроек.
    ///
    /// Это и была цена расхождения: пока блок заготовки стоял без метки,
    /// модель его не узнавала и на первое движение ползунка дописывала перед
    /// `</head>` ещё один `:root`. В файле оказывалось два набора значений, и
    /// какой из них работает, человек узнавал только по экрану.
    private static func rewriteCheck(area: String, templates: [WebSlideTemplates.Template]) -> Check {
        var trouble: [String] = []
        for template in templates {
            let before = WebSlideParameters.parse(html: template.html)
            guard case .present = before.block else {
                trouble.append("\(template.id): блок не читається ще до запису")
                continue
            }
            var settings = before.settings
            settings.set("--sl-size", "7.25")

            guard case .written(let after) = WebSlideParameters.write(html: template.html,
                                                                      settings: settings) else {
                trouble.append("\(template.id): запис відхилено")
                continue
            }
            let parsed = WebSlideParameters.parse(html: after)
            guard case .present(_, let extras) = parsed.block else {
                trouble.append("\(template.id): після запису блок не читається")
                continue
            }
            if extras != 0 { trouble.append("\(template.id): блоків налаштувань стало \(extras + 1)") }
            if parsed.settings["--sl-size"] != "7.25" {
                trouble.append("\(template.id): записане значення не прочиталося назад")
            }
            if parsed.settings.count != settings.count {
                trouble.append("\(template.id): було \(settings.count) значень, прочиталося "
                               + "\(parsed.settings.count)")
            }
            if !parsed.outsideNames.isEmpty {
                trouble.append("\(template.id): після запису поза блоком оголошено — "
                               + parsed.outsideNames.joined(separator: ", "))
            }
        }

        return Check(area: area, name: "Запис не плодить другого блоку налаштувань",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "у всіх десяти спільний запис потрапляє в той самий блок: "
                           + "значень стільки ж, зайвих :root не з'явилося"
                         : trouble.joined(separator: "; "))
    }

    private static func protocolCheck(area: String, templates: [WebSlideTemplates.Template]) -> Check {
        var trouble: [String] = []
        for template in templates {
            let html = template.html
            var notes: [String] = []
            if !html.contains("ws://") || !html.contains(":8100/ws") { notes.append("немає адреси сокета") }
            // Программа ищет ключ Cmd; на Command она отвечает 400 и подписки не будет.
            if !html.contains("Cmd: \"SubscribeToSlideChanges\"") { notes.append("підписка не за ключем Cmd") }
            if !html.contains("NextSlide") { notes.append("не просить наступний слайд") }
            if !html.contains("HideSlide") { notes.append("не розбирає порожній екран") }
            if !html.contains("CSeq") { notes.append("не відбраковує пакети не по порядку") }
            if !html.contains("<br>") { notes.append("не переводить переноси рядків") }
            if html.contains("http://") || html.contains("https://") { notes.append("тягне щось з інтернету") }
            if !notes.isEmpty { trouble.append("\(template.id): \(notes.joined(separator: ", "))") }
        }

        return Check(area: area, name: "Зв'язок із програмою однаковий",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "усі десять підписуються однаково і нічого не тягнуть з інтернету"
                         : trouble.joined(separator: "; "))
    }

    private static func catalogueCheck(area: String, templates: [WebSlideTemplates.Template]) -> Check {
        let used = Set(templates.flatMap { $0.parameterNames })
        let unused = WebSlideTemplates.parameters.map { $0.id }.filter { !used.contains($0) }
        let unnamed = WebSlideTemplates.parameters.filter { $0.label.isEmpty || $0.hint.isEmpty }
        let thin = templates.filter { $0.parameterNames.count < 20 }

        var trouble: [String] = []
        if !unused.isEmpty { trouble.append("не знадобилися ніде: \(unused.joined(separator: ", "))") }
        if !unnamed.isEmpty { trouble.append("без підпису: \(unnamed.map { $0.id }.joined(separator: ", "))") }
        if !thin.isEmpty { trouble.append("майже нічого крутити: "
            + thin.map { "\($0.id) — \($0.parameterNames.count)" }.joined(separator: ", ")) }

        return Check(area: area, name: "Ручок вистачає на всі заготовки",
                     status: trouble.isEmpty ? .ok : .warning,
                     detail: trouble.isEmpty
                         ? "описано \(WebSlideTemplates.parameters.count) ручок, усі десь потрібні"
                         : trouble.joined(separator: "; "))
    }

    // MARK: - Настоящий показ

    /// Ответ страницы о том, что она нарисовала.
    private struct Shown {
        let text: String
        let keepsBreaks: Bool
        let quoted: Bool
        let second: String
        let secondVisible: Bool
        let reference: String
        let referenceVisible: Bool
        let song: String
        let songVisible: Bool
        let columnTitle: String
        let columnTitleVisible: Bool
        let next: String
        let nextVisible: Bool
        let page: String
        let boxHidden: Bool
        let markVisible: Bool
        let idleVisible: Bool
        let fits: Bool

        init?(json: String) {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            func string(_ key: String) -> String { object[key] as? String ?? "" }
            func flag(_ key: String) -> Bool { (object[key] as? NSNumber)?.boolValue ?? false }
            func number(_ key: String) -> Double { (object[key] as? NSNumber)?.doubleValue ?? 0 }

            text = string("text")
            keepsBreaks = flag("breaks")
            quoted = flag("quoted")
            second = string("second")
            secondVisible = flag("secondVisible")
            reference = string("ref")
            referenceVisible = flag("refVisible")
            song = string("song")
            songVisible = flag("songVisible")
            columnTitle = string("each")
            columnTitleVisible = flag("eachVisible")
            next = string("next")
            nextVisible = flag("nextVisible")
            page = string("page")
            boxHidden = flag("boxHidden")
            markVisible = flag("markVisible")
            idleVisible = flag("idleVisible")
            // Подбор кегля удался, если текст уложился и в отведённый блок,
            // и в сам слайд: вылезший за край хвост браузер просто срежет.
            fits = number("layerHeight") <= number("stackHeight") + 1
                && !flag("slideCrowded")
        }
    }

    /// Спрашиваем у показанной страницы, что на ней видно.
    private static let probe = """
        (function () {
          var layer = document.querySelector(".layer.on");
          var main = layer ? layer.querySelector(".quote") : null;
          if (!main) return "";
          var stack = document.querySelector(".stack");
          var second = layer.querySelector(".col-second");
          var reference = document.querySelector(".reference");
          var song = document.querySelector(".song");
          var each = layer.querySelector(".col-main .coltitle");
          var slide = document.querySelector(".slide");
          var page = document.querySelector(".page");
          var bar = document.querySelector(".nextbar");
          var next = document.querySelector(".next");
          var box = document.querySelector(".box");
          var mark = document.querySelector(".mark");
          var idle = document.querySelector(".idle");
          function seen(node) {
            if (!node) return false;
            var style = getComputedStyle(node);
            return style.display !== "none" && style.visibility !== "hidden" && node.offsetHeight > 0;
          }
          var text = main.textContent;
          if (text === "" && !document.body.classList.contains("hide-idle")) return "";
          return JSON.stringify({
            text: text,
            breaks: main.innerHTML.indexOf("<br>") >= 0,
            quoted: text.charAt(0) === "\\u00ab",
            second: second ? second.querySelector(".second").textContent : "",
            secondVisible: seen(second),
            ref: reference ? reference.textContent : "",
            refVisible: seen(reference),
            song: song ? song.textContent : "",
            songVisible: seen(song),
            each: each ? each.textContent : "",
            eachVisible: seen(each),
            slideCrowded: !!slide && slide.scrollHeight > slide.clientHeight + 1,
            next: next ? next.textContent : "",
            nextVisible: seen(bar),
            page: page ? page.textContent : "",
            boxHidden: !seen(box),
            markVisible: seen(mark),
            idleVisible: seen(idle),
            stackHeight: stack ? stack.clientHeight : 0,
            layerHeight: layer.scrollHeight
          });
        })()
        """

    /// Ящик под ответ страницы: ответ приходит из обработчика, а ждём мы его
    /// прокруткой цикла событий, поэтому нужна общая для двух мест ячейка.
    /// Всё трогается только в главном потоке.
    private final class Answer: @unchecked Sendable {
        var json: String?
        var asking = false
    }

    /// Чем кончился показ.
    private enum Rendered {
        case shown([String: Shown])
        /// Браузер не отвечал и не мог ответить — причина словами.
        ///
        /// Отличать это от поломки обязательно. Молчащий браузер выглядит
        /// точно так же, как заготовка, которая ничего не рисует, и целый
        /// день проверка выдавала исправный код за сломанный.
        case unavailable(String)
    }

    /// Сторож главной очереди.
    ///
    /// `WKWebView` и грузит страницу, и отвечает на вопрос через главную
    /// **очередь**, а не просто через главный поток. Если самопроверку начал
    /// блок этой же очереди (так делает запуск с `--selftest`), очередь всё
    /// время ожидания занята нами, и никакой вложенный цикл событий её не
    /// разгребает: libdispatch не входит в разбор очереди повторно. Тогда
    /// браузер молчит не потому, что страница плоха, а потому, что до него
    /// не доходит ни одного сообщения.
    ///
    /// Проверить это можно прямо: положить в очередь пустяк и посмотреть,
    /// выполнился ли он, пока мы ждали. Не выполнился — значит и браузер не
    /// мог ответить, и говорить об этом надо словами, а не ошибкой.
    private final class Pulse: @unchecked Sendable {
        var alive = false
    }

    /// Грузит страницы разом и ждёт, пока каждая покажет слайд.
    ///
    /// Разом — потому что поодиночке десять страниц заняли бы секунды на
    /// пустом ожидании, а самопроверка должна проходить быстро.
    private static func render(pages: [(String, String)]) -> Rendered {
        var views: [WKWebView] = []
        var answers: [Answer] = []
        // Общий котёл на все страницы: иначе на каждую заводится свой
        // отдельный процесс показа, и самопроверка думает секундами.
        let configuration = WKWebViewConfiguration()

        for (_, html) in pages {
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                                 configuration: configuration)
            view.loadHTMLString(html, baseURL: nil)
            views.append(view)
            answers.append(Answer())
        }

        let pulse = Pulse()
        DispatchQueue.main.async { pulse.alive = true }

        // Двадцать секунд на десять страниц: на занятой машине процессы
        // показа WebKit поднимаются медленно, и восемь секунд один раз не
        // хватило всем десяти разом — при исправных заготовках.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && answers.contains(where: { $0.json == nil }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            for (index, view) in views.enumerated()
            where answers[index].json == nil && !answers[index].asking && !view.isLoading {
                let answer = answers[index]
                answer.asking = true
                view.evaluateJavaScript(probe) { value, _ in
                    answer.asking = false
                    if let text = value as? String, !text.isEmpty { answer.json = text }
                }
            }
        }

        if !pulse.alive {
            return .unavailable(
                "головна черга весь час очікування була зайнята самою самоперевіркою, "
                + "а браузер і вантажить сторінку, і відповідає лише через неї — "
                + "мовчання тут нічого не каже про заготовки. Показ перевіряється по-справжньому "
                + "з «Довідка → Діагностика» у працюючій програмі; щоб він перевірявся і "
                + "при --selftest, звіт треба знімати з таймера, а не з блоку головної черги")
        }

        var result: [String: Shown] = [:]
        for (index, page) in pages.enumerated() {
            if let json = answers[index].json, let shown = Shown(json: json) {
                result[page.0] = shown
            }
        }
        return .shown(result)
    }

    private static func liveChecks(area: String,
                                   templates: [WebSlideTemplates.Template],
                                   state: AppState) -> [Check] {

        // Текст берём живой — тот, что программа сейчас показывает.
        let slide = state.slide
        let live = !slide.isBlank && !slide.mainText.isEmpty
        let text = live ? slide.mainText : "В начале сотворил Бог небо и землю.\r\nЗемля же была безвидна и пуста."
        let second = live ? (slide.secondaryTexts.first ?? "") : ""
        let secondText = second.isEmpty
            ? "In the beginning God created the heaven and the earth." : second
        let reference = live && !slide.reference.isEmpty ? slide.reference : "Бытие 1:1-2"
        let nextText = "И сказал Бог: да будет свет. И стал свет."

        let bible = WebSlideTemplates.previewShim(text: text, second: secondText,
                                                  reference: reference, next: nextText,
                                                  pageCurrent: 0, pageCount: 3)
        let songSample = "Как велик Ты, Боже,\r\nвелича полн,\r\nи хвалы достоин Ты!***"
        let song = WebSlideTemplates.previewShim(text: songSample, second: "",
                                                 reference: "Куплет 2", next: "Припев",
                                                 mode: "Song",
                                                 songTitle: "№ 128 · Как велик Ты, Боже",
                                                 pageCurrent: 1, pageCount: 2)
        let empty = WebSlideTemplates.previewShim(text: text, second: secondText,
                                                  reference: reference, next: nextText,
                                                  hidden: true)

        func withShim(_ template: WebSlideTemplates.Template, _ shim: String) -> String {
            var html = template.html
            if let head = html.range(of: "<head>") {
                html = html.replacingCharacters(in: head, with: "<head>\n" + shim)
            }
            return html
        }

        var pages: [(String, String)] = []
        for template in templates { pages.append((template.id, withShim(template, bible))) }
        if let songPage = WebSlideTemplates.template(id: "song") {
            pages.append(("song/пісня", withShim(songPage, song)))
        }
        for id in ["plain", "stage", "foyer"] {
            if let template = WebSlideTemplates.template(id: id) {
                pages.append((id + "/порожньо", withShim(template, empty)))
            }
        }

        // Имена всех пяти проверок держим в одном месте: когда показать
        // нечем, каждая обязана назваться и честно сказать «пропущено»,
        // а не пропасть из отчёта и не соврать зелёной строкой.
        let liveNames = ["Показують текст, адресу і другий переклад",
                         "Лапки ставляться за режимом",
                         "Сторінка пісні знає про пісню",
                         "Порожній екран у кожної по-своєму",
                         "Кегль дібрано, наступний видно"]

        let shown: [String: Shown]
        switch render(pages: pages) {
        case .shown(let answers):
            shown = answers
        case .unavailable(let reason):
            return liveNames.map {
                Check(area: area, name: $0, status: .skipped, detail: reason)
            }
        }

        let source = live ? "текст живого слайда: «\(String(text.prefix(40)))…»"
                          : "живого слайда немає, взято зразок"

        var checks: [Check] = []

        // 1. Текст, адрес и второй перевод.
        var silent: [String] = []
        var wrongText: [String] = []
        var noReference: [String] = []
        var noSecond: [String] = []
        let firstLine = text.components(separatedBy: .newlines).first ?? text

        for template in templates {
            guard let result = shown[template.id] else { silent.append(template.id); continue }
            if !result.text.contains(firstLine.prefix(20)) {
                wrongText.append("\(template.id): «\(String(result.text.prefix(30)))»")
            }
            if !result.keepsBreaks && text.contains("\r\n") {
                wrongText.append("\(template.id): загублено переноси рядків")
            }
            // Спрашиваем только то, что заготовка обещала показывать.
            if template.html.contains("--sl-ref: block"),
               !result.referenceVisible || result.reference.isEmpty {
                noReference.append(template.id)
            }
            // Где адрес свой у каждого перевода — общего может и не быть.
            if template.html.contains("--sl-ref-each: block"),
               !result.columnTitleVisible || result.columnTitle.isEmpty {
                noReference.append(template.id + " (у перекладу)")
            }
            if template.html.contains("--sl-second: block"),
               !result.secondVisible || result.second.isEmpty {
                noSecond.append(template.id)
            }
        }

        var trouble: [String] = []
        if !silent.isEmpty { trouble.append("нічого не показали: \(silent.joined(separator: ", "))") }
        if !wrongText.isEmpty { trouble.append("текст не той — \(wrongText.joined(separator: "; "))") }
        if !noReference.isEmpty { trouble.append("немає адреси: \(noReference.joined(separator: ", "))") }
        if !noSecond.isEmpty { trouble.append("немає другого перекладу: \(noSecond.joined(separator: ", "))") }

        checks.append(Check(area: area, name: "Показують текст, адресу і другий переклад",
                            status: trouble.isEmpty ? .ok : .failed,
                            detail: trouble.isEmpty
                                ? "усі десять на підміненому з'єднанні, \(source)"
                                : trouble.joined(separator: "; ")))

        // 2. Кавычки только в Библии, переносы куплета целы.
        var quoteTrouble: [String] = []
        for template in templates {
            guard let result = shown[template.id] else { continue }
            let wantsQuotes = template.html.contains("--sl-quotes: 1;")
            if wantsQuotes && !result.quoted { quoteTrouble.append("\(template.id): немає лапок у Біблії") }
            if !wantsQuotes && result.quoted { quoteTrouble.append("\(template.id): лапки там, де їх не просили") }
        }
        checks.append(Check(area: area, name: "Лапки ставляться за режимом",
                            status: quoteTrouble.isEmpty ? .ok : .failed,
                            detail: quoteTrouble.isEmpty
                                ? "вірш у лапках там, де це ввімкнено, і ніде більше"
                                : quoteTrouble.joined(separator: "; ")))

        // 3. Страница песни на песенном пакете.
        if let result = shown["song/пісня"] {
            var notes: [String] = []
            if !result.songVisible || result.song.isEmpty { notes.append("не показала назви пісні") }
            if result.referenceVisible { notes.append("показала адресу, хоча в пісні її не буває") }
            if result.quoted { notes.append("взяла куплет у лапки") }
            if !result.keepsBreaks { notes.append("склеїла рядки куплета") }
            if result.text.contains("***") { notes.append("лишила мітку кінця пісні") }
            checks.append(Check(area: area, name: "Сторінка пісні знає про пісню",
                                status: notes.isEmpty ? .ok : .failed,
                                detail: notes.isEmpty
                                    ? "назва «\(result.song)», куплет у три рядки, без лапок і без адреси"
                                    : notes.joined(separator: "; ")))
        } else {
            checks.append(Check(area: area, name: "Сторінка пісні знає про пісню",
                                status: .failed,
                                detail: "сторінка не показала нічого на пісенному пакеті"))
        }

        // 4. Пустой экран в зале: у каждой страницы он свой.
        var hideTrouble: [String] = []
        if let plain = shown["plain/порожньо"], !plain.boxHidden {
            hideTrouble.append("«Вірш на кольорі» не сховав текст")
        }
        if shown["plain/порожньо"] == nil { hideTrouble.append("«Вірш на кольорі» не відповів") }
        if let stage = shown["stage/порожньо"] {
            if stage.boxHidden { hideTrouble.append("екран служителя осліп разом із залом") }
            if !stage.markVisible { hideTrouble.append("екран служителя не попередив про порожній екран") }
        } else {
            hideTrouble.append("екран служителя не відповів")
        }
        if let foyer = shown["foyer/порожньо"], !foyer.idleVisible {
            hideTrouble.append("монітор у фоє не показав заставки")
        }
        checks.append(Check(area: area, name: "Порожній екран у кожної по-своєму",
                            status: hideTrouble.isEmpty ? .ok : .failed,
                            detail: hideTrouble.isEmpty
                                ? "зал гасне, служитель бачить текст і попередження, у фоє — заставка"
                                : hideTrouble.joined(separator: "; ")))

        // 5. Подбор кегля и следующий слайд.
        var fitTrouble: [String] = []
        for template in templates where template.html.contains("--sl-fit: 1;") {
            guard let result = shown[template.id] else { continue }
            if !result.fits { fitTrouble.append("\(template.id): текст не вклався у відведену висоту") }
        }
        for template in templates where template.parameterNames.contains("--sl-next") {
            guard let result = shown[template.id] else { continue }
            if !result.nextVisible || result.next.isEmpty {
                fitTrouble.append("\(template.id): не показала наступного слайда")
            }
        }
        checks.append(Check(area: area, name: "Кегль дібрано, наступний видно",
                            status: fitTrouble.isEmpty ? .ok : .failed,
                            detail: fitTrouble.isEmpty
                                ? "у сторінок із добором текст вліз цілком, у службових унизу видно наступний"
                                : fitTrouble.joined(separator: "; ")))

        return checks
    }
}
