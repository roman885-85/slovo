import AppKit

/// Розміри нижнього ряду — ті самі, що в описі вікна (пункт 7 і розділ 3).
///
/// Числа винесено сюди, а не розкидано по чотирьох панелях, бо їх
/// звіряє самоперевірка: «панель Плану вужча за 150 точок» — це не причіпка, а
/// втрачена кнопка «Вниз», яку в залі шукають руками.
@MainActor
enum NativeBottomMetrics {
    /// Висота частини вікна. Тепер її тягне сам оператор: власник просив
    /// «нижний блок программы с планом, историей, предпросмотром и
    /// управлением можно растягивать вверх», щоб живому екрану було де
    /// розвернутися під указку. Вибір живе між запусками.
    static var rowHeight: CGFloat {
        get {
            let saved = UserDefaults.standard.double(forKey: rowHeightKey)
            return saved > 0 ? min(rowMaxHeight, max(rowMinHeight, saved)) : 218
        }
        set { UserDefaults.standard.set(min(rowMaxHeight, max(rowMinHeight, newValue)), forKey: rowHeightKey) }
    }
    private static let rowHeightKey = "bottomRowHeight"
    /// Нижче цього в ряду не лишається місця під кнопки «Керування».
    static let rowMinHeight: CGFloat = 190
    /// Вище цього робочій області вже нічого не лишається.
    static let rowMaxHeight: CGFloat = 640

    /// Ширина живого екрана поруч із передпоказом. Нуль — його не видно.
    /// Тягнеться роздільником між ними.
    static var liveWidth: CGFloat {
        get {
            guard UserDefaults.standard.object(forKey: liveWidthKey) != nil else { return liveDefaultWidth }
            let saved = UserDefaults.standard.double(forKey: liveWidthKey)
            return saved <= 0 ? 0 : min(liveMaxWidth, max(liveMinWidth, saved))
        }
        set { UserDefaults.standard.set(newValue <= liveMinWidth / 2 ? 0
                                        : min(liveMaxWidth, max(liveMinWidth, newValue)), forKey: liveWidthKey) }
    }
    private static let liveWidthKey = "bottomLiveWidth"
    static let liveDefaultWidth: CGFloat = 300
    static let liveMinWidth: CGFloat = 180
    static let liveMaxWidth: CGFloat = 900
    /// Смуга налаштувань указки під живим екраном.
    static let pointerBarHeight: CGFloat = 22
    /// Ширина роздільника, за який тягнуть живий екран.
    static let dividerWidth: CGFloat = 7
    /// Поля зверху і знизу. По горизонталі їх уже дав ящик частини вікна.
    static let padding: CGFloat = 6
    /// Просвіт між панелями.
    static let gap: CGFloat = 6
    /// Висота рядка підпису над панеллю і просвіт під ним.
    static let captionHeight: CGFloat = 14
    static let captionGap: CGFloat = 2
    static let corner: CGFloat = 4

    // Найменша, звичайна і найбільша ширина списків — ті самі три числа, що
    // стояли в колишнього вікна у `frame(minWidth:idealWidth:maxWidth:)`. Ширше
    // за найбільшу списки не ростуть навмисно: слайд передпоказу тримає 4:3 і
    // впирається у висоту ряду, зайва ширина йому все одно не потрібна, а списку
    // понад 280 точок — і поготів.
    static let planMinWidth: CGFloat = 150
    static let planAutoWidth: CGFloat = 190
    static let planMaxWidth: CGFloat = 240
    static let historyMinWidth: CGFloat = 160
    static let historyAutoWidth: CGFloat = 210
    static let historyMaxWidth: CGFloat = 280
    /// Ширини Плану та Історії. Власник: «хочу, щоб розміри плану, історії
    /// й передпоказу мінялися перетягуванням». Поки їх не тягнули, ширина
    /// йде за вікном між найменшою і найбільшою; потягнули — стоїть як
    /// поставлено (до `planDragMaxWidth`) і пам'ятається між запусками.
    /// Подвійне клацання по роздільнику повертає автоматичну.
    static var planWidth: CGFloat {
        get { NativeWidths.value(planWidthKey, auto: planAutoWidth, min: planMinWidth, max: planDragMaxWidth) }
        set { NativeWidths.set(planWidthKey, newValue, min: planMinWidth, max: planDragMaxWidth) }
    }
    static var historyWidth: CGFloat {
        get { NativeWidths.value(historyWidthKey, auto: historyAutoWidth, min: historyMinWidth, max: historyDragMaxWidth) }
        set { NativeWidths.set(historyWidthKey, newValue, min: historyMinWidth, max: historyDragMaxWidth) }
    }
    static var planWidthIsCustom: Bool { NativeWidths.isCustom(planWidthKey) }
    static var historyWidthIsCustom: Bool { NativeWidths.isCustom(historyWidthKey) }
    static func resetPlanWidth() { NativeWidths.reset(planWidthKey) }
    static func resetHistoryWidth() { NativeWidths.reset(historyWidthKey) }
    static let planWidthKey = "bottomPlanWidth"
    static let historyWidthKey = "bottomHistoryWidth"
    static let planDragMaxWidth: CGFloat = 700
    static let historyDragMaxWidth: CGFloat = 800
    static let previewMinWidth: CGFloat = 280
    /// Найменша ширина «Керування». Справжню рахує сама панель за підписами
    /// кнопок (`NativeControlPanel.preferredWidth`): стала ширина різала
    /// «Поточний», «Знімок» і англійські підписи (власник: «в главном меню
    /// не все надписи видно целиком (керування)»).
    static let controlMinWidth: CGFloat = 340
}

