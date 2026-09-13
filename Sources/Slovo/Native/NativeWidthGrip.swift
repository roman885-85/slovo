import AppKit

/// Роздільник між двома сусідніми блоками: за нього тягнуть ширину.
///
/// Власник: «хочу, щоб розміри плану, історії й передпоказу мінялися
/// перетягуванням по вертикалі й горизонталі, а краще — щоб кожен блок у
/// програмі мав таку опцію». Один вид на всі місця: нижній ряд, вкладки
/// презентацій, зображень, медіа, екрана, Конструктор. По вертикалі
/// тягнеться смужка над нижнім рядом (`NativeBottomHeightGrip`).
///
/// Подвійне клацання повертає ширину автоматичну — ту, що рахується від
/// вікна, — щоб затягнутий у куток блок можна було повернути без «Параметрів».
@MainActor
final class NativeWidthGrip: NSView {

    /// Скільки пунктів проїхала миша вправо від минулого разу.
    var onDrag: ((CGFloat) -> Void)?
    /// Подвійне клацання: повернути автоматичну ширину.
    var onReset: (() -> Void)?
    private var last: CGFloat?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Три крапки посередині: інакше смужку в один піксель не видно і
        // ніхто не здогадається, що її можна тягнути.
        NSColor.separatorColor.setFill()
        let dot: CGFloat = 2
        var y = bounds.midY - dot * 4
        for _ in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - dot / 2, y: y, width: dot, height: dot)).fill()
            y += dot * 3
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); last = nil; return }
        last = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        let now = convert(event.locationInWindow, from: nil).x
        guard let was = last else { last = now; return }
        let delta = now - was
        guard abs(delta) >= 1 else { return }
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) { last = nil }
}

/// Ширини блоків, які тягнули мишею. Поки блок не тягнули, він іде за
/// вікном; потягнули — стоїть як поставлено й пам'ятається між запусками.
@MainActor
enum NativeWidths {

    /// Ширина роздільника, за який тягнуть.
    static let grip: CGFloat = 7

    /// Збережена ширина в межах, або автоматична, коли не тягнули.
    static func value(_ key: String, auto: CGFloat, min floor: CGFloat, max ceiling: CGFloat) -> CGFloat {
        guard UserDefaults.standard.object(forKey: key) != nil else { return auto }
        let saved = CGFloat(UserDefaults.standard.double(forKey: key))
        return Swift.min(Swift.max(ceiling, floor), Swift.max(floor, saved))
    }

    static func isCustom(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) != nil
    }

    static func set(_ key: String, _ width: CGFloat, min floor: CGFloat, max ceiling: CGFloat) {
        UserDefaults.standard.set(Double(Swift.min(Swift.max(ceiling, floor), Swift.max(floor, width))), forKey: key)
    }

    static func reset(_ key: String) {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
