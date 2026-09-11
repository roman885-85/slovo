import AppKit

/// Ctrl + колесо мыши меняет размер шрифта списков.
///
/// Это описано в ответах на частые вопросы на сайте автора: возможность
/// появилась в версии 2.3. На служении это ходовая вещь — оператор
/// увеличивает списки, не отрывая руки от мыши и не лезя в настройки.
@MainActor
final class WheelZoom {

    private var monitor: Any?

    func install(_ change: @escaping (Double) -> Void) {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control else {
                return event
            }
            // Знак прокрутки на трекпаде и на мыши совпадает, а величина —
            // нет: у трекпада шаг дробный. Берём только направление, иначе
            // одно движение пальцем перескочит весь диапазон.
            let step = event.scrollingDeltaY > 0 ? 1.0 : (event.scrollingDeltaY < 0 ? -1.0 : 0)
            guard step != 0 else { return nil }
            change(step)
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
