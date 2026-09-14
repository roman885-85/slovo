import AppKit
import SlovoCore

/// Делегат приложения — он же держатель состояния и точка пуска.
///
/// Раньше вся работа висела на `onAppear` заглушки-сцены. Окно SwiftUI
/// показывается не всегда: программа, запущенная не через LaunchServices —
/// прямо двоичным файлом, из другой программы, из задачи по расписанию, — не
/// показывает его вовсе. Тогда `onAppear` не срабатывал, и не поднималось
/// НИЧЕГО: процесс жив, библиотека не читана, окна нет ни одного, и снаружи
/// это выглядит как «программа не запускается».
///
/// `applicationDidFinishLaunching` приходит всегда, показалось окно или нет.
@MainActor
final class SlovoDelegate: NSObject, NSApplicationDelegate {

    /// Строка меню macOS. Держим её здесь: раньше меню собирала сцена
    /// SwiftUI, а сцены больше нет — программа обычная, на AppKit.
    private var appMenu: NativeAppMenu?
    private var menuToken: Signals.Token?

    let state = AppState()
    private var started = false

    override init() {
        // Обрыв связи не должен убивать программу.
        //
        // Приёмник NDI — микшер, монитор, чужой компьютер в зале — подключается
        // к нашему источнику и в любой миг может отвалиться: выключили,
        // переключили, пропала сеть. Очередная запись в такой сокет уходит
        // «в никуда», и система шлёт процессу SIGPIPE, а у него поведение по
        // умолчанию одно — убить. Программа исчезала с экрана целиком, без
        // отчёта о падении и без единой строчки в журнале; снаружи это
        // выглядело как «при подключении по NDI программа вылетает».
        //
        // Служение важнее одного оборванного сокета: сигнал гасим, и неудачная
        // запись просто вернёт ошибку тому, кто её затеял. Так поступает всякая
        // сетевая программа. Ставим это первым делом — до того как поднимутся
        // трансляция, веб-слайды и всё прочее, что открывает сокеты.
        signal(SIGPIPE, SIG_IGN)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Словари наших подписей на других языках — раньше всего: язык
        // интерфейса читается из настроек следом, и подписи должны быть уже на месте.
        OurWordsBundle.load()
        start()
        // Ресурси й оновлення з GitHub — не в самоперевірці. Пропозиція
        // завантажити переклади — коли бібліотека вже прочитана: доти не
        // видно, порожня тека модулів чи ще читається.
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--check") || $0.hasPrefix("--selftest") }) {
            whenLibraryIsReady { [state] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    ResourceOffer.offerIfEmpty(state: state)
                    AppUpdater.checkOnLaunch(state: state, intervalDays: SettingsStore.shared.settings.options.updateInterval)
                }
            }
        }
        // Дані перенесли в свій дім — сказати один раз, коли вікно вже є.
        if let note = AppState.migrationNote,
           !CommandLine.arguments.contains(where: { $0.hasPrefix("--check") || $0.hasPrefix("--selftest") }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let alert = NSAlert()
                alert.messageText = OurWords.t("Песенники переведены в формат Слова")
                alert.informativeText = OurWords.t("Песенники VisioBible (.vbm) в папке модулей переведены в свой формат .songbook. Оригиналы отложены в папку «Імпорт з VisioBible» рядом с папкой модулей — их можно удалить.")
                    + "\n\n" + note
                alert.runModal()
            }
        }
    }

    private func start() {
        // Заглушка сцены могла показаться и позвать нас второй раз.
        guard !started else { return }
        started = true
        MainThreadWatchdog.shared.start()
        InterfaceSettings.start()      // 7.2: оформление применяется до первого кадра
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Заставка, как у автора: пока читается библиотека, видно имя
        // программы и то, чем она занята.
        NativeSplash.show()
        NativeSplash.say(OurWords.t("Готовлю окно…"))

        state.installKeyHandlers()

        // Окно одно — на AppKit. Поднимается всегда.
        // Строка меню — до окна: пункты нужны с первой секунды, а «Выйти»
        // и «Скрыть» человеку негде взять, пока меню нет.
        let menu = NativeAppMenu(state: state)
        menu.install()
        appMenu = menu
        // Сменили язык — перебираем подписи разделов: пункты внутри
        // собираются заново при каждом открытии и переводятся сами.
        menuToken = Signals.shared.subscribe(.language) { [weak menu] in menu?.relabel() }

        NativeSplash.say(OurWords.t("Открываю библиотеку переводов…"))
        NativeLaunch.start(state: state)

        // Окно слайда поднимается сразу и живёт до закрытия программы —
        // как в оригинале.
        state.startProjection()

        // Своё окно поднимаем ПОСЛЕДНИМ, когда все прочие уже заведены:
        // так порядок не зависит от того, кто когда успел показаться.
        NativeLaunch.raiseOwnWindow()
        // Ctrl+M «Открыть Медиаплеер» и Ctrl+P «Медиаплеер Воспр./Пауза»
        // (6.1.6). Без этого они мертвы до первого открытия панели плеера.
        MediaHotkeys.shared.install(state: state)

        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
        } else if let spec = CommandLine.arguments.first(where: { $0.hasPrefix("--check=") }) {
            runChecks(String(spec.dropFirst("--check=".count)))
        }

        // Поиск, поля быстрого выбора и план ставят свои клавиши сами —
        // F2, F3, Ctrl+F3, F4, F7, F8, F9 и Tab.
        DeskModel.shared.installHotkeys(state: state)

        // Модуль «Текст» отдаёт собранный слайд туда же, куда и Библия:
        // одиночный показ — в предпросмотр, двойной — в зал.
        // Состояние живёт столько же, сколько делегат, — держим прямо.
        TextModuleModel.shared.present = { [state] slide, live in
            state.present(slide, live: live)
        }

        // Першого запуску як окремого обряду немає: мова за умовчанням —
        // українська, налаштування — з файла умовчань у пакеті, а майстер
        // імпорту модулів кличеться з меню, коли справді потрібен.
    }
    /// Прогон самопроверки без участия человека: ждём, пока откроется
    /// библиотека, пишем отчёт в файл и выходим.
    private func runSelfTest() {
        Diagnostics.writesProgressively = true
        selfTestInstallCrashHandler(reportPath: Diagnostics.reportURL.path)
        print("Самоперевірка йде; звіт пишеться по ходу: \(Diagnostics.reportURL.path)")
        fflush(stdout)
        whenLibraryIsReady { [state] in
            let checks = Diagnostics.runAll(state: state)
            let report = Diagnostics.report(checks)
            try? report.write(to: Diagnostics.reportURL, atomically: true, encoding: .utf8)
            let failed = checks.filter { $0.status == .failed }.count
            // Программа закрывается сама — это конец проверки, а не падение.
            // Без этой строки владелец на чужой машине отличить их не мог.
            print("Готово: перевірок \(checks.count), помилок \(failed). Звіт: \(Diagnostics.reportURL.path)")
            print("Програма зараз закриється сама — так і задумано.")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    /// Прогон отдельных разделов самопроверки: `--check=тур,показ`.
    ///
    /// Нужен при разборе одной поломки: полная проверка идёт пять минут, а
    /// здесь — один раздел и сразу ответ в терминал. Отчёт ложится в свой
    /// файл `slovo-check.txt`, чтобы не затирать отчёт полной проверки.
    private func runChecks(_ spec: String) {
        let names = spec.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        Diagnostics.reportURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/slovo-check.txt")
        Diagnostics.writesProgressively = true
        selfTestInstallCrashHandler(reportPath: Diagnostics.reportURL.path)
        print("Перевірка розділів: \(names.joined(separator: ", ")); звіт: \(Diagnostics.reportURL.path)")
        fflush(stdout)
        whenLibraryIsReady { [state] in
            let checks = Diagnostics.runNamed(names, state: state)
            let report = Diagnostics.report(checks)
            try? report.write(to: Diagnostics.reportURL, atomically: true, encoding: .utf8)
            print(report)
            print("Готово: проверок \(checks.count), ошибок \(checks.filter { $0.status == .failed }.count).")
            print("Програма зараз закриється сама — так і задумано.")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    /// Дождаться библиотеки и базы нумерации, потом сделать дело — с таймера.
    private func whenLibraryIsReady(_ finish: @escaping @MainActor () -> Void) {
        func attempt(_ left: Int) {
            guard left > 0 else {
                // Не дочекалися — все одно з таймера, а не з блоку черги: з
                // блоку вкладене очікування в перевірках не бачить відповідей
                // фонових читань (бібліотека, розділи, фільм) — і справні
                // розділи червоніли. Так було, коли база нумерації порожня:
                // сорок спроб минали, і звіт знімався з `asyncAfter`.
                NativeTrace.say("перевірка: бібліотеку не дочекалися (читається \(state.isLoadingLibrary),"
                    + " модулів \(state.allModules.count), правил нумерації \(state.numbering.rules.count)) — починаю")
                Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
                    MainActor.assumeIsolated { finish() }
                }
                return
            }
            // База несоответствий нумерации читается в фоне и приходит позже
            // модулей. Пока её ждали наравне со всем прочим, на загруженной
            // машине отчёт успевал сняться раньше — и «Стандарт доходит до
            // сборки слайда» краснел на исправном коде через раз.
            if state.isLoadingLibrary || state.allModules.isEmpty
                || state.numbering.rules.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { attempt(left - 1) }
            } else {
                // Отчёт снимается с таймера, а не из блока главной очереди.
                // WKWebView и грузит страницу, и отвечает через эту очередь, а
                // libdispatch не входит в её разбор повторно: пока отчёт брали
                // из блока очереди, браузер за всё ожидание не получал ни
                // одного сообщения, и десять исправных заготовок числились
                // сломанными. Таймер срабатывает из цикла событий, очередь при
                // этом свободна.
                Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                    MainActor.assumeIsolated { finish() }
                }
            }
        }
        attempt(40)
    }
}


