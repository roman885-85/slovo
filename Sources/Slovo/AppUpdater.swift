import AppKit
import SlovoCore

/// Оновлення самої програми з GitHub — з того самого місця, звідки ресурси.
///
/// Власник: «при обновлении самой программы также выполнять обновление с
/// того же ресурса» і «в окне при обновлении писать подробный ход
/// обновления». Питаємо `releases/latest` репозиторію `roman885-85/slovo`,
/// порівнюємо тег (`v0.81`) з версією пакета; є новіша — вікно з ходом:
/// завантаження з лічильником, розпакування, перевірка пакета, підготовка
/// заміни; далі програма закривається, помічник переносить дані пакета в
/// новий, підмінює його й запускає.
///
/// Чого тут не можна: питати й показувати вікна з блоку `DispatchQueue.main`.
/// У 0.8 так і було — `runModal` стояв усередині такого блоку, головна черга
/// GCD не розбирала нічого до його кінця, відповідь «завантажено» ніколи не
/// приходила, і вікно «Завантажую…» висіло вічно, хоч файл давно лежав на
/// диску. Тепер усе, що приходить із мережі, йде в головний потік через
/// run loop (`onMain`), а хід показує звичайне вікно, не модальне.
@MainActor
enum AppUpdater {

    static let releasesURL = URL(string: "https://api.github.com/repos/roman885-85/slovo/releases/latest")!

    struct Release: Sendable {
        var version: String          // "0.81"
        var tag: String              // "v0.81"
        var page: String             // сторінка релізу
        var notes: String
        var zip: String?             // адреса Slovo-…-macOS.zip
        var size: Int64
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Чи `a` новіша за `b`. Версії «Слова» — десяткові дроби: 0.6 → 0.65 →
    /// 0.69 → 0.8 (власник). Тому друга частина порівнюється як дріб
    /// (0.8 = 0.80 > 0.69), а не як ціле (8 < 69), решта — цілими.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let left = a.split(separator: ".").map(String.init)
        let right = b.split(separator: ".").map(String.init)
        for index in 0..<max(left.count, right.count) {
            var l = index < left.count ? left[index] : "0"
            var r = index < right.count ? right[index] : "0"
            if index == 1 {
                // Дробова частина: вирівняти довжину нулями справа.
                let width = max(l.count, r.count)
                l = l.padding(toLength: width, withPad: "0", startingAt: 0)
                r = r.padding(toLength: width, withPad: "0", startingAt: 0)
            }
            let li = Int(l) ?? 0, ri = Int(r) ?? 0
            if li != ri { return li > ri }
        }
        return false
    }

    /// Виконати в головному потоці через run loop, а не через головну чергу
    /// GCD: так блок дійде і тоді, коли головний потік стоїть у `runModal`
    /// усередині блоку черги.
    nonisolated static func onMain(_ block: @escaping @MainActor @Sendable () -> Void) {
        let run = CFRunLoopGetMain()
        CFRunLoopPerformBlock(run, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { block() }
        }
        CFRunLoopWakeUp(run)
    }

