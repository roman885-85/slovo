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
        // Рядки абзацу в Markdown переносяться руками, щоб файл читався в
        // редакторі; у вікні ці переноси рвали речення посередині («з 0.82 /
        // і 0.83 — / лише вручну», 0.85). Складаємо абзац і пункт списку в
        // один рядок; заголовок і порожній рядок лишаються межами.
        var result: [String] = []
        var joinable = false
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            let isHeading = line.hasPrefix("#")
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            let startsItem = line.hasPrefix("- ") || line.hasPrefix("* ")
                || line.range(of: "^[0-9]+\\. ", options: .regularExpression) != nil
            if line.isEmpty {
                if result.last != "" { result.append("") }
                joinable = false
            } else if joinable, !isHeading, !startsItem, let last = result.last {
                result[result.count - 1] = last + " " + line
            } else {
                result.append(line)
                joinable = !isHeading
            }
        }
        while result.last == "" { result.removeLast() }
        return result.joined(separator: "\n")
    }

    /// Теки й файли даних у `Contents/Resources/app`, які переходять зі
    /// старого пакета в новий: випуск на GitHub — «лише програма», а в
    /// пакеті власника лежать усі переклади (власник: «все переводы и модули
    /// внутри пакета всегда») — оновлення не має їх загубити.
    nonisolated static let carriedData = ["Modules", "BackGrounds", "Templates", "Plans", "Fonts", "RemoteAPI",
                                          "Імпорт з VisioBible", "settings.json"]

    /// Де пакет лежить насправді.
    ///
    /// Програму, відкриту просто з розпакованого архіву («Завантаження»),
    /// macOS запускає з копії в теці лише для читання
    /// (`/private/var/folders/…/AppTranslocation/…`). Оновлення клало новий пакет
    /// поруч із тією копією й падало: «том доступний лише для читання»
    /// (власник, 0.87 → 0.88). Справжнє місце повертає системна
    /// `SecTranslocateCreateOriginalPathForURL`.
    nonisolated static func isTranslocated(_ bundle: URL) -> Bool {
        bundle.path.contains("/AppTranslocation/")
    }

    nonisolated static func originalBundleURL(of bundle: URL) -> URL? {
        guard isTranslocated(bundle) else { return bundle }
        typealias Create = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        guard let original = create(bundle as CFURL, nil)?.takeRetainedValue() else { return nil }
        let url = original as URL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Скрипт помічника. Окремо — щоб самоперевірка прогнала його на
    /// тимчасових пакетах.
    nonisolated static func helperScript(pid: Int32, bundle: URL, fresh: URL, staging: URL, relaunch: Bool = true) -> String {
        func quoted(_ url: URL) -> String { "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let old = quoted(bundle), new = quoted(fresh), parked = quoted(bundle) + ".old"
        // Дані переходять уже ПІСЛЯ заміни — з відкладеного старого пакета в
        // новий на місці. Не вдалася заміна — старий вертається цілим, з
        // даними. У 0.82–0.83 теку з новим пакетом стирало закриття вікна,
        // заміна падала посередині, і на місці програми не лишалося нічого,
        // крім «Слово.app.old».
        let carry = carriedData.map { name -> String in
            let item = "'" + name + "'"
            return """
            if [ -e \(parked)/Contents/Resources/app/\(item) ]; then
              mkdir -p \(old)/Contents/Resources/app
              rm -rf \(old)/Contents/Resources/app/\(item)
              mv \(parked)/Contents/Resources/app/\(item) \(old)/Contents/Resources/app/\(item)
            fi
            """
        }.joined(separator: "\n")
        return """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.5; done
        if [ ! -x \(new)/Contents/MacOS/Slovo ]; then
          echo "оновлення: нового пакета нема — лишаю старий" >&2
          \(relaunch ? "open " + old : "")
          exit 1
        fi
        rm -rf \(parked)
        if mv \(old) \(parked); then
          if mv \(new) \(old); then
        \(carry)
            codesign --force --deep --sign - \(old) >/dev/null 2>&1
            rm -rf \(parked)
          else
            echo "оновлення: заміна не вдалася — вертаю старий пакет" >&2
            mv \(parked) \(old)
          fi
        fi
        \(relaunch ? "open " + old : "")
        rm -rf \(quoted(staging))
        """
    }

    // MARK: - Перевірка на старті

    static let lastCheckKey = "updateLastCheck"

    /// Раз на заданий у налаштуваннях строк (0 — ніколи) спитати GitHub і, коли
    /// є новіша версія, запропонувати. Тихо: без зв'язку — нічого.
    ///
    /// Власник: «при появлении новой версии выводить сообщение». Тому GitHub
    /// питаємо на кожному запуску (крім «Ніколи»), а поки програма відкрита —
    /// ще раз на 12 годин. Ту саму версію, від якої відмовилися «Пізніше»,
    /// до наступного запуску вдруге не пропонуємо.
    static func checkOnLaunch(state: AppState, intervalDays: Int) {
        guard intervalDays > 0 else { return }
        checkQuietly(state: state)
        guard periodic == nil else { return }
        let timer = Timer(timeInterval: 12 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { checkQuietly(state: state) }
        }
        RunLoop.main.add(timer, forMode: .common)
        periodic = timer
    }

    private static var periodic: Timer?
    private static var declinedVersion: String?

    private static func checkQuietly(state: AppState) {
        fetchLatest { result in
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            guard case .success(let release) = result, isNewer(release.version, than: currentVersion),
                  release.version != declinedVersion else { return }
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
        guard alert.runModal() == .alertFirstButtonReturn else { declinedVersion = release.version; return }
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
    /// Що робимо зараз і скільки з усього зроблено (0…1) — рядок і смужка вікна.
    var step: (@MainActor (String, Double) -> Void)?
    /// Кінець: `nil` — усе готово, помічник чекає виходу; інакше причина.
    var finished: (@MainActor (String?) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var started = Date()
    private var lastLoggedTenth = -1
    /// Звідки запущено програму (може бути копія App Translocation).
    private let running = Bundle.main.bundleURL
    /// Пакет, який замінюємо, — справжнє місце програми.
    private var bundle: URL = Bundle.main.bundleURL
    private(set) var staging: URL?
    private var cancelled = false
    /// Помічник заміни вже запущений: теку з новим пакетом тепер тримає він,
    /// і стирати її не можна нічим — ні «Скасувати», ні закриттям вікна.
    private(set) var handedOff = false

    init(release: AppUpdater.Release) {
        self.release = release
    }

    private func say(_ text: String) {
        let sink = log
        AppUpdater.onMain { sink?(text) }
    }

    private func tell(_ text: String, _ done: Double) {
        say(text)
        let sink = step
        AppUpdater.onMain { sink?(text, done) }
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
        say(OurWords.t("Программа сейчас: %s", running.path))
        guard let original = AppUpdater.originalBundleURL(of: running) else {
            finish(OurWords.t("macOS запустила программу из временной копии, и где лежит сама программа, узнать не удалось. Перенесите «Слово.app» в папку «Программы», откройте оттуда и обновите ещё раз."))
            return
        }
        bundle = original
        if original != running { say(OurWords.t("Сама программа лежит здесь: %s", original.path)) }
        guard FileManager.default.isWritableFile(atPath: original.deletingLastPathComponent().path) else {
            finish(OurWords.t("В папку %s нельзя записать. Перенесите «Слово.app» в папку «Программы», откройте оттуда и обновите ещё раз.", original.deletingLastPathComponent().path))
            return
        }
        tell(OurWords.t("Загружаю новую версию…"), 0.02)
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
        guard !handedOff else { return }
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
        let stepSink = step
        AppUpdater.onMain {
            sink?(fraction, text)
            stepSink?(OurWords.t("Загружаю новую версию: %s из %s · %s МБ/с", Self.megabytes(totalBytesWritten),
                                 total > 0 ? Self.megabytes(total) : "?", String(format: "%.1f", speed)),
                      0.02 + (fraction ?? 0) * 0.78)
        }
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
        tell(OurWords.t("Распаковываю архив…"), 0.82)
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
        tell(OurWords.t("Проверяю новый пакет: версия %s…", version), 0.88)
        guard fm.isExecutableFile(atPath: fresh.appendingPathComponent("Contents/MacOS/Slovo").path) else {
            finish(OurWords.t("в новом пакете нет исполняемого файла")); return
        }
        if version != release.version {
            say(OurWords.t("Внимание: в архиве версия %s, а выпуск называется %s.", version, release.version))
        }
        tell(OurWords.t("Снимаю отметку карантина с нового пакета…"), 0.92)
        _ = run("/usr/bin/xattr", ["-cr", fresh.path])

        let appData = bundle.appendingPathComponent("Contents/Resources/app")
        let carried = AppUpdater.carriedData.filter { fm.fileExists(atPath: appData.appendingPathComponent($0).path) }
        if carried.isEmpty {
            say(OurWords.t("Данных в пакете программы нет — переносить нечего (переводы и ресурсы лежат в Application Support и остаются на месте)."))
        } else {
            say(OurWords.t("Из старого пакета в новый перейдут: %s.", carried.joined(separator: ", ")))
        }

        tell(OurWords.t("Готовлю замену программы…"), 0.96)
        let script = AppUpdater.helperScript(pid: ProcessInfo.processInfo.processIdentifier,
                                             bundle: bundle, fresh: fresh, staging: staging)
        let helper = staging.appendingPathComponent("replace.sh")
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [helper.path]
            try process.run()
            handedOff = true
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

/// Вікно ходу оновлення — у стилі заставки запуску.
///
/// Власник: «процесс обновления подробный, но в красивом стиле (как в плашке
/// запуска)… вместо такого подробного окна сделать строку выполнения и
/// описание что конкретно сейчас выполняется… и полосу выполнения». Темна
/// плашка зі значком: заголовок, рядок «що зараз робиться» і смужка всього
/// оновлення. Докладний журнал кроків іде в щоденник програми
/// (`~/Library/Logs/slovo-start.txt`, рядки «оновлення:»).
@MainActor
enum NativeUpdateWindow {

    private static var window: NSWindow?
    private static var session: UpdateSession?

    /// Безрамкове вікно, що все одно приймає клавіатуру й клацання.
    private final class Panel: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    static func show(release: AppUpdater.Release, startSession: Bool = true) {
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        let size = NSSize(width: 500, height: 250)
        let panel = Panel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.title = OurWords.t("Обновление «Слова» до %s", release.version)

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        // Та сама темна підкладка, що в заставки запуску.
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.18, alpha: 1).cgColor
        root.appearance = NSAppearance(named: .darkAqua)

        let icon = NSImageView(frame: NSRect(x: 28, y: size.height - 28 - 64, width: 64, height: 64))
        icon.image = Bundle.main.url(forResource: "Slovo", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(icon)

        let title = NSTextField(labelWithString: OurWords.t("Обновление «Слова»"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: 108, y: size.height - 62, width: size.width - 136, height: 28)
        root.addSubview(title)

        let versions = NSTextField(labelWithString: "\(AppUpdater.currentVersion)  →  \(release.version)")
        versions.font = .systemFont(ofSize: 13, weight: .medium)
        versions.textColor = NSColor.white.withAlphaComponent(0.6)
        versions.frame = NSRect(x: 108, y: size.height - 86, width: size.width - 136, height: 18)
        root.addSubview(versions)

        // Що робиться зараз — до трьох рядків: причина помилки буває довгою.
        let status = NSTextField(wrappingLabelWithString: OurWords.t("Готовлю обновление…"))
        status.font = .systemFont(ofSize: 13)
        status.textColor = NSColor.white.withAlphaComponent(0.85)
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        status.frame = NSRect(x: 28, y: 86, width: size.width - 56, height: 52)
        root.addSubview(status)

        let bar = NSProgressIndicator(frame: NSRect(x: 28, y: 70, width: size.width - 56, height: 8))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        bar.doubleValue = 0
        root.addSubview(bar)

        let percent = NSTextField(labelWithString: "0 %")
        percent.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percent.textColor = NSColor.white.withAlphaComponent(0.5)
        percent.frame = NSRect(x: 28, y: 28, width: 120, height: 16)
        root.addSubview(percent)

        let button = NSButton(title: OurWords.t("Отмена"), target: nil, action: nil)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: size.width - 28 - 120, y: 20, width: 120, height: 30)
        root.addSubview(button)
        panel.contentView = root

        func log(_ line: String) { NativeTrace.say("оновлення: " + line) }
        func show(_ text: String, _ done: Double) {
            status.stringValue = text
            bar.doubleValue = max(bar.doubleValue, min(1, done))
            percent.stringValue = "\(Int((bar.doubleValue * 100).rounded())) %"
        }

        let session = UpdateSession(release: release)
        /// Іде оновлення: кнопка й закриття скасовують. Скінчилося — закривають.
        var running = true
        let action = UpdateButtonAction()
        action.handler = {
            if running {
                running = false
                session.cancel()
                log("скасовано")
                status.stringValue = OurWords.t("Отменено. Программа осталась прежней.")
                button.title = OurWords.t("Закрыть")
                return
            }
            window?.close()
        }
        button.target = action
        button.action = #selector(UpdateButtonAction.fire)
        objc_setAssociatedObject(button, "action", action, .OBJC_ASSOCIATION_RETAIN)

        session.log = { log($0) }
        session.step = { text, done in if running { show(text, done) } }
        session.finished = { failure in
            running = false
            if let failure {
                log("помилка: " + failure)
                status.stringValue = OurWords.t("Обновление не удалось: %s", failure)
                status.textColor = NSColor(calibratedRed: 1, green: 0.62, blue: 0.55, alpha: 1)
                percent.stringValue = ""
                button.title = OurWords.t("Закрыть")
                return
            }
            show(OurWords.t("Готово. «Слово» перезапустится через %s с…", "3"), 1)
            button.isEnabled = false
            var left = 3
            let timer = Timer(timeInterval: 1, repeats: true) { timer in
                MainActor.assumeIsolated {
                    left -= 1
                    status.stringValue = OurWords.t("Готово. «Слово» перезапустится через %s с…", "\(max(left, 0))")
                    guard left <= 0 else { return }
                    timer.invalidate()
                    log("закриваюся")
                    NSApp.terminate(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        window = panel
        self.session = session
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: nil) { _ in
            MainActor.assumeIsolated {
                // Закриття скасовує лише те, що ще йде: готове оновлення тримає
                // помічник заміни, і його теку стирати не можна.
                if running { session.cancel() }
                window = nil
                self.session = nil
            }
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        log(OurWords.t("Начинаю обновление."))
        if startSession { session.start() }
    }

    /// Самоперевірці: вікно з вигаданим випуском і кроком, без завантаження, —
    /// знімок у `~/Library/Logs`.
    static func previewForCheck(to name: String) -> Bool {
        let fake = AppUpdater.Release(version: "9.99", tag: "v9.99", page: "", notes: "", zip: nil, size: 0)
        show(release: fake, startSession: false)
        session?.step?(OurWords.t("Загружаю новую версию: %s из %s · %s МБ/с", "14.9 МБ", "33.0 МБ", "8.4"), 0.46)
        guard let view = window?.contentView else { return false }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let saved = Diagnostics.snapshot(view, to: name)
        window?.close()
        return saved
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
