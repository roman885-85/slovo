import AppKit

/// Виртуальный список — основание всего окна.
///
/// Что это значит на деле: строк на экране существует столько, сколько видно,
/// обычно два десятка. Данные берутся у источника по номеру строки и никуда
/// не копируются. Ни массивов, ни сличения коллекций, ни пересборки — нажатие
/// меняет одну строку, и перерисовывается ровно она.
///
/// Тот же список умеет показывать сетку клеток (окно выбора Книги «плиткой»,
/// кнопка (22)): ряд таблицы держит несколько клеток, повторное использование
/// и виртуальность при этом сохраняются.
///
/// Выделение список ведёт сам, а не отдаёт `NSTableView`. Так одна правда на
/// оба вида — список и плитку, — и заливка выбранной строки рисуется тем же
/// кодом, что и всё остальное. Отрезок берётся с Shift, вразбивку — с Ctrl
/// или ⌘, как в оригинале.
@MainActor
final class NativeList: NSView, NativeListChecking {

    // MARK: - Настройка

    enum Mode {
        case list
        /// Сетка клеток: клетка не уже `minItemWidth`, высотой `itemHeight`.
        case tiles(minItemWidth: CGFloat, itemHeight: CGFloat, gap: CGFloat)
    }

    enum Heights {
        /// Все строки одной высоты. Самый быстрый путь: `NSTableView` не
        /// спрашивает высоту вовсе. Так живут списки глав, песен, книг и
        /// стихи в режиме «одна линия».
        case uniform(CGFloat)
        /// Высота считается по тексту. Для строк, до которых ещё не дошли,
        /// берётся `estimate`, и источник о них не спрашивают — иначе на
        /// сборнике в 3400 песен пришлось бы построить все 3400 строк, чтобы
        /// узнать длину полосы прокрутки. Настоящая высота считается в тот
        /// миг, когда строка впервые показалась.
        case measured(estimate: CGFloat)
    }

    enum Place {
        /// Довести до края, если строка не видна; видна — не трогать.
        case nearest
        case center
        case top
    }

    /// Чем вызвана смена выделения — щелчком человека или кодом.
    enum Cause {
        case click
        case doubleClick
        case keyboard
        case code
        /// Протяжка мышью с нажатой кнопкой: отрезок от строки, где нажали,
        /// до строки под курсором.
        case drag
    }

    /// Откуда брать строки. Список держит источник слабо: владеет им тот,
    /// кто список создал.
    weak var source: NativeListSource? {
        didSet { reload() }
    }

    /// Кегль списка (ползунок (20), колесо с Ctrl).
    var fontSize: CGFloat = 13 {
        didSet {
            guard fontSize != oldValue else { return }
            rebuildStyle()
            // Строки одной высоты растут вместе с кеглем: при 22 точках на
            // крупном шрифте подписи наползали друг на друга (владелец).
            //
            // Рахуємо це в `applyHeights`, а не тут: висоту рядка задають і
            // після того, як кегль уже змінили — коли міняють вигляд списку
            // («значки», «список», «таблиця»). Доти таке призначення ставило
            // висоту з голови, кегля не питаючи, і великий текст вилазив за
            // рядок. Власник: «при зміні стилів частина тексту губиться,
            // текст наповзає за видимі межі».
            applyHeights()
        }
    }
    /// Высота строки, заданная при создании, — от неё считаем рост с кеглем.
    private var baseUniformHeight: CGFloat?

    /// Висота рядка (чи плитки) під поточний кегль: менша за свій текст вона
    /// бути не може, хоч би що задав той, хто міняв вигляд.
    ///
    /// Рахуємо не від кегля на око, а від справжньої висоти рядка шрифту та
    /// відступів — тих самих, за якими рядок і малюється. Формула «кегль ×
    /// 1,55 + 3» була близька, але на дрібних кеглях давала на дві точки
    /// менше, ніж треба, і текст усе одно не вміщався.
    private func grown(_ base: CGFloat) -> CGFloat {
        max(base, minimumRowHeight)
    }

    /// Найменша висота, за якої в рядок ще влазить один рядок тексту.
    ///
    /// Відступи сюди не входять навмисно: у щільних списках (План, Історія)
    /// рядок навмисно нижчий за відступи, і текст у ньому малюється по
    /// центру. А от менше, ніж сам рядок тексту, не можна ніколи — саме там
    /// текст і різався.
    var minimumRowHeight: CGFloat { ceil(style.textLineHeight) + 2 }

    var metrics: NativeListMetrics {
        didSet { rebuildStyle() }
    }

    var mode: Mode {
        didSet { rebuildStyle() }
    }

    var heights: Heights {
        didSet { applyHeights() }
    }

    var allowsMultipleSelection = false

    /// Отдавать ли списку стрелки и клавиши перехода. По умолчанию нет:
    /// стрелки в программе листают стих и главу, и перехватывать их списку
    /// нельзя, пока об этом не попросят.
    var handlesArrowKeys = false
    /// Enter відкриває виділений пункт (`onActivate`) — як подвійне клацання.
    /// Вмикається лише там, де це потрібно (План): у решті списків Enter
    /// лишається вільним.
    var activatesOnReturn = false

