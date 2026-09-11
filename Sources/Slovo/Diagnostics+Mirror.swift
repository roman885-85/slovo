import AppKit
import SlovoCore

/// Живий екран: стоїть ПОРУЧ із передпоказом, показує кадр залу, указка
/// мишею по ньому лягає на виводи і живе рівно поки тримають кнопку;
/// смуга налаштувань під ним міняє вигляд плями; окреме вікно
/// відкривається, міняє розмір і закривається.
extension Diagnostics {

    static func mirrorSection(state: AppState) -> [Check] {
        let area = "Дзеркало"
        let name = "Живий екран: поруч із передпоказом, указка по натисканню, смуга налаштувань"
        guard let row = NativeBottom.row else {
            return [Check(area: area, name: name, status: .skipped, detail: "нижнього ряду немає")]
        }
        let wasMirror = row.showsMirror
        let wasMode = state.mode
        let wasLive = state.isLive
        defer {
            row.setShowsMirror(wasMirror)
            NativeProjectorMirrorWindow.shared.close()
            SlidePointer.shared.hide()
            state.mode = wasMode
            state.isLive = wasLive
        }
        var faults: [String] = []
        var lines: [String] = []

        // 1. Живий екран стоїть ПОРУЧ із передпоказом: обидва видно разом.
        row.setShowsMirror(true)
        row.layoutSubtreeIfNeeded()
        let frame = row.mirror.frame
        lines.append("живий екран \(Int(frame.width))×\(Int(frame.height)), передпоказ \(row.preview.isHidden ? "спрятан" : "виден") \(Int(row.preview.frame.width))×\(Int(row.preview.frame.height))")
        if row.mirror.isHidden || frame.width < 100 { faults.append("живий екран не показався") }
        if row.preview.isHidden || row.preview.frame.width < 100 { faults.append("передпоказ зник — екрани мають стояти поруч") }
        if row.mirror.frame.intersects(row.preview.frame) { faults.append("живий екран налазить на передпоказ") }
        if row.pointerBar.isHidden || row.pointerBar.frame.width < 100 { faults.append("смуги налаштувань указки не видно") }

        // 2. Стих в зал — в зеркале кадр зала.
        state.mode = .bible
        state.showCurrent()
        wait(untilTrue: { SlideRenderQueue.shared.isIdle && state.projection.hallImage != nil }, seconds: 5)
        row.mirror.refresh()
        lines.append("кадр залу в дзеркалі: \(row.mirror.showsHallImage ? "є" : "немає")")
        if !row.mirror.showsHallImage { faults.append("у дзеркалі немає кадру залу") }

        // 3. Натиснули лівою кнопкою посеред кадру — указка в центрі і на виводах.
        let rect = row.mirror.frameRect
        row.mirror.dragForCheck(to: CGPoint(x: rect.midX, y: rect.midY))
        let mark = SlidePointer.shared.mark
        lines.append("указка: \(mark.map { String(format: "%.2f %.2f", $0.x, $0.y) } ?? "немає"), у дзеркалі \(row.mirror.pointerVisible ? "видно" : "ні")")
        if mark == nil || abs((mark?.x ?? 0) - 0.5) > 0.02 || abs((mark?.y ?? 0) - 0.5) > 0.02 {
            faults.append("миша посередині дзеркала не поставила указку в центр")
        }
        if !row.mirror.pointerVisible { faults.append("указку не намальовано в дзеркалі") }
        if state.projection.isVisible {
            wait(untilTrue: { state.projection.pointerShown }, seconds: 1)
            lines.append("на проекторі: \(state.projection.pointerShown ? "є" : "немає")")
            if !state.projection.pointerShown { faults.append("указка не дійшла до проектора") }
        }

        // 4. Кнопку тримають, а рука виїхала на поле: пляма притискається до
        // краю, а не гасне — інакше указка зникала б від найменшого промаху.
        row.mirror.dragForCheck(to: CGPoint(x: -10, y: -10))
        let atEdge = SlidePointer.shared.mark
        lines.append("рука за краєм: \(atEdge.map { String(format: "%.2f %.2f", $0.x, $0.y) } ?? "немає")")
        if atEdge == nil { faults.append("указка згасла, поки кнопку тримають") }

        // 5. Кнопку відпустили — пляма згасла. Це і є головне правило.
        row.mirror.releaseForCheck()
        if SlidePointer.shared.mark != nil { faults.append("указка не згасла після відпускання кнопки") }
        lines.append("після відпускання: \(SlidePointer.shared.mark == nil ? "згасла" : "лишилася")")

        // 6. Смуга налаштувань: колір, розмір і яскравість доходять до плями.
        let wasLook = SlidePointer.shared.baseLook
        row.pointerBar.setForCheck(colour: SlideStyle.RGBA(0, 0.8, 0.4), sizePercent: 25,
                                   brightnessPercent: 70, output: 1)
        let look = SlidePointer.shared.baseLook
        lines.append(String(format: "смуга: колір %@, розмір %.2f, яскравість %.2f, вивід %@",
                            SlidePointer.Look.hex(look.colour), look.size, look.opacity,
                            look.toProjector && look.toNDI ? "скрізь" : (look.toProjector ? "проектор" : "NDI")))
        if SlidePointer.Look.hex(look.colour) != "#00CC66" { faults.append("колір зі смуги не дійшов до указки") }
        if abs(look.size - 0.25) > 0.01 { faults.append("розмір зі смуги не дійшов до указки") }
        if abs(look.opacity - 0.70) > 0.01 { faults.append("яскравість зі смуги не дійшла до указки") }
        if !look.toProjector || look.toNDI { faults.append("перемикач виводу «тільки проектор» не спрацював") }
        row.pointerBar.setForCheck(colour: wasLook.colour, sizePercent: (wasLook.size * 100).rounded(),
                                   brightnessPercent: (wasLook.opacity * 100).rounded(),
                                   output: wasLook.toProjector && wasLook.toNDI ? 0 : (wasLook.toProjector ? 1 : 2))

        // 7. Висота ряду і ширина живого екрана тягнуться.
        let wasHeight = NativeBottomMetrics.rowHeight
        let wasWidth = NativeBottomMetrics.liveWidth
        NativeBottomMetrics.rowHeight = wasHeight + 60
        // Вужчаємо, а не ширшаємо: у вузькому вікні на зріст може не бути
        // місця, і перевірка сварилася б на тісноту, а не на розкладку.
        NativeBottomMetrics.liveWidth = max(NativeBottomMetrics.liveMinWidth, wasWidth - 60)
        Signals.shared.send(.layout)
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()
        lines.append("розтягування: ряд \(Int(wasHeight))→\(Int(NativeBottomMetrics.rowHeight)), екран \(Int(frame.width))→\(Int(row.mirror.frame.width))")
        if NativeBottomMetrics.rowHeight <= wasHeight { faults.append("нижній ряд не став вищим") }
        if row.mirror.frame.width >= frame.width { faults.append("живий екран не змінив ширину за роздільником") }
        NativeBottomMetrics.rowHeight = wasHeight
        NativeBottomMetrics.liveWidth = wasWidth
        Signals.shared.send(.layout)
        row.needsLayout = true
        row.layoutSubtreeIfNeeded()

        // 8. Указка на зображенні: власник просив, щоб вона працювала «на
        // презентации и изображениях», а не лише на вірші.
        if let picture = makePicture(width: 640, height: 360) {
            state.mode = .pictures
            state.media.showStill(picture, title: "перевірка")
            state.isLive = true
            wait(untilTrue: { state.media.isVideoOnScreen }, seconds: 2)
            row.mirror.refresh()
            row.mirror.dragForCheck(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.25))
            let onPicture = SlidePointer.shared.mark
            lines.append("на зображенні: кадр \(row.mirror.showsPlayerFrame ? "є" : "немає"), указка \(onPicture == nil ? "немає" : "є"), у дзеркалі \(row.mirror.pointerVisible ? "видно" : "ні")")
            if !row.mirror.showsPlayerFrame { faults.append("картинка не дійшла до живого екрана") }
            if onPicture == nil || !row.mirror.pointerVisible { faults.append("указка не працює на зображенні") }
            if state.projection.isVisible {
                wait(untilTrue: { state.projection.pointerShown }, seconds: 1)
                if !state.projection.pointerShown { faults.append("указка на зображенні не дійшла до проектора") }
                if !state.projection.isPointerOverVideo { faults.append("указка сховалася під картинкою") }
            }
            row.mirror.releaseForCheck()
            state.media.showStill(nil)
        } else {
            lines.append("пробна картинка не зібралася — указку на зображенні не ганяли")
        }

