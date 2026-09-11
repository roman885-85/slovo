import Foundation

/// Хто віддає живий потік HLS: список сегментів, заголовок і самі шматки.
/// Кодер живе в програмі, сервер — тут; між ними лише це.
public protocol HLSStreamProvider: AnyObject {
    /// `nil` — потоку зараз немає (канал вимкнено або ще не завівся).
    func playlist() -> String?
    func initSegment() -> Data?
    func segment(named name: String) -> Data?
}

/// Реєстр провайдера: сервер питає його на кожен запит, а
/// підключається він з головного потоку — тому під замком.
public enum HLSStreamRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: HLSStreamProvider?

    public static var provider: HLSStreamProvider? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// Сторінка плеєра «Відео по Wi-Fi». Safari (і все на iOS/macOS) грає HLS
/// сам; для решти браузерів потрібен hls.js — його власник кладе в теку
/// програми (файлів з інтернету сама програма не качає), і сторінка
/// бере його, якщо він є; інакше підказує VLC.
public enum WebVideoPage {
    public static let title = OurWords.t("Слово — видео по Wi-Fi")

    public static func html(hasHlsJs: Bool) -> String {
        let script = hasHlsJs ? """
            <script src="/wifi/hls.min.js"></script>
            <script>
              (function () {
                var v = document.getElementById('v');
                v.addEventListener('error', function () { document.getElementById('hint').style.display = 'block'; });
                if (v.canPlayType('application/vnd.apple.mpegurl') || /Android|iPhone|iPad/.test(navigator.userAgent)) { v.src = '/wifi/stream.m3u8'; return; }
                if (window.Hls && Hls.isSupported()) {
                  var h = new Hls({ lowLatencyMode: false, liveSyncDurationCount: 2, liveMaxLatencyDurationCount: 5 });
                  h.loadSource('/wifi/stream.m3u8'); h.attachMedia(v);
                } else { document.getElementById('hint').style.display = 'block'; }
              })();
            </script>
            """ : """
            <script>
              (function () {
                // Телефони (Safari, Chrome на Android) грають HLS самі, хоча
                // canPlayType про це не завжди каже: ставимо адресу одразу,
                // а підказку показуємо лише за справжньої помилки.
                var v = document.getElementById('v');
                v.addEventListener('error', function () { document.getElementById('hint').style.display = 'block'; });
                v.src = '/wifi/stream.m3u8';
                v.play && v.play().catch(function () {});
              })();
            </script>
            """
        return """
        <!DOCTYPE html><html lang="uk"><head><meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
          html, body { margin: 0; height: 100%; background: #000; color: #ddd; font: 15px -apple-system, Helvetica, Arial, sans-serif; }
          video { width: 100vw; height: 100vh; object-fit: contain; background: #000; }
          #hint { display: none; position: absolute; left: 0; right: 0; top: 40%; text-align: center; padding: 0 5vw; }
          #hint code { color: #fff; }
        </style></head><body>
        <video id="v" autoplay muted playsinline controls></video>
        <div id="hint">Этот браузер не играет HLS сам. Откройте адрес <code>/wifi/stream.m3u8</code> в VLC или OBS,
        либо положите <code>hls.min.js</code> в папку программы и обновите страницу.</div>
        \(script)
        </body></html>
        """
    }
}