    /// Заголовки колонок. Нужны виду «Таблица» окна выбора Книги.
    var headerTitles: [String]? {
        didSet { applyHeader() }
    }

    // MARK: - Обратные вызовы

    /// Выделение изменилось. `active` — строка, по которой щёлкнули.
    var onSelect: ((IndexSet, Int, Cause) -> Void)?
    /// Двойной щелчок по строке — у автора это «в зал».
    var onActivate: ((Int) -> Void)?
    /// Меню правой кнопки, если источник его не даёт.
    var onContextMenu: ((Int) -> NSMenu?)?
    /// Щелчок по узкой колонке слева — по пометке. Списку модулей это
    /// «включить/выключить» одним щелчком, как флажок у автора; без этого
    /// переключать можно было только двойным щелчком, и владелец решил, что
    /// включить модуль нельзя вовсе.
    var onLeadClick: ((Int) -> Void)?

    // MARK: - Внутреннее

    private let scrollView = NSScrollView()
    private let table: NativeTableView
    private let column = NSTableColumn(identifier: .init("row"))
    private var bridge: Bridge!
    /// Ширина, за якої міряли висоти рядків: на іншій вони недійсні.
    private var measuredAtWidth: CGFloat = 0
    private var fitGuardScheduled = false
    private(set) var style: NativeListStyle
    /// Число строк, снятое при последней `reload()`. Спрашивать источник
    /// на каждый чих незачем, а разойтись они не могут: состав меняется
    /// только через `reload()`.
    private(set) var itemCount = 0
    /// Сколько строк сейчас знает сама таблица — самопроверке: список
    /// на вкладке «Параметров» стоял пустым, и надо было понять, кто
    /// молчит — источник или таблица.
    var rowsInTable: Int { table.numberOfRows }
    var hasSource: Bool { source != nil }
    var sourceRowCount: Int { source?.rowCount ?? 0 }
    var describedForCheck: String {
        "джерело \(source?.rowCount ?? -1), знято \(itemCount), у таблиці \(table.numberOfRows), "
            + "место \(Int(frame.width))×\(Int(frame.height)), прокрутка \(Int(scrollView.frame.width))×\(Int(scrollView.frame.height))"
            + (isHidden ? ", сховано" : "") + (window == nil ? ", без вікна" : "")
    }
    private(set) var selection = IndexSet()
    /// Опорная строка для отрезка с Shift.
    private(set) var anchor: Int?
    private var columnsPerRow = 1
    /// Настоящие высоты строк, посчитанные по мере показа. 0 — ещё не считали.
    private var measuredHeights: [CGFloat] = []
    private var heightsToNote = IndexSet()
    private var noteScheduled = false
    private var lastWidth: CGFloat = 0

    /// Прокрутка, про яку попросили, поки список ще не мав висоти.
    ///
    /// Вкладку «Пісні» будують раніше, ніж вона отримує місце у вікні, і
    /// першу пісню ставлять «по центру» видимої області заввишки нуль:
    /// список з'їжджав на пів рядка, і вибрана перша пісня ховалася під
    /// полем швидкого вибору. Таку прокрутку відкладаємо до розкладки, коли
    /// видно хоч один рядок.
    private var pendingScroll: (index: Int, place: Place)?

    /// Сколько раз спросили источник. Только для самопроверки.
    private(set) var sourceQueries = 0
    static var countsQueries = false

