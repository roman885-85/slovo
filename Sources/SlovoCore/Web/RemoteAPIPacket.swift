import Foundation

/// Пакети VisioBible Remote API V1.0 — рівно в тому вигляді, в якому їх чекають
/// авторські сторінки з теки `RemoteAPI`.
///
/// Важлива розбіжність документації і реальності: `Help/RemoteAPI_ru.txt`
/// малює секцію `Slide` вкладеною в `Event`, а весь JavaScript автора
/// (VBWebSlide.html, VBWebSlideCF*.html, VBWebSlideStage.html) читає
/// `data.Slide` і `data.NextSlide` з верхнього рівня, а з події — лише
/// `data.Event.Name`. Щоб працювали і сторінки, і клієнти, написані за
/// документацією, подія віддається в обох видах одразу: `Slide` лежить і поруч з
/// `Event`, і всередині нього. Зайві поля JSON-клієнтам не заважають.

// MARK: - Вміст

/// Назва перекладу для секції `Var[X]`.
public struct RemoteModuleName: Sendable, Hashable {
    public var short: String
    public var full: String

    public init(short: String, full: String = "") {
        self.short = short
        self.full = full.isEmpty ? short : full
    }
}

/// Один переклад у пакеті події — секція `Var[X]` разом з `Out0`.
public struct RemoteSlideVariant: Sendable, Hashable {
    public var moduleShortName: String
    public var moduleName: String
    /// Посилання на місце Писання саме цього перекладу.
    public var title: String
    /// Вибраний текст цілком; рядки розділяються переносом рядка.
    public var text: String
    /// Сторінки слайда так, як його розкладено на проекторі.
    public var pages: [String]
    public var pageCurrent: Int

    /// `pages: nil` — «сторінок немає, слайд уміщається цілком»: тоді єдиною
    /// сторінкою стає сам текст, і `Out0` лишається валідним для клієнтів,
    /// які його читають.
    public init(moduleShortName: String = "",
                moduleName: String = "",
                title: String = "",
                text: String = "",
                pages: [String]? = nil,
                pageCurrent: Int = 0) {
        self.moduleShortName = moduleShortName
        self.moduleName = moduleName.isEmpty ? moduleShortName : moduleName
        self.title = title
        self.text = text
        self.pages = pages ?? (text.isEmpty ? [] : [text])
        self.pageCurrent = pageCurrent
    }

    /// `includeOut0` — підписник просив параметр `Out0`; без нього секцію
    /// форматованого слайда не шлемо, як і оригінал.
    func json(includeOut0: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "ModuleShortName": moduleShortName,
            "ModuleName": moduleName,
            "Title": RemoteText.wireText(title),
            "Text": RemoteText.wireText(text),
        ]
        if includeOut0 {
            result["Out0"] = [
                "PageCurrent": max(0, pageCurrent),
                "Pages": pages.map(RemoteText.wireText),
            ] as [String: Any]
        }
        return result
    }
}

/// Увесь стан слайда, який іде підписникам за один пакет.
public struct RemoteSlidePayload: Sendable, Hashable {

    /// Режим головного вікна: сторінки автора за ним вирішують, чи брати текст у
    /// лапки (вірш — так, куплет пісні — ні).
    public enum Mode: String, Sendable, Hashable, CaseIterable {
        case bible = "Bible"
        case text = "Text"
        case song = "Song"
    }

    public var mode: Mode
    /// Спільне посилання для всіх перекладів.
    public var titleCommon: String
    /// Переклади по порядку: `variants[0]` → `Var0`, і так далі.
    public var variants: [RemoteSlideVariant]
    /// Наступний слайд для екрана служителя (секція `NextSlide`).
    public var next: [RemoteSlideVariant]
    /// Порожній слайд — це не «немає тексту», а подія `HideSlide`.
    public var isVisible: Bool
    /// Розкладка об'єктів шаблону — те, чим слайд виглядає на проекторі.
    ///
    /// Секція необов'язкова і зайва для сторінок автора: вони її просто не
    /// читають, як і все, чого не знають. Потрібна вона нашій сторінці
    /// `slovo-slide.html`, яка малює шаблон, а не лише текст.
    public var layout: WebSlideLayout?