        // 9. Окреме вікно: відкрилося, прийняло розмір, веде указку, закрилося.
        let windows = NativeProjectorMirrorWindow.shared
        windows.show(state: state)
        wait(untilTrue: { windows.isOpen }, seconds: 2)
        windows.resize(to: NSSize(width: 800, height: 450))
        wait(untilTrue: { false }, seconds: 0.2)
        let big = windows.mirror?.bounds.size ?? .zero
        lines.append("вікно: \(windows.isOpen ? "відкрито" : "ні"), дзеркало в ньому \(Int(big.width))×\(Int(big.height))")
        if !windows.isOpen { faults.append("вікно дзеркала не відкрилося") }
        if big.width < 700 { faults.append("вікно дзеркала не прийняло новий розмір") }
        if let inWindow = windows.mirror {
            let inner = inWindow.frameRect
            inWindow.dragForCheck(to: CGPoint(x: inner.minX + inner.width * 0.25, y: inner.minY + inner.height * 0.5))
            let fromWindow = SlidePointer.shared.mark
            lines.append("з вікна: \(fromWindow.map { String(format: "%.2f %.2f", $0.x, $0.y) } ?? "немає")")
            if fromWindow == nil || abs((fromWindow?.x ?? 0) - 0.25) > 0.02 || abs((fromWindow?.y ?? 0) - 0.5) > 0.02 {
                faults.append("указка з вікна дзеркала лягла не туди")
            }
        }
        windows.close()
        wait(untilTrue: { !windows.isOpen }, seconds: 2)
        if windows.isOpen { faults.append("вікно дзеркала не закрилося") }

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; "))]
    }
}

extension Diagnostics {
    /// Проста картинка для перевірок: сіре поле з білою смугою.
    /// Своя, а не з диска: дані користувача перевірки не чіпають.
    static func makePicture(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.25, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2 - height / 12, width: width, height: height / 6))
        return context.makeImage()
    }
}