    /// Останній випуск на GitHub. Відповідь — у головному потоці.
    static func fetchLatest(completion: @escaping @MainActor @Sendable (Result<Release, ResourceError>) -> Void) {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release, ResourceError>
            if let error {
                result = .failure(.network(error.localizedDescription))
            } else if let data, let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = root["tag_name"] as? String {
                let assets = root["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { ($0["name"] as? String)?.hasSuffix("-macOS.zip") == true }
                result = .success(Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                                          tag: tag,
                                          page: root["html_url"] as? String ?? "",
                                          notes: root["body"] as? String ?? "",
                                          zip: zip?["browser_download_url"] as? String,
                                          size: Int64(zip?["size"] as? Int ?? 0)))
            } else {
                result = .failure(.network(OurWords.t("сервер ответил %s", "\((response as? HTTPURLResponse)?.statusCode ?? 0)")))
            }
            onMain { completion(result) }
        }.resume()
    }

    /// Опис випуску без розмітки Markdown — у вікні він читається як текст.
    static func plain(_ markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        // [підпис](адреса) → підпис
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]+\\)") {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        let lines = text.components(separatedBy: .newlines).map { line -> String in
            var line = line
            while line.hasPrefix("#") { line.removeFirst() }
            return line.trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    /// Теки й файли даних у `Contents/Resources/app`, які переходять зі
    /// старого пакета в новий: випуск на GitHub — «лише програма», а в
    /// пакеті власника лежать усі переклади (власник: «все переводы и модули
    /// внутри пакета всегда») — оновлення не має їх загубити.
    nonisolated static let carriedData = ["Modules", "BackGrounds", "Templates", "Plans", "Fonts", "RemoteAPI",
                                          "Імпорт з VisioBible", "settings.json"]

    /// Скрипт помічника. Окремо — щоб самоперевірка прогнала його на
    /// тимчасових пакетах.
    nonisolated static func helperScript(pid: Int32, bundle: URL, fresh: URL, staging: URL, relaunch: Bool = true) -> String {
        func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let old = quoted(bundle), new = quoted(fresh)
        let carry = carriedData.map { name -> String in
            let item = "'" + name + "'"
            return """
            if [ -e \(old)/Contents/Resources/app/\(item) ]; then
              mkdir -p \(new)/Contents/Resources/app
              rm -rf \(new)/Contents/Resources/app/\(item)
              mv \(old)/Contents/Resources/app/\(item) \(new)/Contents/Resources/app/\(item)
            fi
            """
        }.joined(separator: "\n")
        return """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.5; done
        \(carry)
        codesign --force --deep --sign - \(new) >/dev/null 2>&1
        rm -rf \(old).old
        mv \(old) \(old).old && mv \(new) \(old) && rm -rf \(old).old
        \(relaunch ? "open " + old : "")
        rm -rf \(quoted(staging))
        """
    }


    // MARK: - Перевірка на старті

    static let lastCheckKey = "updateLastCheck"

    /// Раз на заданий у налаштуваннях строк (0 — ніколи) спитати GitHub і, коли
    /// є новіша версія, запропонувати. Тихо: без зв'язку — нічого.
    static func checkOnLaunch(state: AppState, intervalDays: Int) {
        guard intervalDays > 0 else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > Double(intervalDays) * 86_400 else { return }
        fetchLatest { result in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            guard case .success(let release) = result, isNewer(release.version, than: currentVersion) else { return }
            NativeTrace.say("оновлення: на GitHub \(release.tag), у нас \(currentVersion)")
            offer(release, state: state)
        }
    }

    /// Вікно «Є нова версія»: оновити зараз або пізніше.
    static func offer(_ release: Release, state: AppState) {
        let alert = NSAlert()
        alert.messageText = OurWords.t("Есть новая версия «Слова»: %s", release.version)
        let notes = plain(release.notes)
        alert.informativeText = OurWords.t("У вас %s. Программа загрузит новую версию, заменит себя и перезапустится; затем можно обновить и ресурсы.", currentVersion)
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(700)))
        alert.addButton(withTitle: OurWords.t("Обновить сейчас"))
        alert.addButton(withTitle: OurWords.t("Позже"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NativeUpdateWindow.show(release: release)
    }

    /// Пункт меню: спитати GitHub зараз і сказати відповідь — навіть «у вас
    /// остання», щоб людина бачила, що перевірка відбулася.
    static func checkNow(state: AppState) {
        fetchLatest { result in
            switch result {
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = OurWords.t("Не удалось спросить GitHub")
                alert.informativeText = "\(error)"
                alert.runModal()
            case .success(let release):
                if isNewer(release.version, than: currentVersion) {
                    offer(release, state: state)
                } else {
                    let alert = NSAlert()
                    alert.messageText = OurWords.t("У вас последняя версия (%s)", release.version)
                    alert.informativeText = OurWords.t("Ресурсы (переводы, песенники, фоны, шаблоны) обновляются отдельно: «Настройка» → «Ресурсы с GitHub…».")
                    alert.addButton(withTitle: OurWords.t("Ок"))
                    alert.addButton(withTitle: OurWords.t("Ресурсы с GitHub…"))
                    if alert.runModal() == .alertSecondButtonReturn { NativeResourcesWindow.show(state: state, updatesOnly: true) }
                }
            }
        }
    }
}

// MARK: - Хід оновлення

