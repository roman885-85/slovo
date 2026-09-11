import Foundation

// MARK: - Що сторінка задає сама

extension WebSlideParameters {

    /// Перевести власне оформлення сторінки в наші змінні.
    ///
    /// Потрібно в ту мить, коли на чужу сторінку вперше надягають блок
    /// налаштувань. Правила прив'язки написано через `!important`, і вони перебивають її
    /// власний лист стилів; якщо при цьому взяти заводські значення,
    /// сторінка разом перестає бути схожою на себе — а людина всього лише
    /// взяла її за основу. Тому читаємо її ж CSS і переводимо те, що
    /// розуміємо: колір і кегль тексту, шрифт, вирівнювання, поля, фон.
    ///
    /// Перевести можна не все: в автора половина вигляду тримається на правилах,
    /// яким у нас немає повзунка. Чого не зрозуміли — того й не чіпаємо, там
    /// лишиться заводське.
    public static func inferred(from html: String, roles: RoleSelectors = .standard) -> WebSlideSettings {
        let rules = cssRules(in: stripBlocks(html: html))

        func declarations(matching selectors: String) -> [String: String] {
            var found: [String: String] = [:]
            for rule in rules where selectorMatches(rule.selector, anyOf: selectors) {
                for (name, value) in rule.declarations { found[name] = value }
            }
            return found
        }

        var page = declarations(matching: roles.page)
        // Фон в автора стоїть просто в атрибуті `style` тіла сторінки, і лист
        // стилів про нього нічого не знає.
        for (name, value) in bodyStyleAttribute(in: html) { page[name] = value }
        return settings(fromComputed: ["page": page,
                                       "stage": declarations(matching: roles.stage),
                                       "text": declarations(matching: roles.quote),
                                       "reference": declarations(matching: roles.reference)])
    }

