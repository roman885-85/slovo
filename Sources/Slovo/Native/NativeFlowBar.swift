import AppKit

/// Полоса кнопок з переносом на наступний ряд.
///
/// Власник: «при открытии окна данных настроек, часть кнопок не видно
/// из-за некорректной работы масштабирования, приходится вручную растягивать
/// окно, чтобы появились все кнопки (если не знать что они там есть, то
/// никогда не будешь растягивать окно и часть функционала теряется)».
///
/// Звичайний `NSStackView` у вузькому вікні просто обрізає хвіст: кнопки
/// нікуди не діваються, їх не видно. Тут не влізло — пішло на наступний ряд,
/// а полоса стала вища. Тому жодна кнопка не пропадає, хоч як вузько.
@MainActor
final class NativeFlowBar: NSView {
    var rowHeight: CGFloat = 24
    var gap: CGFloat = 4
    override var isFlipped: Bool { true }

    func setButtons(_ views: [NSView]) {
        for view in subviews { view.removeFromSuperview() }
        for view in views { addSubview(view) }
        needsLayout = true
    }

    /// Висота полоси при такій ширині — рахується тією самою розкладкою.
    func height(for width: CGFloat) -> CGFloat { place(width: width, apply: false) }

    override func layout() {
        super.layout()
        _ = place(width: bounds.width, apply: true)
    }

    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0
        var y: CGFloat = 0
        for view in subviews {
            // Ширший за саму полосу елемент притискаємо до її ширини:
            // список із довгою назвою краще підрізати, ніж винести за край
            // вікна, де його вже не натиснути.
            let wanted = min(max(40, ceil(view.fittingSize.width)), max(40, width))
            if x > 0, x + wanted > width {
                x = 0
                y += rowHeight + gap
            }
            if apply {
                // Висоту елемента лишаємо його власну, коли вона менша за ряд:
                // прапорець і список поруч із кнопкою не мають розтягуватися.
                let own = ceil(view.fittingSize.height)
                let height = own > 0 && own < rowHeight ? own : rowHeight
                view.frame = NSRect(x: x, y: y + (rowHeight - height) / 2, width: wanted, height: height)
            }
            x += wanted + gap
        }
        return subviews.isEmpty ? rowHeight : y + rowHeight
    }
}
