import AppKit
import WebKit
import CoreVideo
import SlovoCore

/// Встроенный проигрыватель YouTube — официальный IFrame Player API в WebKit.
///
/// Почему не прямым потоком — см. `YouTubeLink`. Здесь страница с одним
/// iframe самого YouTube (её отдаёт `YouTubeHostServer`): пуск, пауза,
/// перемотка и громкость идут через их JavaScript-API, состояние и время
/// приходят обратно сообщениями.
///
/// Кадр для панели плеера и трансляции берётся снимками вида
/// (`takeSnapshot`): другого пути достать картинку из чужого iframe нет.
/// Снимки идут около 12 раз в секунду — микшеру и предпросмотру этого
/// хватает, а зал смотрит на сам вид, вставленный в окно слайда, и там
/// картинка полная, без снимков.
///
/// Вид рисует только стоя в окне. Пока окно слайда не забрало его себе, он
/// живёт в окне-приюте за краем экрана — иначе снимать нечего.
@MainActor
final class YouTubeEmbedPlayer: NSObject, WKScriptMessageHandler {

    /// Состояния из `YT.PlayerState` — числа их, а не наши.
    enum State: Int {
        case unstarted = -1, ended = 0, playing = 1, paused = 2, buffering = 3, cued = 5
    }

    let videoID: String
    let webView: HostedWebView

    var onReady: (() -> Void)?
    var onState: ((State) -> Void)?
    var onError: ((Int) -> Void)?
    var onTime: ((Double, Double) -> Void)?
    var onFrame: ((CVPixelBuffer) -> Void)?

    private(set) var isReady = false
    private var snapshotTimer: Timer?
    private var snapshotInFlight = false
    private var shelter: NSWindow?
    private static let handlerName = "slovo"

    /// Сколько снимков в секунду. Больше — дороже каждому кадру страницы,
    /// а микшер и панель разницы не увидят.
    static let snapshotRate: Double = 12

    init(videoID: String, autoplay: Bool) {
        self.videoID = videoID

        let configuration = WKWebViewConfiguration()
        // Автозапуск со звуком: иначе YouTube ждёт щелчка по ролику, а в
        // окне зала щёлкать некому и нечем.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let relay = Relay()
        configuration.userContentController.add(relay, name: Self.handlerName)
        webView = HostedWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720),
                                configuration: configuration)
        super.init()
        relay.target = self
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.black.cgColor
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .black }
        webView.onOrphaned = { [weak self] in self?.takeShelter() }
        takeShelter()

        // Страницу-обёртку отдаёт свой локальный сервер: YouTube принимает
        // её только с настоящего адреса — см. `YouTubeHostServer`.
        YouTubeHostServer.shared.ready { [weak self] port in
            guard let self else { return }
            guard let port,
                  let url = URL(string: "http://127.0.0.1:\(port)/player?v=\(videoID)&autoplay=\(autoplay ? 1 : 0)")
            else { self.onError?(-1); return }
            self.webView.load(URLRequest(url: url))
        }
    }

    // MARK: - Управление

    func play()  { run("player.playVideo()") }
    func pause() { run("player.pauseVideo()") }
    func seek(to seconds: Double) { run("player.seekTo(\(max(0, seconds)), true)") }
    func setVolume(_ value: Double) {
        run("player.setVolume(\(Int((min(1, max(0, value)) * 100).rounded())))")
    }
    func setMuted(_ muted: Bool) { run(muted ? "player.mute()" : "player.unMute()") }

    private func run(_ script: String) {
        guard isReady else { return }
        webView.evaluateJavaScript("try{\(script)}catch(e){}") { _, _ in }
    }

    /// Снять всё: остановить ролик, отвязать сообщения, убрать вид.
    func shutDown() {
        stopSnapshots()
        onReady = nil; onState = nil; onError = nil; onTime = nil; onFrame = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        webView.evaluateJavaScript("try{player.stopVideo()}catch(e){}") { _, _ in }
        // Пустая страница глушит звук сразу, а не когда вид соберёт мусор.
        webView.loadHTMLString("", baseURL: nil)
        webView.onOrphaned = nil
        webView.removeFromSuperview()
        shelter?.orderOut(nil)
        shelter = nil
    }

    // MARK: - Снимки

    func startSnapshots() {
        guard snapshotTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / Self.snapshotRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshot() }
        }
        RunLoop.main.add(timer, forMode: .common)
        snapshotTimer = timer
    }

    func stopSnapshots() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    /// Один снимок — в `onFrame`. Пока прежний не вернулся, новый не просим:
    /// иначе очередь снимков растёт быстрее, чем WebKit её разбирает.
    func snapshot() {
        guard !snapshotInFlight, webView.window != nil, webView.bounds.width > 1 else { return }
        snapshotInFlight = true
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(min(1280, webView.bounds.width)))
        if #available(macOS 10.15, *) { configuration.afterScreenUpdates = false }
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapshotInFlight = false
                guard let image, let buffer = Self.pixelBuffer(from: image) else { return }
                self.onFrame?(buffer)
            }
        }
    }

    /// Снимок — в буфер того же вида, что отдаёт плеер фильмов (BGRA на
    /// IOSurface): тогда он ложится в те же слои и уходит в ту же трансляцию
    /// без единого лишнего преобразования дальше по пути.
    private static func pixelBuffer(from image: NSImage) -> CVPixelBuffer? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return nil }
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &made) == kCVReturnSuccess,
              let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - Приют

    private func takeShelter() {
        if shelter == nil {
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1280, height: 720),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            shelter = window
        }
        guard let shelter, webView.window !== shelter else { return }
        webView.frame = shelter.contentView?.bounds ?? webView.frame
        webView.autoresizingMask = [.width, .height]
        shelter.contentView?.addSubview(webView)
        shelter.orderFrontRegardless()
    }

    // MARK: - Сообщения со страницы

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            isReady = true
            onReady?()
        case "state":
            if let raw = body["value"] as? Int, let state = State(rawValue: raw) { onState?(state) }
        case "error":
            onError?((body["value"] as? Int) ?? 0)
        case "time":
            onTime?((body["cur"] as? Double) ?? 0, (body["dur"] as? Double) ?? 0)
        default:
            break
        }
    }

    /// Обработчик сообщений WebKit держит крепко, а он держал бы нас — и
    /// проигрыватель не освобождался бы никогда. Прослойка держит слабо.
    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var target: YouTubeEmbedPlayer?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated { target?.userContentController(controller, didReceive: message) }
        }
    }
}

/// WebKit-вид, который сообщает, что остался без окна: окно слайда
/// пересобрали или закрыли — вид возвращается в приют, чтобы не перестать
/// рисовать.
@MainActor
final class HostedWebView: WKWebView {
    var onOrphaned: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, let onOrphaned else { return }
        // Не из середины перестановки видов: AppKit ещё занят ею.
        DispatchQueue.main.async { onOrphaned() }
    }
}