/// Одне оновлення: завантажити, розпакувати, перевірити, підготувати заміну.
/// Кожен крок — рядком у журнал вікна (`log`), хід завантаження — у `progress`.
/// Усе приходить у головний потік через run loop.
final class UpdateSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    let release: AppUpdater.Release
    var log: (@MainActor (String) -> Void)?
    var progress: (@MainActor (Double?, String) -> Void)?
    /// Кінець: `nil` — усе готово, помічник чекає виходу; інакше причина.
    var finished: (@MainActor (String?) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var started = Date()
    private var lastLoggedTenth = -1
    private let bundle = Bundle.main.bundleURL
    private(set) var staging: URL?
    private var cancelled = false

    init(release: AppUpdater.Release) {
        self.release = release
    }

    private func say(_ text: String) {
        let sink = log
        AppUpdater.onMain { sink?(text) }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f МБ", Double(bytes) / 1_048_576)
    }

    func start() {
        guard let zip = release.zip, let url = URL(string: zip) else {
            finish(OurWords.t("в выпуске нет файла программы для macOS")); return
        }
        say(OurWords.t("Сейчас: %s. На GitHub: %s.", AppUpdater.currentVersion, release.tag))
        say(OurWords.t("Файл: %s (%s).", url.lastPathComponent, Self.megabytes(release.size)))
        say(OurWords.t("Программа сейчас: %s", bundle.path))
        say(OurWords.t("Загружаю…"))
        started = Date()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        session?.invalidateAndCancel()
        if let staging { try? FileManager.default.removeItem(at: staging) }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : release.size
        let fraction = total > 0 ? Double(totalBytesWritten) / Double(total) : nil
        let seconds = max(0.1, Date().timeIntervalSince(started))
        let speed = Double(totalBytesWritten) / seconds / 1_048_576
        let text = OurWords.t("Загружено %s из %s · %s МБ/с", Self.megabytes(totalBytesWritten),
                              total > 0 ? Self.megabytes(total) : "?", String(format: "%.1f", speed))
        let sink = progress
        AppUpdater.onMain { sink?(fraction, text) }
        if let fraction {
            let tenth = Int(fraction * 10)
            if tenth > lastLoggedTenth, tenth < 10 {
                lastLoggedTenth = tenth
                if tenth > 0 { say("  \(tenth * 10) % — " + text) }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !cancelled else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { finish(OurWords.t("сервер ответил %s", "\(status)")); return }
        let fm = FileManager.default
        let staging = bundle.deletingLastPathComponent().appendingPathComponent(".slovo-update-" + UUID().uuidString)
        self.staging = staging
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let kept = staging.appendingPathComponent("update.zip")
            try fm.moveItem(at: location, to: kept)
            let size = (try? fm.attributesOfItem(atPath: kept.path)[.size] as? Int64) ?? 0
            say(OurWords.t("Загружено: %s за %s с.", Self.megabytes(size), String(format: "%.0f", Date().timeIntervalSince(started))))
        } catch {
            finish(OurWords.t("не удалось сохранить загруженное: %s", "\(error)")); return
        }
        prepare(in: staging)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !cancelled else { return }
        finish(OurWords.t("загрузка прервалась: %s", error.localizedDescription))
    }

    // MARK: Підготовка

    private func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func prepare(in staging: URL) {
        let fm = FileManager.default
        say(OurWords.t("Распаковываю архив…"))
        let kept = staging.appendingPathComponent("update.zip")
        let status = run("/usr/bin/ditto", ["-x", "-k", kept.path, staging.path])
        guard status == 0 else { finish(OurWords.t("не распаковалось: %s", "ditto \(status)")); return }
        guard let fresh = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else {
            finish(OurWords.t("в архиве нет пакета программы")); return
        }
        try? fm.removeItem(at: kept)
        let info = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist"))
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        say(OurWords.t("Распаковано: %s, версия %s.", fresh.lastPathComponent, version))
        guard fm.isExecutableFile(atPath: fresh.appendingPathComponent("Contents/MacOS/Slovo").path) else {
            finish(OurWords.t("в новом пакете нет исполняемого файла")); return
        }
        if version != release.version {
            say(OurWords.t("Внимание: в архиве версия %s, а выпуск называется %s.", version, release.version))
        }
        say(OurWords.t("Снимаю отметку карантина с нового пакета…"))
        _ = run("/usr/bin/xattr", ["-cr", fresh.path])

        let appData = bundle.appendingPathComponent("Contents/Resources/app")
        let carried = AppUpdater.carriedData.filter { fm.fileExists(atPath: appData.appendingPathComponent($0).path) }
        if carried.isEmpty {
            say(OurWords.t("Данных в пакете программы нет — переносить нечего (переводы и ресурсы лежат в Application Support и остаются на месте)."))
        } else {
            say(OurWords.t("Из старого пакета в новый перейдут: %s.", carried.joined(separator: ", ")))
        }

        let script = AppUpdater.helperScript(pid: ProcessInfo.processInfo.processIdentifier,
                                             bundle: bundle, fresh: fresh, staging: staging)
        let helper = staging.appendingPathComponent("replace.sh")
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [helper.path]
            try process.run()
        } catch {
            finish(OurWords.t("помощник замены не запустился: %s", "\(error)")); return
        }
        say(OurWords.t("Помощник замены запущен: ждёт, пока программа закроется, переносит данные, заменяет пакет и открывает новую версию."))
        finish(nil)
    }

    private func finish(_ failure: String?) {
        let sink = finished
        AppUpdater.onMain { sink?(failure) }
    }
}

/// Вікно ходу оновлення: журнал кроків, смужка, «Скасувати» / «Закрити».
@MainActor
enum NativeUpdateWindow {

    private static var window: NSWindow?
    private static var session: UpdateSession?

    static func show(release: AppUpdater.Release) {
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = OurWords.t("Обновление «Слова» до %s", release.version)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 320)