    init(mode: Mode = .list, metrics: NativeListMetrics = NativeListMetrics(),
         heights: Heights = .uniform(22), fontSize: CGFloat = 13) {
        self.mode = mode
        self.metrics = metrics
        self.heights = heights
        self.fontSize = fontSize
        if case .uniform(let base) = heights { baseUniformHeight = base }
        self.style = NativeListStyle(fontSize: fontSize, metrics: metrics)
        self.table = NativeTableView()
        super.init(frame: .zero)

        bridge = Bridge(list: self, wantsRowHeights: isMeasured)

        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.owner = self
        table.dataSource = bridge
        table.delegate = bridge
        table.headerView = nil
        table.backgroundColor = metrics.background
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.wantsLayer = true

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = metrics.background
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        applyHeights()
        // Полоса прокрутки появляется и исчезает уже ПОСЛЕ раскладки — когда
        // строки перечитаны и высота содержимого стала другой. Видимая
        // область при этом сужается на ширину полосы, а наша раскладка об
        // этом не узнавала: клетки книг третьей колонки уходили под полосу,
        // и подписи «Книга Ісуса Навина», «Екклезіастова» резались по краю
        // (замечание 8). Следим за рамкой видимой области сами.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleWidthChanged),
                                               name: NSView.frameDidChangeNotification,
                                               object: scrollView.contentView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Ширина, по якій рахуються стовпці плитки й міряються рядки.
    ///
    /// Це ширина самої таблиці — та, якою потім малюється рядок. Полотно
    /// (`contentSize`) буває на кілька точок ширшим за таблицю, і на цій
    /// різниці третя плитка вилазила за край списку, а зміряні висоти не
    /// сходилися з намальованими.
    private var contentWidth: CGFloat {
        // Рахуємо по ширині СТОВПЦЯ — саме її дістає клітинка, коли малює
        // рядок. Ширина таблиці буває більшою (смуга прокрутки, відступи), і
        // на цій різниці міряна висота виходила меншою за намальований текст:
        // останній рядок куплета зрізало (власник: «некоторые песни
        // отображаются не в одну строку, а очень широко» — на знімку видно
        // обрізаний нижній рядок). Різниця була 32 точки — рівно смуга.
        if column.width > 1 { return column.width }
        let inner = table.bounds.width - table.intercellSpacing.width
        return inner > 1 ? inner : max(1, scrollView.contentSize.width)
    }

    @objc private func visibleWidthChanged() {
        if pendingScroll != nil { needsLayout = true }
        guard abs(scrollView.contentSize.width - lastWidth) > 0.5 else { return }
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override func layout() {
        scrollView.frame = bounds
        super.layout()
        defer {
            if let pending = pendingScroll { scrollTo(pending.index, place: pending.place) }
        }
        let width = scrollView.contentSize.width
        guard width > 0, abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        // Колонка таблицы — ровно в ширину видимого. `NSTableColumn` рождается
        // шириной 100, и таблица уже колонки не становится: в узкой колонке
        // глав (72 пункта) строка была на 100, её середина уходила за правый
        // край, и номера глав выглядели прижатыми вправо, хотя выключены по
        // центру. Ширину задаём сами на каждую раскладку.
        if abs(column.width - width) > 0.5 {
            column.minWidth = 1
            column.width = width
            table.sizeLastColumnToFit()
        }
        // Стовпці рахуємо від ширини таблиці — тієї, якою потім малюється
        // рядок: інакше край плитки не збігався б із краєм списку.
        let columns = tileColumns(for: contentWidth)
        if columns != columnsPerRow {
            columnsPerRow = columns
            table.reloadData()
        } else if columns > 1 {
            // Число колонок то же, а ширина другая (появилась полоса
            // прокрутки): клетки видимых рядов помнят прежнюю ширину, и
            // третья колонка уходила под полосу. Перенаполняем их — ширина
            // клетки считается заново от видимой области.
            refreshVisibleCells()
        } else if case .measured = heights {
            // Ширина изменилась — все посчитанные высоты недействительны.
            measuredHeights = Array(repeating: 0, count: measuredHeights.count)
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }
    }

    // MARK: - Обновление

    /// Состав списка изменился целиком: другой перевод, другая глава,
    /// другой песенник.
    func reload() {
        pendingScroll = nil
        itemCount = source?.rowCount ?? 0
        if case .measured = heights {
            measuredHeights = Array(repeating: 0, count: itemCount)
        } else {
            measuredHeights = []
        }
        heightsToNote.removeAll()
        columnsPerRow = tileColumns(for: contentWidth)
        selection = selection.filteredIndexSet(includeInteger: { $0 < itemCount })
        if let anchor, anchor >= itemCount { self.anchor = nil }

        // Число строк не изменилось — клетки обновляются на месте.
        //
        // `reloadData()` снимает виды всех видимых строк и ставит новые, а
        // AppKit для каждого нового вида заново строит дерево слоёв: в
        // профиле смены кегля на это уходила половина главного потока. Те же
        // клетки с новым содержимым — это только перерисовка.
        let rows = columnsPerRow > 1 ? (itemCount + columnsPerRow - 1) / columnsPerRow : itemCount
        if rows > 0, rows == table.numberOfRows {
            refreshVisibleCells()
            if case .measured = heights {
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows))
            }
            scheduleFitGuard()
            return
        }
        table.reloadData()
        scheduleFitGuard()
    }

