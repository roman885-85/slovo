import Foundation

/// Дані для стартової сторінки веб-виводу (`RemoteAPI/index.tpl`).
///
/// Шаблон авторський, правити його не можна, тому підписи колонок приходять
/// звідси — їх беруть із файла перекладу інтерфейсу.
public struct WebIndexModel: Sendable, Hashable {

    public struct Entry: Sendable, Hashable {
        public let name: String          // ім'я файлу сторінки
        public let description: String   // що це за сторінка

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    public var title: String
    public var languageCode: String
    public var pageColumn: String
    public var descriptionColumn: String
    public var qrColumn: String
    public var entries: [Entry]

    public init(title: String = OurWords.t("Слово — веб-слайды"),
                languageCode: String = "ru",
                pageColumn: String = "Страница",
                descriptionColumn: String = OurWords.t("Описание"),
                qrColumn: String = "QR-код",
                entries: [Entry] = []) {
        self.title = title
        self.languageCode = languageCode
        self.pageColumn = pageColumn
        self.descriptionColumn = descriptionColumn
        self.qrColumn = qrColumn
        self.entries = entries
    }

    public init(pages: [WebOutputSettings.WebPage],
                title: String = OurWords.t("Слово — веб-слайды"),
                languageCode: String = "ru") {
        self.init(title: title,
                  languageCode: languageCode,
                  entries: pages.map {
                      Entry(name: $0.fileName,
                            description: WebIndexModel.knownDescriptions[$0.fileName.lowercased()].map { OurWords.t($0) } ?? $0.title)
                  })
    }

    /// Імена файлів авторських сторінок нічого не кажуть операторові, а колонка
    /// «Опис» — єдине місце, де можна пояснити різницю між ними.
    static let knownDescriptions: [String: String] = [
        "vbwebslide.html": "Титры внизу экрана поверх прозрачного фона",
        "vbwebslidecf.html": "Титры с плавной сменой, подложка под текстом",
        "vbwebslidecf1.html": "Титры с плавной сменой, без подложки",
        "vbwebslidestage.html": "Экран служителя: текущий слайд крупно и следующий внизу",
        "visiobiblewebslidecf-bible.html": "Стихи Писания с плавной сменой",
        "visiobiblewebslidecf-song.html": "Куплеты песни с плавной сменой",
    ]
}

/// Підстановки в авторські сторінки.
///
extension WebTemplate {
    /// Сторінки автора — його файли, ми їх не правимо; але в залі, коли сервер
    /// мовчить, на екрані спливає «Connect to стара програма WS-Server…».
    /// Власник: «в веб-странице при отсутствии сигнала есть надпись чужой программы».
    /// Підміняємо фрази на видачі — нашою мовою.
    public static func replaceAuthorPhrases(_ page: String) -> String {
        var result = page
        for (theirs, ours) in authorPhrases where result.contains(theirs) {
            result = result.replacingOccurrences(of: theirs, with: safeForScript(OurWords.t(ours)))
        }
        return result
    }

    /// Що і на що підміняється. Окремо — щоб самоперевірка могла
    /// пройтися тими самими парами.
    static let authorPhrases: [(String, String)] = [
        ("Connection lost. Trying to reconnect to VisioBible WS-Server...", "Связь потеряна. Подключаюсь к «Слову» снова…"),
        ("Connect to VisioBible WS-Server...", "Подключение к «Слову»…"),
        ("VisioBible Web Slide", "Слово — веб-слайд"),
    ]

    /// Автор вписує ці фрази не лише в розмітку, а й у рядки свого
    /// JavaScript — в одинарних лапках: `contentDiv.text('Connection lost…')`.
    /// Українське «Зв'язок втрачено» несло звичайний апостроф, лапка
    /// закривалася завчасно, і весь скрипт сторінки не розбирався:
    /// она навсегда оставалась с надписью «Підключення…» и к сокету не шла.
    /// Саме це власник бачив як «базовые страницы не подключаются».
    /// Апостроф тут замінюється типографським, а зворотна скісна і
    /// переноси рядків прибираються: у тексті вони не потрібні, а рядок ламають.
    static func safeForScript(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "\u{2019}")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

/// Свого рушія шаблонів у старій програмі немає — є кілька міток і один цикл
/// `{{#each WebSlides as WebSlide}}`. Рівно їх і підтримуємо: чужі фігурні
/// дужки чіпати не можна, інакше поїде JavaScript сторінки, який сам
/// порівнює текст з `'{'+'{SERVER_ADDR}'+'}'`.
public enum WebTemplate {

