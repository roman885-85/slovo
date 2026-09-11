import AppKit
import SlovoCore

/// Замер верха окна: полоса меню и вкладки режима.
///
/// Меряется не вызов, а весь путь до пикселей — работа, раскладка, отрисовка,
/// как и в замере основания. Иначе числа не с чем сравнивать: у прежнего окна
/// нажатие стоило 214 мс именно потому, что после «быстрой» правки состояния
/// SwiftUI пересобирал полтора десятка панелей.
///
/// Запускается ключом `--appkit-top-bench`, отчёт ложится в
/// `~/Library/Logs/slovo-native-top-bench.txt`.
@MainActor
enum NativeTopBench {

    static var isWanted: Bool { CommandLine.arguments.contains("--appkit-top-bench") }

    private struct Sample {
        var model = 0.0
        var layout = 0.0
        var draw = 0.0
        var total = 0.0
    }

    private static var lines: [String] = []

    static func start(state: AppState) {
        // Библиотека читается в фоне. Мерить окно, пока разбираются пятьдесят
        // пять переводов и двадцать файлов перевода интерфейса, — значит
        // мерить чужую работу, а на слабой машине ещё и получить полосу меню
        // без подписей: языка-то ещё нет.
        wait(state: state, left: 60)
    }

    private static func wait(state: AppState, left: Int) {
        guard left > 0 else { run(state: state); return }
        let ready = !state.isLoadingLibrary && !state.allModules.isEmpty
            && state.language != nil
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                if ready { run(state: state) } else { wait(state: state, left: left - 1) }
            }
        }
    }

    static func run(state: AppState) {
        guard let window = NativeMainWindowController.shared.window,
              let bar = NativeTop.menuBar, let tabs = NativeTop.modeTabs else { return }
        window.setContentSize(NSSize(width: 1600, height: 1000))
        window.makeKeyAndOrderFront(nil)
        settle(window)

        lines.append("# Замір верху вікна на AppKit: смуга меню і вкладки режиму")
        lines.append("")
        lines.append("Збірка робоча. Вікно 1600×1000, справжнє, на екрані.")
        lines.append("Мова інтерфейсу: \(state.language?.displayName ?? "не вибрано"), "
            + "мов у каталозі \(state.languageCatalog?.languages.count ?? 0).")
        lines.append("")

        // Заодно проверяем то, что глазами проверяется один раз, а ломается
        // молча: поднимаются ли «Параметры» над новым окном. Окно «Параметры»
        // открывается своим окном.
        NativeSettingsSheet.open()
        settle(window)
        settle(window)
        let sheet = window.attachedSheet
        lines.append("«Параметри» над новим вікном: "
            + (sheet != nil
                ? "лист поднялся, размер \(Int(sheet!.frame.width))×\(Int(sheet!.frame.height))"
                : "ЛИСТ НЕ ПОДНЯЛСЯ"))
        NativeSettingsSheet.close()
        settle(window)
        lines.append("Після закриття аркуш знято: "
            + (window.attachedSheet == nil ? "да" : "НЕТ"))
        lines.append("")

        lines.append("| действие | работа | сборка+раскл. | отрисовка | всего |")
        lines.append("|---|---|---|---|---|")

        // Открытие раздела меню. Меряется то, что делает открытие: состав
        // пунктов собирается в этот самый миг (`menuNeedsUpdate`) — пока меню
        // закрыто, пунктов не существует вовсе. Само выпадение окошка меряет
        // AppKit, а не мы: `popUp` не отдаёт управление, пока человек не
        // закроет меню.
        for group in NativeMenuGroup.allCases {
            report("відкрити розділ «\(bar.caption(of: group))»", repeats: 61, window: window) {
                bar.rebuild(group)
            }
        }
        report("відкрити всі шість розділів підряд", repeats: 41, window: window) {
            for group in NativeMenuGroup.allCases { bar.rebuild(group) }
        }

        // Переключение режима. Считается всё, что за ним стоит, включая
        // работу самого состояния: человеку важно время от нажатия до кадра,
        // а не время нашей перекраски.
        var next = 0
        let order: [AppState.WorkMode] = [.text, .songs, .bible]
        report("переключить режим (Библия → Текст → Песни)", repeats: 61, window: window) {
            tabs.select(order[next % order.count])
            next += 1
        }
        state.mode = .bible
        settle(window)

        // Движение ползунка кегля списков. Тянут его непрерывно, и каждый шаг
        // обязан уложиться в кадр.
        var step = 0
        report("зрушити повзунок кегля на ступінь", repeats: 121, window: window) {
            step += 1
            let size = 9.0 + Double(step % 13)
            tabs.drag(to: size)
        }
        // И то же самое, но без окна вовсе: одна правка величины в состоянии.
        // Строка нужна, чтобы видеть, чья это работа. `listFontSize` помечен
        // `@Published`, и всякая правка бьёт в общий `objectWillChange`, на
        // который отвечает дерево видов окна —
        // но живо. Когда прежнее окно уберут, разница уйдёт вместе с ним.
        var bare = 0
        report("правка кегля в стані (один рядок, без вікна)",
               repeats: 121, window: window) {
            bare += 1
            state.listFontSize = 9.0 + Double(bare % 13)
        }
        tabs.drag(to: 13)
        settle(window)

        lines.append("")
        lines.append("Медіани в мілісекундах. «Робота» — сам виклик;")
        lines.append("«збирання+розкл.» — `layoutSubtreeIfNeeded` по вікну;")
        lines.append("«малювання» — `displayIfNeeded` по вікну; «разом» — сума.")
        lines.append("Кадр — 16 мс.")

        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: reportURL, atomically: true, encoding: .utf8)
        FileHandle.standardOutput.write(Data(text.utf8))
        NSApp.terminate(nil)
    }

    static var reportURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        return logs.appendingPathComponent("slovo-native-top-bench.txt")
    }

    // MARK: - Измерение

    private static func report(_ name: String, repeats: Int, window: NSWindow,
                               _ body: () -> Void) {
        var samples: [Sample] = []
        samples.reserveCapacity(repeats)
        for pass in 0..<repeats {
            let sample = measure(window: window, body)
            // Первые три прохода — прогрев: шрифты и значки заводятся один раз.
            if pass >= 3 { samples.append(sample) }
        }
        guard !samples.isEmpty else { return }
        func median(_ pick: (Sample) -> Double) -> String {
            let sorted = samples.map(pick).sorted()
            return String(format: "%.3f", sorted[sorted.count / 2])
        }
        lines.append("| \(name) | \(median(\.model)) | \(median(\.layout)) | "
            + "\(median(\.draw)) | \(median(\.total)) |")
    }

    private static func measure(window: NSWindow, _ body: () -> Void) -> Sample {
        var sample = Sample()
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        window.contentView?.layoutSubtreeIfNeeded()
        let t2 = DispatchTime.now().uptimeNanoseconds
        window.displayIfNeeded()
        let t3 = DispatchTime.now().uptimeNanoseconds
        sample.model = Double(t1 - t0) / 1_000_000
        sample.layout = Double(t2 - t1) / 1_000_000
        sample.draw = Double(t3 - t2) / 1_000_000
        sample.total = Double(t3 - t0) / 1_000_000
        return sample
    }

    private static func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