/// Підпис над панеллю: 11 пунктів, вторинний колір, відступ зліва 6.
///
/// Звичайне `NSTextField` замість свого малювання навмисно: підпис міняється
/// раз на годину, при зміні мови, і городити заради нього малювання в шарі нема чого.
@MainActor
final class NativeBottomCaption: NSTextField {

    init(_ text: String = "") {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 11)
        textColor = .secondaryLabelColor
        stringValue = text
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }
}

/// Рамка навколо списку: заокруглений кут 4 і риска по краю.
///
/// Колір риски міняється, коли список бере фокус, — за нею видно, куди зараз
/// підуть стрілки і Del. У колишньому вікні це робив `overlay(RoundedRectangle)`
/// поверх `List`, і на кожну зміну стану він будувався заново.
@MainActor
final class NativeBottomFramedBox: NSView {

    /// Список усередині тримає клавіатуру — рамка стає кольоровою і вдвічі товщою.
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            applyBorder()
        }
    }

    private(set) var content: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = NativeBottomMetrics.corner
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        applyBorder()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    func install(_ view: NSView) {
        content?.removeFromSuperview()
        content = view
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func layout() {
        super.layout()
        content?.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorder()
    }

    private func applyBorder() {
        // Кольори `NSColor` живуть у просторі теми, а `CGColor` — ні:
        // без явного `performAsCurrentDrawingAppearance` рамка лишилася б
        // світлою після переходу на темну тему.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = isHighlighted ? 2 : 1
            layer?.borderColor = isHighlighted
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }
}

/// Кнопка зі значком і без підпису — рівно так виглядають кнопки над Планом (10)
/// і кнопки перегортання в «Керуванні» (13) в автора.
@MainActor
final class NativeBottomIconButton: NSButton {

    private let handler: () -> Void

    init(symbol: String, hint: String, size: CGFloat = 11,
         bordered: Bool = false, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: hint)?
            .withSymbolConfiguration(configuration)
        imagePosition = .imageOnly
        title = ""
        isBordered = bordered
        bezelStyle = .texturedRounded
        toolTip = hint
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    /// Підказка приходить із файла перекладу і міняється разом із мовою.
    func setHint(_ hint: String) { toolTip = hint }

    @objc private func fire() { handler() }
}

/// Кнопка з підписом і значком — «Показати» і «Сховати» (13).
@MainActor
final class NativeBottomLabelButton: NSButton {

    private let handler: () -> Void

    /// `compact` — дрібна кнопка переходу: менший кегль і значок, щоб три
    /// стали в ряд панелі «Керування».
    init(symbol: String, title: String, hint: String,
         prominent: Bool, compact: Bool = false, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        let configuration = NSImage.SymbolConfiguration(pointSize: compact ? 9 : 12, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(configuration)
        imagePosition = .imageLeading
        bezelStyle = .rounded
        if compact {
            controlSize = .small
            font = .systemFont(ofSize: 10)
        }
        toolTip = hint
        if prominent {
            // «Показати» в автора виділено кольором: це єдина кнопка,
            // яку в залі натискають наосліп.
            bezelColor = .controlAccentColor
            contentTintColor = .white
        }
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    func apply(title: String, hint: String) {
        self.title = title
        toolTip = hint
    }

    @objc private func fire() { handler() }
}
