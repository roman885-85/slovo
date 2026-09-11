import Foundation

/// Чтение шаблона слайда `.sch`.
///
/// Формат — XML без объявления кодировки: `VisioBibleScheme` → `Scheme` →
/// список `Object`, у каждого свои `FXPresets` с парой `Scene` (по кадру на
/// вариант слайда). Разбор нарочно нестрогий: неизвестные атрибуты и целые
/// незнакомые узлы не мешают — всё, что не разобрано в поля, остаётся в
/// `attributes`, а чего нет вовсе, подставляется значением по умолчанию.
/// Пользователь мог сохранить свой шаблон в любой сборке оригинала, и падать
/// из-за лишнего атрибута нам нельзя.
public enum SchemeParser {

    public enum Failure: Error, LocalizedError {
        case unreadable(URL)
        case malformed(String)
        case noScheme

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url): return "Не удалось прочитать шаблон \(url.lastPathComponent)"
            case .malformed(let text): return OurWords.t("Шаблон разобрать не удалось: %s", "\(text)")
            case .noScheme:            return OurWords.t("В файле нет узла Scheme")
            }
        }
    }

    public static func scheme(contentsOf url: URL) throws -> SlideScheme {
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(url) }
        return try scheme(data: data, fallbackName: url.deletingPathExtension().lastPathComponent)
    }

    /// `fallbackName` идёт в дело, если в файле нет атрибута `Name`.
    public static func scheme(data: Data, fallbackName: String = "") throws -> SlideScheme {
        // Кодировка не объявлена: свежие файлы UTF-8, старые могли быть в
        // CP1251 — там кириллица в именах объектов и в имени фона.
        let declared: String.Encoding? = String(data: data, encoding: .utf8) != nil ? .utf8 : nil
        let text = CodePage.decode(data, declared: declared)

        let collector = Collector(fallbackName: fallbackName)
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = collector
        guard parser.parse() else {
            throw Failure.malformed(parser.parserError?.localizedDescription ?? "неизвестная ошибка XML")
        }
        guard let scheme = collector.finish() else { throw Failure.noScheme }
        return scheme
    }

    // MARK: - Разбор значений

    /// Delphi пишет дробные с запятой и иногда в научной записи
    /// (`-3,66568565368652E-6`); на английской локали была бы точка.
    static func number(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    static func flag(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes":  return true
        case "false", "0", "no":  return false
        default:                  return nil
        }
    }

    /// `TColor` — `0x00BBGGRR`. Отрицательные значения в Delphi это системные
    /// цвета вроде `clWindowText`; их брать неоткуда, отдаём nil.
    static func color(_ raw: String?) -> SlideStyle.RGBA? {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        return SlideStyle.RGBA(Double(value & 0xFF) / 255,
                               Double((value >> 8) & 0xFF) / 255,
                               Double((value >> 16) & 0xFF) / 255)
    }

    /// Атрибуты узла с поиском без учёта регистра.
    struct Attributes {
        let raw: [String: String]
        private let index: [String: String]

        init(_ raw: [String: String]) {
            self.raw = raw
            var index: [String: String] = [:]
            for (key, value) in raw { index[key.lowercased()] = value }
            self.index = index
        }

        func string(_ key: String) -> String? { index[key.lowercased()] }
        func number(_ key: String) -> Double? { SchemeParser.number(string(key)) }
        func flag(_ key: String) -> Bool? { SchemeParser.flag(string(key)) }
        func color(_ key: String) -> SlideStyle.RGBA? { SchemeParser.color(string(key)) }
    }
}

// MARK: - Обход дерева

private final class Collector: NSObject, XMLParserDelegate {

    private let fallbackName: String

    private var schemeAttributes: SchemeParser.Attributes?
    private var presetNames: [String] = []
    private var elements: [SlideScheme.Element] = []

    // Открытые узлы: `FXPreset` встречается и в списке пресетов схемы,
    // и внутри объекта — различаем по тому, начат ли объект.
    private var inPresetList = false
    private var elementAttributes: SchemeParser.Attributes?
    private var elementPresets: [SlideScheme.FXPreset] = []
    private var openPreset: SlideScheme.FXPreset?

    init(fallbackName: String) {
        self.fallbackName = fallbackName
    }