    /// Перевести готові значення властивостей у наші змінні.
    ///
    /// Сюди приходить або розбір листа стилів, або — що точніше — відповідь
    /// самого браузера (`getComputedStyle`). Розбір один на обидва випадки: і там,
    /// і там на вході звичайні властивості CSS у звичайному вигляді.
    public static func settings(fromComputed roles: [String: [String: String]]) -> WebSlideSettings {
        var settings = WebSlideSettings()
        let page = roles["page"] ?? [:]
        let stage = roles["stage"] ?? [:]
        let text = roles["text"] ?? [:]
        let reference = roles["reference"] ?? [:]

        // Фон сторінки
        if let raw = page["background-color"], let rgba = colour(raw) {
            settings.set("--sl-page-rgb", "\(rgba.r) \(rgba.g) \(rgba.b)")
            settings.set("--sl-page-opacity", trim(rgba.a))
        }
        if let image = page["background-image"], !image.isEmpty { settings.set("--sl-bg-image", image) }
        if let fit = page["background-size"], !fit.isEmpty { settings.set("--sl-bg-fit", fit) }
        if let pos = page["background-position"], !pos.isEmpty { settings.set("--sl-bg-pos", pos) }
        if let repeated = page["background-repeat"], !repeated.isEmpty { settings.set("--sl-bg-repeat", repeated) }
        // Того, чого в сторінки немає, ми їй і не додаємо: пелена і розмиття
        // наші власні, і заводські значення були б чужою правкою.
        settings.set("--sl-dim", "0")
        settings.set("--sl-bg-blur", "0px")
        settings.set("--sl-safe", "0%")
        settings.set("--sl-offset-x", "0")
        settings.set("--sl-offset-y", "0")

        // Текст. Не знайшовши свого в блоку тексту, дивимося в тіло сторінки:
        // в автора кегль і колір суціль задано разом на всю сторінку.
        func textValue(_ property: String) -> String? {
            if let own = text[property], !own.isEmpty { return own }
            let inherited = page[property]
            return (inherited?.isEmpty ?? true) ? nil : inherited
        }
        let fontPixels = textValue("font-size").flatMap(pixels)

        if let raw = textValue("color"), let rgba = colour(raw) {
            settings.set("--sl-color", hex(rgba))
            settings.set("--sl-text-opacity", trim(rgba.a))
        }
        if let font = textValue("font-family") { settings.set("--sl-font", font) }
        if let weight = textValue("font-weight") { settings.set("--sl-weight", cssWeight(weight)) }
        if let stretch = textValue("font-stretch") { settings.set("--sl-stretch", cssStretch(stretch)) }
        if let style = textValue("font-style") {
            settings.set("--sl-italic", style.hasPrefix("italic") || style.hasPrefix("oblique") ? "italic" : "normal")
        }
        if let caps = textValue("text-transform") {
            settings.set("--sl-caps", caps == "uppercase" ? "uppercase" : "none")
        }
        if let align = textValue("text-align"), ["left", "center", "right", "justify"].contains(align) {
            settings.set("--sl-align", align)
        }
        if let size = textValue("font-size"), let pair = fontSize(size) {
            settings.set("--sl-unit", pair.unit)
            settings.set("--sl-size", pair.size)
        }
        if let spacing = textValue("letter-spacing") {
            if spacing == "normal" {
                settings.set("--sl-tracking", "0em")
            } else if let px = pixels(spacing), let base = fontPixels, base > 0 {
                settings.set("--sl-tracking", trim(px / base) + "em")
            }
        }
        if let height = textValue("line-height") {
            if height == "normal" {
                settings.set("--sl-line", "1.25")
            } else if let px = pixels(height), let base = fontPixels, base > 0 {
                settings.set("--sl-line", trim(px / base))
            }
        }
        if let width = textValue("width"), let px = pixels(width), px > 0 {
            settings.set("--sl-width", trim(min(100, px / 19.2)) + "%")
        }
        // Обведення і тінь: у чужої сторінки їх зазвичай немає, а наші заводські
        // значення обвели б увесь текст разом.
        if let stroke = textValue("-webkit-text-stroke-width"), let px = pixels(stroke), px > 0 {
            settings.set("--sl-stroke-on", "1")
            settings.set("--sl-stroke", trim(px / 10.8))
            if let raw = textValue("-webkit-text-stroke-color"), let rgba = colour(raw) {
                settings.set("--sl-stroke-color", hex(rgba))
            }
        } else {
            settings.set("--sl-stroke-on", "0")
        }
        settings.set("--sl-shadow-on", (textValue("text-shadow") ?? "none") == "none" ? "0" : "1")
        // Тривалість переходу — теж зі сторінки. Своя, нав'язана поверх
        // чужого скрипту, розтягувала підміну тексту, і старий слайд устигав
        // побути на екрані разом із новим: на око це «накладання слайдів».
        // Немає своєї — значить нуль, а не наші третина секунди.
        if let raw = textValue("transition-duration") {
            let first = raw.split(separator: ",").first.map(String.init) ?? raw
            settings.set("--sl-fade", first.trimmingCharacters(in: .whitespaces))
        } else {
            settings.set("--sl-fade", "0s")
        }

        // Розташування і підкладка під текстом.
        let box = stage.isEmpty ? text : stage
        // Притиски беремо за місцем, де текст насправді опинився. Властивості
        // розкладки про положення мовчать: в автора шар із текстом лежить
        // абсолютно, а `align-items` у батька обчислюється навіть там, де
        // жодної флекс-розкладки немає, — і ми записували в «притиск справа»
        // те, чого на екрані немає. Тому налаштування й не збігалися з виглядом.
        if let place = roles["место"], let x = place["x"].flatMap(Double.init),
           let y = place["y"].flatMap(Double.init) {
            settings.set("--sl-h", edge(x))
            settings.set("--sl-v", edge(y))
        } else if (box["display"] ?? "").contains("flex") {
            if let value = box["align-items"], flexValues.contains(value) { settings.set("--sl-h", value) }
            if let value = box["justify-content"], flexValues.contains(value) { settings.set("--sl-v", value) }
        }
        // Напрямок розкладки зі сторінки не беремо зовсім. Це наша ручка
        // «як ставити другий переклад», і вона ж вирішує, яка вісь у флекса
        // головна: при `row` «притиск по горизонталі» починає рухати по
        // вертикалі. Списане з чужої сторінки `row` рівно так і перевертало
        // підписи повзунків. Хай лишається `column`: тоді «по горизонталі»
        // завжди горизонталь, а «по вертикалі» — вертикаль.
        settings.set("--sl-second-place", "column")
        // Поля приходять то одним рядком (лист стилів), то за сторонами
        // (відповідь браузера) — беремо що є.
        if let raw = box["padding"], let pair = padding(raw) {
            settings.set("--sl-pad-x", pair.x)
            settings.set("--sl-pad-y", pair.y)
        } else if let top = box["padding-top"], let left = box["padding-left"],
                  let y = length(top, vertical: true), let x = length(left, vertical: false) {
            settings.set("--sl-pad-x", x)
            settings.set("--sl-pad-y", y)
        }
        if let plate = box["background-color"], let rgba = colour(plate) {
            settings.set("--sl-plate-rgb", "\(rgba.r) \(rgba.g) \(rgba.b)")
            settings.set("--sl-plate-opacity", trim(rgba.a))
        }
        if let radius = box["border-radius"], let px = pixels(radius) {
            settings.set("--sl-plate-radius", trim(px / 10.8) + "vh")
        }
        settings.set("--sl-plate-blur", "0px")
        // Поля підкладки — це поля самого блоку з текстом. Наші заводські
        // два відсотки зсували напис на добрих сорок точок убік від
        // того місця, де він стоїть в автора.
        if let top = text["padding-top"], let left = text["padding-left"],
           let y = length(top, vertical: true), let x = length(left, vertical: false) {
            settings.set("--sl-plate-pad-x", x)
            settings.set("--sl-plate-pad-y", y)
        }
        // Рамки і тіні в чужої сторінки немає — не малюємо і ми.
        settings.set("--sl-plate-border", "0vh")
        settings.set("--sl-plate-shadow", "0vh")

        // Адреса
        if let raw = reference["color"], let rgba = colour(raw) { settings.set("--sl-ref-color", hex(rgba)) }
        if let style = reference["font-style"] {
            settings.set("--sl-ref-italic", style.hasPrefix("italic") ? "italic" : "normal")
        }
        if let display = reference["display"], !display.isEmpty {
            settings.set("--sl-ref-display", display == "none" ? "none" : "block")
        }
        if let size = reference["font-size"], let px = pixels(size), let base = fontPixels, base > 0 {
            settings.set("--sl-ref-size", trim(min(1, max(0.2, px / base))))
        }
        return settings
    }

