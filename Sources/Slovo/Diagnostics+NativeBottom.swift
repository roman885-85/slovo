import AppKit
import SlovoCore

/// Самопроверка нижнего ряда нового окна: План (10), История (11),
/// Предпросмотр (12), Управление (13).
///
/// Глазами это не проверяется. «Предпросмотр обновляется» на вид одинаково и
/// когда на слайд уходит одна отрисовка, и когда пересобирается полокна:
/// разница видна только в задержке, а задержку на служении замечают поздно.
/// Поэтому каждая проверка считает по-настоящему — сколько раз спросили
/// источник, куда встал пункт после перетаскивания, сколько миллисекунд стоит
/// смена слайда.
extension Diagnostics {

    static func nativeBottomSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        checks.append(contentsOf: bottomRender())

        // Дальше нужно настоящее окно: без раскладки ни один список не заводит
        // строк, а слой предпросмотра не получает размера.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let host = NSView(frame: window.contentLayoutRect)
        window.contentView = host

        let row = NativeBottomRow(state: state)
        row.frame = NSRect(x: 6, y: 0, width: 1588, height: NativeBottomMetrics.rowHeight)
        host.addSubview(row)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        checks.append(contentsOf: bottomLayout(row))
        checks.append(contentsOf: bottomGrips(row))
        checks.append(contentsOf: bottomPreview(row, state, host))
        checks.append(contentsOf: bottomPlan(row, host))
        checks.append(contentsOf: bottomHistory(row))
        checks.append(contentsOf: bottomControlLabels(row, state))

