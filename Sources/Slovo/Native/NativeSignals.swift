import AppKit

/// Точечные оповещения «изменилось вот это».
///
/// Зачем они вообще нужны. `AppState` — `ObservableObject`, и всякая правка
/// любого его поля бьёт в один общий `objectWillChange`. SwiftUI на это
/// пересобирает тела всех видов окна: замер показал 15–16 панелей на каждое
/// нажатие, 23 мс первого кадра даже там, где ни один список не изменился.
/// Окну AppKit такое не нужно и не годится: у него элементы постоянные, и на
/// смену стиха обязан обновиться один список стихов, а не окно целиком.
///
/// Поэтому вместо «что-то изменилось» ходит «изменилось вот это»: узкий
/// перечень поводов (`Signals.Kind`), подписчик берёт только свои. Оповещение
/// уходит СРАЗУ, в том же вызове, что и правка состояния, — не через очередь.
/// Так к моменту, когда цикл событий дойдёт до отрисовки, окно уже правильное,
/// и лишнего кадра задержки нет.
///
/// `AppState` остаётся единственным источником правды: сигнал не несёт данных,
/// он лишь говорит, что пора перечитать. Данные подписчик берёт у состояния
/// сам и по индексу — так значения не копируются.
@MainActor
final class Signals {

    static let shared = Signals()

    /// Поводы. Список нарочно закрытый и мелкий: чем точнее повод, тем меньше
    /// работы на нажатие. Общего «всё изменилось» здесь нет намеренно — если
    /// он появится, окно вернётся к нынешней пересборке целиком.
    enum Kind: String, CaseIterable, Hashable {
        /// Смена режима: Библия / Текст / Песни.
        case mode
        /// Сменился класс книг (Вся Библия, Ветх., Нов., Неканон.).
        case bookClass
        /// Сменился состав списка книг: другой перевод, другой класс.
        case books
        /// Выбрана другая книга. Состав списка тот же.
        case bookSelection
        /// Сменился состав списка глав (перечитали книгу).
        case chapters
        /// Выбрана другая глава.
        case chapterSelection
        /// Сменился состав списка стихов (другая глава или другой перевод).
        case verses
        /// Изменился набор выбранных стихов.
        case verseSelection
        /// Сменился состав или порядок полосы переводов.
        case translations
        /// Библиотека открылась: появились переводы и песенники.
        ///
        /// Отдельный повод, потому что библиотека читается в фоне и приходит
        /// ПОЗЖЕ, чем поднимается окно. Пока его не было, песенник брался
        /// один раз — в миг подъёма, когда его ещё нет, — и модуль «Песни»
        /// оставался пустым до конца работы.
        case library
        /// Открыт другой песенник — список песен другой.
        case songBook
        /// Сменился отбор песен: набрали букву или цифру в быстром выборе.
        case songFilter
        /// Выбрана другая песня.
        case songSelection
        /// Выбрана другая часть песни.
        case songPart
        /// Изменился кегль списков (ползунок (20), колесо с Ctrl).
        case listFontSize
        /// Изменился вид списка: плиткой/списком, одна линия/много.
        case listKind
        /// Пересобран слайд предпросмотра.
        case slide
        /// Показ в зал включён или выключен.
        case live
        /// Сменился язык интерфейса или файл перевода.
        case language
        /// Изменился план служения.
        case plan
        /// Изменилась история.
        case history
        /// Изменились результаты поиска.
        case searchResults
        /// Открыт или закрыт медиаплеер, окно результатов поиска и прочее,
        /// что меняет саму раскладку окна.
        case layout
    }

    /// Подписка. Живёт, пока её держат: подписчик хранит `Token` у себя,
    /// отпустил — подписка снялась сама. Это нарочно: элементы окна создают и
    /// уничтожают, а забытая подписка на мёртвый элемент — это и утечка, и
    /// работа впустую на каждое нажатие.
    final class Token {
        fileprivate let kinds: Set<Kind>
        fileprivate let body: (Kind) -> Void
        fileprivate weak var owner: Signals?
        /// Откуда подписка — файл и строка. Только для замера подписчиков.
        fileprivate var origin = ""

        fileprivate init(kinds: Set<Kind>, body: @escaping (Kind) -> Void, owner: Signals) {
            self.kinds = kinds
            self.body = body
            self.owner = owner
        }

        deinit {
            // `deinit` не на главном потоке звать нельзя, а он тут всегда на
            // главном: подписки заводит и отпускает только окно.
            let owner = self.owner
            MainActor.assumeIsolated { owner?.forget(self) }
        }
    }

    private struct Slot {
        weak var token: Token?
    }