    /// Сторож першого показу: через мить після того, як список наповнився,
    /// звіряє видимі рядки — чи вміщається в них те, що намальовано.
    ///
    /// Власник 19.09.2026: «при запуске программы часто окно со списком
    /// стихов или куплетов отображается с перекрытием некоторых строк,
    /// исправляется если переключить песню или главу». Перемикання лагодить
    /// тому, що міряє висоти наново. Сторож робить те саме сам: не шукаючи,
    /// хто саме не встиг стати на місце при запуску, він просто перевіряє
    /// результат і, коли той не сходиться, переміряє.
    private func scheduleFitGuard() {
        guard isMeasured, !fitGuardScheduled else { return }
        fitGuardScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.fitGuardScheduled = false
            self.remeasureIfTight()
        }
    }

    /// Чи розійшлася висота видимих рядків із їхнім текстом — і замало, і
    /// забагато. Забагато буває тоді, коли рядок так і лишився з попередньою
    /// висотою (наприклад, з першої оцінки у 86 точок): текст в один рядок, а
    /// під ним порожнеча. Власник: «некоторые песни отображаются не в одну
    /// строку, а очень широко, занимая полезное место».
    private func remeasureIfTight() {
        guard isMeasured, source != nil, table.numberOfRows > 0 else { return }
        let visible = table.rows(in: scrollView.contentView.bounds)
        guard visible.length > 0 else { return }
        var tight = false
        var roomy = false
        for row in visible.location..<min(table.numberOfRows, visible.location + visible.length) {
            guard let fit = fit(ofRow: row) else { continue }
            if fit.drawn > fit.given + 0.5 { tight = true; break }
            // Вісім точок — це відступи; більше означає справжню порожнечу.
            if fit.given - fit.drawn > 8 { roomy = true }
        }
        guard tight || roomy else { return }
        NativeTrace.say(tight
                        ? "список: рядкам було замало місця при першому показі — переміряв"
                        : "список: рядки стояли вищі за свій текст — переміряв")
        measuredAtWidth = contentWidth
        measuredHeights = Array(repeating: 0, count: measuredHeights.count)
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        refreshVisibleCells()
    }

    /// Перечитать содержимое стоящих на экране клеток из источника.
    private func refreshVisibleCells() {
        let visible = table.rows(in: scrollView.contentView.bounds)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeRowCell
            else { continue }
            refresh(cell: cell, tableRow: row)
            noteRealHeight(ofTableRow: row)
            cell.needsDisplay = true
        }
    }

    /// Изменилась одна строка. Всё остальное не трогается вовсе: если строка
    /// сейчас не видна, работы нет ни на грош.
    func reloadRow(_ index: Int) {
        guard index >= 0, index < itemCount else { return }
        if case .measured = heights, index < measuredHeights.count {
            measuredHeights[index] = 0
            heightsToNote.insert(index)
            scheduleHeightNote()
        }
        guard let cell = visibleCell(forItem: index) else { return }
        refresh(cell: cell, tableRow: tableRow(ofItem: index))
        cell.needsDisplay = true
    }

    func reloadRows(_ indexes: IndexSet) {
        for index in indexes { reloadRow(index) }
    }

    // MARK: - Выделение

    /// Поставить выделение из кода. Перерисовываются только те строки, у
    /// которых состояние изменилось, — не список целиком.
    func setSelection(_ new: IndexSet, active: Int? = nil, notify: Bool = false, cause: Cause = .code) {
        let changed = selection.symmetricDifference(new)
        selection = new
        if let active { anchor = active }
        // Обходим видимые строки, а не изменившиеся: «выделить всё» на
        // сборнике в 3400 песен меняет три с половиной тысячи строк, а
        // перерисовать надо два десятка — те, что на экране.
        for index in visibleItems where changed.contains(index) { redraw(item: index) }
        if notify { onSelect?(selection, active ?? selection.first ?? -1, cause) }
    }

    func selectAll() {
        guard allowsMultipleSelection, itemCount > 0 else { return }
        setSelection(IndexSet(integersIn: 0..<itemCount), notify: true, cause: .keyboard)
    }

    override func selectAll(_ sender: Any?) { selectAll() }

    // MARK: - Прокрутка

    func scrollTo(_ index: Int, place: Place = .nearest) {
        pendingScroll = nil
        guard index >= 0, index < itemCount else { return }
        let row = tableRow(ofItem: index)
        guard row < table.numberOfRows else { return }
        let rect = table.rect(ofRow: row)
        let clip = scrollView.contentView
        // Висоту чекаємо від рамки видимої області (`visibleWidthChanged`),
        // а не просимо раскладку звідси: `layout()` сам кличе цей метод.
        guard clip.bounds.height >= rect.height else {
            pendingScroll = (index, place)
            return
        }
        switch place {
        case .nearest:
            // Никакой плавности: у автора список встаёт на место мгновенно,
            // а четверть секунды анимации — это четверть секунды, которую
            // зал ждёт лишнего.
            table.scrollRowToVisible(row)
        case .center:
            var y = rect.midY - clip.bounds.height / 2
            y = max(0, min(y, max(0, table.bounds.height - clip.bounds.height)))
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scrollView.reflectScrolledClipView(clip)
        case .top:
            let y = max(0, min(rect.minY, max(0, table.bounds.height - clip.bounds.height)))
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// Зсув видимої області від початку списку — самоперевірці.
    var scrollOffsetForCheck: CGFloat { scrollView.contentView.bounds.minY }

    /// Какие строки сейчас видно. По ним считают, надо ли вообще что-то делать.
    var visibleItems: Range<Int> {
        let rows = table.rows(in: scrollView.contentView.bounds)
        guard rows.length > 0 else { return 0..<0 }
        let first = rows.location * columnsPerRow
        let last = min(itemCount, (rows.location + rows.length) * columnsPerRow)
        return first..<max(first, last)
    }

    // MARK: - Мышь и клавиши

    /// Одинарне клацання по рядку — миша піднялася там, де опустилася, без
    /// протяжки й без клавіш. На відміну від `onSelect`, не спрацьовує, коли
    /// рядок лише тягнуть (переставляють пункт плану) чи розтягують
    /// виділення: План відкриває пункт саме звідси.
    var onClick: ((Int) -> Void)?
    private var pressedItem: Int?
    private var pressedAt: NSPoint = .zero
    private var pressedMoved = false

    fileprivate func handleMouseDown(_ event: NSEvent) {
        window?.makeFirstResponder(table)
        dragOrigin = nil
        dragLast = nil
        pressedItem = nil
        pressedMoved = false
        guard let index = item(at: event) else { return }
        let plain = event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty
        if plain, event.clickCount == 1 {
            pressedItem = index
            pressedAt = event.locationInWindow
        }
        if let onLeadClick, columnsPerRow == 1, metrics.leadWidth > 0 {
            let x = table.convert(event.locationInWindow, from: nil).x
            if x <= metrics.leadWidth + metrics.padding.left + 6 {
                onLeadClick(index)
                return
            }
        }
        click(item: index, modifiers: event.modifierFlags, clickCount: event.clickCount)
        // Простое нажатие в списке с множественным выбором может стать
        // протяжкой: запоминаем, откуда потянут.
        let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
        if allowsMultipleSelection, event.clickCount == 1, modifiers.isEmpty { dragOrigin = index }
    }

    /// Строка, с которой началась протяжка, и последняя строка под курсором.
    private var dragOrigin: Int?
    private var dragLast: Int?

    /// Тянут мышь с нажатой кнопкой: выделяется отрезок от строки нажатия до
    /// строки под курсором — так выделяют несколько стихов одним движением.
    /// Раньше отрезок набирался только Ctrl-щелчками по каждому стиху
    /// (владелец просил «выбор нескольких стихов одним движением мышки»).
    fileprivate func handleMouseDragged(_ event: NSEvent) {
        if pressedItem != nil, !pressedMoved {
            let shift = hypot(event.locationInWindow.x - pressedAt.x, event.locationInWindow.y - pressedAt.y)
            if shift > 4 { pressedMoved = true }
        }
        guard let origin = dragOrigin else { return }
        table.autoscroll(with: event)
        guard let index = item(at: event), index != dragLast else { return }
        dragLast = index
        setSelection(IndexSet(integersIn: min(origin, index)...max(origin, index)), active: origin)
        onSelect?(selection, index, .drag)
    }

    fileprivate func handleMouseUp(_ event: NSEvent) {
        dragOrigin = nil
        dragLast = nil
        defer { pressedItem = nil }
        guard let pressed = pressedItem, !pressedMoved, event.clickCount == 1,
              item(at: event) == pressed else { return }
        onClick?(pressed)
    }

    /// Щелчок по строке. Вынесен из разбора события нарочно: так его можно
    /// проверить самопроверкой, не подделывая события мыши, и так же его
    /// зовут снаружи, когда по строке «щёлкают» из кода.
    func click(item index: Int, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        guard index >= 0, index < itemCount else { return }
        if clickCount >= 2 {
            onActivate?(index)
            return
        }
        var new = selection
        // Отрезок: от опорной строки до нажатой. Опорная не двигается —
        // иначе Shift подряд растил бы отрезок с конца, а не от начала.
        if allowsMultipleSelection, modifiers.contains(.shift), let from = anchor {
            new = IndexSet(integersIn: min(from, index)...max(from, index))
            setSelection(new, notify: false)
            onSelect?(selection, index, .click)
            return
        }
        // Вразбивку: у автора это Ctrl, на этой машине привычнее ⌘. Берём оба.
        if allowsMultipleSelection, modifiers.contains(.command) || modifiers.contains(.control) {
            if new.contains(index) { new.remove(index) } else { new.insert(index) }
            setSelection(new, active: index, notify: false)
            onSelect?(selection, index, .click)
            return
        }
        setSelection(IndexSet(integer: index), active: index, notify: false)
        onSelect?(selection, index, .click)
    }

    fileprivate func handleRightMouseDown(_ event: NSEvent) -> NSMenu? {
        guard let index = item(at: event) else { return nil }
        if !selection.contains(index) {
            setSelection(IndexSet(integer: index), active: index, notify: true, cause: .click)
        }
        return source?.menu(at: index) ?? onContextMenu?(index)
    }

    fileprivate func handleKeyDown(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            selectAll()
            return true
        }
        // Enter і Enter на цифровій клавіатурі — відкрити виділене.
        if activatesOnReturn, event.keyCode == 36 || event.keyCode == 76,
           let row = anchor ?? selection.first, row < itemCount {
            onActivate?(row)
            return true
        }
        guard handlesArrowKeys, itemCount > 0 else { return false }
        let current = anchor ?? selection.first ?? 0
        var target = current
        switch event.keyCode {
        case 126: target = current - 1                       // вверх
        case 125: target = current + 1                       // вниз
        case 115: target = 0                                 // Home
        case 119: target = itemCount - 1                     // End
        case 116: target = current - pageStep                // PageUp
        case 121: target = current + pageStep                // PageDown
        default: return false
        }
        target = max(0, min(itemCount - 1, target))
        if allowsMultipleSelection, event.modifierFlags.contains(.shift), let from = anchor {
            setSelection(IndexSet(integersIn: min(from, target)...max(from, target)), notify: false)
            onSelect?(selection, target, .keyboard)
        } else {
            setSelection(IndexSet(integer: target), active: target, notify: false)
            onSelect?(selection, target, .keyboard)
        }
        scrollTo(target)
        return true
    }

    /// Самоперевірці: натиснути Enter так, як це робить клавіатура.
    @discardableResult
    func pressReturnForCheck() -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil,
                                           characters: "\r", charactersIgnoringModifiers: "\r",
                                           isARepeat: false, keyCode: 36) else { return false }
        return handleKeyDown(event)
    }

    private var pageStep: Int {
        let visible = visibleItems
        return max(1, visible.count - 1)
    }

    private func item(at event: NSEvent) -> Int? {
        item(atTablePoint: table.convert(event.locationInWindow, from: nil))
    }

    /// Елемент під точкою списку — самоперевірці: той самий розрахунок, що й у
    /// миші, з плитками включно.
    func item(atListPoint point: NSPoint) -> Int? {
        item(atTablePoint: table.convert(point, from: self))
    }

    private func item(atTablePoint point: NSPoint) -> Int? {
        let row = table.row(at: point)
        guard row >= 0 else { return nil }
        guard columnsPerRow > 1 else { return row < itemCount ? row : nil }
        let step = tileStep(width: contentWidth)
        let column = min(columnsPerRow - 1, max(0, Int(point.x / max(1, step))))
        let index = row * columnsPerRow + column
        return index < itemCount ? index : nil
    }

    // MARK: - Строки таблицы и клетки

    private func tableRow(ofItem index: Int) -> Int {
        columnsPerRow > 1 ? index / columnsPerRow : index
    }

    private func visibleCell(forItem index: Int) -> NativeRowCell? {
        let row = tableRow(ofItem: index)
        guard row >= 0, row < table.numberOfRows else { return nil }
        return table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NativeRowCell
    }

    private func redraw(item index: Int) {
        guard let cell = visibleCell(forItem: index) else { return }
        refresh(cell: cell, tableRow: tableRow(ofItem: index))
        cell.needsDisplay = true
    }

    /// Наполнить клетку данными. Единственное место, где спрашивают источник.
    fileprivate func refresh(cell: NativeRowCell, tableRow row: Int) {
        guard let source else { cell.items = []; return }
        cell.style = style
        cell.fixedHeight = !isMeasured
        if columnsPerRow > 1, case .tiles(_, _, let gap) = mode {
            let step = tileStep(width: contentWidth)
            cell.tileWidth = max(1, step - gap)
            cell.tileGap = gap
            cell.tileColumns = columnsPerRow
            var items: [(index: Int, row: NativeRow, selected: Bool)] = []
            items.reserveCapacity(columnsPerRow)
            for position in 0..<columnsPerRow {
                let index = row * columnsPerRow + position
                guard index < itemCount else { break }
                items.append((index: index, row: ask(source, index),
                              selected: selection.contains(index)))
            }
            cell.items = items
        } else {
            cell.tileWidth = 0
            guard row < itemCount else { cell.items = []; return }
            cell.items = [(index: row, row: ask(source, row), selected: selection.contains(row))]
        }
        cell.refreshToolTips()
    }

    /// Спросить у источника строку — с оглядкой на то, сколько их у него
    /// СЕЙЧАС.
    ///
    /// `NSTableView` держит своё число строк до `reload()`, а состав списка
    /// меняется и мимо нас: файл убрали из панели плеера, список очистили с
    /// клавиши, модуль догрузился. Между правкой и перезагрузкой таблица
    /// успевает перерисоваться и спросить строку, которой уже нет. Раньше это
    /// была не пустая строка, а падение всей программы посреди служения —
    /// «Index out of range» в источнике. Ловим здесь, в одном месте, а не в
    /// каждом из двух десятков источников.
    private func ask(_ source: NativeListSource, _ index: Int) -> NativeRow {
        if NativeList.countsQueries { sourceQueries += 1 }
        guard index >= 0, index < source.rowCount else { return NativeRow() }
        return source.row(at: index)
    }

    // MARK: - Высоты

    private func applyHeights() {
        switch heights {
        case .uniform(let height):
            baseUniformHeight = height
            table.rowHeight = grown(height)
            measuredHeights = []
        case .measured(let estimate):
            table.rowHeight = grown(estimate)
            measuredHeights = Array(repeating: 0, count: itemCount)
        }
        bridge.wantsRowHeights = isMeasured
        // `NSTableView` запоминает, на что делегат отвечает, в тот миг, когда
        // его назначили. Пока делегата не переназначить, таблица так и будет
        // спрашивать высоту у списка с одинаковыми строками — или наоборот.
        table.delegate = nil
        table.delegate = bridge
        table.reloadData()
    }

    /// Считаются ли высоты строк по тексту.
    private var isMeasured: Bool {
        if case .measured = heights { return true }
        return false
    }

    fileprivate func height(ofTableRow row: Int) -> CGFloat {
        if case .tiles(_, let itemHeight, let gap) = mode { return grown(itemHeight) + gap }
        guard case .measured(let estimate) = heights else { return table.rowHeight }
        guard row >= 0, row < measuredHeights.count else { return estimate }
        let known = measuredHeights[row]
        return known > 0 ? known : estimate
    }

    /// Настоящая высота строки считается тогда же, когда строка впервые
    /// показалась, — на видимые два десятка строк это доли миллисекунды.
    fileprivate func noteRealHeight(ofTableRow row: Int) {
        guard case .measured = heights, row >= 0, row < measuredHeights.count, let source else { return }
        let width = contentWidth
        // Висота рядка залежить від ширини: те саме речення на вузькому місці
        // переноситься більше разів. Ширина міняється не лише коли міняється
        // наш власний розмір (тоді `layout` сам скидає виміряне), а й коли
        // з'являється смуга прокрутки чи стовпець стає на своє місце вже
        // після першого малювання. Власник 19.09.2026: «при запуске программы
        // часто окно со списком стихов или куплетов отображается с
        // перекрытием некоторых строк, исправляется если переключить песню
        // или главу». Тому міряне пам'ятає свою ширину, і на іншій —
        // міряється наново.
        if abs(width - measuredAtWidth) > 0.5 {
            measuredAtWidth = width
            if measuredHeights.contains(where: { $0 > 0 }) {
                measuredHeights = Array(repeating: 0, count: measuredHeights.count)
                heightsToNote.formUnion(IndexSet(integersIn: 0..<measuredHeights.count))
            }
        }
        guard measuredHeights[row] == 0 else { return }
        let layout = NativeRowLayout(row: ask(source, row), width: width, style: style, measure: true)
        let real = max(1, layout.height)
        measuredHeights[row] = real
        // Спрашивать таблицу о её же строке, пока она эту строку строит,
        // нельзя — AppKit ругается на повторный вход. Сверку делает
        // отложенный проход: он и так сравнивает высоты перед пересчётом.
        heightsToNote.insert(row)
        scheduleHeightNote()
    }

    private func scheduleHeightNote() {
        guard !noteScheduled else { return }
        noteScheduled = true
        // Двигать высоты прямо посреди раскладки нельзя: `NSTableView` сейчас
        // как раз строит строки. Дожидаемся конца прохода.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.noteScheduled = false
            let indexes = self.heightsToNote
            self.heightsToNote.removeAll()
            guard !indexes.isEmpty else { return }
            let live = indexes.filteredIndexSet { $0 < self.table.numberOfRows }
            guard !live.isEmpty else { return }
            self.table.noteHeightOfRows(withIndexesChanged: live)
        }
    }

    // MARK: - Самоперевірка

    /// Чи вміщається рядок у відведену йому висоту.
    ///
    /// `потрібно` — висота, якої просить текст рядка за поточним кеглем і
    /// шириною стовпця; `дано` — висота, яку рядкові відводить таблиця.
    /// Коли потрібно більше, ніж дано, текст або обрізається, або наповзає
    /// на сусідній рядок — саме на це скаржився власник після зміни вигляду
    /// списків.
    /// Які рядки зараз на екрані — самоперевірці: висоту решти рядків
    /// список навмисно не рахує, поки вони не показалися.
    var visibleRows: Range<Int> {
        let visible = table.rows(in: scrollView.contentView.bounds)
        guard visible.length > 0 else { return 0..<0 }
        let upper = min(table.numberOfRows, visible.location + visible.length)
        return visible.location..<max(visible.location, upper)
    }

    /// Ширини, за якими рахують і малюють рядок, — самоперевірці.
    /// Розійшлися вони — і текст ріжеться по нижньому краю: міряли по
    /// широкому, а малюють по вузькому (смуга прокрутки з'їдає точки).
    func widths(ofRow index: Int) -> (measured: CGFloat, cell: CGFloat) {
        let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false)?.bounds.width ?? 0
        return (contentWidth, cell)
    }

    func fit(ofRow index: Int) -> (drawn: CGFloat, given: CGFloat, cut: Bool)? {
        guard let source, index >= 0, index < source.rowCount else { return nil }
        let row = ask(source, index)
        let width = tileStep(width: contentWidth)

        // Плитка: підпис і назва в один рядок кожен, кегль підганяється.
        if case .tiles(_, let itemHeight, _) = mode {
            let title = row.lead.isEmpty ? row.text : row.lead
            let hasCaption = !row.lead.isEmpty && !row.text.isEmpty
            let block = style.leadLineHeight + (hasCaption ? style.detailLineHeight + 1 : 0)
            let inner = max(1, width - 6)
            var cut = fitsCut(title, font: style.leadFont, width: inner, minimum: 0.72)
            if hasCaption, fitsCut(row.text, font: style.detailFont, width: inner, minimum: 0.55) { cut = true }
            return (block, grown(itemHeight), cut)
        }

        let given: CGFloat
        if case .measured = heights { given = height(ofTableRow: index) } else { given = table.rowHeight }
        let full = NativeRowLayout(row: row, width: width, style: style, measure: !row.singleLine)
        if !row.singleLine, full.height <= given + 0.5 { return (full.height, given, false) }
        // Список із міряними висотами малює перенос як є: висота наздожене.
        if !row.singleLine, isMeasured { return (min(full.height, given), given, false) }
        // Той самий запасний шлях, яким іде малювання: один рядок, а в тісному
        // рядку — ще й по центру, без відступів.
        let one = NativeRowLayout(row: row, width: width, style: style, measure: false)
        let font = row.bold ? style.boldTextFont : style.textFont
        // Текст кеглем не підганяється (див. NativeRowCell), тож і «обрізано»
        // рахуємо за справжнім кеглем.
        let cut = fitsCut(row.text, font: font, width: one.textRect.width, minimum: 1)
        if one.height <= given + 0.5 { return (one.height, given, cut) }
        return (ceil(style.textLineHeight), given, cut)
    }

    /// Чи ріже текст три крапки навіть після підгонки кегля.
    private func fitsCut(_ text: String, font: NSFont, width: CGFloat, minimum: CGFloat) -> Bool {
        guard !text.isEmpty, width > 1 else { return false }
        let shrunk = NativeRowCell.fitted(font, to: text, width: width, minimum: minimum)
        let need = (text as NSString).size(withAttributes: [.font: shrunk]).width
        return need > width + 0.5
    }

    /// Скільки рядків у списку — самоперевірці.
    var rowsNow: Int { source?.rowCount ?? 0 }

    /// Де на списку лежить елемент (у координатах самого списку) — самоперевірці:
    /// вона клацає в середину і дивиться, чи туди влучила.
    func frameOfItem(_ index: Int) -> NSRect? {
        guard index >= 0, index < itemCount else { return nil }
        let row = tableRow(ofItem: index)
        guard row >= 0, row < table.numberOfRows else { return nil }
        var rect = table.rect(ofRow: row)
        if columnsPerRow > 1, case .tiles(_, _, let gap) = mode {
            let step = tileStep(width: contentWidth)
            let column = index - row * columnsPerRow
            rect = NSRect(x: rect.minX + CGFloat(column) * step, y: rect.minY,
                          width: max(1, step - gap), height: rect.height)
        }
        return convert(rect, from: table)
    }

    // MARK: - Плитка

    private func tileColumns(for width: CGFloat) -> Int {
        guard case .tiles(let minWidth, _, let gap) = mode, width > 0 else { return 1 }
        return max(1, Int((width + gap) / (minWidth + gap)))
    }

    private func tileStep(width: CGFloat) -> CGFloat {
        guard columnsPerRow > 1, case .tiles(_, _, let gap) = mode else { return width }
        return (width + gap) / CGFloat(columnsPerRow)
    }

    // MARK: - Оформление

    private func rebuildStyle() {
        style = NativeListStyle(fontSize: fontSize, metrics: metrics)
        table.backgroundColor = metrics.background
        scrollView.backgroundColor = metrics.background
        if case .measured = heights {
            measuredHeights = Array(repeating: 0, count: itemCount)
            measuredAtWidth = 0
        }
        columnsPerRow = tileColumns(for: contentWidth)
        table.reloadData()
    }

    private func applyHeader() {
        guard let titles = headerTitles, !titles.isEmpty else {
            table.headerView = nil
            return
        }
        let header = NativeListHeader()
        header.titles = titles
        header.metrics = metrics
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
        table.headerView = header
    }

    // MARK: - Мост к NSTableView

    /// Отдельный объект нарочно: `NSTableView` спрашивает делегата о высоте
    /// строки только если тот на это отвечает. Когда высоты одинаковые,
    /// отвечать нельзя — иначе таблица уйдёт на медленный путь переменных
    /// высот и спросит про каждую из 3400 строк.
    private final class Bridge: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var list: NativeList?
        /// Отвечать ли на вопрос о высоте строки. Величина простая нарочно:
        /// `responds(to:)` зовут из мест, где до состояния списка не дотянуться.
        var wantsRowHeights = false

        init(list: NativeList, wantsRowHeights: Bool) {
            self.list = list
            self.wantsRowHeights = wantsRowHeights
            super.init()
        }

        override func responds(to selector: Selector!) -> Bool {
            if selector == #selector(NSTableViewDelegate.tableView(_:heightOfRow:)) {
                return wantsRowHeights
            }
            return super.responds(to: selector)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            guard let list else { return 0 }
            guard list.columnsPerRow > 1 else { return list.itemCount }
            return (list.itemCount + list.columnsPerRow - 1) / list.columnsPerRow
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            list?.height(ofTableRow: row) ?? 22
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let list else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NativeRowCell)
                ?? {
                    let fresh = NativeRowCell()
                    fresh.identifier = identifier
                    return fresh
                }()
            list.refresh(cell: cell, tableRow: row)
            list.noteRealHeight(ofTableRow: row)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    }
}