    public init(mode: Mode = .bible,
                titleCommon: String = "",
                variants: [RemoteSlideVariant] = [],
                next: [RemoteSlideVariant] = [],
                isVisible: Bool = true,
                layout: WebSlideLayout? = nil) {
        self.mode = mode
        self.titleCommon = titleCommon
        self.variants = variants
        self.next = next
        self.isVisible = isVisible
        self.layout = layout
    }

    /// Збирання з готового слайда застосунку.
    ///
    /// `Slide` не знає, з яких модулів узято текст, тому назви
    /// перекладів приходять окремим списком у тому самому порядку: основний, потім
    /// паралельні. Чого забракло — заповнюється порожнім рядком, пакет від
    /// цього не ламається.
    public init(slide: Slide,
                mode: Mode = .bible,
                moduleNames: [RemoteModuleName] = [],
                next: [RemoteSlideVariant] = []) {
        let texts = [slide.mainText] + slide.secondaryTexts
        let variants = texts.enumerated().map { index, text -> RemoteSlideVariant in
            let name = moduleNames.indices.contains(index) ? moduleNames[index] : RemoteModuleName(short: "")
            return RemoteSlideVariant(moduleShortName: name.short,
                                      moduleName: name.full,
                                      title: slide.reference,
                                      text: text)
        }
        self.init(mode: mode,
                  titleCommon: slide.reference,
                  variants: slide.isBlank ? [] : variants,
                  next: next,
                  isVisible: !slide.isBlank)
    }

    public var event: RemoteSlideEvent { isVisible ? .show : .hide }

    func slideJSON(includeOut0: Bool) -> [String: Any] {
        var result: [String: Any] = [
            "TitleCommon": RemoteText.wireText(titleCommon),
            "VarsNum": variants.count,
        ]
        for (index, variant) in variants.enumerated() {
            result["Var\(index)"] = variant.json(includeOut0: includeOut0)
        }
        return result
    }

    func nextJSON(includeOut0: Bool) -> [String: Any] {
        var result: [String: Any] = ["VarsNum": next.count]
        for (index, variant) in next.enumerated() {
            result["Var\(index)"] = variant.json(includeOut0: includeOut0)
        }
        return result
    }
}

/// Подія зміни слайда.
public enum RemoteSlideEvent: String, Sendable {
    case show = "ShowSlide"
    case hide = "HideSlide"
}

// MARK: - Розбір запиту

/// Запит клієнта: `{"Cmd": "...", "Params": "..."}` плюс поля UDP-транспорту.
public struct RemoteAPIRequest: Sendable {
    public let command: String
    public let params: [String]
    public let sessionGUID: String?
    public let sequence: Int?
    public let udpPort: Int?

    public init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }

        // Регістр ключів у прикладах автора плаває, тому шукаємо без урахування регістру.
        func value(_ key: String) -> Any? {
            if let exact = root[key] { return exact }
            return root.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }

        guard let command = value("Cmd") as? String else { return nil }
        self.command = command.trimmingCharacters(in: .whitespaces)
        self.params = (value("Params") as? String)?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        self.sessionGUID = value("SessionGUID") as? String
        self.sequence = (value("CSeq") as? NSNumber)?.intValue
        self.udpPort = (value("UDPPort") as? NSNumber)?.intValue
    }

    public func hasParam(_ name: String) -> Bool {
        params.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Підписник просить вміст слайда з проектора №0.
    public var wantsProjectorContent: Bool { hasParam("Out0") }
    /// Екран служителя додатково просить наступний слайд.
    public var wantsNextSlide: Bool { hasParam("NextSlide") }
}

// MARK: - Збирання пакетів

/// Коди результату з документації протоколу.
public enum RemoteAPICode {
    public static let ok = (code: 200, text: "OK")
    public static let badRequest = (code: 400, text: "Bad Request")
    public static let notFound = (code: 404, text: "Not Found")
    public static let notAllowed = (code: 405, text: "Method Not Allowed")
    /// 410 — сесію UDP закрито за тайм-аутом.
    public static let gone = (code: 410, text: "Gone")
}

enum RemoteAPIPacket {

    /// Спільна частина будь-якого пакета сервера.
    private static func envelope(instance: String,
                                 session: String,
                                 sequence: Int,
                                 code: (code: Int, text: String)) -> [String: Any] {
        [
            "InstanceGUID": instance,
            "SessionGUID": session,
            "CSeq": sequence,
            "Sender": ["Name": RemoteAPIIdentity.senderName],
            "Code": code.code,
            "CodeText": code.text,
        ]
    }