// MARK: - Падение во время самопроверки

/// Последний завершённый раздел и путь к отчёту — в буферах C: обработчику
/// сигнала нельзя ни выделять память, ни звать Swift-строки.
nonisolated(unsafe) private var selfTestSectionBuffer = [CChar](repeating: 0, count: 200)
nonisolated(unsafe) private var selfTestReportBuffer = [CChar](repeating: 0, count: 1024)
nonisolated(unsafe) private var crashHead = Array("\n\nПАДЕНИЕ САМОПРОВЕРКИ: сигнал ".utf8)
nonisolated(unsafe) private var crashAfter = Array(" після розділу «".utf8)
nonisolated(unsafe) private var crashTail = Array("». Слід викликів:\n".utf8)

func selfTestRemember(section: String) {
    section.utf8CString.withUnsafeBufferPointer { source in
        guard let base = source.baseAddress else { return }
        _ = strlcpy(&selfTestSectionBuffer, base, selfTestSectionBuffer.count)
    }
}

/// Ставит обработчики на сигналы падения. Он дописывает в отчёт, после
/// какого раздела упало и след вызовов, — и отдаёт сигнал системе, чтобы
/// обычный отчёт о падении тоже появился.
func selfTestInstallCrashHandler(reportPath: String) {
    reportPath.utf8CString.withUnsafeBufferPointer { source in
        guard let base = source.baseAddress else { return }
        _ = strlcpy(&selfTestReportBuffer, base, selfTestReportBuffer.count)
    }
    for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE] {
        signal(sig, selfTestCrashHandler)
    }
}

