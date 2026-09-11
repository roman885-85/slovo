import AppKit

/// Готовые шрифты и стили абзаца списка.
///
/// Собираются один раз на список и живут, пока не сменится кегль. Строить их
/// на каждую строку — значит платить за словарь атрибутов двадцать раз на
/// кадр и столько же раз искать шрифт в системе.
final class NativeListStyle {

    private(set) var fontSize: CGFloat
    private(set) var metrics: NativeListMetrics

    private(set) var leadFont: NSFont
    private(set) var textFont: NSFont
    private(set) var boldTextFont: NSFont
    private(set) var detailFont: NSFont

    /// Стиль абзаца для многострочного текста и для однострочного с обрезкой.
    let wrapping = NSMutableParagraphStyle()
    let clipping = NSMutableParagraphStyle()
    let leadStyle = NSMutableParagraphStyle()
    let centered = NSMutableParagraphStyle()

    init(fontSize: CGFloat, metrics: NativeListMetrics) {
        self.fontSize = fontSize
        self.metrics = metrics
        leadFont = NativeListStyle.rounded(size: max(7, fontSize + metrics.leadFontDelta), weight: .semibold)
        textFont = .systemFont(ofSize: max(7, fontSize + metrics.textFontDelta))
        boldTextFont = .systemFont(ofSize: max(7, fontSize + metrics.textFontDelta), weight: .semibold)
        detailFont = .systemFont(ofSize: max(7, fontSize + metrics.detailFontDelta))
        wrapping.lineBreakMode = .byWordWrapping
        clipping.lineBreakMode = .byTruncatingTail
        leadStyle.lineBreakMode = .byClipping
        leadStyle.alignment = metrics.leadAlign
        centered.alignment = .center
        // Подпись под клеткой книги: что не влезло даже после уменьшения
        // кегля — обрывается многоточием, а не уходит за край клетки.
        centered.lineBreakMode = .byTruncatingTail
        wrapping.alignment = metrics.align
        clipping.alignment = metrics.align
    }

    /// Шрифт со скруглёнными цифрами — номера стихов и глав у автора набраны
    /// именно так, и в узкой колонке они читаются заметно лучше обычных.
    private static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }

    var textLineHeight: CGFloat { ceil(textFont.ascender - textFont.descender + textFont.leading) }
    var detailLineHeight: CGFloat { ceil(detailFont.ascender - detailFont.descender + detailFont.leading) }
    var leadLineHeight: CGFloat { ceil(leadFont.ascender - leadFont.descender + leadFont.leading) }
}

/// Разметка одной строки: где номер, где текст, где приписка.
///
/// Одна и та же на рисование и на расчёт высоты — иначе строка рисуется по
/// одним правилам, а место под неё считается по другим, и текст обрезается.
struct NativeRowLayout {

    let leadRect: NSRect
    let textRect: NSRect
    let detailRect: NSRect
    let height: CGFloat

    /// - Parameter measure: считать настоящую высоту текста (дорого) или
    ///   обойтись одной строкой (когда высота задана извне).
    init(row: NativeRow, width: CGFloat, style: NativeListStyle, measure: Bool) {
        let m = style.metrics
        let left = m.padding.left
        let right = m.padding.right
        var textX = left
        var lead = NSRect.zero

        if !row.lead.isEmpty {
            let leadWidth = m.leadWidth > 0
                ? m.leadWidth
                : ceil(NativeRowLayout.width(of: row.lead, font: style.leadFont)) + 2
            lead = NSRect(x: left, y: m.padding.top, width: leadWidth, height: style.leadLineHeight)
            textX = left + leadWidth + 4
        }

        let detailIsColumn = m.detailWidth > 0 && !row.detail.isEmpty
        let detailIsLine = m.detailWidth == 0 && !row.detail.isEmpty
        var textWidth = width - textX - right
        if detailIsColumn { textWidth -= m.detailWidth + 4 }
        textWidth = max(1, textWidth)

        let textHeight: CGFloat
        if row.singleLine || !measure {
            textHeight = style.textLineHeight
        } else {
            textHeight = NativeRowLayout.height(of: row.text, width: textWidth,
                                                font: row.bold ? style.boldTextFont : style.textFont,
                                                style: style.wrapping)
        }

        textRect = NSRect(x: textX, y: m.padding.top, width: textWidth, height: textHeight)

        if detailIsColumn {
            detailRect = NSRect(x: width - right - m.detailWidth, y: m.padding.top,
                                width: m.detailWidth, height: style.detailLineHeight)
        } else if detailIsLine {
            detailRect = NSRect(x: textX, y: m.padding.top + textHeight + m.lineGap,
                                width: textWidth, height: style.detailLineHeight)
        } else {
            detailRect = .zero
        }

        leadRect = lead
        let content = max(max(textRect.maxY, detailRect.maxY), lead.maxY)
        height = ceil(content + m.padding.bottom)
    }

