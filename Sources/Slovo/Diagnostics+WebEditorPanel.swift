import AppKit
import SlovoCore

/// Панель редактора веб-слайдів: чи все видно і чи не розвалюється вона під
/// рукою.
///
/// Тут перевіряється не те, що ручка пише в файл (це роблять перевірки
/// поруч), а те, як панель поводиться, поки з нею працюють. Три речі, на які
/// скаржився власник, на око не видно зовсім:
///
/// — «часть кнопок не видно… приходится вручную растягивать окно»: кнопка
///   нікуди не дівається, вона просто за краєм виду;
/// — «ползунки не всегда следуют за мышью при перетягивании»: панель
///   пересобиралась на кожен крок, і повзунок під пальцем зникав разом із
///   рядом — знімок показав би такий самий повзунок на тому самому місці;
/// — «размер текста выполняет изменение только размера адреса»: у сторінці
///   всі блоки, крім головного, стояли на оголошеному кеглі, а не на
///   підібраному.
extension Diagnostics {

    static func webEditorPanelSection(state: AppState) -> [Check] {
        let area = "Редактор веб-слайдів"
        var checks: [Check] = []
        checks.append(barsFitCheck(area: area, state: state))
        checks.append(rowsStayCheck(area: area, state: state))
        checks.append(fittedSizesCheck(area: area))
        checks.append(colourFieldCheck(area: area, state: state))
        return checks
    }