    /// Відповідь на команду. `extra` — додаткові секції конкретної команди.
    static func answer(command: String,
                       instance: String,
                       session: String,
                       sequence: Int,
                       code: (code: Int, text: String) = RemoteAPICode.ok,
                       extra: [String: Any] = [:]) -> Data {
        var packet = envelope(instance: instance, session: session, sequence: sequence, code: code)
        packet["Answer"] = ["Cmd": command]
        for (key, value) in extra { packet[key] = value }
        return encode(packet)
    }

    /// Подія зміни слайда.
    ///
    /// `NextSlide` кладеться завжди: сторінка екрана служителя звертається до
    /// `data.NextSlide.Var0` без перевірки, і без цієї секції в неї падає
    /// весь обробник повідомлення.
    static func slideEvent(_ payload: RemoteSlidePayload,
                           instance: String,
                           session: String,
                           sequence: Int,
                           includeOut0: Bool) -> Data {
        var packet = envelope(instance: instance, session: session, sequence: sequence, code: RemoteAPICode.ok)
        let slide = payload.slideJSON(includeOut0: includeOut0)
        packet["Mode"] = payload.mode.rawValue
        packet["Event"] = ["Name": payload.event.rawValue, "Slide": slide] as [String: Any]
        packet["Slide"] = slide
        packet["NextSlide"] = payload.nextJSON(includeOut0: includeOut0)
        if let layout = payload.layout, !layout.isEmpty { packet["Layout"] = layout.json() }
        return encode(packet)
    }

    /// Подія «сесію закрито за тайм-аутом» — лише для UDP.
    ///
    /// В решти транспортів про розрив каже сам сокет, а по UDP клієнт
    /// інакше не дізнається, що його забули, і чекатиме слайдів до кінця
    /// служіння.
    static func sessionClosed(instance: String, session: String, sequence: Int) -> Data {
        var packet = envelope(instance: instance, session: session, sequence: sequence,
                              code: RemoteAPICode.gone)
        packet["Event"] = ["Name": "CloseSession"]
        packet["MsgID"] = RemoteAPICode.gone.code
        return encode(packet)
    }

    /// Серіалізація в один рядок: специфікація забороняє сирі 0x0D/0x0A у
    /// пакеті, а перенос рядка всередині тексту має приїхати
    /// послідовністю «\r\n» — це рівно те, що робить JSON-екранування.
    private static func encode(_ packet: [String: Any]) -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: packet, options: []) else {
            return Data("{\"Code\":500,\"CodeText\":\"Internal Error\"}".utf8)
        }
        return data
    }
}

/// Хто ми для клієнтів протоколу.
public enum RemoteAPIIdentity {
    /// Сторінки автора і сторонні клієнти звіряються з цим ім'ям, тому
    /// підписуємося так само, як оригінал; своє ім'я іде окремим полем.
    public static let senderName = "VisioBible"
    public static let implementationName = "Slovo"
    public static let version = (majorHi: 2, majorLo: 5, minorHi: 0, build: 1)

    static func senderInfo(installGUID: String) -> [String: Any] {
        [
            "Name": senderName,
            "Implementation": implementationName,
            "InstallGUID": installGUID,
            "Version": [
                "MajorHi": version.majorHi,
                "MajorLo": version.majorLo,
                "MinorHi": version.minorHi,
                "Build": version.build,
            ],
        ]
    }

    /// GUID у фігурних дужках, як в усіх прикладах протоколу.
    public static func makeGUID() -> String { "{" + UUID().uuidString + "}" }
}

/// Текст для дроту.
enum RemoteText {
    /// Усі варіанти переносу рядка зводимо до «\r\n»: так вимагає протокол,
    /// і так їх ріже JavaScript авторських сторінок (`replace(/\r\n/g, '<br>')`).
    static func wireText(_ text: String) -> String {
        guard text.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }) else {
            return text
        }
        var result = ""
        result.reserveCapacity(text.count + 8)
        var iterator = text.startIndex
        while iterator < text.endIndex {
            let character = text[iterator]
            switch character {
            case "\r\n", "\n", "\r", "\u{2028}", "\u{2029}":
                result += "\r\n"
            default:
                result.append(character)
            }
            iterator = text.index(after: iterator)
        }
        return result
    }
}
