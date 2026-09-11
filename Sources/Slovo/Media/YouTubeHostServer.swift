import Foundation
import Network

/// Крошечный HTTP-сервер для одной страницы — обёртки встроенного
/// проигрывателя YouTube.
///
/// Зачем он вообще нужен. Страницу-обёртку YouTube принимает только с
/// настоящего адреса: с заголовком Referer и совпадающим `origin`. Страница
/// из строки (`loadHTMLString`) и прямая загрузка их же страницы встраивания
/// отвечают «ошибка конфигурации видеопроигрывателя» (коды 152/153; их
/// требование с 2025 года) — проверено опытом 2026-09-03 на этой машине,
/// заголовок Referer в запросе не помогает. Та же страница со своего
/// 127.0.0.1 играет.
///
/// Слушает только петлю и случайный свободный порт: снаружи его не видно, а
/// с портами веб-вывода (82, 8100) он не спорит.
@MainActor
final class YouTubeHostServer {

    static let shared = YouTubeHostServer()

    private var listener: NWListener?
    private(set) var port: Int?
    private var waiting: [(Int?) -> Void] = []
    private let queue = DispatchQueue(label: "slovo.youtube.host")

    /// Порт, когда сервер готов; уже готов — сразу. `nil` — не поднялся.
    func ready(_ body: @escaping (Int?) -> Void) {
        if let port { body(port); return }
        waiting.append(body)
        start()
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.stateChanged(state) }
                }
            }
            let queue = self.queue
            listener.newConnectionHandler = { connection in
                Self.serve(connection, on: queue)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            finish(nil)
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            finish(listener?.port.map { Int($0.rawValue) })
        case .failed, .cancelled:
            listener = nil
            port = nil
            finish(nil)
        default:
            break
        }
    }

    private func finish(_ port: Int?) {
        self.port = port
        let callbacks = waiting
        waiting = []
        for body in callbacks { body(port) }
    }

    // MARK: - Ответ

    /// Один запрос — один ответ — закрыть. Строка запроса всегда в первом
    /// куске, разбирать заголовки целиком незачем.
    nonisolated private static func serve(_ connection: NWConnection, on queue: DispatchQueue) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = text.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : "/"
            connection.send(content: response(for: target), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    nonisolated static func response(for target: String) -> Data {
        guard let parts = URLComponents(string: target) else { return packet(status: "404 Not Found", body: Data()) }
        if parts.path.hasPrefix("/hls/") { return hlsResponse(path: parts.path) }
        guard parts.path == "/player",
              let id = parts.queryItems?.first(where: { $0.name == "v" })?.value,
              isVideoID(id) else {
            return packet(status: "404 Not Found", body: Data())
        }
        let autoplay = parts.queryItems?.first(where: { $0.name == "autoplay" })?.value == "1"
        return packet(status: "200 OK", body: Data(page(videoID: id, autoplay: autoplay).utf8))
    }

    nonisolated private static func packet(status: String, body: Data,
                                           type: String = "text/html; charset=utf-8") -> Data {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    // MARK: - Поток, склеенный на лету

    /// Папки с HLS, которые отдаём: `/hls/<ключ>/index.m3u8` и куски рядом.
    ///
    /// AVFoundation играет HLS только по http — плейлист с диска (`file://`)
    /// он не берёт. Поэтому папку, куда ffmpeg пишет склеенный на лету поток,
    /// отдаёт тот же локальный сервер.
    nonisolated(unsafe) private static var roots: [String: URL] = [:]
    nonisolated(unsafe) private static let rootsLock = NSLock()

    /// Зарегистрировать папку; вернуть ключ для адреса.
    nonisolated static func publish(folder: URL) -> String {
        let key = UUID().uuidString.lowercased()
        rootsLock.lock(); roots[key] = folder; rootsLock.unlock()
        return key
    }

    nonisolated static func withdraw(_ key: String) {
        rootsLock.lock(); roots.removeValue(forKey: key); rootsLock.unlock()
    }

    /// Адрес плейлиста для ключа — когда сервер готов.
    func playlistURL(for key: String) -> URL? {
        guard let port else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/hls/\(key)/index.m3u8")
    }

    nonisolated private static func hlsResponse(path: String) -> Data {
        let parts = path.split(separator: "/").map(String.init)   // ["hls", ключ, файл]
        guard parts.count == 3, !parts[2].contains(".."), !parts[2].contains("/") else {
            return packet(status: "404 Not Found", body: Data())
        }
        rootsLock.lock(); let folder = roots[parts[1]]; rootsLock.unlock()
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent(parts[2])) else {
            return packet(status: "404 Not Found", body: Data())
        }
        let type: String
        switch (parts[2] as NSString).pathExtension.lowercased() {
        case "m3u8": type = "application/vnd.apple.mpegurl"
        case "ts":   type = "video/mp2t"
        case "m4s", "mp4": type = "video/mp4"
        default:     type = "application/octet-stream"
        }
        return packet(status: "200 OK", body: data, type: type)
    }

    /// Номер ролика — 11 знаков из букв, цифр, «-» и «_»; ничего иного в
    /// страницу не подставляется.
    nonisolated private static func isVideoID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }

    // MARK: - Страница

    /// Обёртка: один iframe YouTube на весь экран, управление и состояние —
    /// через их IFrame Player API, сообщения — в программу через WebKit.
    nonisolated static func page(videoID: String, autoplay: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Слово · YouTube</title>
        <style>html,body{margin:0;background:#000;height:100%;overflow:hidden}
        #player{position:absolute;left:0;top:0;width:100%;height:100%}</style></head>
        <body><div id="player"></div>
        <script>
        var player, ticker;
        function say(m){ try { window.webkit.messageHandlers.slovo.postMessage(m); } catch (e) {} }
        function tick(){
          if (!player || !player.getCurrentTime) return;
          say({kind:'time', cur: player.getCurrentTime() || 0, dur: player.getDuration() || 0});
        }
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('player', {
            videoId: '\(videoID)', width: '100%', height: '100%',
            playerVars: {autoplay: \(autoplay ? 1 : 0), controls: 0, rel: 0, playsinline: 1,
                         iv_load_policy: 3, fs: 0, disablekb: 1, origin: location.origin},
            events: {
              onReady: function(){ say({kind:'ready'}); if (!ticker) ticker = setInterval(tick, 250); },
              onStateChange: function(e){ say({kind:'state', value: e.data}); tick(); },
              onError: function(e){ say({kind:'error', value: e.data}); }
            }
          });
        }
        var tag = document.createElement('script');
        tag.src = 'https://www.youtube.com/iframe_api';
        tag.onerror = function(){ say({kind:'error', value: -1}); };
        document.head.appendChild(tag);
        </script></body></html>
        """
    }
}