    /// Жодна кнопка не має стояти за краєм виду — навіть у вузькому вікні.
    private static func barsFitCheck(area: String, state: AppState) -> Check {
        let name = "Панель: усі кнопки видно у вузькому вікні"
        let editor = NativeWebSlideEditor(state: state)
        var faults: [String] = []
        var lines: [String] = []
        // Найвужче, що дозволяє вікно, і ще вужче за нього — щоб було видно
        // саме перенос рядів, а не запас.
        for width in [720.0, 900.0, 1240.0] as [CGFloat] {
            editor.frame = NSRect(x: 0, y: 0, width: width, height: 520)
            editor.needsLayout = true
            editor.layoutSubtreeIfNeeded()
            var hidden = 0
            for bar in editor.barsForCheck {
                for button in bar.subviews {
                    let box = bar.convert(button.frame, to: editor)
                    if box.maxX > editor.bounds.width + 0.5 || box.minX < -0.5
                        || box.maxY > editor.bounds.height + 0.5 || box.minY < -0.5 {
                        hidden += 1
                    }
                }
            }
            lines.append("\(Int(width)) пт: за краєм \(hidden)")
            if hidden > 0 { faults.append("при ширині \(Int(width)) пт за краєм \(hidden) кнопок") }
        }
        editor.finish()
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                        + lines.joined(separator: "; "))
    }

    /// Крок ползунка не має пересобирать панель.
    ///
    /// Міряємо за тотожністю: ті самі ряди й той самий елемент усередині
    /// після зміни значення означають, що рука, яка тягне повзунок, не
    /// втратить його посеред руху.
    private static func rowsStayCheck(area: String, state: AppState) -> Check {
        let name = "Панель: ряд не пересобирається на кожен крок ползунка"
        let editor = NativeWebSlideEditor(state: state)
        defer { editor.finish() }
        editor.frame = NSRect(x: 0, y: 0, width: 1100, height: 640)
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()

        let model = editor.modelForCheck
        guard let page = (model.myPages + model.authorPages).first else {
            return Check(area: area, name: name, status: .skipped, detail: "сторінок немає")
        }
        model.open(page)
        let knobs = editor.knobsForCheck
        knobs.refresh()
        let before = knobs.rowsForCheck
        guard !before.isEmpty else {
            return Check(area: area, name: name, status: .skipped, detail: "ручок у розділі немає")
        }
        // Рухаємо перше ж число в розділі — так само, як це робить рука.
        guard let knob = model.sheet.knobs.first(where: {
            if case .number = $0.kind { return !model.sheet.isHandWritten($0) }
            return false
        }) else {
            return Check(area: area, name: name, status: .skipped, detail: "числових ручок немає")
        }
        let was = model.sheet.value(knob)
        let stepped = String(format: "%.2f", (Double(was.filter { "0123456789.".contains($0) }) ?? 1) + 0.05)
        model.change(knob, to: stepped)
        // Ползунок кладе значення в чергу і вписує його в текст сторінки за
        // 45 мс — щоб на кожен крок не переписувати весь файл. Перевірці
        // чекати нема чого: просимо вписати зараз.
        model.flushApply()
        knobs.refresh()
        let after = knobs.rowsForCheck
        let moved = model.sheet.value(knob)
        // Сторінка людини має лишитися такою, якою була: перевірка світить
        // ліхтариком, а не переставляє меблі.
        model.change(knob, to: was)
        model.flushApply()
        knobs.refresh()
        let back = model.sheet.value(knob)

        var faults: [String] = []
        if moved == was { faults.append("значення не змінилося зовсім: \(was)") }
        if after.count != before.count {
            faults.append("рядів було \(before.count), стало \(after.count)")
        } else {
            let same = zip(before, after).allSatisfy { $0 === $1 }
            if !same { faults.append("ряди пересобрано — повзунок під пальцем зник би") }
        }
        if back != was { faults.append("сторінку не повернуто: \(was) → \(back)") }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                        + "ручка \(knob.name): \(was) → \(moved) → \(back); рядів \(after.count)")
    }

    /// Усі блоки сторінки мають іти за підібраним кеглем, а не за оголошеним.
    ///
    /// Поки адреса, назва пісні, годинник і «далі» стояли на `--sl-size`,
    /// а головний текст — на підібраному `--sl-auto`, рух ручки «Розмір
    /// тексту» на довгому вірші рухав саме адресу й більше нічого.
    private static func fittedSizesCheck(area: String) -> Check {
        let name = "Заготовки: розмір блоків іде за підібраним кеглем"
        let html = WebSlideTemplates.all.first?.html ?? ""
        var faults: [String] = []
        var counted = 0
        for line in html.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.contains("var(--sl-size") else { continue }
            counted += 1
            // Оголошення самої ручки в блоці настройок і сам добір — не рахуються.
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("--sl-size:") { continue }
            if !text.contains("--sl-auto") {
                faults.append(String(text.prefix(60)))
            }
        }
        let detail = "рядків із розміром: \(counted)"
        guard counted > 0 else {
            return Check(area: area, name: name, status: .failed, detail: "у заготовці немає жодного розміру")
        }
        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty ? detail
                        : "повз добір: " + faults.joined(separator: " | ") + ". " + detail)
    }

    /// Колір ручки крутиться своїм полем, а не системною палітрою.
    ///
    /// Власник: «при смене цвета и выбора в меню цвета в rgb sliders, если
    /// ползунки цветов находятся не в положении ноль, то они показывают не
    /// правильное свое значение цвета внутри ползунка». Палітра malює свої
    /// повзунки в тому просторі, який у ній вибрано, а сторінка живе в sRGB.
    /// Тому перевіряємо дві речі: що палітри тут немає зовсім і що набране
    /// число доїжджає в файл байт у байт.
    private static func colourFieldCheck(area: String, state: AppState) -> Check {
        let name = "Колір ручки: своє поле в sRGB"
        let editor = NativeWebSlideEditor(state: state)
        defer { editor.finish() }
        editor.frame = NSRect(x: 0, y: 0, width: 1100, height: 640)
        editor.needsLayout = true
        editor.layoutSubtreeIfNeeded()

        let model = editor.modelForCheck
        guard let page = model.myPages.first ?? model.authorPages.first else {
            return Check(area: area, name: name, status: .skipped, detail: "сторінок немає")
        }
        model.open(page)
        let knobs = editor.knobsForCheck

        // Розділ із кольорами може бути не першим — шукаємо його.
        var row: NativeWebSlideKnobs.KnobRow?
        for section in WebSlideSection.allCases {
            knobs.showForCheck(section: section)
            for candidate in knobs.rowsForCheck {
                guard let knobRow = candidate as? NativeWebSlideKnobs.KnobRow else { continue }
                if case .color = knobRow.knobForCheck.kind { row = knobRow; break }
                if case .colorRGB = knobRow.knobForCheck.kind { row = knobRow; break }
            }
            if row != nil { break }
        }
        guard let row else {
            return Check(area: area, name: name, status: .skipped, detail: "ручок кольору немає")
        }

        var faults: [String] = []
        func palettes(in view: NSView) -> Int {
            var found = view is NSColorWell ? 1 : 0
            for child in view.subviews { found += palettes(in: child) }
            return found
        }
        let left = palettes(in: editor)
        if left > 0 { faults.append("системних палітр лишилося: \(left)") }

        guard let field = row.controlForCheck as? NativeColourField else {
            return Check(area: area, name: name, status: .failed,
                         detail: "колір крутить не наше поле, а \(type(of: row.controlForCheck))")
        }
        let knob = row.knobForCheck
        let was = model.sheet.value(knob)
        let wanted = SlideStyle.RGBA(0.2, 0.6, 0.9, 1)
        field.pickForCheck(wanted)
        model.flushApply()
        let written = model.sheet.value(knob)
        let back = WebSlideKnobColour.parse(written)
        if abs(back.red - wanted.red) > 0.01 || abs(back.green - wanted.green) > 0.01
            || abs(back.blue - wanted.blue) > 0.01 {
            faults.append("записалося «\(written)» — це інший колір")
        }
        // Повертаємо сторінку такою, якою вона була.
        model.change(knob, to: was)
        model.flushApply()
        let restored = model.sheet.value(knob)
        if restored != was { faults.append("сторінку не повернуто: \(was) → \(restored)") }

        return Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                        + "ручка \(knob.name): \(was) → \(written) → \(restored)")
    }
}
