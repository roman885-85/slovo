import Foundation
import SlovoCore

/// yt-dlp — свободная программа, которая умеет получить прямые дорожки ролика
/// YouTube (и сотен других сайтов) там, где сам YouTube их не отдаёт.
///
/// Когда она есть, ролик идёт через обычный плеер файлов и потоков: в зал,
/// в NDI и в веб полным кадром, а не снимками встроенного проигрывателя.
/// Нет — работает встроенный проигрыватель (`YouTubeEmbedPlayer`).
///
/// Ничего не скачивается целиком — владелец просил именно воспроизведение по
/// ссылке, «как в плеере YouTube»: быстрый пуск и перемотка без ожидания.
/// YouTube с 2025 года отдаёт звук и картинку раздельными дорожками
/// (проверено на этой машине: ни одного склеенного формата ни у одного
/// клиента). Но среди них есть его же HLS-дорожки — картинка по качествам и
/// звук врозь, — а плеер macOS играет такие пары нативно: сборный плейлист
/// со ссылками на их дорожки, и перемотка, буферизация и подбор качества по
/// каналу работают как у самого YouTube. Ни ffmpeg, ни временных кусков.
///
/// Когда HLS-дорожек у ролика нет, остаётся запасной путь: ffmpeg склеивает
/// прямые дорожки на лету в HLS-кусочки во временную папку, плеер стартует с
/// первых кусков (на проповеди в 44 минуты — через 6 с), а перемотка дальше
/// уже склеенного ждёт.
///
/// Владелец кладёт yt-dlp сам: файлы из сети программа не качает. Ищем в
/// папке программы (`~/Desktop/Слово`, рядом с пакетом), в `~/Applications`,
/// в Homebrew и в `~/.local/bin`; путь можно указать и руками — в «Параметрах»
/// на вкладке «Медиа». Принимаются два вида: готовая программа (`yt-dlp`,
/// `yt-dlp_macos`) и папка с исходниками (`yt-dlp-master`, внутри
/// `yt_dlp/__main__.py`) — той нужен Python не старше 3.10, и его тоже ищем.
enum YouTubeResolver {

    /// Что нашли.
    enum Tool: Equatable {
        case executable(URL)
        case sources(folder: URL, python: URL)

        var description: String {
            switch self {
            case .executable(let url): return url.path
            case let .sources(folder, python): return folder.path + " (" + python.path + ")"
            }
        }
    }

    /// Итог поиска — для строки состояния в «Параметрах» и самопроверки.
    struct Availability {
        var tool: Tool?
        var note: String
    }

    /// Что получилось: адрес потока для плеера и название. Поток либо прямой
    /// (трансляции — у них HLS со звуком), либо сборный плейлист HLS-дорожек
    /// YouTube с нашего сервера, либо — запасным путём — склеенный на лету.
    struct Resolved {
        let url: URL
        let title: String
        let isLive: Bool
        /// Длительность по описанию ролика: у склеиваемого на лету потока
        /// плеер узнаёт её лишь в самом конце, а ползунку она нужна сразу.
        let duration: Double
        /// Склеивается на лету — ffmpeg ещё работает.
        let isRemuxed: Bool
    }

    enum Failure: Error, CustomStringConvertible {
        case launch(String)
        case failed(String)
        case timeout
        case noURL(String)
        case noFFmpeg

        var description: String {
            switch self {
            case .launch(let text): return OurWords.t("yt-dlp не запустился: %s", text)
            case .failed(let text): return OurWords.t("yt-dlp: %s", text)
            case .timeout: return OurWords.t("yt-dlp не ответил за отведённое время")
            case .noURL(let text): return OurWords.t("yt-dlp не дал потока: %s", text)
            case .noFFmpeg: return OurWords.t("ffmpeg не найден — склеить дорожки нечем")
            }
        }
    }

