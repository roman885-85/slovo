import AppKit
import SlovoCore

/// Оновлення самої програми з GitHub — з того самого місця, звідки ресурси.
///
/// Власник: «при обновлении самой программы также выполнять обновление с
/// того же ресурса». Питаємо `releases/latest` репозиторію `roman885-85/slovo`,
/// порівнюємо тег (`v0.68`) з версією пакета; є новіша — завантажуємо
/// `Slovo-<версія>-macOS.zip`, розпаковуємо поруч із пакетом і підмінюємо
/// його помічником після виходу: сама себе програма підмінити не може.
/// Разом із програмою — оновлення ресурсів у вікні «Ресурси з GitHub».
@MainActor
enum AppUpdater {

    static let releasesURL = URL(string: "https://api.github.com/repos/roman885-85/slovo/releases/latest")!

    struct Release: Sendable {
        var version: String          // "0.68"
        var tag: String              // "v0.68"
        var page: String             // сторінка релізу
        var notes: String
        var zip: String?             // адреса Slovo-…-macOS.zip
        var size: Int64
    }

    static var currentVersion: String {
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

    /// Останній випуск на GitHub. Відповідь — у головному потоці.
    static func fetchLatest(completion: @escaping @MainActor (Result<Release, ResourceError>) -> Void) {
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
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }.resume()
    }

    /// Завантажити випуск і підмінити пакет. Хід — рядком у `progress`.
    static func install(_ release: Release,
                        progress: @escaping @MainActor (String) -> Void,
                        completion: @escaping @MainActor (String?) -> Void) {
        guard let zip = release.zip, let url = URL(string: zip) else {
            completion(OurWords.t("в выпуске нет файла программы для macOS")); return
        }
        progress(OurWords.t("Загружаю %s…", release.tag))
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            var failure: String?
            if let error {
                failure = error.localizedDescription
            } else if let location, (response as? HTTPURLResponse)?.statusCode == 200 {
                failure = replaceBundle(with: location)
            } else {
                failure = OurWords.t("сервер ответил %s", "\((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(failure) } }
        }
        task.resume()
    }

    /// Розпакувати поруч із пакетом і лишити помічника, який після виходу
    /// програми підмінить пакет і запустить новий. Повертає причину невдачі.
    nonisolated private static func replaceBundle(with zip: URL) -> String? {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        let staging = bundle.deletingLastPathComponent().appendingPathComponent(".slovo-update-" + UUID().uuidString)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let kept = staging.appendingPathComponent("update.zip")
            try fm.moveItem(at: zip, to: kept)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", kept.path, staging.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { return "ditto \(ditto.terminationStatus)" }
            guard let fresh = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
                    .first(where: { $0.pathExtension == "app" }) else {
                return OurWords.t("в архиве нет пакета программы")
            }
            // Карантин з нового пакета знімаємо самі: він прийшов від нас же.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", fresh.path]
            try? xattr.run(); xattr.waitUntilExit()
            // Помічник: чекає, поки програма вийде, переносить дані з
            // пакета, підмінює пакет, запускає.
            let script = helperScript(pid: ProcessInfo.processInfo.processIdentifier,
                                      bundle: bundle, fresh: fresh, staging: staging)
            let helper = staging.appendingPathComponent("replace.sh")
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/bin/sh")
            run.arguments = [helper.path]
            try run.run()
            return nil
        } catch {
            try? fm.removeItem(at: staging)
            return "\(error)"
        }
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

    static var lastCheckKey = "updateLastCheck"

    /// Раз на заданий у налаштуваннях строк (0 — ніколи) спитати GitHub і, коли
    /// є новіша версія, показати вікно. Тихо: без зв'язку — нічого.
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
        alert.informativeText = OurWords.t("У вас %s. Программа загрузит новую версию, заменит себя и перезапустится; затем можно обновить и ресурсы.", currentVersion)
            + (release.notes.isEmpty ? "" : "\n\n" + String(release.notes.prefix(600)))
        alert.addButton(withTitle: OurWords.t("Обновить сейчас"))
        alert.addButton(withTitle: OurWords.t("Позже"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NativeUpdateProgress.run(release: release, state: state)
    }
}

/// Маленьке вікно ходу оновлення програми.
@MainActor
enum NativeUpdateProgress {
    static func run(release: AppUpdater.Release, state: AppState) {
        let alert = NSAlert()
        alert.messageText = OurWords.t("Загружаю %s…", release.tag)
        alert.informativeText = OurWords.t("Программа закроется и откроется снова уже новой.")
        alert.addButton(withTitle: OurWords.t("Отмена"))
        let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 300, height: 16))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        alert.accessoryView = bar
        var finished = false
        AppUpdater.install(release, progress: { text in alert.messageText = text }) { failure in
            finished = true
            NSApp.abortModal()
            if let failure {
                let bad = NSAlert()
                bad.messageText = OurWords.t("Обновление не удалось")
                bad.informativeText = failure
                bad.runModal()
            } else {
                // Помічник чекає нашого виходу.
                NSApp.terminate(nil)
            }
        }
        _ = alert.runModal()
        if !finished { NativeTrace.say("оновлення: скасовано") }
    }
}

extension AppUpdater {
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