    private var slots: [Kind: [Slot]] = [:]

    /// Глубина `batch`. Пока больше нуля — поводы копятся.
    private var batchDepth = 0
    private var pending: Set<Kind> = []
    /// Поводы, которые прямо сейчас разносятся. Нужны от самозацикливания:
    /// подписчик вправе тронуть состояние, и оно пошлёт тот же повод обратно.
    private var delivering: Set<Kind> = []

    // MARK: - Подписка

    /// Подписаться на несколько поводов сразу.
    ///
    /// Возвращённый `Token` надо сохранить — иначе подписка снимется тут же.
    /// Поэтому итог намеренно не помечен `@discardableResult`: забытая
    /// подписка молчит, а не ломается, и искать её потом негде.
    func subscribe(_ kinds: Set<Kind>, file: String = #fileID, line: Int = #line,
                   _ body: @escaping (Kind) -> Void) -> Token {
        let token = Token(kinds: kinds, body: body, owner: self)
        token.origin = "\(file):\(line)"
        for kind in kinds {
            slots[kind, default: []].append(Slot(token: token))
        }
        return token
    }

    /// Подписаться на один повод.
    func subscribe(_ kind: Kind, file: String = #fileID, line: Int = #line,
                   _ body: @escaping () -> Void) -> Token {
        subscribe([kind], file: file, line: line) { _ in body() }
    }

    // MARK: - Замер подписчиков

    /// Пока включено, каждый вызов подписчика меряется, и медленные
    /// записываются: повод, откуда подписка и миллисекунды. Так замер
    /// «переключение вкладки — 180 мс» раскладывается по виновникам, а не
    /// остаётся одним числом. Выключено — не стоит ничего.
    var profiling = false {
        didSet { if profiling { slowCalls.removeAll() } }
    }
    private(set) var slowCalls: [(kind: Kind, origin: String, ms: Double)] = []

    /// Виновники по убыванию времени — самопроверке.
    func slowReport(top: Int = 8) -> String {
        var byOrigin: [String: (ms: Double, count: Int)] = [:]
        for call in slowCalls {
            let key = "\(call.kind) ← \(call.origin)"
            byOrigin[key, default: (0, 0)].ms += call.ms
            byOrigin[key, default: (0, 0)].count += 1
        }
        return byOrigin.sorted { $0.value.ms > $1.value.ms }.prefix(top)
            .map { String(format: "%@ %.0f мс/%d", $0.key, $0.value.ms, $0.value.count) }
            .joined(separator: "; ")
    }

    private func forget(_ token: Token) {
        for kind in token.kinds {
            slots[kind]?.removeAll { $0.token === token || $0.token == nil }
        }
    }

    // MARK: - Оповещение

    /// Сказать, что повод наступил. Подписчики вызываются тут же, до возврата.
    func send(_ kind: Kind) {
        guard batchDepth == 0 else { pending.insert(kind); return }
        guard !delivering.contains(kind) else {
            // Повод пришёл, пока его же и разносили. Разносить второй раз
            // прямо сейчас — верный способ уйти в бесконечность; отдадим его
            // сразу после текущего круга.
            pending.insert(kind)
            return
        }

        delivering.insert(kind)
        defer {
            delivering.remove(kind)
            if delivering.isEmpty, batchDepth == 0, !pending.isEmpty {
                let queued = pending
                pending.removeAll()
                for next in queued { send(next) }
            }
        }

        guard var list = slots[kind] else { return }
        var died = false
        for slot in list {
            guard let token = slot.token else { died = true; continue }
            if profiling {
                let started = DispatchTime.now().uptimeNanoseconds
                token.body(kind)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                if ms >= 1 { slowCalls.append((kind, token.origin, ms)) }
            } else {
                token.body(kind)
            }
        }
        if died {
            list.removeAll { $0.token == nil }
            slots[kind] = list
        }
    }

    /// Несколько правок разом: поводы копятся и уходят по одному разу в конце.
    ///
    /// Нужно там, где одно действие меняет многое — открытие другого перевода
    /// меняет и книги, и главы, и стихи. Без этого список стихов перечитался
    /// бы трижды.
    func batch(_ body: () -> Void) {
        batchDepth += 1
        body()
        batchDepth -= 1
        guard batchDepth == 0 else { return }
        let queued = pending
        pending.removeAll()
        for kind in queued { send(kind) }
    }

    /// Сколько живых подписок на повод. Для самопроверки.
    func subscriberCount(_ kind: Kind) -> Int {
        (slots[kind] ?? []).reduce(0) { $0 + ($1.token == nil ? 0 : 1) }
    }
}
