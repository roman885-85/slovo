import AppKit
import Combine

/// Тимчасовий перекладач: правка стану — точковий привід.
///
/// `AppState` і `DeskModel` поки повідомляють про зміни по-старому — одним
/// спільним `objectWillChange` на все разом, без жодного слова про те, що саме
/// змінилося. Нижній ряд слухає лише точкові приводи (`Signals`), і поки
/// стан не навчиться слати їх сам, хтось має перекладати одне в
/// інше. Цей хтось — тут.
///
/// Як це не перетворюється на колишню перезбірку. Спільне сповіщення приходить
/// часто — на кожну літеру в полі пошуку, — тому воно не розсилається далі
/// як є: спершу копиться до кінця поточного кола подій, потім звіряється
/// зі знімком того небагатого, що нижньому ряду важливе, і йде лише те, що
/// і справді змінилося. Вартість однієї правки — кілька порівнянь.
///
/// Коли `AppState` почне слати `Signals.send` сам, цей файл викидається,
/// і не міняється більше нічого: панелі про нього не знають.
@MainActor
final class NativeBottomBridge {

    private weak var state: AppState?
    private var sinks: [AnyCancellable] = []
    private var scheduled = false

    /// Знімок того, від чого залежить нижній ряд. Зберігається хешами: порівняти
    /// чотири числа дешевше, ніж тримати копії слайда і стилю.
    private var slideStamp = 0
    private var live = false
    private var languageCode = ""
    /// Правки Плану та Історії розбирають самі панелі — у них уже є свій
    /// відбиток складу, і другий тут був би тією самою роботою двічі.
    private var deskTouched = false

    init(state: AppState, desk: DeskModel) {
        self.state = state
        sinks.append(state.objectWillChange.sink { [weak self] _ in self?.schedule() })
        sinks.append(desk.objectWillChange.sink { [weak self] _ in
            self?.deskTouched = true
            self?.schedule()
        })
        snapshot()
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        // `objectWillChange` повідомляє ДО того, як значення записано, — читати
        // стан прямо зараз значить прочитати вчорашнє. Чекаємо кінця
        // поточного кола подій: воно кінчається раніше за малювання, і кадру на
        // цьому не втрачається.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        scheduled = false
        guard let state else { return }
        var kinds: [Signals.Kind] = []

        let stamp = Self.stamp(of: state)
        if stamp != slideStamp {
            slideStamp = stamp
            kinds.append(.slide)
        }
        if state.isLive != live {
            live = state.isLive
            kinds.append(.live)
        }
        let code = state.language?.code ?? ""
        if code != languageCode {
            languageCode = code
            kinds.append(.language)
        }
        if deskTouched {
            deskTouched = false
            // Панелі Плану та Історії самі вирішать, чи міняти рядки: у кожної
            // є відбиток складу, і зайвий привід коштує їм одного хеша.
            kinds.append(.plan)
            kinds.append(.history)
        }

        guard !kinds.isEmpty else { return }
        Signals.shared.batch {
            for kind in kinds { Signals.shared.send(kind) }
        }
    }

    private func snapshot() {
        guard let state else { return }
        slideStamp = Self.stamp(of: state)
        live = state.isLive
        languageCode = state.language?.code ?? ""
    }

    /// Усе, від чого залежить картинка передпоказу і три мініатюри
    /// «Керування». Слайд і стиль — значення, їхній хеш рахується на місці.
    private static func stamp(of state: AppState) -> Int {
        var hasher = Hasher()
        hasher.combine(state.slide)
        hasher.combine(state.style)
        hasher.combine(state.templateName)
        hasher.combine(state.commonBackgroundPath ?? "")
        hasher.combine(state.showsCommonBackground)
        return hasher.finalize()
    }
}
