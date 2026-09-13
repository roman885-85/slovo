import Foundation
import CoreGraphics
import ImageIO

/// Розбір презентації PowerPoint (`.pptx`) — свій, без чужих бібліотек.
///
/// Формат відкритий: ECMA-376 OOXML. Файл — це архів ZIP, усередині XML на
/// кожен слайд, на кожну розмітку і на зразок, плюс тека `ppt/media` з
/// картинками. Ми читаємо рівно те, з чого складається вигляд слайда на екрані:
/// розмір полотна, фон, картинки і написи з їхнім місцем, кеглем і кольором.
///
/// Чого тут немає — і це сказано чесно: складних заливок з переходом кольору,
/// таблиць, діаграм, тіні й об'єму, анімації всередині слайда. Для проповіді з
/// текстом на картинці цього не потрібно; якщо знадобиться — доберемо по одному,
/// а не будемо обіцяти «повну сумісність», якої не буває.
///
/// Одиниця довжини в OOXML — EMU: 914 400 на дюйм, 12 700 на пункт. Усе, що
/// приходить із файла, переводиться в частки полотна, і далі слайд малюється в
/// будь-якому розмірі: і в передпоказ, і на проектор, і в трансляцію.
public final class PPTXDocument {

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ text: String) { description = text }
    }

    /// Один слайд: фон і те, що на ньому стоїть.
    public struct Slide {
        public var background: Fill
        public var shapes: [Shape]
    }

    public enum Fill {
        case none
        case solid(CGColor)
        /// Ім'я частини архіву з картинкою — її дістає сам документ.
        case picture(String)
    }

    /// Форма фігури. У презентаціях проповідей трапляються рівно ці:
    /// прямокутник, заокруглений прямокутник, овал і лінія.
    public enum Outline: String {
        case rectangle, roundedRectangle, ellipse, line
    }

    /// Тінь — `<a:outerShdw>`: зсув і розмиття в частках висоти полотна,
    /// колір із прозорістю. Буває у фігури й картинки (своя або зі стилю
    /// теми через `effectRef`) і в тексту (своя в `rPr` або успадкована зі
    /// стилів заповнювача в розмітці чи зразку). Власник: «відсутні ефекти
    /// (немає тіней)».
    public struct Shadow {
        public var offset: CGSize
        public var blur: Double
        public var color: CGColor
    }

    /// Обрізка картинки частками її власного розміру — `<a:srcRect>`.
    /// У презентаціях так вставляють шматок фотографії, і без обрізки на слайд
    /// потрапляє вся картинка цілком, а потрібен був куток.
    public struct Crop {
        public var left, top, right, bottom: Double
        public var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
    }

    public struct Shape {
        /// Місце і розмір у частках полотна, 0…1.
        public var frame: CGRect
        public var fill: Fill
        /// Обведення: колір і товщина в частках висоти полотна. Ним у презентаціях
        /// обводять слово в тексті — без нього кружечок перетворювався на залитий
        /// прямокутник поверх рядка.
        public var strokeColor: CGColor?
        public var strokeWidth: Double
        public var outline: Outline
        public var paragraphs: [Paragraph]
        /// Поворот у градусах — у написів на фотографіях він трапляється.
        public var rotation: Double
        /// Віддзеркалення по горизонталі і по вертикалі.
        public var flipH: Bool
        public var flipV: Bool
        /// Обрізка картинки.
        public var crop: Crop
        /// Куди притиснуто текст: `top`, `center`, `bottom`. У PowerPoint за
        /// умовчанням верх — притискати все до середини означало б рухати
        /// заголовки вниз на кожному слайді.
        public var anchor: String
        /// У скільки PowerPoint сам стиснув текст (`normAutofit fontScale`).
        /// Він уже порахував це при верстці — рахувати заново означає розійтися
        /// з тим, що людина бачила, коли робила слайд.
        public var fontScale: Double
        /// Тінь самої фігури або картинки.
        public var shadow: Shadow?
        /// Тінь тексту в ній.
        public var textShadow: Shadow?
    }

    public struct Paragraph {
        public var runs: [Run]
        /// `left`, `center`, `right`, `justify`.
        public var alignment: String
        /// Відступ рівня списку, в частках ширини полотна.
        public var indent: Double
        /// Маркер списку, якщо він є.
        public var bullet: String?
    }

    public struct Run {
        public var text: String
        /// Кегль у пунктах при полотні в його власний розмір.
        public var size: Double
        public var isBold: Bool
        public var isItalic: Bool
        public var isUnderlined: Bool
        public var color: CGColor
        public var fontName: String?
    }

    // MARK: - Стан

    private let archive: ZipArchive.Reader
    /// Розмір полотна в EMU — за ним усе переводиться в частки.
    public let canvasSize: CGSize
    /// Слайди в тому порядку, в якому вони йдуть у презентації.
    public private(set) var slides: [Slide] = []
    /// Імена частин зі слайдами — потрібні для повідомлень і перевірки.
    public private(set) var slideParts: [String] = []

    public var count: Int { slides.count }

    // MARK: - Відкриття

    public init(fileAt url: URL) throws {
        do {
            archive = try ZipArchive.open(url)
        } catch {
            throw Failure(OurWords.t("не открылся архив презентации: %s", "\(error)"))
        }
        guard archive.contains("ppt/presentation.xml") else {
            throw Failure(OurWords.t("это не презентация PowerPoint — внутри нет ppt/presentation.xml"))
        }

        guard let presentationXML = try? archive.text("ppt/presentation.xml"),
              let presentation = try? XMLDocument(xmlString: presentationXML, options: Self.xmlOptions) else {
            throw Failure(OurWords.t("не разобрать ppt/presentation.xml"))
        }

        // Розмір полотна. За умовчанням 4:3 — так робить і сам PowerPoint,
        // коли розмір не записано.
        var width = 9_144_000.0, height = 6_858_000.0
        if let size = try? presentation.nodes(forXPath: "//*[local-name()='sldSz']").first as? XMLElement {
            width = Double(size.attribute(forName: "cx")?.stringValue ?? "") ?? width
            height = Double(size.attribute(forName: "cy")?.stringValue ?? "") ?? height
        }
        canvasSize = CGSize(width: width, height: height)

        let relations = Self.relations(of: "ppt/presentation.xml", in: archive)
        var parts: [String] = []
        for node in (try? presentation.nodes(forXPath: "//*[local-name()='sldId']")) ?? [] {
            guard let element = node as? XMLElement,
                  let id = element.attribute(forLocalName: "id", uri: Self.relationshipNamespace)?.stringValue
                    ?? element.attributes?.first(where: { $0.name?.hasSuffix("id") == true
                                                          && $0.name != "id" })?.stringValue,
                  let target = relations[id] else { continue }
            parts.append(Self.resolve(target, from: "ppt/presentation.xml"))
        }
        // Порядку немає — беремо всі слайди за іменами: краще показати в порядку
        // імен, ніж не показати зовсім.
        if parts.isEmpty {
            parts = archive.names
                .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { Self.slideNumber($0) < Self.slideNumber($1) }
        }
        slideParts = parts
        guard !parts.isEmpty else { throw Failure(OurWords.t("в презентации нет ни одного слайда")) }

        theme = Self.readTheme(archive)
        themeEffects = Self.readThemeEffects(archive, theme: theme)
        slides = parts.map { read(slide: $0) }
    }

    /// Кольори теми: `schemeClr` посилається на них за іменем.
    private var theme: [String: CGColor] = [:]
    /// Стилі ефектів теми — на них фігура посилається через `effectRef idx`
    /// (1…3; 0 — без ефекту).
    private var themeEffects: [Shadow?] = []

    /// Картинка частини архіву — її просить малювання.
    public func image(part: String) -> CGImage? {
        guard let bytes = try? archive.part(part), let data = bytes as CFData? else { return nil }
        guard let source = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Розбір одного слайда

    private func read(slide part: String) -> Slide {
        guard let xml = try? archive.text(part),
              let document = try? XMLDocument(xmlString: xml, options: Self.xmlOptions),
              let root = document.rootElement() else {
            return Slide(background: .none, shapes: [])
        }
        let relations = Self.relations(of: part, in: archive)

        // Розмітка і зразок: із них беруться і фон, і місце заповнювачів.
        let layoutPart = relations.values
            .first { $0.contains("slideLayout") }
            .map { Self.resolve($0, from: part) }
        let layout = layoutPart.flatMap { name -> (XMLElement, [String: String], String)? in
            guard let text = try? archive.text(name),
                  let doc = try? XMLDocument(xmlString: text, options: Self.xmlOptions),
                  let root = doc.rootElement() else { return nil }
            return (root, Self.relations(of: name, in: archive), name)
        }
        let masterPart = layout.flatMap { item in
            item.1.values.first { $0.contains("slideMaster") }.map { Self.resolve($0, from: item.2) }
        }
        let master = masterPart.flatMap { name -> (XMLElement, [String: String], String)? in
            guard let text = try? archive.text(name),
                  let doc = try? XMLDocument(xmlString: text, options: Self.xmlOptions),
                  let root = doc.rootElement() else { return nil }
            return (root, Self.relations(of: name, in: archive), name)
        }

        // Фон: свій у слайда, інакше розмітки, інакше зразка.
        let background = fill(in: root, relations: relations, from: part)
            ?? layout.flatMap { fill(in: $0.0, relations: $0.1, from: $0.2) }
            ?? master.flatMap { fill(in: $0.0, relations: $0.1, from: $0.2) }
            ?? .none

        var shapes: [Shape] = []
        // Прикраси зразка й розмітки — лінії, орнаменти, емблеми — стоять під
        // усім, що на слайді. Заповнювачі звідти не малюються: це лише місця
        // для тексту слайда. Слайд може вимкнути їх (`showMasterSp="0"`).
        let showsMaster = root.attribute(forName: "showMasterSp")?.stringValue != "0"
        if showsMaster {
            for source in [master, layout] {
                guard let source,
                      let tree = (try? source.0.nodes(forXPath: ".//*[local-name()='spTree']"))?.first as? XMLElement
                else { continue }
                collect(from: tree, into: &shapes, relations: source.1, part: source.2,
                        layout: nil, master: nil, transform: nil, decorationsOnly: true)
            }
        }
        if let tree = (try? root.nodes(forXPath: ".//*[local-name()='spTree']"))?.first as? XMLElement {
            collect(from: tree, into: &shapes, relations: relations, part: part,
                    layout: layout?.0, master: master?.0, transform: nil)
        }
        return Slide(background: background, shapes: shapes)
    }

    /// Перерахунок місця всередині групи.
    ///
    /// У групи своя система координат: `<a:chOff>` і `<a:chExt>` кажуть, у
    /// яких числах записано дітей, а `<a:off>` і `<a:ext>` — куди цю групу
    /// поставлено на слайді. Без перерахунку фігури з групи їдуть за край:
    /// їхні числа стосуються іншої сітки.
    private struct GroupTransform {
        let childOrigin: CGPoint
        let childSize: CGSize
        let placedOrigin: CGPoint
        let placedSize: CGSize

        func apply(_ box: CGRect) -> CGRect {
            let scaleX = childSize.width > 0 ? placedSize.width / childSize.width : 1
            let scaleY = childSize.height > 0 ? placedSize.height / childSize.height : 1
            return CGRect(x: placedOrigin.x + (box.minX - childOrigin.x) * scaleX,
                          y: placedOrigin.y + (box.minY - childOrigin.y) * scaleY,
                          width: box.width * scaleX,
                          height: box.height * scaleY)
        }
    }

    /// `decorationsOnly` — зі зразка чи розмітки: беремо лише те, що не є
    /// заповнювачем.
    private func collect(from tree: XMLElement, into shapes: inout [Shape],
                         relations: [String: String], part: String,
                         layout: XMLElement?, master: XMLElement?,
                         transform: GroupTransform?, decorationsOnly: Bool = false) {
        for child in tree.children ?? [] {
            guard let element = child as? XMLElement, let name = element.name else { continue }
            let local = name.contains(":") ? String(name.split(separator: ":").last!) : name
            // Схована фігура (`<p:cNvPr hidden="1"/>`) у PowerPoint не показується.
            if Self.attribute(element, path: ".//*[local-name()='cNvPr']", name: "hidden") == "1" { continue }
            if decorationsOnly, local != "grpSp", Self.placeholder(of: element) != nil { continue }
            switch local {
            case "sp", "pic", "cxnSp":
                if var shape = read(shape: element, relations: relations, part: part,
                                    layout: layout, master: master) {
                    if let transform {
                        // Місце фігури вже переведено в частки полотна — повернемо
                        // його в EMU, перерахуємо і переведемо назад.
                        let emu = CGRect(x: shape.frame.minX * canvasSize.width,
                                         y: shape.frame.minY * canvasSize.height,
                                         width: shape.frame.width * canvasSize.width,
                                         height: shape.frame.height * canvasSize.height)
                        let moved = transform.apply(emu)
                        shape.frame = CGRect(x: moved.minX / canvasSize.width,
                                             y: moved.minY / canvasSize.height,
                                             width: moved.width / canvasSize.width,
                                             height: moved.height / canvasSize.height)
                    }
                    shapes.append(shape)
                }
            case "grpSp":
                var inner = transform
                if let xfrm = (try? element.nodes(forXPath: "./*[local-name()='grpSpPr']/*[local-name()='xfrm']"))?
                    .first as? XMLElement,
                   let off = (try? xfrm.nodes(forXPath: "./*[local-name()='off']"))?.first as? XMLElement,
                   let ext = (try? xfrm.nodes(forXPath: "./*[local-name()='ext']"))?.first as? XMLElement,
                   let chOff = (try? xfrm.nodes(forXPath: "./*[local-name()='chOff']"))?.first as? XMLElement,
                   let chExt = (try? xfrm.nodes(forXPath: "./*[local-name()='chExt']"))?.first as? XMLElement {
                    func value(_ node: XMLElement, _ key: String) -> Double {
                        Double(node.attribute(forName: key)?.stringValue ?? "") ?? 0
                    }
                    var placed = CGRect(x: value(off, "x"), y: value(off, "y"),
                                        width: value(ext, "cx"), height: value(ext, "cy"))
                    if let transform { placed = transform.apply(placed) }
                    inner = GroupTransform(
                        childOrigin: CGPoint(x: value(chOff, "x"), y: value(chOff, "y")),
                        childSize: CGSize(width: value(chExt, "cx"), height: value(chExt, "cy")),
                        placedOrigin: placed.origin,
                        placedSize: placed.size)
                }
                collect(from: element, into: &shapes, relations: relations, part: part,
                        layout: layout, master: master, transform: inner, decorationsOnly: decorationsOnly)
            default:
                continue
            }
        }
    }

    private func read(shape element: XMLElement,
                      relations: [String: String],
                      part: String,
                      layout: XMLElement?,
                      master: XMLElement?) -> Shape? {
        // Місце: своє, а в заповнювача — з розмітки або зразка.
        var box = Self.frame(in: element)
        if box == nil, let placeholder = Self.placeholder(of: element) {
            box = Self.placeholderFrame(placeholder, in: layout) ?? Self.placeholderFrame(placeholder, in: master)
        }
        guard let box else { return nil }

        let rect = CGRect(x: box.minX / canvasSize.width, y: box.minY / canvasSize.height,
                          width: box.width / canvasSize.width, height: box.height / canvasSize.height)
        guard rect.width > 0, rect.height > 0 else { return nil }

        // Властивості фігури. Заливку і обведення беремо ЛИШЕ звідси і лише
        // прямими дітьми: колір обведення лежить усередині `<a:ln>`, і пошук «десь
        // усередині» фарбував ним усю фігуру — кружечок навколо слова перетворювався на
        // залитий прямокутник поверх рядка.
        let properties = (try? element.nodes(forXPath: "./*[local-name()='spPr']"))?
            .first as? XMLElement

        var shapeFill = Fill.none
        if let blip = (try? element.nodes(forXPath: ".//*[local-name()='blipFill']/*[local-name()='blip']"))?
            .first as? XMLElement,
           let id = Self.embedID(of: blip), let target = relations[id] {
            shapeFill = .picture(Self.resolve(target, from: part))
        } else if let properties, Self.hasDirect(properties, name: "noFill") {
            shapeFill = .none
        } else if let properties, let solid = Self.directColor(in: properties, theme: theme) {
            shapeFill = .solid(solid)
        }

        var strokeColor: CGColor?
        var strokeWidth = 0.0
        if let line = (try? properties?.nodes(forXPath: "./*[local-name()='ln']"))?
            .flatMap({ $0.first as? XMLElement }), !Self.hasDirect(line, name: "noFill") {
            strokeColor = Self.directColor(in: line, theme: theme)
            // Товщина в EMU; нуль означає «тонка лінія», а не «немає лінії».
            let emu = Double(line.attribute(forName: "w")?.stringValue ?? "") ?? 9525
            strokeWidth = emu / canvasSize.height
            if strokeColor == nil { strokeWidth = 0 }
        }

        let shape: Outline
        switch Self.attribute(element, path: "./*[local-name()='spPr']/*[local-name()='prstGeom']",
                              name: "prst") ?? "rect" {
        case "ellipse", "circle":       shape = .ellipse
        case "roundRect":               shape = .roundedRectangle
        case "line", "straightConnector1": shape = .line
        default:                        shape = .rectangle
        }

        let xfrm = (try? element.nodes(forXPath: ".//*[local-name()='xfrm']"))?.first as? XMLElement
        let rotation = Double(xfrm?.attribute(forName: "rot")?.stringValue ?? "0").map { $0 / 60_000 } ?? 0
        let flipH = xfrm?.attribute(forName: "flipH")?.stringValue == "1"
        let flipV = xfrm?.attribute(forName: "flipV")?.stringValue == "1"

        var crop = Crop(left: 0, top: 0, right: 0, bottom: 0)
        if let source = (try? element.nodes(forXPath: ".//*[local-name()='srcRect']"))?
            .first as? XMLElement {
            func part(_ name: String) -> Double {
                (Double(source.attribute(forName: name)?.stringValue ?? "") ?? 0) / 100_000
            }
            crop = Crop(left: part("l"), top: part("t"), right: part("r"), bottom: part("b"))
        }

        let body = (try? element.nodes(forXPath: ".//*[local-name()='bodyPr']"))?.first as? XMLElement
        let anchor: String
        switch body?.attribute(forName: "anchor")?.stringValue {
        case "ctr": anchor = "center"
        case "b":   anchor = "bottom"
        default:    anchor = "top"
        }
        // PowerPoint уже порахував, у скільки стиснути текст, щоб він уліз, —
        // беремо його число, а не своє: людина бачила саме такий слайд.
        let autofit = (try? body?.nodes(forXPath: "./*[local-name()='normAutofit']"))?
            .flatMap { $0.first as? XMLElement }
        let scale = Double(autofit?.attribute(forName: "fontScale")?.stringValue ?? "")
            .map { $0 / 100_000 } ?? 1

        // Тінь фігури: своя в `spPr/effectLst`, інакше зі стилю теми.
        var shadow: Shadow?
        if let properties, let own = (try? properties.nodes(forXPath: "./*[local-name()='effectLst']"))?.first as? XMLElement {
            shadow = Self.shadow(in: own, theme: theme)
        } else if let index = Self.attribute(element, path: "./*[local-name()='style']/*[local-name()='effectRef']", name: "idx")
                    .flatMap(Int.init), index >= 1, themeEffects.indices.contains(index - 1) {
            shadow = themeEffects[index - 1]
        }

        return Shape(frame: rect, fill: shapeFill,
                     strokeColor: strokeColor, strokeWidth: strokeWidth,
                     outline: shape,
                     paragraphs: paragraphs(in: element),
                     rotation: rotation,
                     flipH: flipH, flipV: flipV,
                     crop: crop, anchor: anchor,
                     fontScale: max(0.1, min(1, scale)),
                     shadow: shadow,
                     textShadow: textShadow(of: element, layout: layout, master: master))
    }

    // MARK: - Тіні

    /// Тінь тексту фігури.
    ///
    /// Своя — у `rPr` будь-якого шматка або в `defRPr` абзацу чи `lstStyle`
    /// напису. Далі — успадкована: заповнювач розмітки з тим самим типом чи
    /// номером, заповнювач зразка, і нарешті загальні стилі тексту зразка
    /// (`titleStyle`, `bodyStyle`). Саме там у більшості шаблонів і лежить
    /// тінь заголовка.
    private func textShadow(of element: XMLElement, layout: XMLElement?, master: XMLElement?) -> Shadow? {
        if let body = (try? element.nodes(forXPath: "./*[local-name()='txBody']"))?.first as? XMLElement,
           let found = Self.firstShadow(under: body, theme: theme) {
            return found
        }
        guard let wanted = Self.placeholder(of: element) else { return nil }
        for root in [layout, master] {
            guard let root, let twin = Self.placeholderElement(wanted, in: root),
                  let body = (try? twin.nodes(forXPath: "./*[local-name()='txBody']"))?.first as? XMLElement
            else { continue }
            if let found = Self.firstShadow(under: body, theme: theme) { return found }
        }
        guard let master else { return nil }
        let styleName: String
        switch wanted.type {
        case "title", "ctrTitle": styleName = "titleStyle"
        case "body", "subTitle", "obj": styleName = "bodyStyle"
        default: styleName = "otherStyle"
        }
        if let styles = (try? master.nodes(forXPath: ".//*[local-name()='txStyles']/*[local-name()='\(styleName)']"))?
            .first as? XMLElement {
            return Self.firstShadow(under: styles, theme: theme)
        }
        return nil
    }

    private static func firstShadow(under root: XMLElement, theme: [String: CGColor]) -> Shadow? {
        guard let list = (try? root.nodes(forXPath: ".//*[local-name()='effectLst']"))?.first as? XMLElement
        else { return nil }
        return shadow(in: list, theme: theme)
    }

    /// Заповнювач розмітки або зразка з тим самим номером чи типом.
    private static func placeholderElement(_ wanted: (type: String, index: String),
                                           in root: XMLElement) -> XMLElement? {
        var byType: XMLElement?
        for node in (try? root.nodes(forXPath: ".//*[local-name()='sp']")) ?? [] {
            guard let shape = node as? XMLElement, let found = placeholder(of: shape) else { continue }
            if !wanted.index.isEmpty, found.index == wanted.index { return shape }
            if byType == nil, found.type == wanted.type { byType = shape }
        }
        return byType
    }

    /// `<a:effectLst>` → тінь, якщо в ньому є `<a:outerShdw>`.
    private static func shadow(in list: XMLElement, theme: [String: CGColor]) -> Shadow? {
        guard let outer = (try? list.nodes(forXPath: "./*[local-name()='outerShdw']"))?.first as? XMLElement
        else { return nil }
        func number(_ name: String, _ fallback: Double) -> Double {
            Double(outer.attribute(forName: name)?.stringValue ?? "") ?? fallback
        }
        // Відстань і розмиття — в EMU; кут — у 60 000-х градуса, за стрілкою
        // годинника від напрямку «вправо» (90° — униз).
        let distance = number("dist", 0), blur = number("blurRad", 0)
        let angle = number("dir", 5_400_000) / 60_000 * Double.pi / 180
        // Висота полотна в EMU: слайд PowerPoint — 6 858 000 EMU (7,5 дюйма).
        let unit = 6_858_000.0
        var color = CGColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        if let base = self.color(of: outer, theme: theme) {
            var alpha = 1.0
            if let node = (try? outer.nodes(forXPath: ".//*[local-name()='alpha']"))?.first as? XMLElement,
               let value = Double(node.attribute(forName: "val")?.stringValue ?? "") {
                alpha = value / 100_000
            }
            color = base.copy(alpha: alpha) ?? base
        }
        return Shadow(offset: CGSize(width: cos(angle) * distance / unit, height: sin(angle) * distance / unit),
                      blur: blur / unit, color: color)
    }

    private static func readThemeEffects(_ archive: ZipArchive.Reader, theme: [String: CGColor]) -> [Shadow?] {
        guard let part = archive.names.first(where: { $0.hasPrefix("ppt/theme/") && $0.hasSuffix(".xml") }),
              let xml = try? archive.text(part),
              let document = try? XMLDocument(xmlString: xml, options: xmlOptions),
              let root = document.rootElement(),
              let list = (try? root.nodes(forXPath: ".//*[local-name()='effectStyleLst']"))?.first as? XMLElement
        else { return [] }
        return ((try? list.nodes(forXPath: "./*[local-name()='effectStyle']")) ?? []).map { node in
            guard let style = node as? XMLElement,
                  let effects = (try? style.nodes(forXPath: "./*[local-name()='effectLst']"))?.first as? XMLElement
            else { return nil }
            return shadow(in: effects, theme: theme)
        }
    }

    private func paragraphs(in element: XMLElement) -> [Paragraph] {
        var result: [Paragraph] = []
        for node in (try? element.nodes(forXPath: ".//*[local-name()='txBody']/*[local-name()='p']")) ?? [] {
            guard let paragraph = node as? XMLElement else { continue }
            let properties = (try? paragraph.nodes(forXPath: "./*[local-name()='pPr']"))?
                .first as? XMLElement
            let alignment: String
            switch properties?.attribute(forName: "algn")?.stringValue {
            case "ctr":  alignment = "center"
            case "r":    alignment = "right"
            case "just": alignment = "justify"
            default:     alignment = "left"
            }
            let level = Double(properties?.attribute(forName: "lvl")?.stringValue ?? "0") ?? 0
            let bullet = (try? properties?.nodes(forXPath: "./*[local-name()='buChar']"))?
                .flatMap { $0.first as? XMLElement }?
                .attribute(forName: "char")?.stringValue

            var runs: [Run] = []
            // Діти абзацу по порядку: шматки тексту `r`, поля `fld` (номер слайда,
            // дата) і розриви рядка `br`. Доти бралися лише `r`: поле пропадало,
            // а текст після розриву приклеювався до попереднього рядка.
            for item in (try? paragraph.nodes(forXPath: "./*[local-name()='r' or local-name()='fld' or local-name()='br']")) ?? [] {
                guard let run = item as? XMLElement else { continue }
                let local = (run.name ?? "").split(separator: ":").last.map(String.init) ?? ""
                let text: String
                if local == "br" {
                    text = "\n"
                } else {
                    guard let node = (try? run.nodes(forXPath: "./*[local-name()='t']"))?
                        .first as? XMLElement else { continue }
                    text = Self.text(of: node)
                }
                let style = (try? run.nodes(forXPath: "./*[local-name()='rPr']"))?.first as? XMLElement
                let size = Double(style?.attribute(forName: "sz")?.stringValue ?? "") ?? 1800
                runs.append(Run(text: text,
                                size: size / 100,
                                isBold: style?.attribute(forName: "b")?.stringValue == "1",
                                isItalic: style?.attribute(forName: "i")?.stringValue == "1",
                                isUnderlined: (style?.attribute(forName: "u")?.stringValue ?? "none") != "none",
                                color: style.flatMap { Self.solidColor(in: $0, theme: theme) }
                                    ?? CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                                fontName: Self.fontName(in: style)))
            }
            // Порожній абзац — це порожній рядок між блоками тексту, і він
            // тримає вигляд слайда: викидати його не можна.
            result.append(Paragraph(runs: runs, alignment: alignment,
                                    indent: level * 0.03, bullet: bullet))
        }
        // Абзаци в кінці без жодного слова нічого не тримають — вони лише
        // розтягують блок і збивають добір кегля.
        while let last = result.last, last.runs.isEmpty { result.removeLast() }
        return result
    }

    // MARK: - Дрібниці розбору

    private static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// Текст шматка рядка — із сирого XML, а не зі `stringValue`.
    ///
    /// `XMLDocument` віддає для `<a:t> </a:t>` порожній рядок: одиночний
    /// пробіл він вважає «незначущим» і викидає, і жодні
    /// `nodePreserveWhitespace` цього не міняють — перевірено. А в презентації
    /// пробіл між словами часто стоїть окремим шматком, бо в нього
    /// другое начертание. Из-за этого выходило «розсіялисяпо околицях».
    private static func text(of node: XMLElement) -> String {
        let raw = node.xmlString
        guard let open = raw.firstIndex(of: ">"), let close = raw.lastIndex(of: "<"),
              open < close else { return node.stringValue ?? "" }
        return HTMLText.decodeEntities(String(raw[raw.index(after: open)..<close]))
    }

    /// Пробіли зберігаємо. Без цього XMLDocument «прибирає» їх, і сусідні
    /// куски строки слипаются: «розсіялисяпо околицях» вместо «розсіялися по
    /// околицях». У презентації пробіл часто стоїть окремим шматком, бо
    /// в нього інше накреслення.
    private static let xmlOptions: XMLNode.Options = [.nodePreserveWhitespace,
                                                      .nodeLoadExternalEntitiesNever]

    /// Зв'язки частини: `rId7` → куди він веде.
    private static func relations(of part: String, in archive: ZipArchive.Reader) -> [String: String] {
        let folder = (part as NSString).deletingLastPathComponent
        let name = (part as NSString).lastPathComponent
        let path = folder.isEmpty ? "_rels/\(name).rels" : "\(folder)/_rels/\(name).rels"
        guard let text = try? archive.text(path),
              let document = try? XMLDocument(xmlString: text, options: Self.xmlOptions) else { return [:] }
        var result: [String: String] = [:]
        for node in (try? document.nodes(forXPath: "//*[local-name()='Relationship']")) ?? [] {
            guard let element = node as? XMLElement,
                  let id = element.attribute(forName: "Id")?.stringValue,
                  let target = element.attribute(forName: "Target")?.stringValue else { continue }
            result[id] = target
        }
        return result
    }

    /// Шлях зв'язку — відносний. Зводимо його до імені частини архіву.
    private static func resolve(_ target: String, from part: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var pieces = (part as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            if piece == ".." { if !pieces.isEmpty { pieces.removeLast() } }
            else if piece != "." { pieces.append(String(piece)) }
        }
        return pieces.joined(separator: "/")
    }

    private static func slideNumber(_ name: String) -> Int {
        let digits = name.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private static func embedID(of blip: XMLElement) -> String? {
        if let value = blip.attribute(forLocalName: "embed", uri: relationshipNamespace)?.stringValue {
            return value
        }
        return blip.attributes?.first { $0.name?.hasSuffix(":embed") == true }?.stringValue
    }

    private static func attribute(_ element: XMLElement, path: String, name: String) -> String? {
        ((try? element.nodes(forXPath: path))?.first as? XMLElement)?
            .attribute(forName: name)?.stringValue
    }

    /// Місце фігури: `<a:off>` і `<a:ext>` в EMU.
    private static func frame(in element: XMLElement) -> CGRect? {
        guard let xfrm = (try? element.nodes(forXPath: ".//*[local-name()='xfrm']"))?.first as? XMLElement,
              let off = (try? xfrm.nodes(forXPath: "./*[local-name()='off']"))?.first as? XMLElement,
              let ext = (try? xfrm.nodes(forXPath: "./*[local-name()='ext']"))?.first as? XMLElement,
              let x = Double(off.attribute(forName: "x")?.stringValue ?? ""),
              let y = Double(off.attribute(forName: "y")?.stringValue ?? ""),
              let cx = Double(ext.attribute(forName: "cx")?.stringValue ?? ""),
              let cy = Double(ext.attribute(forName: "cy")?.stringValue ?? "") else { return nil }
        return CGRect(x: x, y: y, width: cx, height: cy)
    }

    /// Заповнювач: його місце записано не в слайді, а в розмітці або зразку.
    private static func placeholder(of element: XMLElement) -> (type: String, index: String)? {
        guard let ph = (try? element.nodes(forXPath: ".//*[local-name()='ph']"))?.first as? XMLElement
        else { return nil }
        return (ph.attribute(forName: "type")?.stringValue ?? "body",
                ph.attribute(forName: "idx")?.stringValue ?? "")
    }

    private static func placeholderFrame(_ wanted: (type: String, index: String),
                                         in root: XMLElement?) -> CGRect? {
        guard let root else { return nil }
        for node in (try? root.nodes(forXPath: ".//*[local-name()='sp']")) ?? [] {
            guard let shape = node as? XMLElement, let found = placeholder(of: shape) else { continue }
            let sameIndex = !wanted.index.isEmpty && found.index == wanted.index
            let sameType = found.type == wanted.type
            guard sameIndex || sameType else { continue }
            if let box = frame(in: shape) { return box }
        }
        return nil
    }

    private static func fontName(in style: XMLElement?) -> String? {
        guard let style else { return nil }
        for path in ["./*[local-name()='latin']", "./*[local-name()='cs']"] {
            if let font = (try? style.nodes(forXPath: path))?.first as? XMLElement,
               let name = font.attribute(forName: "typeface")?.stringValue, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    /// Чи є в елемента такий прямий нащадок — наприклад `<a:noFill/>`.
    private static func hasDirect(_ element: XMLElement, name: String) -> Bool {
        ((try? element.nodes(forXPath: "./*[local-name()='\(name)']")) ?? []).isEmpty == false
    }

    /// Суцільний колір ПРЯМОГО нащадка — заливка самого елемента, а не того,
    /// що лежить у нього всередині.
    private static func directColor(in element: XMLElement, theme: [String: CGColor]) -> CGColor? {
        guard let solid = (try? element.nodes(forXPath: "./*[local-name()='solidFill']"))?
                .first as? XMLElement else { return nil }
        return color(of: solid, theme: theme)
    }

    /// Суцільний колір: свій шістнадцятковий або посилання на колір теми.
    private static func solidColor(in element: XMLElement, theme: [String: CGColor]) -> CGColor? {
        guard let solid = (try? element.nodes(forXPath: ".//*[local-name()='solidFill']"))?
                .first as? XMLElement else { return nil }
        return color(of: solid, theme: theme)
    }

    private static func color(of solid: XMLElement, theme: [String: CGColor]) -> CGColor? {
        if let own = (try? solid.nodes(forXPath: "./*[local-name()='srgbClr']"))?.first as? XMLElement,
           let hex = own.attribute(forName: "val")?.stringValue {
            return color(hex: hex)
        }
        if let scheme = (try? solid.nodes(forXPath: "./*[local-name()='schemeClr']"))?.first as? XMLElement,
           let name = scheme.attribute(forName: "val")?.stringValue {
            return theme[name] ?? defaultScheme(name)
        }
        return nil
    }

    private static func color(hex: String) -> CGColor? {
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value), hex.count >= 6 else { return nil }
        return CGColor(red: Double((value >> 16) & 0xFF) / 255,
                       green: Double((value >> 8) & 0xFF) / 255,
                       blue: Double(value & 0xFF) / 255, alpha: 1)
    }

    /// Якщо теми немає, кольори все одно мають бути осмисленими: текст темний,
    /// фон світлий. Порожній слайд краще показати чорним по білому, ніж ніяк.
    private static func defaultScheme(_ name: String) -> CGColor? {
        switch name {
        case "bg1", "lt1", "background1": return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        case "tx1", "dk1", "text1":       return CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        case "bg2", "lt2":                return CGColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1)
        case "tx2", "dk2":                return CGColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1)
        default:                           return nil
        }
    }

    private static func readTheme(_ archive: ZipArchive.Reader) -> [String: CGColor] {
        let part = archive.names.first { $0.hasPrefix("ppt/theme/") && $0.hasSuffix(".xml") }
        guard let part, let text = try? archive.text(part),
              let document = try? XMLDocument(xmlString: text, options: Self.xmlOptions) else { return [:] }
        var result: [String: CGColor] = [:]
        for node in (try? document.nodes(forXPath: "//*[local-name()='clrScheme']/*")) ?? [] {
            guard let element = node as? XMLElement, let key = element.name else { continue }
            let short = key.contains(":") ? String(key.split(separator: ":").last!) : key
            if let own = (try? element.nodes(forXPath: "./*[local-name()='srgbClr']"))?.first as? XMLElement,
               let hex = own.attribute(forName: "val")?.stringValue, let value = color(hex: hex) {
                result[short] = value
            } else if let system = (try? element.nodes(forXPath: "./*[local-name()='sysClr']"))?
                        .first as? XMLElement,
                      let hex = system.attribute(forName: "lastClr")?.stringValue,
                      let value = color(hex: hex) {
                result[short] = value
            }
        }
        // Імена кольорів теми та імена в посиланнях розходяться: у темі «lt1», у
        // посиланні «bg1». Розводимо їх тут, а не в кожному місці розбору.
        for (from, to) in [("lt1", "bg1"), ("dk1", "tx1"), ("lt2", "bg2"), ("dk2", "tx2")] {
            if result[to] == nil, let value = result[from] { result[to] = value }
        }
        return result
    }

    /// Фон частини: слайда, розмітки або зразка.
    private func fill(in root: XMLElement, relations: [String: String], from part: String) -> Fill? {
        guard let background = (try? root.nodes(forXPath: ".//*[local-name()='bg']"))?
                .first as? XMLElement else { return nil }
        if let blip = (try? background.nodes(forXPath: ".//*[local-name()='blip']"))?.first as? XMLElement,
           let id = Self.embedID(of: blip), let target = relations[id] {
            return .picture(Self.resolve(target, from: part))
        }
        if let solid = Self.solidColor(in: background, theme: theme) { return .solid(solid) }
        // `<p:bgRef idx="1002"><a:schemeClr val="bg2"/>` — посилання на стиль фону
        // теми з кольором, який у той стиль підставляється. Стилі теми — це
        // здебільшого той самий колір із ледь помітним відтінком, тому беремо
        // колір як є. Доти такий фон лишався білим, хоч у PowerPoint слайд
        // кремовий.
        if let reference = (try? background.nodes(forXPath: "./*[local-name()='bgRef']"))?.first as? XMLElement,
           let solid = Self.color(of: reference, theme: theme) {
            return .solid(solid)
        }
        return nil
    }
}