/// Таблица отдаёт мышь и клавиши списку: своё выделение у неё выключено.
private final class NativeTableView: NSTableView {
    weak var owner: NativeList?

    override func mouseDown(with event: NSEvent) { owner?.handleMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { owner?.handleMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { owner?.handleMouseUp(event) }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = owner?.handleRightMouseDown(event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Ctrl со щелчком у автора значит «добавить строку вразбивку», а не
    /// «показать меню». Меню остаётся на правой кнопке.
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func keyDown(with event: NSEvent) {
        if owner?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    /// ⌘A з меню «Редагування» приходить сюди, у таблицю, раніше за список:
    /// виділення веде сам список, тож і команду віддаємо йому.
    override func selectAll(_ sender: Any?) { owner?.selectAll() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(selectAll(_:)) {
            return owner.map { $0.allowsMultipleSelection && $0.itemCount > 0 } ?? false
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// Шапка списка для вида «Таблица» окна выбора Книги.
private final class NativeListHeader: NSTableHeaderView {
    var titles: [String] = []
    var metrics = NativeListMetrics()

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()

        let font = NSFont.systemFont(ofSize: 11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ]
        var x = metrics.padding.left
        let y = (bounds.height - font.pointSize - 3) / 2
        for (position, title) in titles.enumerated() {
            let width: CGFloat
            switch position {
            case 0: width = metrics.leadWidth > 0 ? metrics.leadWidth : 60
            case 1: width = bounds.width - x - metrics.padding.right - metrics.detailWidth - 4
            default: width = metrics.detailWidth
            }
            guard width > 0 else { break }
            (title as NSString).draw(in: NSRect(x: x, y: y, width: width, height: font.pointSize + 4),
                                     withAttributes: attributes)
            x += width + 4
        }
    }
}
