import AppKit
import SlovoCore

/// Указка: підсвічена пляма на слайді, яку ведуть мишею по дзеркалу
/// проєктора в головному вікні або пальцем по картинці сторінки на телефоні.
///
/// Власник: «подсвечивание области слайда презентации, показываемой мышью
/// (выбор цвета, размера выделения, яркости); вывод выделения выбирать
/// переключателями — показ везде, только на проектор, только NDI».
///
/// Пляма живе окремо від слайда: вона не входить ні у відбиток кадру, ні в
/// текст, тому її рух не змушує перемальовувати слайд. На
/// проєкторі це свій шар поверх усього, у трансляції — підмішування в уже
/// готовий кадр перед самим надсиланням, у дзеркалі — такий самий шар.
@MainActor
final class SlidePointer {

    static let shared = SlidePointer()

    /// Який вигляд має пляма й куди її виводити.
    struct Look: Equatable, Sendable {
        var colour = SlideStyle.RGBA(1, 0.85, 0.1)
        /// Діаметр — частка висоти кадру: так пляма однаково виглядає на
        /// проєкторі й у трансляції будь-якого розміру.
        var size = 0.14
        /// «Яскравість» — непрозорість заливки.
        var opacity = 0.45
        var toProjector = true
        var toNDI = true

        /// З налаштувань програми. Чого у файлі немає — заводські значення.
        init() {}
        init(options: ProgramOptions) {
            if let hex = options.pointerColour, let parsed = Self.colour(fromHex: hex) { colour = parsed }
            if let size = options.pointerSize { self.size = min(0.6, max(0.03, size)) }
            if let opacity = options.pointerOpacity { self.opacity = min(1, max(0.05, opacity)) }
            toProjector = options.pointerProjector ?? true
            toNDI = options.pointerNDI ?? true
        }

        static func colour(fromHex text: String) -> SlideStyle.RGBA? {
            var hex = text.trimmingCharacters(in: .whitespaces)
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            return SlideStyle.RGBA(Double((value >> 16) & 0xFF) / 255,
                                   Double((value >> 8) & 0xFF) / 255,
                                   Double(value & 0xFF) / 255)
        }

        static func hex(_ colour: SlideStyle.RGBA) -> String {
            String(format: "#%02X%02X%02X", Int((colour.red * 255).rounded()),
                   Int((colour.green * 255).rounded()), Int((colour.blue * 255).rounded()))
        }
    }

    /// Де пляма: частки ширини й висоти кадру, вісь Y донизу (як на екрані й
    /// на телефоні).
    struct Mark: Equatable, Sendable {
        var x: Double
        var y: Double
    }

    /// Привід «указка змінилася» — для дзеркал; виводи залу слухають `onChange`.
    static let changed = Notification.Name("slovo.pointerChanged")

    /// Колір, розмір і яскравість, які телефон надіслав разом із точкою.
    /// Оператор вибирає їх у самому пульті, і пляма в залі має бути такою ж,
    /// як у нього на екрані. Виводи лишаються з налаштувань програми: куди
    /// саме йде указка, вирішує той, хто стоїть за комп'ютером.
    struct PhoneLook: Equatable, Sendable {
        var colour: SlideStyle.RGBA?
        var size: Double?
        var opacity: Double?
    }

    /// Джерело, з якого приходять точки з пульта, — рядок той самий, що
    /// передає сервер пульта.
    static let phoneSource = "телефон"

    /// Вигляд з налаштувань програми — без поправок телефона.
    private(set) var baseLook = Look()
    /// Поправки телефона до вигляду; діють, поки пляму веде телефон.
    private(set) var phoneLook: PhoneLook?
    private(set) var mark: Mark?
    /// Хто останнім рухав указку — миша чи телефон: чуже «прибрати» не
    /// має гасити пляму, яку веде інший.
    private(set) var source = ""
    var onChange: (() -> Void)?

    /// Як малювати пляму зараз: налаштування програми, а поверх них — колір і
    /// розмір телефона, якщо пляму веде він.
    var look: Look {
        guard source == Self.phoneSource, let phone = phoneLook else { return baseLook }
        var merged = baseLook
        if let colour = phone.colour { merged.colour = colour }
        if let size = phone.size { merged.size = min(0.6, max(0.03, size)) }
        if let opacity = phone.opacity { merged.opacity = min(1, max(0.05, opacity)) }
        return merged
    }

    func apply(look fresh: Look) {
        guard fresh != baseLook else { return }
        baseLook = fresh
        announce()
    }

    /// Посунути пляму. `phone` — колір і розмір з пульта; для миші не передається.
    func move(to x: Double, _ y: Double, from who: String, phone: PhoneLook? = nil) {
        let clamped = Mark(x: min(1, max(0, x)), y: min(1, max(0, y)))
        let override = who == Self.phoneSource ? phone : nil
        guard clamped != mark || who != source || override != phoneLook else { return }
        mark = clamped
        source = who
        phoneLook = override
        announce()
    }

    func hide(from who: String? = nil) {
        guard mark != nil else { return }
        if let who, !source.isEmpty, who != source { return }
        mark = nil
        phoneLook = nil
        announce()
    }

    private func announce() {
        onChange?()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Намалювати пляму в контексті кадру. Одна функція для трансляції
    /// (підмішування в пікселі) і для шарів — щоб скрізь була та сама пляма.
    /// `flipped` — вісь Y контексту спрямована донизу.
    nonisolated static func draw(_ mark: Mark, look: Look, in context: CGContext,
                                 width: CGFloat, height: CGFloat, flipped: Bool) {
        let radius = max(2, look.size * height / 2)
        let cx = mark.x * width
        let cy = flipped ? mark.y * height : (1 - mark.y) * height
        let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setFillColor(CGColor(red: look.colour.red, green: look.colour.green,
                                     blue: look.colour.blue, alpha: look.opacity))
        context.fillEllipse(in: rect)
        // Тонкий обідок: заливку з малою яскравістю на світлому слайді інакше не видно.
        context.setStrokeColor(CGColor(red: look.colour.red, green: look.colour.green,
                                       blue: look.colour.blue, alpha: min(1, look.opacity + 0.4)))
        context.setLineWidth(max(1.5, radius * 0.08))
        context.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
        context.restoreGState()
    }

    /// Відбиток для кадру трансляції: пляма зсунулася — кадр інший.
    nonisolated static func hash(_ mark: Mark, look: Look) -> Int {
        var hasher = Hasher()
        hasher.combine(Int(mark.x * 4096))
        hasher.combine(Int(mark.y * 4096))
        hasher.combine(Int(look.size * 1000))
        hasher.combine(Int(look.opacity * 1000))
        hasher.combine(Int(look.colour.red * 255))
        hasher.combine(Int(look.colour.green * 255))
        hasher.combine(Int(look.colour.blue * 255))
        return hasher.finalize()
    }
}
