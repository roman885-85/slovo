import AppKit
import SlovoCore

/// Точка фокуса: шматок картинки, розтягнутий на весь екран.
///
/// Власник: «масштабирование содержимого для более удобной демонстрации
/// участка, на который нужно обратить внимание (точка фокуса)» і окремо —
/// «добавить точки фокуса для презентаций».
///
/// Працює як лупа над тим, що вже показують: сторінка презентації або
/// зображення лишаються такими, як були, а в зал іде вирізаний навколо точки
/// прямокутник. Тому наближення нічого не псує і знімається одним рухом.
///
/// Точку вибирають натисканням по живому екрану в нижньому ряду — там, куди
/// ведуть і указку. Натиснули — цей шматок став на весь екран; наближення
/// вимкнули — повернулася вся сторінка.
@MainActor
final class SlideFocus {

    static let shared = SlideFocus()

    /// Повод «наближення змінилося» — для дзеркала і смуги налаштувань.
    static let changed = Notification.Name("slovo.focusChanged")

    /// Наскільки наближати і куди дивитися. Точка — в частках ВИХІДНОЇ
    /// картинки, а не показаної: інакше після другого натискання шматок
    /// поїхав би сам від себе.
    struct Look: Equatable, Sendable {
        var zoom: Double = 2
        var x: Double = 0.5
        var y: Double = 0.5
    }

    static let minZoom = 1.0
    static let maxZoom = 6.0

    private(set) var isOn = false
    private(set) var look = Look()
    var onChange: (() -> Void)?

    /// Що зараз на екрані. `rect` — куди дивитися, і міняється він одразу;
    /// а показане вікно їде до нього плавно, кадр за кадром. Власник:
    /// «переход в исходное состояние не резко, а плавно… подтягивание
    /// слайда — пусть это будет тоже плавно». Виводи ріжуть картинку по
    /// `shownRect`; стан для пультів іде з `look` — вони їдуть самі.
    private(set) var shownRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Повод «показане вікно зсунулося на кадр» — для виводів.
    static let shownChanged = Notification.Name("slovo.focusShownChanged")
    var onShownChange: (() -> Void)?
    /// Тривалість переїзду. У самоперевірці — нуль: перевірки міряють
    /// картинку одразу після дії, а плавність перевіряє окрема перевірка,
    /// яка ставить час сама.
    static var animationDuration: TimeInterval = CommandLine.arguments
        .contains { $0.hasPrefix("--check") || $0.hasPrefix("--selftest") } ? 0 : 0.28
    /// Скільки кадрів проїхав останній переїзд — самоперевірці.
    private(set) var rideFrames = 0
    private var ride: Timer?
    private var rideFrom = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var rideStart = Date()

    /// Прямокутник у частках картинки: що саме піде в зал.
    var rect: CGRect {
        guard isOn else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let side = 1 / min(Self.maxZoom, max(Self.minZoom, look.zoom))
        // Вікно наближення не має вилазити за край картинки: інакше по
        // краях сторінки з'явилися б чорні поля, і виглядало б це поломкою.
        let x = min(1 - side, max(0, look.x - side / 2))
        let y = min(1 - side, max(0, look.y - side / 2))
        return CGRect(x: x, y: y, width: side, height: side)
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        announce()
    }

    func setZoom(_ zoom: Double) {
        let value = min(Self.maxZoom, max(Self.minZoom, zoom))
        guard value != look.zoom else { return }
        look.zoom = value
        announce()
    }

    /// Поставити точку фокуса. Координати — в частках ПОКАЗАНОЇ картинки,
    /// тобто того, що людина бачить на живому екрані. Переводимо їх у
    /// вихідну картинку самі: після кількох натискань підряд лупа має
    /// їхати туди, куди тицяють, а не стрибати.
    func move(toShown x: Double, _ y: Double) {
        let window = rect
        let fresh = Look(zoom: look.zoom,
                         x: window.minX + min(1, max(0, x)) * window.width,
                         y: window.minY + min(1, max(0, y)) * window.height)
        guard fresh != look else { return }
        look = fresh
        announce()
    }

