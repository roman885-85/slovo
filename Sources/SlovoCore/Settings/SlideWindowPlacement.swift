import Foundation

/// Куди програма ставить вікно слайда — елементи (5) (7) (9) вкладки
/// «Основні» (6.1.1).
///
/// Посібник: список (5) вибирає монітор; панель ручних налаштувань (9)
/// задає положення й розмір вікна слайда; поле (7) «Розміри за умовчанням»
/// діє, «якщо при запуску програми встановленого в (5) монітора не
/// виявиться — вікно слайда відобразиться на головному моніторі з розмірами,
/// вказаними в цьому полі».
///
/// Окремий тип, а не пара полів у вікна проекції: правило вибирається за
/// налаштуваннями, а виконується в AppKit, і розводити ці дві речі по різних
/// шарах дешевше, ніж тягти `ProgramOptions` у вікно.
public enum SlideWindowPlacement: Sendable, Hashable {

    /// (5) вибрано монітор. Номер у нумерації оригіналу: 1 — перший у списку.
    /// Якщо такого монітора зараз немає, вікно йде на головний із розмірами (7).
    case monitor(number: Int, fallbackWidth: Int, fallbackHeight: Int)

    /// (9) «Ручне налаштування»: вікно ставиться за цими координатами, навіть коли
    /// монітора там зараз немає. Відлік — як в оригіналі: від лівого верхнього
    /// кута головного монітора, вісь Y униз.
    case manual(left: Int, top: Int, width: Int, height: Int)

    /// Правило за значеннями вікна «Параметри».
    public init(options: ProgramOptions) {
        if options.monitorIndex <= 0 {
            self = .manual(left: options.customLeft,
                           top: options.customTop,
                           width: max(1, options.customWidth),
                           height: max(1, options.customHeight))
        } else {
            self = .monitor(number: options.monitorIndex,
                            fallbackWidth: max(1, options.defaultWidth),
                            fallbackHeight: max(1, options.defaultHeight))
        }
    }

    /// Для звіту самоперевірки й підписів — коротко і мовою посібника.
    public var summary: String {
        switch self {
        case let .monitor(number, width, height):
            return "монитор \(number), запасной размер \(width)×\(height)"
        case let .manual(left, top, width, height):
            return "ручная настройка \(left),\(top) \(width)×\(height)"
        }
    }
}