    private static func width(of string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }

    private static func height(of string: String, width: CGFloat,
                               font: NSFont, style: NSParagraphStyle) -> CGFloat {
        guard !string.isEmpty else { return ceil(font.ascender - font.descender + font.leading) }
        let box = NSSize(width: width, height: .greatestFiniteMagnitude)
        let rect = (string as NSString).boundingRect(
            with: box, options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: style])
        return ceil(rect.height)
    }
}

/// Вид одной строки таблицы: рисует себя сам, подвидов внутри нет.
///
/// Три `NSTextField` на строку — это три вида, три раскладки и три слоя на
/// каждую видимую строку; в оригинале строка списка это одна отрисовка текста
/// в готовый прямоугольник. Здесь так же: `draw(_:)` и ничего больше, поэтому
/// повторное использование строки при прокрутке ничего не строит и не считает.
final class NativeRowCell: NSView, NSViewToolTipOwner {

    /// В обычном списке здесь одна строка, в режиме плитки — все клетки ряда.
    var items: [(index: Int, row: NativeRow, selected: Bool)] = []
    var style: NativeListStyle?
    /// Ширина клетки в режиме плитки. 0 — обычный список.
    var tileWidth: CGFloat = 0
    var tileGap: CGFloat = 0
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// Строку рисуют целиком на каждый показ, накопленного состояния нет —
    /// поэтому пустой `wantsDefaultClipping` и никакого слоя на строку.
    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        if tileWidth > 0 {
            drawTiles(style: style)
        } else if let first = items.first {
            drawRow(first.row, selected: first.selected, in: bounds, style: style)
        }
    }

    private func drawRow(_ row: NativeRow, selected: Bool, in rect: NSRect, style: NativeListStyle) {
        let m = style.metrics
        if selected {
            m.selectionColor.setFill()
            rect.fill()
        } else if let fill = row.fill {
            fill.setFill()
            rect.fill()
        }

        let layout = NativeRowLayout(row: row, width: rect.width, style: style, measure: !row.singleLine)

        if !row.lead.isEmpty {
            let color = selected ? m.selectedTextColor.withAlphaComponent(0.9) : (row.leadColor ?? m.leadColor)
            draw(row.lead, in: layout.leadRect.offsetBy(dx: rect.minX, dy: rect.minY),
                 font: Self.fitted(style.leadFont, to: row.lead, width: layout.leadRect.width),
                 color: color, paragraph: style.leadStyle)
        }

        let textColor = selected ? m.selectedTextColor : (row.textColor ?? m.textColor)
        let textFont = row.bold ? style.boldTextFont : style.textFont
        draw(row.text, in: layout.textRect.offsetBy(dx: rect.minX, dy: rect.minY),
             font: row.singleLine ? Self.fitted(textFont, to: row.text, width: layout.textRect.width) : textFont,
             color: textColor,
             paragraph: row.singleLine ? style.clipping : style.wrapping)

        if !row.detail.isEmpty {
            let color = selected ? m.selectedTextColor.withAlphaComponent(0.8) : m.detailColor
            draw(row.detail, in: layout.detailRect.offsetBy(dx: rect.minX, dy: rect.minY),
                 font: Self.fitted(style.detailFont, to: row.detail, width: layout.detailRect.width),
                 color: color, paragraph: style.clipping)
        }

        if let rule = row.rule {
            rule.setFill()
            NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        }
    }

    /// Клетка сетки книг: сокращение крупно, под ним полное название мелко.
    private func drawTiles(style: NativeListStyle) {
        let m = style.metrics
        for (position, item) in items.enumerated() {
            let x = CGFloat(position) * (tileWidth + tileGap)
            let rect = NSRect(x: x, y: 0, width: tileWidth, height: bounds.height)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            if item.selected {
                m.selectionColor.setFill()
            } else {
                (item.row.fill ?? NSColor.controlBackgroundColor).setFill()
            }
            path.fill()

            let title = item.row.lead.isEmpty ? item.row.text : item.row.lead
            let titleColor = item.selected ? m.selectedTextColor : (item.row.textColor ?? m.textColor)
            let hasCaption = !item.row.lead.isEmpty && !item.row.text.isEmpty
            let titleHeight = style.leadLineHeight
            let captionHeight = hasCaption ? style.detailLineHeight : 0
            let block = titleHeight + (hasCaption ? captionHeight + 1 : 0)
            let top = rect.minY + max(2, (rect.height - block) / 2)

            draw(title, in: NSRect(x: rect.minX + 3, y: top, width: rect.width - 6, height: titleHeight),
                 font: Self.fitted(style.leadFont, to: title, width: rect.width - 6),
                 color: titleColor, paragraph: style.centered)
            if hasCaption {
                let color = item.selected ? m.selectedTextColor.withAlphaComponent(0.85)
                                          : titleColor.withAlphaComponent(0.75)
                draw(item.row.text,
                     in: NSRect(x: rect.minX + 3, y: top + titleHeight + 1,
                                width: rect.width - 6, height: captionHeight),
                     // Подпись под клеткой («Книга Ісуса Навина», «Екклезіастова»)
                     // короче не станет, а клетка шире — нет: ей можно ужаться
                     // сильнее строки списка, лишь бы не резаться многоточием.
                     font: Self.fitted(style.detailFont, to: item.row.text, width: rect.width - 6, minimum: 0.55),
                     color: color, paragraph: style.centered)
            }
        }
    }

    /// Кегль, при котором строка входит в ширину.
    ///
    /// Уменьшаем до 72 % от заданного, дальше строку режет многоточие: мельче
    /// уже не прочесть с места оператора. Владелец: «часть текста теряется за
    /// пределами видимого поля — нет масштабирования текста с длинными
    /// названиями» — «Стар.Заповіт» в колонке класса, «Іс.Навин» в колонке
    /// сокращений, подписи под клетками книг. Промер идёт только по видимым
    /// строкам, на отрисовку, и стоит десятки микросекунд на строку.
    static func fitted(_ font: NSFont, to string: String, width: CGFloat, minimum: CGFloat = 0.72) -> NSFont {
        guard width > 4, !string.isEmpty else { return font }
        let wanted = (string as NSString).size(withAttributes: [.font: font]).width
        guard wanted > width else { return font }
        let scale = max(minimum, width / wanted)
        var size = (font.pointSize * scale * 2).rounded(.down) / 2
        // Через описатель, а не NSFontManager.convert(_:toSize:): системный
        // шрифт интерфейса тот возвращает как есть, и вся подгонка молча не
        // срабатывала — «Стар.Заповіт» так и резался многоточием.
        func sized(_ points: CGFloat) -> NSFont {
            NSFont(descriptor: font.fontDescriptor, size: points) ?? NSFontManager.shared.convert(font, toSize: points)
        }
        var candidate = sized(size)
        // Ширина шрифта не всегда меняется ровно пропорционально кеглю
        // (округления, хинтинг): промеряем ещё раз и при нужде ужимаем по
        // полпункта, пока строка не войдёт, — иначе «Стар.Заповіт» всё равно
        // резался многоточием на последних долях пункта.
        let floor = font.pointSize * minimum
        var attempts = 0
        while attempts < 6, size - 0.5 >= floor,
              (string as NSString).size(withAttributes: [.font: candidate]).width > width {
            size -= 0.5
            candidate = sized(size)
            attempts += 1
        }
        return candidate
    }

    private func draw(_ string: String, in rect: NSRect, font: NSFont,
                      color: NSColor, paragraph: NSParagraphStyle) {
        guard !string.isEmpty, rect.width > 0 else { return }
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                  attributes: [.font: font, .foregroundColor: color,
                                               .paragraphStyle: paragraph])
    }

    // MARK: - Подсказки

    /// Подсказки заводятся прямоугольниками, а не полем `toolTip`: в режиме
    /// плитки в одном ряду до десятка клеток, и у каждой своя подпись.
    func refreshToolTips() {
        removeAllToolTips()
        guard items.contains(where: { !$0.row.tooltip.isEmpty }) else { return }
        if tileWidth > 0 {
            for (position, item) in items.enumerated() where !item.row.tooltip.isEmpty {
                let x = CGFloat(position) * (tileWidth + tileGap)
                registerTip(NSRect(x: x, y: 0, width: tileWidth, height: bounds.height), item.index)
            }
        } else if let first = items.first, !first.row.tooltip.isEmpty {
            registerTip(bounds, first.index)
        }
    }

    private func registerTip(_ rect: NSRect, _ index: Int) {
        _ = addToolTip(rect, owner: self, userData: nil)
        tipIndexes.append((rect, index))
    }

    private var tipIndexes: [(NSRect, Int)] = []

    override func removeAllToolTips() {
        super.removeAllToolTips()
        tipIndexes.removeAll()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        for (rect, index) in tipIndexes where rect.contains(point) {
            if let item = items.first(where: { $0.index == index }) { return item.row.tooltip }
        }
        return items.first?.row.tooltip ?? ""
    }
}
