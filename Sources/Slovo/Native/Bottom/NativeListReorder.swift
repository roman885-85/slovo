import AppKit

/// Де в списку лежить точка і де лежить рядок.
///
/// `NativeList` такого не віддає: його справа — малювати рядки, а не відповідати
/// на питання про геометрію. Перетягуванню пункту Плану (10) це потрібно, і
/// питати доводиться ту саму таблицю, яка всередині. Пошук іде по
/// дереву видів, а не по нутрощах класу: з'явиться у списку своя відповідь —
/// ці двадцять рядків підуть, і нічого більше правити не доведеться.
///
/// Годиться лише для звичайного списку. Плитка (клітинки в ряд) сюди не ходить:
/// у Плані та Історії її немає і бути не може.
@MainActor
enum NativeListProbe {

    static func table(in list: NativeList) -> NSTableView? {
        func search(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(list)
    }

    /// Рядок під точкою. Точка — в координатах самого списку.
    static func item(at point: NSPoint, in list: NativeList) -> Int? {
        guard let table = table(in: list) else { return nil }
        let inside = table.convert(point, from: list)
        let row = table.row(at: inside)
        guard row >= 0, row < list.itemCount else { return nil }
        return row
    }

    /// Прямокутник рядка в координатах списку.
    static func rect(ofItem index: Int, in list: NativeList) -> NSRect? {
        guard let table = table(in: list), index >= 0, index < table.numberOfRows else { return nil }
        return list.convert(table.rect(ofRow: index), from: table)
    }
}

/// Перетягування пункту списку мишею.
///
/// В автора пункти Плану рухають кнопками «Вгору» і «Вниз» над списком, але в
/// колишньому вікні працювало й перетягування — губити його не можна. Робиться воно
/// розпізнавачем жесту, а не перехопленням миші: клацання як було, так і лишається
/// у списку (інакше перестало б працювати виділення), а жест вмикається лише
/// після того, як палець справді поїхав.
///
/// Під час перетягування не рухається нічого, крім тонкої рисочки —
/// позначки вставки. Ні рядки, ні дані не чіпаються до відпускання: список із
/// сорока пунктів переставляти по кадру означало б сорок перезбірок на
/// секунду замість однієї в кінці.
@MainActor
final class NativeListReorder: NSObject {

    /// Куди переставити: звідки взяли і перед якою позицією покласти.
    /// Позиція рахується ДО вилучення пункту — так її чекає `ServicePlan.move`.
    var onMove: ((Int, Int) -> Void)?

    /// Скільки разів позначка вставки переїхала за останнє перетягування.
    /// Потрібно заміру: вартість одного кроку — це і є «плавно чи смикано».
    private(set) var steps = 0

    private weak var list: NativeList?
    private let mark = NSView(frame: .zero)
    private var from: Int?
    private var destination: Int?

    init(list: NativeList) {
        self.list = list
        super.init()

        mark.wantsLayer = true
        mark.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        mark.layer?.cornerRadius = 1
        mark.isHidden = true
        list.addSubview(mark)

        let pan = NSPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        // Клацання зобов'язане дійти до списку: без цього перестало б працювати
        // саме виділення, а жест починається лише після зсуву миші.
        pan.delaysPrimaryMouseButtonEvents = false
        list.addGestureRecognizer(pan)
    }

    @objc private func drag(_ recognizer: NSPanGestureRecognizer) {
        guard let list else { return }
        let point = recognizer.location(in: list)
        switch recognizer.state {
        case .began:   begin(at: point)
        case .changed: track(to: point)
        case .ended:   drop()
        default:       cancel()
        }
    }

    // Три кроки перетягування винесено з розбору жесту навмисно — рівно з тієї
    // самої причини, що й `NativeList.click(item:)`: так їх можна перевірити
    // самоперевіркою і заміряти, не підробляючи подій миші.

    /// Узяли пункт під точкою.
    func begin(at point: NSPoint) {
        guard let list else { return }
        steps = 0
        from = NativeListProbe.item(at: point, in: list)
        destination = nil
        guard from != nil else { return }
        mark.isHidden = false
        move(to: point)
    }

    /// Миша поїхала: рахуємо, куди стане пункт, і рухаємо позначку вставки.
    func track(to point: NSPoint) {
        guard from != nil else { return }
        autoscroll(near: point)
        move(to: point)
    }

    /// Відпустили.
    func drop() {
        defer { cancel() }
        guard let from, let destination else { return }
        // Ставити туди ж, звідки взяли, — не перестановка, а блимання списку
        // на рівному місці.
        guard destination != from, destination != from + 1 else { return }
        onMove?(from, destination)
    }

    func cancel() {
        mark.isHidden = true
        from = nil
        destination = nil
    }

    /// Куди стане пункт, якщо відпустити зараз. Для самоперевірки.
    var target: Int? { destination }

    /// Куди стане пункт, якщо відпустити зараз, і де намалювати рисочку.
    ///
    /// Рахуємо в координатах самої таблиці, а не списку: таблиця перевернута
    /// (рахунок згори вниз), список — ні, і «вище» з «нижче» в них міняються
    /// місцями. Один перерахунок у кінці дешевший, ніж пам'ятати про це в кожному
    /// рядку.
    private func move(to point: NSPoint) {
        guard let list, let table = NativeListProbe.table(in: list) else { return }
        let count = list.itemCount
        guard count > 0, table.numberOfRows > 0 else { return }

        let inside = table.convert(point, from: list)
        let first = table.rect(ofRow: 0)
        let last = table.rect(ofRow: min(count, table.numberOfRows) - 1)

        var place: Int
        var line: CGFloat
        let row = table.row(at: inside)
        if row >= 0, row < count {
            let rect = table.rect(ofRow: row)
            // Верхня половина рядка означає «покласти перед ним», нижня —
            // «після»: так це роблять усі списки, до яких звикли руки.
            let above = inside.y < rect.midY
            place = above ? row : row + 1
            line = above ? rect.minY : rect.maxY
        } else if inside.y <= first.minY {
            place = 0
            line = first.minY
        } else {
            place = count
            line = last.maxY
        }

        guard place != destination else { return }
        destination = place
        steps += 1
        let inTable = NSRect(x: 2, y: line - 1, width: max(0, table.bounds.width - 4), height: 2)
        var frame = list.convert(inTable, from: table)
        frame.origin.y = min(max(0, frame.origin.y), max(0, list.bounds.height - 2))
        mark.frame = frame
    }

    /// Підтягнути список, коли миша пішла до краю: інакше довгий план не
    /// перетягнути далі видимого шматка.
    private func autoscroll(near point: NSPoint) {
        guard let list, let table = NativeListProbe.table(in: list),
              let clip = table.enclosingScrollView?.contentView else { return }
        let visible = list.visibleItems
        guard visible.count > 0 else { return }
        // `NSClipView` перевернутий: нуль — це верхній край видимого шматка.
        let inClip = clip.convert(point, from: list)
        let edge: CGFloat = 14
        if inClip.y < clip.bounds.minY + edge, visible.lowerBound > 0 {
            list.scrollTo(visible.lowerBound - 1, place: .top)
        } else if inClip.y > clip.bounds.maxY - edge, visible.upperBound < list.itemCount {
            list.scrollTo(visible.upperBound, place: .nearest)
        }
    }
}