    /// Наблизити навколо точки, на яку зараз дивиться миша.
    ///
    /// Власник: «точка масштабирования от текущего места положения мыши на
    /// координатах окна вывода лайв». Тому колесо не просто міняє число:
    /// шматок, що стоїть під курсором, лишається під курсором, а сторінка
    /// наїжджає на нього. Інакше після другого повороту колеса потрібне
    /// місце виїжджає за край, і його доводиться ловити наново.
    ///
    /// Координати — в частках ПОКАЗАНОГО кадру, як і в `move(toShown:_:)`.
    func zoom(to value: Double, aroundShown x: Double, _ y: Double) {
        let target = min(Self.maxZoom, max(Self.minZoom, value))
        let window = rect
        let shownX = min(1, max(0, x))
        let shownY = min(1, max(0, y))
        // Куди дивиться курсор у вихідній картинці.
        let pointX = window.minX + shownX * window.width
        let pointY = window.minY + shownY * window.height
        let side = 1 / target
        // Нове вікно ставимо так, щоб ця сама точка лишилася на тому самому
        // місці кадру, а середину вікна виводимо з неї.
        let half = side / 2
        let fresh = Look(zoom: target,
                         x: min(1 - half, max(half, pointX + side * (0.5 - shownX))),
                         y: min(1 - half, max(half, pointY + side * (0.5 - shownY))))
        guard fresh != look else { return }
        look = fresh
        announce()
    }

    /// Повернути все як було: наближення зняте, погляд посередині.
    ///
    /// Власник: «исходное состояние масштаба по нажатию третьей кнопки мыши».
    /// Одна дія, а не три: вимкнути, скинути кратність, поставити середину.
    func reset() {
        let wasOn = isOn
        let fresh = Look()
        guard wasOn || fresh != look else { return }
        isOn = false
        look = fresh
        announce()
    }

    /// Повернути погляд на середину.
    func center() {
        guard look.x != 0.5 || look.y != 0.5 else { return }
        look.x = 0.5
        look.y = 0.5
        announce()
    }

    private func announce() {
        onChange?()
        NotificationCenter.default.post(name: Self.changed, object: nil)
        ride(to: rect)
    }

    /// Повезти показане вікно до нового: 60 кадрів на секунду, з розгоном
    /// і гальмуванням. Нова ціль посеред дороги — їдемо далі з того місця,
    /// де є, а не стрибаємо на початок.
    private func ride(to target: CGRect) {
        ride?.invalidate()
        ride = nil
        guard target != shownRect else { return }
        guard Self.animationDuration > 0 else {
            shownRect = target
            announceShown()
            return
        }
        rideFrom = shownRect
        rideStart = Date()
        rideFrames = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        // У звичайному режимі таймер став би, поки тягнуть мишею по
        // живому екрану, — а саме тоді вікно й їде.
        RunLoop.main.add(timer, forMode: .common)
        ride = timer
    }

    private func step() {
        let part = min(1, Date().timeIntervalSince(rideStart) / max(0.001, Self.animationDuration))
        let eased = part < 0.5 ? 2 * part * part : 1 - pow(-2 * part + 2, 2) / 2
        let to = rect
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(eased) }
        shownRect = part >= 1 ? to : CGRect(x: mix(rideFrom.minX, to.minX), y: mix(rideFrom.minY, to.minY),
                                             width: mix(rideFrom.width, to.width), height: mix(rideFrom.height, to.height))
        rideFrames += 1
        if part >= 1 {
            ride?.invalidate()
            ride = nil
        }
        announceShown()
    }

    private func announceShown() {
        onShownChange?()
        NotificationCenter.default.post(name: Self.shownChanged, object: nil)
    }

    /// Самоперевірці: дочекатися кінця переїзду.
    var isRiding: Bool { ride != nil }

    /// Вирізати шматок картинки. Повертає ту саму картинку, коли наближення
    /// вимкнено або різати нічого.
    nonisolated static func crop(_ image: CGImage, rect: CGRect) -> CGImage {
        guard rect.width < 0.999 || rect.height < 0.999 else { return image }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let box = CGRect(x: (rect.minX * width).rounded(),
                         y: (rect.minY * height).rounded(),
                         width: max(2, (rect.width * width).rounded()),
                         height: max(2, (rect.height * height).rounded()))
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard box.width >= 2, box.height >= 2, let cut = image.cropping(to: box) else { return image }
        return cut
    }
}