private func selfTestSignalName(_ sig: Int32) -> StaticString {
    switch sig {
    case SIGSEGV: return "SIGSEGV (обращение к чужой памяти)"
    case SIGBUS: return "SIGBUS (обращение к чужой памяти)"
    case SIGILL: return "SIGILL (недопустима команда — часто виклик недоступної на цій системі функції)"
    case SIGABRT: return "SIGABRT (аварийная остановка)"
    case SIGTRAP: return "SIGTRAP (ловушка Swift: nil, переполнение, недоступная функция)"
    case SIGFPE: return "SIGFPE (ділення на нуль)"
    default: return "невідомий"
    }
}

private func selfTestCrashHandler(_ sig: Int32) {
    let fd = open(selfTestReportBuffer, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    let name = selfTestSignalName(sig)
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
    let depth = backtrace(&frames, 64)
    for out in [fd, STDERR_FILENO] where out >= 0 {
        write(out, crashHead, crashHead.count)
        name.withUTF8Buffer { buffer in _ = write(out, buffer.baseAddress, buffer.count) }
        write(out, crashAfter, crashAfter.count)
        write(out, selfTestSectionBuffer, strlen(selfTestSectionBuffer))
        write(out, crashTail, crashTail.count)
        backtrace_symbols_fd(&frames, depth, out)
    }
    if fd >= 0 { close(fd) }
    signal(sig, SIG_DFL)
    raise(sig)
}
