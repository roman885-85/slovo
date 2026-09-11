import AppKit
import SlovoCore

/// Мелочи, общие полосе меню и вкладкам режима: подписи из файла перевода,
/// значки и «пилюля» выбранного.
///
/// Вынесено отдельно нарочно: и полоса меню, и вкладки берут подписи из одного
/// и того же файла автора и рисуют выбранное одинаково. Разъедься эти две
/// стороны — и вкладка «Песни» показывала бы одно, а меню «Интерфейс» другое.

// MARK: - Подписи

@MainActor
enum NativeTopCaptions {

    /// Подпись элемента формы `MainForm` из ПЕРЕДАННОГО файла перевода.
    ///
    /// Именно переданного, а не `state.text(...)`. `@Published` оповещает
    /// подписчиков до того, как свойство получит новое значение: в этот миг
    /// `state.language` ещё старый. Пока подписи брались у состояния, полоса
    /// меню отставала на один шаг и переключалась только со второго выбора
    /// языка — то самое «меню врёт о себе», на котором уже обжигались.
    static func caption(_ key: String, default fallback: String,
                        in language: LanguageFile?) -> String {
        // Запасний підпис — через наш словник: без цього там, де у файлі
        // перекладу автора ключа немає, за будь-якої мови лишалася російська.
        let spare = OurWords.t(fallback)
        return language?.caption(key, form: "MainForm", default: spare) ?? spare
    }

    /// Всплывающая подсказка того же элемента. У кнопок оригинала подпись
    /// часто пуста, а весь текст лежит в подсказке.
    static func hint(_ key: String, default fallback: String,
                     in language: LanguageFile?) -> String {
        language?.hint(key, form: "MainForm") ?? OurWords.t(fallback)
    }

    /// Подпись вкладки режима (18).
    ///
    /// Повторяет `AppState.WorkMode.title(in:)`, но читает переданный файл
    /// перевода — по той же причине, что и `caption` выше.
    static func modeTitle(_ mode: AppState.WorkMode, in language: LanguageFile?) -> String {
        switch mode {
        case .bible: return caption("TSBible", default: mode.title, in: language)
        case .text:  return caption("TSText", default: mode.title, in: language)
        // У песенника подпись вкладки записана в поле подсказки: форма
        // вставлена в окно отдельно, и автор положил её название туда.
        case .songs: return hint("SongsPluginFrame", default: mode.title, in: language)
        // Наша вкладка, и подпись наша: у автора четвёртого режима нет.
        case .media, .pictures, .presentation, .screen: return OurWords.t(mode.title)
        }
    }
}

// MARK: - Значки

/// Готовые значки SF Symbols нужного цвета.
///
/// Значок собирается один раз и потом только рисуется. Собирать его на каждую
/// отрисовку нельзя: разбор имени символа и наложение цвета стоят дороже, чем
/// вся остальная строка меню вместе взятая, а полоса перерисовывается на
/// каждое движение мыши по ней.
@MainActor
enum NativeTopIcon {

    private static var cache: [String: NSImage] = [:]

    /// Значок с наложенным цветом. `role` — короткое имя набора цветов
    /// («обычный», «белый»): по нему складывается ключ, потому что сам
    /// `NSColor` бывает системным и своего постоянного имени не имеет.
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight,
                       tint: NSColor, role: String) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)|\(role)"
        if let ready = cache[key] { return ready }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let configured = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: size, weight: weight)) ?? base
        let tinted = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect)
            tint.set()
            // Заливка «поверх непрозрачного» красит сам знак и не трогает
            // прозрачное вокруг него. Делается в своём холсте, иначе краска
            // легла бы и на подложку выбранной вкладки.
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        cache[key] = tinted
        return tinted
    }

    /// Светлое оформление сменилось тёмным — цвета в готовых значках чужие.
    static func flush() { cache.removeAll(keepingCapacity: true) }
}

// MARK: - Отрисовка

@MainActor
enum NativeTopDraw {

    /// Подсветка выбранного: у автора это заливка в 85 % силы и белый текст.
    static var selectionFill: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.85) }

    /// Скруглённая подложка под выбранной вкладкой и под открытым разделом
    /// меню. Радиус 5 — как в описи окна.
    static func pill(_ rect: NSRect, radius: CGFloat = 5, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// Готовая строка подписи: шрифт и цвет заданы, ширина посчитана.
    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                      color: NSColor) -> (line: NSAttributedString, size: NSSize) {
        let line = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ])
        return (line, line.size())
    }
}