        let content = NSView(frame: panel.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 6, height: 6)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let button = NSButton(title: OurWords.t("Отмена"), target: nil, action: nil)
        button.bezelStyle = .rounded

        let gap: CGFloat = 12
        let size = content.bounds.size
        button.frame = NSRect(x: size.width - gap - 120, y: gap, width: 120, height: 28)
        button.autoresizingMask = [.minXMargin, .maxYMargin]
        status.frame = NSRect(x: gap, y: gap + 5, width: size.width - gap * 3 - 120, height: 18)
        status.autoresizingMask = [.width, .maxYMargin]
        bar.frame = NSRect(x: gap, y: gap + 36, width: size.width - gap * 2, height: 12)
        bar.autoresizingMask = [.width, .maxYMargin]
        scroll.frame = NSRect(x: gap, y: gap + 56, width: size.width - gap * 2, height: size.height - gap * 2 - 56)
        scroll.autoresizingMask = [.width, .height]
        for view in [scroll, bar, status, button] as [NSView] { content.addSubview(view) }
        panel.contentView = content

        let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
        func append(_ line: String) {
            let entry = "\(stamp.string(from: Date()))  \(line)\n"
            text.textStorage?.append(NSAttributedString(string: entry, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                                  .foregroundColor: NSColor.labelColor]))
            text.scrollToEndOfDocument(nil)
            NativeTrace.say("оновлення: " + line)
        }

        let session = UpdateSession(release: release)
        let action = UpdateButtonAction()
        action.handler = {
            if session.staging != nil || window?.isVisible == true, button.title == OurWords.t("Отмена") {
                session.cancel()
                append(OurWords.t("Отменено. Программа осталась прежней."))
                button.title = OurWords.t("Закрыть")
                return
            }
            window?.close()
        }
        button.target = action
        button.action = #selector(UpdateButtonAction.fire)
        objc_setAssociatedObject(button, "action", action, .OBJC_ASSOCIATION_RETAIN)

        session.log = { append($0) }
        session.progress = { fraction, line in
            if let fraction { bar.doubleValue = fraction } else { bar.isIndeterminate = true; bar.startAnimation(nil) }
            status.stringValue = line
        }
        session.finished = { failure in
            bar.isIndeterminate = false
            if let failure {
                append(OurWords.t("Ошибка: %s", failure))
                append(OurWords.t("Программа осталась прежней. Можно попробовать позже: «Настройка» → «Проверить обновление программы…»."))
                status.stringValue = OurWords.t("Обновление не удалось")
                button.title = OurWords.t("Закрыть")
                return
            }
            bar.doubleValue = 1
            button.isEnabled = false
            var left = 3
            append(OurWords.t("Всё готово. Программа закроется через %s с и откроется уже новой.", "\(left)"))
            status.stringValue = OurWords.t("Закрываюсь через %s с…", "\(left)")
            let timer = Timer(timeInterval: 1, repeats: true) { timer in
                MainActor.assumeIsolated {
                    left -= 1
                    status.stringValue = OurWords.t("Закрываюсь через %s с…", "\(left)")
                    guard left <= 0 else { return }
                    timer.invalidate()
                    append(OurWords.t("Закрываюсь."))
                    NSApp.terminate(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        window = panel
        self.session = session
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: nil) { _ in
            MainActor.assumeIsolated {
                if button.title == OurWords.t("Отмена") { session.cancel() }
                window = nil
                self.session = nil
            }
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        append(OurWords.t("Начинаю обновление."))
        session.start()
    }
}

final class UpdateButtonAction: NSObject {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

/// Пропозиція на старті, коли перекладів і пісенників нема зовсім
/// (збірка «лише програма»): завантажити з GitHub або імпортувати.
@MainActor
enum ResourceOffer {
    static var shown = false

    static func offerIfEmpty(state: AppState) {
        guard !shown, state.allModules.isEmpty, (state.songLibrary?.books.isEmpty ?? true), !state.isLoadingLibrary else { return }
        shown = true
        let alert = NSAlert()
        alert.messageText = OurWords.t("В папке модулей пусто")
        alert.informativeText = OurWords.t("Переводов и песенников у программы ещё нет. Загрузить их с GitHub (ресурсы «Слова» или модули «Цитата из Библии») или импортировать с этого компьютера (VisioBible, папка с модулями, архив)?")
        alert.addButton(withTitle: OurWords.t("Загрузить с GitHub…"))
        alert.addButton(withTitle: OurWords.t("Импортировать…"))
        alert.addButton(withTitle: OurWords.t("Позже"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:  NativeResourcesWindow.show(state: state)
        case .alertSecondButtonReturn: ImportWizardWindow.show(state: state)
        default: break
        }
    }
}