    /// Мітка адреси сервера: сторінки підставляють її в `ws://…` і без неї
    /// ідуть на localhost, тобто з телефона не працюють.
    static let serverAddress = "{{SERVER_ADDR}}"

    static func renderIndex(template: String, model: WebIndexModel, serverAddress address: String) -> String {
        var result = expandEachBlock(in: template, entries: model.entries)
        result = result
            .replacingOccurrences(of: "{{TITLE}}", with: escape(model.title))
            .replacingOccurrences(of: "{{LANG}}", with: escape(model.languageCode))
            .replacingOccurrences(of: "{{PAGE}}", with: escape(model.pageColumn))
            .replacingOccurrences(of: "{{DESCRIPTION}}", with: escape(model.descriptionColumn))
            .replacingOccurrences(of: "{{QRCODE}}", with: escape(model.qrColumn))
            .replacingOccurrences(of: serverAddress, with: escape(address))
        return result
    }

    /// Звичайна сторінка слайда: міток мало, але `SERVER_ADDR` обов'язковий.
    static func renderPage(_ page: String, model: WebIndexModel, serverAddress address: String) -> String {
        page
            .replacingOccurrences(of: serverAddress, with: escape(address))
            .replacingOccurrences(of: "{{LANG}}", with: escape(model.languageCode))
            .replacingOccurrences(of: "{{TITLE}}", with: escape(model.title))
    }

    /// Порт WebSocket в автора вшито в сторінки числом 8100. Файли на диску —
    /// чужі, правити їх не можна, тому адреса підміняється на льоту, вже у
    /// відповіді, що віддається. Заразом відводимо з `localhost` ті дві сторінки, де він
    /// прописаний намертво: з телефона вони інакше стукаються самі в себе.
    static func retargetWebSocket(_ page: String, host: String, port: Int) -> String {
        var result = page
        if host != "localhost", host != "127.0.0.1" {
            result = result.replacingOccurrences(of: "ws://localhost:", with: "ws://\(host):")
        }
        if port != 8100 {
            result = result.replacingOccurrences(of: ":8100/ws", with: ":\(port)/ws")
        }
        return result
    }

    /// `{{#each WebSlides as WebSlide}} … {{/each}}` — єдиний цикл шаблону.
    private static func expandEachBlock(in template: String, entries: [WebIndexModel.Entry]) -> String {
        let opening = "{{#each WebSlides as WebSlide}}"
        let closing = "{{/each}}"
        guard let start = template.range(of: opening),
              let end = template.range(of: closing, range: start.upperBound..<template.endIndex) else {
            return template
        }
        let body = String(template[start.upperBound..<end.lowerBound])
        let rows = entries.map { entry in
            // У посиланні — коротке ім'я, у підписі — ім'я файлу. Автор у своїй
            // заготовці підставляє `Name` і туди, і туди, а з імені файлу
            // виходить адреса з відсотками замість кирилиці: таку ні
            // продиктувати, ні в OBS вписати.
            let address = escape(WebPageAddress.slug(of: entry.name))
            return body
                .replacingOccurrences(of: "data-href=\"{{WebSlide->Name}}\"", with: "data-href=\"\(address)\"")
                .replacingOccurrences(of: "href=\"{{WebSlide->Name}}\"", with: "href=\"\(address)\"")
                .replacingOccurrences(of: "{{WebSlide->Address}}", with: address)
                .replacingOccurrences(of: "{{WebSlide->Name}}", with: escape(entry.name))
                .replacingOccurrences(of: "{{WebSlide->Description}}", with: escape(entry.description))
        }
        return template.replacingCharacters(in: start.lowerBound..<end.upperBound, with: rows.joined())
    }

    /// Усе підставлюване екрануємо: в імена сторінок і в заголовок потрапляють
    /// дані з диска і з перекладу, а адреса сервера — взагалі із заголовка
    /// запиту, тобто від клієнта.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