    /// Идущая работа: yt-dlp, а затем ffmpeg, который живёт всё время показа.
    /// Прервать — когда открыли другое или закрыли плеер.
    final class Job {
        private var processes: [Process] = []
        private let lock = NSLock()
        private(set) var isCancelled = false
        /// Временная папка склейки и её ключ на сервере — снять при отмене.
        fileprivate var folder: URL?
        fileprivate var key: String?

        fileprivate func track(_ process: Process) { lock.lock(); processes.append(process); lock.unlock() }

        /// Идёт ли ещё склейка. Самопроверке — доказать, что играем раньше,
        /// чем всё готово.
        var isRemuxing: Bool {
            lock.lock(); defer { lock.unlock() }
            return processes.last?.isRunning ?? false
        }

        func cancel() {
            lock.lock(); isCancelled = true; let running = processes; lock.unlock()
            for process in running where process.isRunning { process.terminate() }
            if let key { YouTubeHostServer.withdraw(key) }
            if let folder { try? FileManager.default.removeItem(at: folder) }
        }
    }

    // MARK: - Поиск

    private static let executableNames = ["yt-dlp", "yt-dlp_macos", "yt-dlp_macos_legacy"]
    private static let sourceFolderNames = ["yt-dlp-master", "yt-dlp", "yt-dlp-main"]