    /// Довжина в пікселях — так браузер відповідає майже завжди.
    static func pixels(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix("px") { return Double(value.dropLast(2)) }
        if value.hasSuffix("vw") { return Double(value.dropLast(2)).map { $0 * 19.2 } }
        if value.hasSuffix("vh") { return Double(value.dropLast(2)).map { $0 * 10.8 } }
        return Double(value)
    }

    /// Ширина літер: браузер відповідає відсотками, у нас — словами.
    static func cssStretch(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard value.hasSuffix("%"), let percent = Double(value.dropLast()) else {
            return value.isEmpty ? "normal" : value
        }
        switch percent {
        case ..<93:    return "condensed"
        case ..<100:   return "semi-condensed"
        case 100:      return "normal"
        case ..<113:   return "semi-expanded"
        case ..<126:   return "expanded"
        default:       return "ultra-expanded"
        }
    }

    /// До якого краю притиснуто текст, судячи з того, де він стоїть.
    static func edge(_ fraction: Double) -> String {
        switch fraction {
        case ..<0.34:  return "flex-start"
        case 0.66...:  return "flex-end"
        default:       return "center"
        }
    }

    private static let flexValues: Set<String> =
        ["flex-start", "center", "flex-end", "space-between"]

    // MARK: Розбір CSS

