import Foundation
import CryptoKit
import SlovoCore

/// Свій yt-dlp, що оновлюється сам.
///
/// Власник 24.11.2026: «yt-dlp — нужно чтобы он автоматически обновлялся в
/// программах, если выходит его обновление». YouTube часто міняє сторінки, і
/// старий yt-dlp перестає діставати ролики — нові випуски виходять щотижня, а в
/// пакеті програми лежить той, що був на день збирання (і чіпати його не можна:
/// зламається підпис пакета).
///
/// Тому програма тримає СВОЮ копію в теці даних (`Tools/yt-dlp_macos`) і раз на
/// добу, у фоні, звіряє її з останнім випуском на GitHub: новіший — завантажує,
/// звіряє суму SHA-256 з `SHA2-256SUMS` того самого випуску й підміняє. Копії
/// немає — завантажує. Вимикається галочкою в «Параметри → Медіа → YouTube»;
/// шлях, указаний людиною вручну, не чіпаємо. Так само у Windows-версії.
enum YouTubeToolUpdater {

    static let assetName = "yt-dlp_macos"
    private static let releases = "https://github.com/yt-dlp/yt-dlp/releases"
    private static let autoKey = "youTubeToolAutoUpdate"
    private static let checkedKey = "youTubeToolCheckedAt"
    private static let statusKey = "youTubeToolStatus"
    /// Стан змінився — «Параметрам» перемалювати рядок.
    static let statusChanged = Notification.Name("ua.church.slovo.youTubeToolStatus")

    /// Своя копія — у теці даних.
    static var managedURL: URL { DataHome.folder.appendingPathComponent("Tools").appendingPathComponent(assetName) }

    /// «Оновлювати yt-dlp автоматично» — за замовчанням так.
    static var autoUpdate: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    /// Що сказати в «Параметрах»: версія й коли перевірено, або чому не вийшло.
    static var status: String { UserDefaults.standard.string(forKey: statusKey) ?? "" }

    nonisolated(unsafe) private static var running = false

    /// Чим скінчилася остання звірка — самоперевірці.
    enum Outcome { case none, upToDate, downloaded, updated, failed }
    nonisolated(unsafe) private(set) static var lastOutcome: Outcome = .none

    /// Після запуску: раз на добу, у фоні, якщо не вимкнено. Під самоперевіркою — ні.
    static func checkInBackground() {
        guard autoUpdate, !CommandLine.arguments.contains(where: { $0.hasPrefix("--check") }) else { return }
        if let last = UserDefaults.standard.object(forKey: checkedKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600,
           FileManager.default.fileExists(atPath: managedURL.path) { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { check() }
    }

    /// Перевірити й, якщо треба, оновити — у фоні; `done` отримує рядок стану (головний потік).
    static func check(done: (@MainActor (String) -> Void)? = nil) {
        guard !running else { done.map { callback in DispatchQueue.main.async { MainActor.assumeIsolated { callback(status) } } }; return }
        running = true
        DispatchQueue.global(qos: .utility).async {
            let text = runCheck()
            UserDefaults.standard.set(text, forKey: statusKey)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    running = false
                    NotificationCenter.default.post(name: statusChanged, object: nil)
                    done?(text)
                }
            }
        }
    }

    // MARK: - Робота (фоновий потік)

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter.string(from: Date())
    }

    private static func runCheck() -> String {
        do {
            let latest = try latestVersion()
            let current = installedVersion(managedURL)
            let text: String
            if let current, compare(current, latest) >= 0 {
                text = OurWords.t("yt-dlp %s — последняя версия (проверено %s)", current, stamp())
                lastOutcome = .upToDate
            } else {
                try download(version: latest)
                let installed = installedVersion(managedURL) ?? latest
                if let current {
                    text = OurWords.t("yt-dlp обновлён: %s → %s (%s)", current, installed, stamp())
                    lastOutcome = .updated
                } else {
                    text = OurWords.t("yt-dlp %s скачан с GitHub (%s)", installed, stamp())
                    lastOutcome = .downloaded
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { NativeTrace.say("yt-dlp: " + text) } }
            }
            UserDefaults.standard.set(Date(), forKey: checkedKey)
            return text
        } catch {
            lastOutcome = .failed
            return OurWords.t("Не удалось проверить обновление yt-dlp: %s", error.localizedDescription)
        }
    }

    private struct Problem: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// Не йти за переадресацією: адресу останнього випуску видно саме в ній.
    private final class StayPut: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Запит і чекання відповіді (фоновий потік).
    private static func fetch(_ address: String, followRedirects: Bool = true, timeout: TimeInterval = 300) throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: address) else { throw Problem(text: address) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        // Своє ім'я без жодних даних про людину чи комп'ютер.
        request.setValue("Slovo-yt-dlp-updater/1.0", forHTTPHeaderField: "User-Agent")
        let session = followRedirects ? URLSession(configuration: .ephemeral)
            : URLSession(configuration: .ephemeral, delegate: StayPut(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        session.dataTask(with: request) { data, response, error in
            result = (data, response, error)
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + timeout + 5) == .timedOut { throw Problem(text: OurWords.t("нет ответа от %s", url.host ?? address)) }
        if let error = result.2 { throw error }
        guard let response = result.1 as? HTTPURLResponse else { throw Problem(text: address) }
        return (result.0 ?? Data(), response)
    }

    /// Останній випуск — з переадресації сторінки «latest» (без API GitHub і його лімітів).
    private static func latestVersion() throws -> String {
        let (_, response) = try fetch(releases + "/latest", followRedirects: false, timeout: 30)
        let location = response.value(forHTTPHeaderField: "Location") ?? ""
        guard let mark = location.range(of: "/tag/", options: .backwards) else {
            throw Problem(text: OurWords.t("GitHub не назвал последний выпуск"))
        }
        return (String(location[mark.upperBound...]).removingPercentEncoding ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Версія встановленого файла (`--version`), nil — не відповів.
    private static func installedVersion(_ url: URL) -> String? {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.first?.isNumber == true ? text : nil
    }

    /// Завантажити файл випуску, звірити SHA-256 і покласти на місце своєї копії.
    private static func download(version: String) throws {
        let (sumsData, _) = try fetch("\(releases)/download/\(version)/SHA2-256SUMS", timeout: 60)
        let sums = String(data: sumsData, encoding: .utf8) ?? ""
        var expected: String?
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if parts.count == 2, parts[1] == assetName { expected = parts[0]; break }
        }
        guard let expected else { throw Problem(text: OurWords.t("в выпуске %s нет суммы для %s", version, assetName)) }
        let (binary, response) = try fetch("\(releases)/download/\(version)/\(assetName)")
        guard response.statusCode == 200 else { throw Problem(text: "HTTP \(response.statusCode)") }
        let actual = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw Problem(text: OurWords.t("сумма SHA-256 не совпала — файл не принят")) }
        let folder = managedURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(assetName + ".download")
        try binary.write(to: partial, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: partial.path)
        if FileManager.default.fileExists(atPath: managedURL.path) { try FileManager.default.removeItem(at: managedURL) }
        try FileManager.default.moveItem(at: partial, to: managedURL)
    }

    /// Порівняти версії yt-dlp («2026.11.23», «2026.11.23.1»).
    static func compare(_ one: String, _ two: String) -> Int {
        let a = one.split(separator: ".").map { Int($0) ?? 0 }
        let b = two.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