    /// Папки, где смотрим. Первым — свой пакет: собранный yt-dlp едет внутри
    /// него, и на чужой машине это единственное, что есть. Потом папка
    /// программы — туда владелец кладёт исходники и прочее.
    private static var searchFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL { folders.append(resources) }
        folders.append(home.appendingPathComponent("Desktop/Слово"))
        let bundle = Bundle.main.bundleURL
        folders.append(bundle.deletingLastPathComponent())
        folders.append(home.appendingPathComponent("Applications"))
        folders.append(URL(fileURLWithPath: "/opt/homebrew/bin"))
        folders.append(URL(fileURLWithPath: "/usr/local/bin"))
        folders.append(home.appendingPathComponent(".local/bin"))
        folders.append(home.appendingPathComponent("bin"))
        return folders
    }

    /// Поиск с памятью на минуту: он запускает `python3 --version`, а звать
    /// его при каждом открытии ссылки и каждой перерисовке окна незачем.
    private static var remembered: (key: String, when: Date, value: Availability)?

    static func locate(manual: String? = Defaults.youTubeToolPath, fresh: Bool = false) -> Availability {
        let key = manual ?? ""
        if !fresh, let remembered, remembered.key == key, Date().timeIntervalSince(remembered.when) < 60 {
            return remembered.value
        }
        let value = search(manual: manual)
        remembered = (key, Date(), value)
        return value
    }

    private static func search(manual: String?) -> Availability {
        let files = FileManager.default
        if let manual, !manual.isEmpty {
            let url = URL(fileURLWithPath: (manual as NSString).expandingTildeInPath)
            if isSourceFolder(url) {
                guard let python = findPython() else {
                    return Availability(tool: nil, note: sourcesWithoutPython(url))
                }
                return Availability(tool: .sources(folder: url, python: python),
                                    note: OurWords.t("yt-dlp из исходников: %s; Python: %s", url.path, python.path))
            }
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return Availability(tool: nil, note: OurWords.t("По указанному пути yt-dlp нет: %s", url.path))
            }
            markExecutable(url)
            return Availability(tool: .executable(url), note: OurWords.t("yt-dlp: %s", url.path))
        }

        for folder in searchFolders {
            for name in executableNames {
                let candidate = folder.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard files.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                markExecutable(candidate)
                return Availability(tool: .executable(candidate), note: OurWords.t("yt-dlp: %s", candidate.path))
            }
        }
        for folder in searchFolders {
            for name in sourceFolderNames {
                let candidate = folder.appendingPathComponent(name)
                guard isSourceFolder(candidate) else { continue }
                guard let python = findPython() else {
                    return Availability(tool: nil, note: sourcesWithoutPython(candidate))
                }
                return Availability(tool: .sources(folder: candidate, python: python),
                                    note: OurWords.t("yt-dlp из исходников: %s; Python: %s", candidate.path, python.path))
            }
            // Архив лежит, но не распакован — сказать об этом полезнее, чем «не найден».
            if files.fileExists(atPath: folder.appendingPathComponent("yt-dlp-master.zip").path) {
                return Availability(tool: nil, note: OurWords.t(
                    "Найден только архив %s — распакуйте его рядом (папка yt-dlp-master) или положите готовую программу yt-dlp_macos",
                    folder.appendingPathComponent("yt-dlp-master.zip").path))
            }
        }
        return Availability(tool: nil, note: OurWords.t(
            "yt-dlp не найден — ролики YouTube идут встроенным проигрывателем. Положите yt-dlp_macos в папку %s",
            searchFolders[0].path))
    }

    private static func sourcesWithoutPython(_ folder: URL) -> String {
        OurWords.t("Исходники yt-dlp есть (%s), но им нужен Python 3.10 или новее, а его на этой машине нет. "
            + "Проще положить готовую программу yt-dlp_macos рядом с исходниками", folder.path)
    }

    private static func isSourceFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("yt_dlp/__main__.py").path)
    }

    /// Скачанный файл часто не помечен исполняемым — ставим бит сами: владелец
    /// положил его именно затем, чтобы он запускался.
    private static func markExecutable(_ url: URL) {
        guard !FileManager.default.isExecutableFile(atPath: url.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Python не старше 3.10 — где бы он ни стоял.
    ///
    /// Homebrew кладёт версии врозь (`/usr/local/opt/python@3.12/bin/
    /// python3.12`), а общий `python3` при этом может оставаться старым —
    /// так и было на машине владельца: 3.8 общий, 3.12 в своей папке.
    static func findPython() -> URL? {
        let files = FileManager.default
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        for opt in ["/opt/homebrew/opt", "/usr/local/opt"] {
            let names = ((try? files.contentsOfDirectory(atPath: opt)) ?? [])
                .filter { $0.hasPrefix("python@3.") }.sorted().reversed()
            for name in names {
                let version = name.dropFirst("python@".count)
                candidates.append("\(opt)/\(name)/bin/python\(version)")
            }
        }
        for bin in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let names = ((try? files.contentsOfDirectory(atPath: bin)) ?? [])
                .filter { $0.hasPrefix("python3.") && !$0.contains("-") }.sorted().reversed()
            for name in names { candidates.append("\(bin)/\(name)") }
        }
        let frameworks = "/Library/Frameworks/Python.framework/Versions"
        if let versions = try? files.contentsOfDirectory(atPath: frameworks) {
            for version in versions.sorted().reversed() where version != "Current" {
                candidates.append("\(frameworks)/\(version)/bin/python3")
            }
        }
        for path in candidates where files.isExecutableFile(atPath: path) {
            if let (major, minor) = pythonVersion(at: path), major == 3, minor >= 10 {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func pythonVersion(at path: String) -> (Int, Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let digits = text.split(whereSeparator: { !$0.isNumber && $0 != "." }).first { $0.contains(".") }
        let parts = digits?.split(separator: ".").compactMap { Int($0) } ?? []
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    /// Самопроверке: пройти запасным путём (ffmpeg), даже когда есть
    /// HLS-дорожки, — иначе он не проверяется никогда.
    nonisolated(unsafe) static var preferRemuxForTests = false

    /// ffmpeg — склеивать дорожки. Без него ролики идут встроенным проигрывателем.
    static var ffmpeg: URL? {
        // Сначала папки программы: на чужой машине ffmpeg кладут рядом с
        // пакетом, а не ставят Homebrew.
        let candidates = searchFolders.map { $0.appendingPathComponent("ffmpeg").path }
            + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Папки, где ищем и вспомогательные программы — deno, node, ffmpeg:
    /// yt-dlp зовёт их по PATH, а на чужой машине они лежат рядом с пакетом.
    private static var helperPath: String {
        (searchFolders.map(\.path) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
            .joined(separator: ":")
    }

    private static var hasNode: Bool {
        (searchFolders.map { $0.appendingPathComponent("node").path } + ["/opt/homebrew/bin/node", "/usr/local/bin/node"])
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Получение потока

    /// Поток ролика. Отвечает в фоне: yt-dlp думает секунды, ffmpeg —
    /// ещё несколько, пока не готовы первые куски.
    @discardableResult
    static func obtain(_ link: URL, with tool: Tool,
                       completion: @escaping (Result<Resolved, Failure>) -> Void) -> Job {
        let job = Job()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(link, with: tool, job: job)
            DispatchQueue.main.async { if !job.isCancelled { completion(result) } }
        }
        return job
    }

    private static func run(_ link: URL, with tool: Tool, job: Job) -> Result<Resolved, Failure> {
        let described = launch(tool, ["-j", "--no-playlist", "--no-warnings", "--no-progress",
                                      link.absoluteString], job: job, timeout: 90)
        guard case .success(let outData) = described else {
            if case .failure(let failure) = described { return .failure(failure) }
            return .failure(.failed(OurWords.t("ответ не разобран")))
        }
        guard let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            return .failure(.failed(OurWords.t("ответ не разобран")))
        }
        let title = (json["title"] as? String) ?? ""
        let live = (json["is_live"] as? Bool) ?? false
        let length = (json["duration"] as? Double) ?? 0

        // Поток со звуком и картинкой вместе — сразу. Так живут трансляции.
        if let text = json["url"] as? String, let url = URL(string: text),
           (json["vcodec"] as? String ?? "") != "none", (json["acodec"] as? String ?? "") != "none" {
            return .success(Resolved(url: url, title: title, isLive: live, duration: length, isRemuxed: false))
        }
        let formats = json["formats"] as? [[String: Any]] ?? []
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-youtube-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            return .failure(.failed(OurWords.t("не создалась временная папка %s", folder.path)))
        }
        job.folder = folder
        let key = YouTubeHostServer.publish(folder: folder)
        job.key = key
        let playlist = folder.appendingPathComponent("index.m3u8")

        // Свои HLS-дорожки YouTube — плееру напрямую, сборным плейлистом.
        if !preferRemuxForTests, let master = masterPlaylist(from: formats) {
            guard (try? master.write(to: playlist, atomically: true, encoding: .utf8)) != nil else {
                return .failure(.failed(OurWords.t("не записался плейлист в %s", folder.path)))
            }
            guard let served = servedURL(for: key) else {
                return .failure(.failed(OurWords.t("локальный сервер не поднялся")))
            }
            return .success(Resolved(url: served, title: title, isLive: false, duration: length, isRemuxed: false))
        }

        // Запасной путь: склейка прямых дорожек на лету.
        guard let (video, audio) = pickTracks(formats) else {
            return .failure(.noURL(OurWords.t("нет дорожек, которые можно склеить")))
        }
        guard let ffmpeg else { return .failure(.noFFmpeg) }
        // Адреса дорожек привязаны к тому, кто их спрашивал: без заголовков
        // yt-dlp сервер отвечает 403. Берём их из описания формата.
        let headers = (formats.first { ($0["url"] as? String) == video }?["http_headers"] as? [String: String]) ?? [:]
        let agent = headers["User-Agent"] ?? "Mozilla/5.0"
        let extraHeaders = headers.filter { $0.key != "User-Agent" }
            .map { "\($0.key): \($0.value)\r\n" }.joined()

        let process = Process()
        // Куски по 4 с и плейлист «событие»: плеер играет с первых кусков, а
        // список только растёт. `temp_file` — плейлист подменяется целиком,
        // иначе плеер мог бы прочитать его недописанным.
        var ffmpegArguments = [
            "-loglevel", "error", "-nostdin",
            "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5",
            "-user_agent", agent]
        if !extraHeaders.isEmpty { ffmpegArguments += ["-headers", extraHeaders] }
        ffmpegArguments += ["-i", video]
        ffmpegArguments += ["-user_agent", agent]
        if !extraHeaders.isEmpty { ffmpegArguments += ["-headers", extraHeaders] }
        ffmpegArguments += ["-i", audio,
            "-map", "0:v:0", "-map", "1:a:0", "-c", "copy",
            "-f", "hls", "-hls_time", "4", "-hls_playlist_type", "event",
            "-hls_flags", "independent_segments+temp_file",
            folder.appendingPathComponent("index.m3u8").path,
        ]
        // Через обёртку, которая следит за программой: упала она или снята
        // — ffmpeg не должен тянуть проповедь дальше сам по себе. Так уже
        // осталась сирота на полгигабайта после снятого прогона.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c",
            "\"$0\" \"$@\" & FF=$!; trap 'kill $FF 2>/dev/null; exit 143' TERM INT; "
            + "while kill -0 $PPID 2>/dev/null && kill -0 $FF 2>/dev/null; do sleep 2; done; "
            + "kill $FF 2>/dev/null; wait $FF",
            ffmpeg.path] + ffmpegArguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do { try process.run() } catch { return .failure(.launch(error.localizedDescription)) }
        job.track(process)

        // Ждём двух кусков: с одного плеер ещё не стартует.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !job.isCancelled {
            if let text = try? String(contentsOf: playlist, encoding: .utf8),
               text.components(separatedBy: "#EXTINF").count > 2 { break }
            if !process.isRunning {
                let said = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return .failure(.failed(OurWords.t("ffmpeg остановился: %s",
                                                   said.split(separator: "\n").last.map(String.init) ?? "")))
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard FileManager.default.fileExists(atPath: playlist.path) else { return .failure(.timeout) }
        guard let served = servedURL(for: key) else { return .failure(.failed(OurWords.t("локальный сервер не поднялся"))) }
        return .success(Resolved(url: served, title: title, isLive: false, duration: length, isRemuxed: true))
    }

    /// Адрес плейлиста на нашем сервере — дождавшись, пока он поднимется.
    private static func servedURL(for key: String) -> URL? {
        var served: URL?
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                YouTubeHostServer.shared.ready { _ in
                    served = YouTubeHostServer.shared.playlistURL(for: key)
                    gate.signal()
                }
            }
        }
        gate.wait()
        return served
    }

    /// Сборный плейлист из HLS-дорожек YouTube: все качества H.264 до 1080p
    /// как варианты и один звук как отдельную дорожку группы.
    ///
    /// Проверено на проповеди с канала владельца: картинка — MPEG-TS по 5 с,
    /// звук — в формате Apple для раздельного звука, куски отдаются без
    /// препятствий. Кодек звука yt-dlp у этих дорожек не знает — AAC-LC, как
    /// у всего звука YouTube.
    static func masterPlaylist(from formats: [[String: Any]]) -> String? {
        func text(_ format: [String: Any], _ key: String) -> String { format[key] as? String ?? "" }
        func number(_ format: [String: Any], _ key: String) -> Double { format[key] as? Double ?? 0 }
        let hls = formats.filter { text($0, "protocol").hasPrefix("m3u8") && !text($0, "url").isEmpty }
        let videos = hls.filter {
            text($0, "vcodec").hasPrefix("avc1") && number($0, "height") > 0 && number($0, "height") <= 1080
        }.sorted { number($0, "height") < number($1, "height") }
        let audios = hls.filter {
            (text($0, "vcodec") == "none" || text($0, "vcodec").isEmpty) && text($0, "resolution") == "audio only"
        }.sorted { (number($0, "tbr"), text($0, "format_id")) < (number($1, "tbr"), text($1, "format_id")) }
        guard let audio = audios.last, !videos.isEmpty else { return nil }

        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-INDEPENDENT-SEGMENTS",
                     "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"zvuk\",NAME=\"звук\",DEFAULT=YES,AUTOSELECT=YES,URI=\""
                         + text(audio, "url") + "\""]
        let audioBits = Int(max(number(audio, "tbr"), 128) * 1000)
        for video in videos {
            let bits = Int(number(video, "tbr") * 1000) + audioBits
            let width = Int(number(video, "width")), height = Int(number(video, "height"))
            lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(bits),AVERAGE-BANDWIDTH=\(bits),"
                + "CODECS=\"\(text(video, "vcodec")),mp4a.40.2\",RESOLUTION=\(width)x\(height),AUDIO=\"zvuk\"")
            lines.append(text(video, "url"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Дорожки для склейки: лучшая картинка H.264 не выше 1080p и звук AAC —
    /// то, что плеер играет без перекодирования, а ffmpeg склеивает копией.
    /// Прямые адреса (`https`) — ffmpeg читает их кусками по запросу.
    private static func pickTracks(_ formats: [[String: Any]]) -> (String, String)? {
        func has(_ format: [String: Any], _ key: String) -> Bool {
            let value = format[key] as? String ?? "none"
            return value != "none" && !value.isEmpty
        }
        let videos = formats.filter {
            has($0, "vcodec") && !has($0, "acodec")
                && ($0["vcodec"] as? String ?? "").hasPrefix("avc1")
                && ($0["protocol"] as? String) == "https"
                && ((($0["height"] as? Double) ?? 0) <= 1080)
                && ($0["url"] as? String) != nil
        }.sorted { (($0["height"] as? Double) ?? 0, ($0["tbr"] as? Double) ?? 0)
                   < (($1["height"] as? Double) ?? 0, ($1["tbr"] as? Double) ?? 0) }
        let audios = formats.filter {
            !has($0, "vcodec") && has($0, "acodec")
                && ($0["ext"] as? String) == "m4a"
                && ($0["protocol"] as? String) == "https"
                && ($0["url"] as? String) != nil
        }.sorted { (($0["abr"] as? Double) ?? 0) < (($1["abr"] as? Double) ?? 0) }
        guard let video = videos.last?["url"] as? String, let audio = audios.last?["url"] as? String else { return nil }
        return (video, audio)
    }

    /// Запуск yt-dlp с чтением вывода целиком.
    private static func launch(_ tool: Tool, _ arguments: [String], job: Job,
                               timeout: TimeInterval?) -> Result<Data, Failure> {
        let process = Process()
        switch tool {
        case .executable(let url):
            process.executableURL = url
            process.arguments = arguments
        case let .sources(folder, python):
            process.executableURL = python
            process.arguments = ["-m", "yt_dlp"] + arguments
            process.currentDirectoryURL = folder
        }
        // yt-dlp ищет deno, node и ffmpeg по PATH, а у программы он куцый.
        // Свой JavaScript-движок он по умолчанию ждёт только deno; node на
        // машине есть — разрешаем и его.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = helperPath + ":" + (environment["PATH"] ?? "")
        process.environment = environment
        if hasNode, !arguments.contains("--js-runtimes") {
            process.arguments = (process.arguments ?? []) + ["--js-runtimes", "node"]
        }

        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failure(.launch(error.localizedDescription)) }
        job.track(process)

        var timedOut = false
        var watchdog: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { timedOut = true; process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            watchdog = item
        }
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog?.cancel()
        if job.isCancelled { return .failure(.failed(OurWords.t("прервано"))) }
        if timedOut { return .failure(.timeout) }

        let errText = (String(data: errData, encoding: .utf8) ?? "")
            .split(separator: "\n").last.map(String.init) ?? ""
        guard process.terminationStatus == 0 else {
            return .failure(.failed(errText.isEmpty
                ? OurWords.t("код выхода %s", "\(process.terminationStatus)") : errText))
        }
        return .success(outData)
    }
}