    struct CSSRule {
        var selector: String
        var declarations: [(name: String, value: String)]
    }

    /// Правила з усіх `<style>` сторінки.
    ///
    /// Справжній розбір CSS тут не потрібен і був би шкідливий: нам досить
    /// «селектор — оголошення», а все, всередині чого є вкладені дужки
    /// (`@media`, `@keyframes`), пропускаємо цілком — правила звідти
    /// застосовуються не завжди, і брати з них значення було б брехнею.
    static func cssRules(in html: String) -> [CSSRule] {
        var rules: [CSSRule] = []
        for sheet in styleBodies(in: html) {
            var rest = Substring(withoutComments(String(sheet)))
            while let open = rest.firstIndex(of: "{") {
                let selector = rest[rest.startIndex..<open].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let close = rest[rest.index(after: open)...].firstIndex(of: "}") else { break }
                let body = rest[rest.index(after: open)..<close]
                if !body.contains("{"), !selector.hasPrefix("@") {
                    rules.append(CSSRule(selector: selector, declarations: pairs(in: String(body))))
                }
                rest = rest[rest.index(after: close)...]
            }
        }
        return rules
    }

    private static func styleBodies(in html: String) -> [Substring] {
        var found: [Substring] = []
        var search = html.startIndex..<html.endIndex
        while let open = html.range(of: "<style", options: [.caseInsensitive], range: search),
              let headEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</style>", options: [.caseInsensitive],
                                     range: headEnd.upperBound..<html.endIndex) {
            found.append(html[headEnd.upperBound..<close.lowerBound])
            search = close.upperBound..<html.endIndex
        }
        return found
    }

    /// Оголошення з атрибута `style` у `<body>`.
    private static func bodyStyleAttribute(in html: String) -> [String: String] {
        guard let tag = html.range(of: "<body", options: [.caseInsensitive]),
              let end = html.range(of: ">", range: tag.upperBound..<html.endIndex) else { return [:] }
        let head = html[tag.upperBound..<end.lowerBound]
        guard let mark = head.range(of: "style", options: [.caseInsensitive]),
              let quote = head[mark.upperBound...].firstIndex(where: { $0 == "\"" || $0 == "'" }) else {
            return [:]
        }
        let mark2 = head[quote]
        guard let closing = head[head.index(after: quote)...].firstIndex(of: mark2) else { return [:] }
        var result: [String: String] = [:]
        for pair in pairs(in: String(head[head.index(after: quote)..<closing])) {
            result[pair.name] = pair.value
        }
        return result
    }

    private static func withoutComments(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "/*") {
            result += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound..<rest.endIndex) else {
                return result
            }
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    private static func pairs(in body: String) -> [(name: String, value: String)] {
        body.split(separator: ";").compactMap { piece in
            guard let colon = piece.firstIndex(of: ":") else { return nil }
            let name = piece[piece.startIndex..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = piece[piece.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix("!important") {
                value = String(value.dropLast("!important".count)).trimmingCharacters(in: .whitespaces)
            }
            guard !name.isEmpty, !value.isEmpty, !name.hasPrefix("--") else { return nil }
            return (name, value)
        }
    }

    /// Чи збігається селектор правила хоч з одним із наших.
    ///
    /// Порівнюємо за шматками, розділеними комою, і без псевдоелементів:
    /// `#content:first-line` — це все той самий `#content`.
    static func selectorMatches(_ selector: String, anyOf list: String) -> Bool {
        let wanted = Set(list.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
        for piece in selector.split(separator: ",") {
            var name = piece.trimmingCharacters(in: .whitespaces)
            if let colon = name.firstIndex(of: ":") { name = String(name[name.startIndex..<colon]) }
            if wanted.contains(name) { return true }
        }
        return false
    }

    // MARK: Значення

    struct RGBA { var r: Int; var g: Int; var b: Int; var a: Double }

    static func colour(_ raw: String) -> RGBA? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "white":       return RGBA(r: 255, g: 255, b: 255, a: 1)
        case "black":       return RGBA(r: 0, g: 0, b: 0, a: 1)
        case "transparent": return RGBA(r: 0, g: 0, b: 0, a: 0)
        default: break
        }
        if value.hasPrefix("#") {
            let digits = Array(value.dropFirst())
            func byte(_ pair: [Character]) -> Int { Int(String(pair), radix: 16) ?? 0 }
            if digits.count == 6 {
                return RGBA(r: byte(Array(digits[0...1])), g: byte(Array(digits[2...3])),
                            b: byte(Array(digits[4...5])), a: 1)
            }
            if digits.count == 3 {
                func twice(_ c: Character) -> Int { Int(String([c, c]), radix: 16) ?? 0 }
                return RGBA(r: twice(digits[0]), g: twice(digits[1]), b: twice(digits[2]), a: 1)
            }
            return nil
        }
        guard value.hasPrefix("rgb"), let open = value.firstIndex(of: "("),
              let close = value.firstIndex(of: ")") else { return nil }
        let parts = value[value.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
        let a = parts.count > 3 ? (Double(parts[3]) ?? 1) : 1
        return RGBA(r: Int(r), g: Int(g), b: Int(b), a: a)
    }

    static func hex(_ rgba: RGBA) -> String {
        String(format: "#%02x%02x%02x", min(255, max(0, rgba.r)),
               min(255, max(0, rgba.g)), min(255, max(0, rgba.b)))
    }

    /// Кегль у наших одиницях.
    ///
    /// Пікселі переводимо за кадром 1920×1080: сторінка слайда завжди на весь
    /// екран, і іншої опори в пікселя тут немає. Так напис лишається тієї самої
    /// величини на звичній роздільності і, на відміну від пікселів, тепер
    /// тягнеться разом з екраном.
    static func fontSize(_ raw: String) -> (size: String, unit: String)? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        func number(_ suffix: String) -> Double? {
            guard value.hasSuffix(suffix) else { return nil }
            return Double(value.dropLast(suffix.count).trimmingCharacters(in: .whitespaces))
        }
        if let vw = number("vw") { return (trim(vw), "1vw") }
        if let vh = number("vh") { return (trim(vh), "1vh") }
        if let px = number("px") { return (trim(px / 19.2), "1vw") }
        if let em = number("em") { return (trim(em * 16 / 19.2), "1vw") }
        if let percent = number("%") { return (trim(percent * 16 / 100 / 19.2), "1vw") }
        return nil
    }

    /// Довжина в частках екрана. Пікселі рахуємо за кадром 1920×1080.
    static func length(_ text: String, vertical: Bool) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        func number(_ suffix: String) -> Double? {
            guard value.hasSuffix(suffix) else { return nil }
            return Double(value.dropLast(suffix.count))
        }
        if let vw = number("vw") { return trim(vw) + "vw" }
        if let vh = number("vh") { return trim(vh) + "vh" }
        if let px = number("px") {
            return vertical ? trim(px / 10.8) + "vh" : trim(px / 19.2) + "vw"
        }
        return nil
    }

    static func padding(_ raw: String) -> (x: String, y: String)? {
        let parts = raw.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return nil }
        let vertical = length(parts[0], vertical: true)
        let horizontal = length(parts.count > 1 ? parts[1] : parts[0], vertical: false)
        guard let vertical, let horizontal else { return nil }
        return (horizontal, vertical)
    }

    /// `bold` і `normal` — ті самі числа, лише словами.
    static func cssWeight(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "bold":   return "700"
        case "normal": return "400"
        case "bolder": return "800"
        case "lighter": return "300"
        default:       return raw.trimmingCharacters(in: .whitespaces)
        }
    }

    static func trim(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(rounded)
    }
}