        row.removeFromSuperview()
        window.contentView = nil
        return checks
    }

    // MARK: - Раскладка

    private static func bottomLayout(_ row: NativeBottomRow) -> [Check] {
        var checks: [Check] = []

        let panes: [(String, NSView)] = [("План", row.plan), ("Історія", row.history),
                                         ("Передпоказ", row.preview), ("Керування", row.control)]
        let empty = panes.filter { $0.1.frame.width < 40 || $0.1.frame.height < 40 }
        checks.append(Check(area: "Нижній ряд", name: "Чотири панелі на місцях",
                            status: empty.isEmpty ? .ok : .failed,
                            detail: empty.isEmpty
                                ? panes.map { "\($0.0) \(Int($0.1.frame.width))" }
                                    .joined(separator: ", ") + " точок завширшки"
                                : "не розклалися: " + empty.map(\.0).joined(separator: ", ")))

        let overlap = zip(panes, panes.dropFirst()).contains { left, right in
            left.1.frame.maxX > right.1.frame.minX + 0.5
        }
        checks.append(Check(area: "Нижній ряд", name: "Панелі не налазять одна на одну",
                            status: overlap ? .failed : .ok,
                            detail: overlap ? "панелі перекриваються" : "ідуть підряд із просвітом 6"))

        // Стороны слайда 4:3 — предпросмотр обязан показывать ту же рамку,
        // что уйдёт на проектор.
        let preview = row.preview.frame
        let ratio = preview.height > 0 ? preview.width / preview.height : 0
        checks.append(Check(area: "Нижній ряд", name: "Слайд передпоказу тримає 4:3",
                            status: abs(ratio - 4.0 / 3.0) < 0.02 ? .ok : .failed,
                            detail: String(format: "%.0f×%.0f, відношення %.3f (чекали 1.333)",
                                           preview.width, preview.height, ratio)))

        let control = row.control.frame.width
        checks.append(Check(area: "Нижній ряд", name: "«Керування» тієї ширини, що просять підписи",
                            status: abs(control - row.control.preferredWidth) < 1
                                && control >= NativeBottomMetrics.controlMinWidth ? .ok : .failed,
                            detail: "ширина \(Int(control)), треба \(Int(row.control.preferredWidth))"))

        // Ширина окна ходит от 1120 до целого экрана, и оба края надо пройти:
        // в узком окне у Плана пропадали кнопки, а в широком лишние триста
        // точек доставались пустоте справа от слайда, а не спискам.
        let wide = row.frame
        func widths(at width: CGFloat) -> (plan: CGFloat, history: CGFloat, preview: CGFloat) {
            row.frame = NSRect(x: wide.minX, y: wide.minY, width: width, height: wide.height)
            row.layoutSubtreeIfNeeded()
            // Панель предпросмотра — это не слайд: слайд держит 4:3 и стоит в
            // ней слева, а мерить надо саму панель — от Истории до
            // «Управления», за вычетом двух просветов.
            return (row.plan.frame.width, row.history.frame.width,
                    row.control.frame.minX - row.history.frame.maxX
                        - NativeBottomMetrics.gap * 2)
        }

        // Живий екран забирає свою ширину першим — так просив власник, і по
        // ньому ведуть указку. Тому міряємо на вікні, широкому настільки, щоб
        // вистачило і йому, і спискам до їхніх меж.
        let live = NativeBottomMetrics.liveWidth
        let roomy = widths(at: 1588 + live)
        let grown = abs(roomy.plan - NativeBottomMetrics.planMaxWidth) < 1
            && abs(roomy.history - NativeBottomMetrics.historyMaxWidth) < 1
        let custom = NativeBottomMetrics.planWidthIsCustom || NativeBottomMetrics.historyWidthIsCustom
        checks.append(Check(area: "Нижній ряд", name: "У широкому вікні простір дістається спискам",
                            status: custom ? .skipped : grown ? .ok : .failed,
                            detail: custom ? "ширину списків поставив оператор — вони не ростуть навмисно" : grown
                                ? "План \(Int(roomy.plan)) та Історія \(Int(roomy.history)) "
                                    + "доросли до своїх меж (живий екран \(Int(live)))"
                                : "списки лишилися \(Int(roomy.plan)) і \(Int(roomy.history)) — "
                                    + "простір пішов у порожнечу праворуч від слайда"))

        // 1108 — наименьшая ширина окна из описи (1120) минус поля ящика.
        // Второй замер — самое узкое окно, в которое ещё помещаются все
        // панели на своих нижних пределах: там списки ужаты до упора, а живой
        // экран спрятан, — без него половина арифметики не проверена. Раньше
        // тут стояло 960, но «Керування» теперь берёт ширину по подписям
        // (українською 362 замість 340), и в 960 минимумы уже не
        // помещаются физически — это был бы замер невозможного окна.
        let tightest = ceil(NativeBottomMetrics.planMinWidth + NativeBottomMetrics.historyMinWidth
            + row.control.preferredWidth + NativeBottomMetrics.previewMinWidth
            + NativeBottomMetrics.dividerWidth * 2 + NativeBottomMetrics.gap)
        var floors: [String] = []
        var kept = true
        for width in [CGFloat(1108), tightest] {
            let got = widths(at: width)
            kept = kept
                && got.plan >= NativeBottomMetrics.planMinWidth - 0.5
                && got.history >= NativeBottomMetrics.historyMinWidth - 0.5
                && got.preview >= NativeBottomMetrics.previewMinWidth - 0.5
            floors.append(String(format: "при %.0f — План %.0f, Історія %.0f, передпоказ %.0f",
                                 width, got.plan, got.history, got.preview))
        }
        checks.append(Check(area: "Нижній ряд", name: "У вузькому вікні ніхто не пропадає",
                            status: kept ? .ok : .failed,
                            detail: floors.joined(separator: "; ") + " (не менше 150, 160 і 280)"))
        row.frame = wide
        row.layoutSubtreeIfNeeded()
        return checks
    }

    // MARK: - Роздільники

    /// Роздільники за Планом і за Історією: тягнуть, пам'ятають між
    /// запусками, не з'їдають передпоказ, подвійним клацанням повертаються.
    /// Власник: «хочу, щоб розміри плану, історії й передпоказу мінялися
    /// перетягуванням».
    private static func bottomGrips(_ row: NativeBottomRow) -> [Check] {
        var checks: [Check] = []
        let area = "Нижній ряд"
        let defaults = UserDefaults.standard
        let savedPlan = defaults.object(forKey: NativeBottomMetrics.planWidthKey)
        let savedHistory = defaults.object(forKey: NativeBottomMetrics.historyWidthKey)
        defer {
            defaults.set(savedPlan, forKey: NativeBottomMetrics.planWidthKey)
            defaults.set(savedHistory, forKey: NativeBottomMetrics.historyWidthKey)
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
        }
        NativeBottomMetrics.resetPlanWidth()
        NativeBottomMetrics.resetHistoryWidth()
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        let planBefore = row.plan.frame.width
        let historyBefore = row.history.frame.width
        // Знімок ряду з роздільниками — щоб на око звірити, що крапки видно.
        let picture = snapshot(row, to: "slovo-низ-роздільники.png") ? "; знімок ~/Library/Logs/slovo-низ-роздільники.png" : ""

        // Як рукою: роздільник повідомляє зсув, ряд перекладається одразу.
        row.planDivider.onDrag?(60)
        let planAfter = row.plan.frame.width
        let historyAfterPlan = row.history.frame.width
        row.historyDivider.onDrag?(-40)
        let historyAfter = row.history.frame.width
        let remembered = NativeBottomMetrics.planWidthIsCustom && NativeBottomMetrics.historyWidthIsCustom
        let inOrder = row.plan.frame.maxX <= row.planDivider.frame.minX + 0.5
            && row.planDivider.frame.maxX <= row.history.frame.minX + 0.5
            && row.history.frame.maxX <= row.historyDivider.frame.minX + 0.5
            && row.historyDivider.frame.maxX <= row.preview.frame.minX + 0.5
        let dragged = abs(planAfter - (planBefore + 60)) < 1 && abs(historyAfter - (historyAfterPlan - 40)) < 1
        checks.append(Check(area: area, name: "План та Історію тягнуть роздільниками",
                            status: dragged && remembered && inOrder ? .ok : .failed,
                            detail: "План \(Int(planBefore)) → +60 → \(Int(planAfter)); "
                                + "Історія \(Int(historyAfterPlan)) → −40 → \(Int(historyAfter)); "
                                + (remembered ? "обидві ширини записано" : "ширини НЕ записано")
                                + (inOrder ? "; роздільники стоять між панелями" : "; роздільники не на місці") + picture))

        // Далі за найменший передпоказ список не пускають.
        row.planDivider.onDrag?(5000)
        let kept = row.lastPreviewWidth >= NativeBottomMetrics.previewMinWidth - 0.5
        checks.append(Check(area: area, name: "Списки не з'їдають передпоказ",
                            status: kept ? .ok : .failed,
                            detail: "потягнули План на 5000: План \(Int(row.plan.frame.width)), "
                                + "передпоказ \(Int(row.lastPreviewWidth)) (не менше \(Int(NativeBottomMetrics.previewMinWidth)))"))

        // Подвійне клацання — усе як було.
        row.planDivider.onReset?()
        row.historyDivider.onReset?()
        let back = abs(row.plan.frame.width - planBefore) < 1 && abs(row.history.frame.width - historyBefore) < 1
            && !NativeBottomMetrics.planWidthIsCustom && !NativeBottomMetrics.historyWidthIsCustom
        checks.append(Check(area: area, name: "Подвійне клацання по роздільнику повертає автоматичну ширину",
                            status: back ? .ok : .failed,
                            detail: "План \(Int(row.plan.frame.width)) (було \(Int(planBefore))), "
                                + "Історія \(Int(row.history.frame.width)) (було \(Int(historyBefore)))"))
        return checks
    }

    // MARK: - Предпросмотр

    private static func bottomRender() -> [Check] {
        var checks: [Check] = []
        var style = SlideStyle()
        style.transition = .fade
        let size = CGSize(width: 320, height: 240)

        let slide = Slide(mainText: "Ибо так возлюбил Бог мир, что отдал Сына Своего Единородного",
                          secondaryTexts: ["For God so loved the world"],
                          reference: "Ин 3:16")
        let blocks = NativeSlideRender.blocks(slide: slide, style: style, size: size)
        checks.append(Check(area: "Нижній ряд", name: "Слайд розкладено на три шматки",
                            status: blocks.count == 3 ? .ok : .failed,
                            detail: "цитата, другий переклад і адреса — вийшло шматків \(blocks.count)"))

        let inside = blocks.allSatisfy { $0.rect.minY >= -0.5 && $0.rect.maxY <= size.height + 0.5 }
        let ordered = zip(blocks, blocks.dropFirst()).allSatisfy { $0.rect.minY < $1.rect.minY }
        checks.append(Check(area: "Нижній ряд", name: "Шматки йдуть згори вниз і не вилазять",
                            status: inside && ordered ? .ok : .failed,
                            detail: blocks.map { String(format: "%.0f…%.0f", $0.rect.minY, $0.rect.maxY) }
                                .joined(separator: ", ") + " при висоті \(Int(size.height))"))

        let picture = NativeSlideRender.text(slide: slide, style: style, size: size)
        checks.append(Check(area: "Нижній ряд", name: "Напис малюється просто в картинку",
                            status: picture != nil
                                && picture?.width == 320 && picture?.height == 240 ? .ok : .failed,
                            detail: picture.map { "\($0.width)×\($0.height) точок, без жодного виду" }
                                ?? "картинка не намалювалася"))

        let blank = NativeSlideRender.text(slide: .blank, style: style, size: size)
        checks.append(Check(area: "Нижній ряд", name: "Порожній слайд нічого не малює",
                            status: blank == nil ? .ok : .failed,
                            detail: blank == nil ? "напису немає — лише підкладка" : "намалювалося зайве"))

        // Тот же слайд другим кеглем — другой отпечаток отрисовки, но тот же
        // отпечаток текста: растворение на смену настроек играть нельзя.
        var bigger = style
        bigger.main.fontSize *= 1.4
        // Кегль вырос: рисовать надо заново, а растворение играть нельзя.
        let sameText = NativeSlideRender.textIdentity(slide: slide)
        let otherText = NativeSlideRender.textIdentity(slide: Slide(mainText: "Другой стих",
                                                                    reference: "Ин 3:16"))
        let otherDraw = NativeSlideRender.drawIdentity(slide: slide, style: style, size: size)
            != NativeSlideRender.drawIdentity(slide: slide, style: bigger, size: size)
        let right = sameText != otherText && otherDraw
        checks.append(Check(area: "Нижній ряд", name: "Зміна кегля не вважається зміною слайда",
                            status: right ? .ok : .failed,
                            detail: right
                                ? "інший текст — інший відбиток; інший кегль — той самий напис, "
                                    + "але перемальований"
                                : "відбитки переплутано: повзунок налаштувань заблимає"))

        let backdrop = NativeSlideRender.backdropIdentity(style: style, size: size)
        var dimmed = style
        dimmed.dimBackground = 0.3
        checks.append(Check(area: "Нижній ряд", name: "Підкладка відрізняється від напису",
                            status: backdrop != NativeSlideRender.backdropIdentity(style: dimmed, size: size)
                                ? .ok : .failed,
                            detail: "затемнення фону міняє підкладку і не чіпає тексту"))
        return checks
    }

    private static func bottomPreview(_ row: NativeBottomRow, _ state: AppState,
                                      _ host: NSView) -> [Check] {
        var checks: [Check] = []
        var style = SlideStyle()
        style.transition = .fade

        let verses = (1...40).map { "Стих номер \($0). " + String(repeating: "слово ", count: 14 + $0 % 12) }

        func median(_ repeats: Int, _ body: (Int) -> Void) -> Double {
            var times: [Double] = []
            times.reserveCapacity(repeats)
            for pass in 0..<repeats {
                let start = DispatchTime.now().uptimeNanoseconds
                body(pass)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            return times.sorted()[times.count / 2]
        }

        // Где именно уходит время на смену стиха: сперва надпись рисуется в
        // картинку, потом картинка ложится в слой. Без этого деления «медленно»
        // нечем чинить — все попытки ускорить слой были бы мимо.
        let size = row.preview.bounds.size
        let drawing = median(41) { pass in
            _ = NativeSlideRender.text(slide: Slide(mainText: verses[pass % verses.count],
                                                    reference: "Ин 3:\(pass % 30 + 1)"),
                                       style: style, size: size)
        }
        let canvas = median(41) { _ in _ = NativeSlideRender.backdrop(style: style, size: size) }
        checks.append(Check(area: "Нижній ряд", name: "З чого складається зміна слайда",
                            status: .ok,
                            detail: String(format: "напис %.3f мс, підкладка %.3f мс на %.0f×%.0f",
                                           drawing, canvas, size.width, size.height)))

        let switching = median(41) { pass in
            row.preview.show(slide: Slide(mainText: verses[pass % verses.count],
                                          reference: "Ин 3:\(pass % 30 + 1)"),
                             style: style)
        }
        // Поріг — кадр у 60 Гц. Але в повному прогоні машина зайнята сама
        // собою (перед цим ішли NDI, веб і захоплення екрана), і те саме
        // малювання займає на кілька мілісекунд більше. Тому «не встигли в
        // кадр» це попередження, а помилка — лише тоді, коли не встигли й у
        // півтора кадри: ось тоді зміна вірша справді видна оком.
        checks.append(Check(area: "Нижній ряд", name: "Швидкість: передпоказ на зміну вірша",
                            status: switching < 16 ? .ok : (switching < 25 ? .warning : .failed),
                            detail: String(format: "%.3f мс до пікселів (кадр — 16 мс)", switching)))

        let same = Slide(mainText: verses[0], reference: "Ин 3:1")
        row.preview.show(slide: same, style: style)
        host.displayIfNeeded()
        let repeated = median(41) { _ in row.preview.show(slide: same, style: style) }
        checks.append(Check(area: "Нижній ряд", name: "Той самий слайд удруге нічого не коштує",
                            status: repeated < switching / 2 || repeated < 0.2 ? .ok : .warning,
                            detail: String(format: "повтор %.3f мс проти %.3f мс на зміну",
                                           repeated, switching)))

        row.preview.isLive = true
        let live = row.preview.isLive
        row.preview.isLive = false
        checks.append(Check(area: "Нижній ряд", name: "Показ у зал позначено рамкою",
                            status: live ? .ok : .failed,
                            detail: live ? "червона рамка у 2 точки, як у попередньому вікні"
                                         : "рамка не перемкнулася"))
        return checks
    }

    // MARK: - План

    private static func bottomPlan(_ row: NativeBottomRow, _ host: NSView) -> [Check] {
        var checks: [Check] = []
        let desk = DeskModel.shared

        // План человека самопроверка не трогает: он собран к служению, и
        // ронять его ради проверки нельзя. Читаем только число пунктов.
        checks.append(Check(area: "Нижній ряд", name: "Список плану збігається з планом",
                            status: row.plan.list.itemCount == desk.plan.count ? .ok : .failed,
                            detail: "у плані \(desk.plan.count) пунктів, "
                                + "список тримає \(row.plan.list.itemCount)"))

        // Клацання лише виділяє пункт; подвійне клацання та Enter відкривають
        // (власник, 14.09.2026). Рахуємо відкриття, а не дивимося на стан:
        // пункти в плані бувають будь-які.
        if desk.plan.count > 1 {
            let before = desk.planActivationsForCheck
            row.plan.list.click(item: 1)
            let afterClick = desk.planActivationsForCheck
            row.plan.list.click(item: 1, clickCount: 2)
            let afterDouble = desk.planActivationsForCheck
            row.plan.list.click(item: 0)
            row.plan.list.pressReturnForCheck()
            let afterReturn = desk.planActivationsForCheck
            let ok = afterClick == before && afterDouble == before + 1 && afterReturn == before + 2
            checks.append(Check(area: "Нижній ряд", name: "Пункт Плану: клацання виділяє, подвійне клацання і Enter відкривають",
                                status: ok ? .ok : .failed,
                                detail: "після клацання відкриттів +\(afterClick - before), після подвійного +\(afterDouble - afterClick), "
                                    + "після Enter +\(afterReturn - afterDouble)"))
        }

        // Історія — так само, як План (власник, 15.09.2026: «когда по истории
        // нажимаешь, то сразу идет вывод на проектор»).
        if desk.history.records.count > 1 {
            let order = desk.history.records.map(\.id)
            let before = desk.historyActivationsForCheck
            row.history.list.click(item: 1)
            let afterClick = desk.historyActivationsForCheck
            row.history.list.click(item: 1, clickCount: 2)
            let afterDouble = desk.historyActivationsForCheck
            row.history.list.click(item: 0)
            row.history.list.pressReturnForCheck()
            let afterReturn = desk.historyActivationsForCheck
            let ok = afterClick == before && afterDouble == before + 1 && afterReturn == before + 2
            checks.append(Check(area: "Нижній ряд", name: "Запис Історії: клацання виділяє, подвійне клацання і Enter виводять",
                                status: ok ? .ok : .failed,
                                detail: "після клацання виведень +\(afterClick - before), після подвійного +\(afterDouble - afterClick), "
                                    + "після Enter +\(afterReturn - afterDouble)"))
            // Показ відкладений, поки розділ читається, — чекаємо.
            wait(untilTrue: { false }, seconds: 1.5)
            let kept = desk.history.records.map(\.id) == order
            checks.append(Check(area: "Нижній ряд", name: "Показ із Історії не міняє Історію",
                                status: kept ? .ok : .failed,
                                detail: kept ? "записів \(order.count), порядок той самий"
                                             : "було \(order.count) записів, стало \(desk.history.records.count); перший запис інший: \(desk.history.records.first?.id != order.first)"))
        } else {
            checks.append(Check(area: "Нижній ряд", name: "Запис Історії: клацання виділяє, подвійне клацання і Enter виводять",
                                status: .skipped, detail: "в Історії менше двох записів"))
        }

        // Перетаскивание проверяем на отдельном списке той же выделки: так
        // проверяется именно перенос, а не содержимое чужого плана.
        let sample = SamplePlan(count: 12)
        let list = NativeList(mode: .list, heights: .uniform(18), fontSize: 12)
        list.frame = NSRect(x: 0, y: 0, width: 190, height: 160)
        host.addSubview(list)
        list.source = sample
        let reorder = NativeListReorder(list: list)
        reorder.onMove = { [weak list] from, to in
            sample.move(from: from, to: to)
            list?.reload()
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        list.click(item: 3)
        checks.append(Check(area: "Нижній ряд", name: "Клацання по пункту плану виділяє його",
                            status: list.selection == IndexSet(integer: 3) ? .ok : .failed,
                            detail: "клацнули 4-й пункт, виділено \(describeRows(list.selection))"))

        guard let table = NativeListProbe.table(in: list), table.numberOfRows > 6 else {
            list.source = nil
            list.removeFromSuperview()
            checks.append(Check(area: "Нижній ряд", name: "Пункт плану переноситься мишею",
                                status: .failed, detail: "список не завів рядків — розкладки не було"))
            return checks
        }

        // Точки считаем в координатах таблицы (счёт сверху вниз) и переводим
        // в координаты списка: у списка счёт снизу вверх, и «ниже» с «выше»
        // в них меняются местами.
        func point(row: Int, part: CGFloat) -> NSPoint {
            let rect = table.rect(ofRow: row)
            return list.convert(NSPoint(x: 20, y: rect.minY + rect.height * part), from: table)
        }

        let travelling = sample.titles[1]
        reorder.begin(at: point(row: 1, part: 0.5))
        reorder.track(to: point(row: 5, part: 0.8))
        let aim = reorder.target
        reorder.drop()
        let moved = sample.titles[5] == travelling
        checks.append(Check(area: "Нижній ряд", name: "Пункт плану переноситься мишею",
                            status: moved ? .ok : .failed,
                            detail: moved
                                ? "«\(travelling)» поїхав із 2-го місця на 6-те, мітка вставки стояла на \(aim ?? -1)"
                                : "після перенесення на 6-му місці «\(sample.titles[5])», мітка була на \(aim ?? -1)"))

        // Отпустить там же, откуда взяли, — не перестановка.
        let before = sample.titles
        reorder.begin(at: point(row: 1, part: 0.5))
        reorder.track(to: point(row: 1, part: 0.4))
        reorder.drop()
        checks.append(Check(area: "Нижній ряд", name: "Перенесення на своє ж місце нічого не міняє",
                            status: sample.titles == before ? .ok : .failed,
                            detail: "порядок пунктів лишився попереднім"))

        // Стоимость одного шага перетаскивания.
        reorder.begin(at: point(row: 1, part: 0.5))
        var times: [Double] = []
        for pass in 0..<41 {
            let start = DispatchTime.now().uptimeNanoseconds
            reorder.track(to: point(row: 1 + pass % 6, part: 0.3))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        reorder.cancel()
        let step = times.sorted()[times.count / 2]
        checks.append(Check(area: "Нижній ряд", name: "Швидкість: крок перетягування пункту",
                            status: step < 16 ? .ok : .failed,
                            detail: String(format: "%.3f мс на крок (кадр — 16 мс)", step)))

        list.source = nil
        list.removeFromSuperview()
        return checks
    }

    /// Список пунктов для проверки переноса — тот же вид строки, что у Плана.
    private final class SamplePlan: NativeListSource {
        private(set) var titles: [String]
        init(count: Int) { titles = (1...count).map { "Пункт \($0)" } }
        var rowCount: Int { titles.count }
        func row(at index: Int) -> NativeRow { NativeRow(text: titles[index], singleLine: true) }
        /// Позиция вставки считается ДО изъятия — так же, как в `ServicePlan`.
        func move(from: Int, to: Int) {
            guard titles.indices.contains(from), to >= 0, to <= titles.count else { return }
            let item = titles.remove(at: from)
            titles.insert(item, at: to > from ? to - 1 : to)
        }
    }

    private static func describeRows(_ set: IndexSet) -> String {
        set.isEmpty ? "нічого" : set.map(String.init).joined(separator: ", ")
    }

    // MARK: - История

    private static func bottomHistory(_ row: NativeBottomRow) -> [Check] {
        let desk = DeskModel.shared
        row.history.reloadHistory()
        let list = row.history.list
        let matches = list.itemCount == desk.history.count
        var checks: [Check] = [
            Check(area: "Нижній ряд", name: "Історія віддає потрібне число рядків",
                  status: matches ? .ok : .failed,
                  detail: "у журналі \(desk.history.count) записів, список тримає \(list.itemCount)"),
        ]

        // Список виртуальный при любой длине: 3000 строк — а построено два
        // десятка. У автора история ограничена шестьюдесятью, но правило
        // одно на все списки окна.
        let long = CountingCaptions(count: 3000)
        let probe = NativeList(mode: .list, heights: .uniform(16), fontSize: 11)
        probe.frame = NSRect(x: 0, y: 0, width: 220, height: 180)
        row.history.addSubview(probe)
        probe.source = long
        row.history.layoutSubtreeIfNeeded()
        row.history.displayIfNeeded()
        let asked = long.asked
        let visible = probe.visibleItems.count

        var times: [Double] = []
        for pass in 0..<41 {
            let start = DispatchTime.now().uptimeNanoseconds
            probe.scrollTo((pass * 137) % probe.itemCount, place: .center)
            row.history.layoutSubtreeIfNeeded()
            row.history.displayIfNeeded()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let scroll = times.sorted()[times.count / 2]
        probe.source = nil
        probe.removeFromSuperview()

        checks.append(Check(area: "Нижній ряд", name: "Довжина історії не впливає на роботу",
                            status: visible > 0 && asked <= max(8, visible * 3) ? .ok : .failed,
                            detail: "3000 рядків, видно \(visible), джерело спитали про \(asked)"))
        checks.append(Check(area: "Нижній ряд", name: "Швидкість: прокрутка довгої історії",
                            status: scroll < 16 ? .ok : .failed,
                            detail: String(format: "%.3f мс на 3000 рядків (кадр — 16 мс)", scroll)))
        return checks
    }

    /// Источник, который считает, о скольких строках его спросили.
    private final class CountingCaptions: NativeListSource {
        private let captions: [String]
        private var seen = Set<Int>()
        init(count: Int) {
            captions = (1...count).map { "Быт. \($0)- В начале сотворил Бог небо и землю." }
        }
        var asked: Int { seen.count }
        var rowCount: Int { captions.count }
        func row(at index: Int) -> NativeRow {
            seen.insert(index)
            return NativeRow(text: captions[index], singleLine: true)
        }
    }
    /// Власник: «в главном меню не все надписи видно целиком (керування)».
    /// Кожен підпис має влазити у свою кнопку — українською, англійською й
    /// російською; галочка «Активна» стоїть у рядку підпису панелі й перемикає
    /// настройку.
    private static func bottomControlLabels(_ row: NativeBottomRow, _ state: AppState) -> [Check] {
        var checks: [Check] = []
        let languageBefore = state.languageCode
        var clipped: [String] = []
        for language in ["uk", "en", "ru"] {
            state.setLanguage(code: language)
            Signals.shared.send(.language)
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            for button in row.control.labelButtonsForCheck
            where ceil(button.fittingSize.width) > button.frame.width + 0.5 {
                clipped.append("\(language): «\(button.title)» \(Int(button.fittingSize.width))>\(Int(button.frame.width))")
            }
            let box = row.control.activeBox
            if box.superview == nil || box.frame.width + 0.5 < ceil(box.fittingSize.width)
                || box.frame.maxX > row.control.frame.maxX + 0.5 || box.title.isEmpty {
                clipped.append("\(language): «\(box.title)» не на місці")
            }
            if abs(row.control.frame.width - row.control.preferredWidth) >= 1 {
                clipped.append("\(language): панель \(Int(row.control.frame.width)), треба \(Int(row.control.preferredWidth))")
            }
        }
        state.setLanguage(code: languageBefore)
        Signals.shared.send(.language)
        row.layoutSubtreeIfNeeded()
        checks.append(Check(area: "Нижній ряд", name: "Підписи «Керування» видно цілком (uk, en, ru)",
                            status: clipped.isEmpty ? .ok : .failed,
                            detail: clipped.isEmpty ? "кнопки й «Активна» вміщають підписи" : clipped.joined(separator: "; ")))

        // Галочка перемикає настройку, і стрілки слухаються її.
        let before = state.arrowsShowLive
        let box = row.control.activeBox
        if box.state != (before ? .on : .off) { box.state = before ? .on : .off }
        box.performClick(nil)
        let flipped = state.arrowsShowLive == !before
        box.performClick(nil)
        let restored = state.arrowsShowLive == before

        var live: [Bool] = []
        var active = true
        let actions = ArrowNavigator.Actions(
            stepVerse: { _, isLive in live.append(isLive) },
            extendSelection: { _, isLive in live.append(isLive) },
            selectAll: {}, isLinked: { true }, isActive: { active },
            show: { live.append(true) }, blackout: {})
        func press(_ code: UInt16) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: 0, windowNumber: 0, context: nil,
                                               characters: " ", charactersIgnoringModifiers: " ",
                                               isARepeat: false, keyCode: code) else { return }
            _ = ArrowNavigator.handle(event, actions: actions)
        }
        // Увімкнено: ↓ іде в зал, → — лише передпоказ (пари «зв'язано»).
        press(125); press(124)
        let onRule = live == [true, false]
        live.removeAll()
        active = false
        // Знято: жодна стрілка в зал не йде; Enter — іде.
        press(125); press(124); press(126); press(123)
        let offArrows = live == [false, false, false, false]
        live.removeAll()
        press(36)
        let enterShows = live == [true]
        checks.append(Check(area: "Нижній ряд", name: "Галочка «Активна» керує виводом стрілками",
                            status: flipped && restored && onRule && offArrows && enterShows ? .ok : .failed,
                            detail: "клацання міняє настройку: \(flipped && restored ? "так" : "ні"); "
                                + "увімкнено — стрілка в зал: \(onRule ? "так" : "ні"); "
                                + "знято — стрілки лише передпоказ: \(offArrows ? "так" : "ні"); "
                                + "Enter виводить: \(enterShows ? "так" : "ні")"))
        return checks
    }
}
