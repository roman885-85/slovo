import AppKit
import SlovoCore

/// Владелец: «в настройках слайда при выборе цветов ползунками путаница —
/// ползунки меняют свой цвет не соответствующий их надписи».
///
/// В Конструкторе у объекта три цвета (текст, контур, тень) и два ползунка
/// прозрачности (объекта и тени). Проверяем то, что видит человек: цвет,
/// пришедший из палитры в одно поле, ложится ровно в свою связку и не
/// трогает соседние; ползунок меняет своё число; после перечитывания
/// значений (так панель обновляется на каждую правку) поля показывают то,
/// что лежит в модели. Второй заход — после пересборки панелей (смена
/// объекта туда и обратно): новые поля не должны стрелять чужими связками.
extension Diagnostics {

    static func constructorColoursSection(state: AppState) -> [Check] {
        stripCheck() + fieldsSection(state: state)
    }

    /// Смуга повзунка кольору показує саме той колір, який вийде.
    ///
    /// Власник: «если ползунки цветов находятся не в положении ноль, то они
    /// показывают не правильное свое значение цвета внутри ползунка».
    /// Дивимося не на вид, а на пікселі: беремо смугу зеленого при заданих
    /// червоному й синьому і питаємо в неї колір у трьох місцях. Якщо смуга
    /// малюється «сама по собі», а не від решти кольору, тут же й видно.
    private static func stripCheck() -> [Check] {
        let area = "Конструктор"
        let name = "Смуга повзунка кольору показує справжній колір"
        let base = SlideStyle.RGBA(0.8, 0.5, 0.2, 1)
        let width = 200, height = 22
        let slider = NativeChannelSlider(channel: 1)
        slider.base = base
        // Ручку відводимо в лівий край, щоб біле кільце не закривало
        // жодного з місць, у які ми зазираємо.
        slider.value = 0
        slider.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))

        // Малюємо своїм полотном, а не `cacheDisplay`: вид не в вікні, і
        // системний знімок віддає порожнечу.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return [Check(area: area, name: name, status: .skipped, detail: "полотно не зібралося")]
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        slider.draw(slider.bounds)
        NSGraphicsContext.restoreGraphicsState()

        var faults: [String] = []
        var lines: [String] = []
        let row = context.bytesPerRow
        // Три місця смуги — подалі від ручки.
        for share in [0.25, 0.55, 0.85] {
            let trackLeft = 7.0, trackWidth = Double(width) - 14
            let x = Int(trackLeft + trackWidth * share)
            let y = height / 2
            let at = y * row + x * 4
            let red = Double(pixels[at]) / 255
            let green = Double(pixels[at + 1]) / 255
            let blue = Double(pixels[at + 2]) / 255
            lines.append(String(format: "%.2f: %.2f %.2f %.2f", share, red, green, blue))
            if abs(red - base.red) > 0.06 || abs(blue - base.blue) > 0.06 {
                faults.append(String(format: "на %.2f смуга забула про сусідні канали", share))
            }
            if abs(green - share) > 0.08 {
                faults.append(String(format: "на %.2f зелений %.2f замість %.2f", share, green, share))
            }
        }
        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                        + "смуга зеленого при R \(Int(base.red * 255)) B \(Int(base.blue * 255)): "
                        + lines.joined(separator: "; "))]
    }

    private static func fieldsSection(state: AppState) -> [Check] {
        let area = "Конструктор"
        let name = "Кольори й повзунки об'єкта не плутаються між собою"
        let constructor = NativeSlideConstructor(state: state, onClose: {})
        constructor.frame = NSRect(x: 0, y: 0, width: 1180, height: 720)
        constructor.layoutSubtreeIfNeeded()
        let model = constructor.modelForCheck
        guard model.selectedObject != nil else {
            return [Check(area: area, name: name, status: .skipped, detail: "у конструкторі не вибрано об'єкт")]
        }

        func wells(in view: NSView) -> [NativeColourField] {
            var found: [NativeColourField] = []
            if let well = view as? NativeColourField { found.append(well) }
            for child in view.subviews { found.append(contentsOf: wells(in: child)) }
            return found
        }
        func sliders(in view: NSView) -> [NSSlider] {
            var found: [NSSlider] = []
            if let slider = view as? NSSlider, slider.maxValue == 255 { found.append(slider) }
            for child in view.subviews { found.append(contentsOf: sliders(in: child)) }
            return found
        }
        func near(_ a: SlideStyle.RGBA, _ b: SlideStyle.RGBA) -> Bool {
            abs(a.red - b.red) < 0.02 && abs(a.green - b.green) < 0.02 && abs(a.blue - b.blue) < 0.02
        }
        /// Як людина повзунком: поле отримало колір і сказало про це зв'язці.
        func pick(_ well: NativeColourField, _ colour: SlideStyle.RGBA) {
            well.pickForCheck(colour)
        }

        let textTie = model.tie(\.text.color, default: .white)
        let outlineTie = model.tie(\.text.outlineColor, default: .black)
        let shadowTie = model.sceneTie(\.shadow.color, default: .black)
        let opacityTie = model.sceneTie(\.opacity, default: 1)
        let shadowOpacityTie = model.sceneTie(\.shadow.opacity, default: 1)
        let savedText = textTie.get(), savedOutline = outlineTie.get(), savedShadow = shadowTie.get()
        let savedOpacity = opacityTie.get(), savedShadowOpacity = shadowOpacityTie.get()
        defer {
            textTie.set(savedText); outlineTie.set(savedOutline); shadowTie.set(savedShadow)
            opacityTie.set(savedOpacity); shadowOpacityTie.set(savedShadowOpacity)
        }

        var faults: [String] = []
        var lines: [String] = []

        // Различимые исходные цвета — по ним узнаём, какое поле за что отвечает.
        let red = SlideStyle.RGBA(1, 0, 0), green = SlideStyle.RGBA(0, 1, 0), blue = SlideStyle.RGBA(0, 0, 1)
        textTie.set(red); outlineTie.set(green); shadowTie.set(blue)
        constructor.refreshValuesForCheck()
        var all = wells(in: constructor)
        func find(_ colour: SlideStyle.RGBA) -> NativeColourField? { all.first { near($0.colour, colour) } }
        guard let textWell = find(red), let outlineWell = find(green), let shadowWell = find(blue) else {
            return [Check(area: area, name: name, status: .failed,
                          detail: "після запису в модель поля показують не свої кольори: полів \(all.count), кольори " +
                              all.map { let c = $0.colour; return String(format: "(%.1f %.1f %.1f)", c.red, c.green, c.blue) }.joined(separator: " "))]
        }
        lines.append("полів кольору \(all.count), зв'язки впізнано")

        // Палитра красит каждое поле по очереди — соседи не должны меняться.
        let magenta = SlideStyle.RGBA(1, 0, 1), cyan = SlideStyle.RGBA(0, 1, 1), yellow = SlideStyle.RGBA(1, 1, 0)
        pick(textWell, magenta)
        if !near(textTie.get(), magenta) { faults.append("колір із поля «Текст» не дійшов до тексту") }
        if !near(outlineTie.get(), green) || !near(shadowTie.get(), blue) { faults.append("колір тексту змінив контур або тінь") }
        pick(outlineWell, cyan)
        if !near(outlineTie.get(), cyan) { faults.append("колір із поля контуру не дійшов до контуру") }
        if !near(textTie.get(), magenta) || !near(shadowTie.get(), blue) { faults.append("колір контуру змінив текст або тінь") }
        pick(shadowWell, yellow)
        if !near(shadowTie.get(), yellow) { faults.append("колір із поля тіні не дійшов до тіні") }
        if !near(textTie.get(), magenta) || !near(outlineTie.get(), cyan) { faults.append("колір тіні змінив текст або контур") }

        // Перечитывание значений: каждое поле показывает своё.
        constructor.refreshValuesForCheck()
        if !near(textWell.colour, magenta) || !near(outlineWell.colour, cyan) || !near(shadowWell.colour, yellow) {
            faults.append("після перечитування поля показують чужі кольори")
        }

        // Ползунки прозрачности: объекта и тени.
        opacityTie.set(1); shadowOpacityTie.set(0.5)
        constructor.refreshValuesForCheck()
        let bars = sliders(in: constructor)
        if let objectBar = bars.first(where: { abs($0.doubleValue - 255) < 1 }),
           let shadowBar = bars.first(where: { abs($0.doubleValue - 127.5) < 1.5 }) {
            objectBar.doubleValue = 100
            if let action = objectBar.action { NSApp.sendAction(action, to: objectBar.target, from: objectBar) }
            if abs(opacityTie.get() * 255 - 100) > 1 { faults.append("повзунок прозорості об'єкта не змінив об'єкт") }
            if abs(shadowOpacityTie.get() - 0.5) > 0.01 { faults.append("повзунок об'єкта змінив прозорість тіні") }
            shadowBar.doubleValue = 40
            if let action = shadowBar.action { NSApp.sendAction(action, to: shadowBar.target, from: shadowBar) }
            if abs(shadowOpacityTie.get() * 255 - 40) > 1 { faults.append("повзунок тіні не змінив тінь") }
            if abs(opacityTie.get() * 255 - 100) > 1 { faults.append("повзунок тіні змінив об'єкт") }
            lines.append("повзунків 0…255: \(bars.count), обидва ведуть свої значення")
        } else {
            faults.append("не знайшлися повзунки прозорості зі значеннями 255 і 128 (знайдено \(bars.count))")
        }

        // Пересборка панелей: другой объект и обратно — поля новые, связки прежние.
        if let current = model.selectedObject, let other = model.preset.objects.first(where: { $0.id != current.id }) {
            model.selection = other.id
            constructor.layoutSubtreeIfNeeded()
            model.selection = current.id
            constructor.layoutSubtreeIfNeeded()
            constructor.refreshValuesForCheck()
            all = wells(in: constructor)
            if let freshText = find(magenta) {
                pick(freshText, red)
                if !near(textTie.get(), red) { faults.append("після перезбирання колір із поля «Текст» пішов не в текст") }
                if !near(outlineTie.get(), cyan) || !near(shadowTie.get(), yellow) { faults.append("після перезбирання колір тексту зачепив контур або тінь") }
                lines.append("після перезбирання панелей зв'язки на місці")
            } else {
                faults.append("після перезбирання не знайшлося поле з кольором тексту")
            }
        } else {
            lines.append("другого об'єкта немає — перезбирання не ганяли")
        }

        // Колір із поля має лягти на слайд тим самим числом. Раніше тут
        // стояла палітра macOS: вона віддавала колір у своєму просторі
        // («Generic RGB», «Display P3»), а малювання рахує в sRGB — на
        // екрані виходив інший відтінок, і повзунок показував не те.
        // Женемо колір тим самим шляхом, яким він іде на проектор.
        let probe = SlideStyle.RGBA(0.2, 0.6, 0.9)
        textTie.set(probe)
        constructor.refreshValuesForCheck()
        let drawn = SlideDrawing.color(textTie.get())
        var painted: SlideStyle.RGBA?
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.setFillColor(drawn)
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        painted = SlideStyle.RGBA(Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
        if let painted {
            lines.append(String(format: "колір %.2f %.2f %.2f намальовано як %.2f %.2f %.2f",
                                probe.red, probe.green, probe.blue, painted.red, painted.green, painted.blue))
            if !near(painted, probe) {
                faults.append("колір із поля намальовано іншим — простір кольору розходиться")
            }
        } else {
            lines.append("пробний кадр не зібрався — колір малювання не звіряли")
        }

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; "))]
    }
}