    func finish() -> SlideScheme? {
        guard let attributes = schemeAttributes else { return nil }
        return SlideScheme(name: attributes.string("Name") ?? fallbackName,
                           backgroundImageName: attributes.string("BackImg") ?? "",
                           outlineEnabled: attributes.flag("QuoteOutLineEnable") ?? false,
                           outlineWidth: attributes.number("QuoteOutLineWidth") ?? 0,
                           outlineColor: attributes.color("QuoteOutLineColor") ?? .black,
                           shadowEnabled: attributes.flag("QuoteShadowEnabled") ?? false,
                           shadowOffset: attributes.number("QuoteShadowOffset") ?? 0,
                           shadowBlur: attributes.number("QuoteShadowBlur") ?? 0,
                           shadowOpacity: (attributes.number("QuoteShadowOpacity") ?? 0) / 255,
                           shadowColor: attributes.color("QuoteShadowColor") ?? .black,
                           presetNames: presetNames,
                           elements: elements,
                           attributes: attributes.raw)
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?,
                attributes attributeDict: [String: String]) {
        let attributes = SchemeParser.Attributes(attributeDict)

        switch elementName.lowercased() {
        case "scheme":
            schemeAttributes = attributes

        case "fxpresetslist":
            inPresetList = true

        case "fxpreset":
            if inPresetList {
                presetNames.append(attributes.string("Name") ?? "Fx\(presetNames.count + 1)")
            } else if elementAttributes != nil {
                let name = presetNames.indices.contains(elementPresets.count)
                    ? presetNames[elementPresets.count]
                    : "Fx\(elementPresets.count + 1)"
                openPreset = SlideScheme.FXPreset(name: name,
                                                  hasVariantParameters: attributes.flag("EnableFxParamsVariant") ?? false)
            }

        case "object":
            elementAttributes = attributes
            elementPresets = []
            openPreset = nil

        case "scene":
            guard openPreset != nil else { break }
            openPreset?.scenes.append(scene(from: attributes))

        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName: String?) {
        switch elementName.lowercased() {
        case "fxpresetslist":
            inPresetList = false

        case "fxpreset":
            if let preset = openPreset {
                elementPresets.append(preset)
                openPreset = nil
            }

        case "object":
            if let attributes = elementAttributes {
                elements.append(element(from: attributes, presets: elementPresets))
            }
            elementAttributes = nil
            elementPresets = []

        default:
            break
        }
    }

    // MARK: - Сборка моделей

    private func element(from attributes: SchemeParser.Attributes,
                         presets: [SlideScheme.FXPreset]) -> SlideScheme.Element {
        let image = attributes.string("Image").flatMap { $0.isEmpty ? nil : $0 }
        let mask = attributes.string("ImageMask").flatMap { $0.isEmpty ? nil : $0 }
        let rawType = attributes.string("Type").flatMap { Int($0) } ?? -1

        // Второй вариант может быть не описан вовсе — тогда он повторяет первый,
        // а не схлопывается в пустую рамку по умолчанию.
        let primary = placement(from: attributes, suffix: "")
        let dual = attributes.string("Width_2") == nil ? primary : placement(from: attributes, suffix: "_2")

        return SlideScheme.Element(
            name: attributes.string("Name") ?? "",
            rawType: rawType,
            imageName: image,
            imageMaskName: mask,
            textColor: attributes.color("TextColor"),
            hasVariantParameters: attributes.flag("EnableParamsVariant") ?? false,
            placements: [primary, dual],
            presets: presets,
            attributes: attributes.raw)
    }

    /// Второй вариант слайда записан теми же ключами с хвостом `_2`.
    private func placement(from attributes: SchemeParser.Attributes, suffix: String) -> SlideScheme.Placement {
        func value(_ key: String) -> Double? { attributes.number(key + suffix) }

        return SlideScheme.Placement(
            width: value("Width") ?? 100,
            height: value("Height") ?? 100,
            indentX: value("IndentionX") ?? 0,
            indentY: value("IndentionY") ?? 0,
            anchor: SlideScheme.Anchor(rawValue: Int(value("Align") ?? 0)),
            opacity: (value("Opacity") ?? 255) / 255,
            isEnabled: attributes.flag("Enabled" + suffix) ?? true,
            shadowOffset: value("ShadowOffsetPerc") ?? 0,
            shadowBlur: value("ShadowBlurPerc") ?? 0,
            shadowOpacity: (value("ShadowOpacity") ?? 0) / 255,
            shadowColor: attributes.color("ShadowColor" + suffix) ?? .black,
            textAlignment: value("Alignment").flatMap { SlideScheme.TextAlignment(rawValue: Int($0)) },
            textLayout: value("Layout").flatMap { SlideScheme.TextLayout(rawValue: Int($0)) })
    }

    private func scene(from attributes: SchemeParser.Attributes) -> SlideScheme.Scene {
        SlideScheme.Scene(fx: attributes.string("FX").flatMap { Int($0) } ?? 0,
                          isAnimated: attributes.flag("Animation") ?? false,
                          fromOpacity: (attributes.number("FromOpacity") ?? 255) / 255,
                          fromScale: (attributes.number("FromScale") ?? 0) / 100,
                          moveFromX: attributes.number("MoveFromX") ?? 0,
                          moveFromY: attributes.number("MoveFromY") ?? 0,
                          delay: (attributes.number("Delay") ?? 0) / 1000,
                          duration: (attributes.number("TimeLength") ?? 0) / 1000)
    }
}
