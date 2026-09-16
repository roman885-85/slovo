import AppKit
import WebKit
import SlovoCore

/// Вікно «Довідка»: як працювати зі «Словом» — українською й англійською,
/// без інтернету.
///
/// Власник: «добавь подсказки и помощь в программу (на украинском и
/// английском)». Досі пункт «Довідка» відкривав сторінку на GitHub — без
/// мережі в залі її не було, а знайти там відповідь на «чому стрілка не
/// виводить у зал» було ніде.
///
/// Текст лежить у пакеті файлами `Help/uk.html` і `Help/en.html` (правляться
/// без пересборки), оболонка зі змістом, пошуком і перемикачем мови —
/// `Help/index.html`. Мова — за інтерфейсом: українська й російська
/// відкривають українську довідку, решта — англійську; перемикач угорі.
@MainActor
final class NativeHelpWindow: NSObject, WKNavigationDelegate {

    static let shared = NativeHelpWindow()

    private var window: NSWindow?
    private var web: WKWebView?
    /// Чи сторінка вже завантажилася — для самоперевірки.
    private(set) var isLoaded = false

    /// Тека довідки в пакеті.
    static var folder: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Help"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) else { return nil }
        return url
    }

    /// Мова довідки для мови інтерфейсу.
    static func language(for interface: String) -> String {
        ["uk", "ru"].contains(interface) ? "uk" : "en"
    }

    /// Відкрити довідку; `topic` — розділ (`start`, `show`, `remote`, `trouble`…).
    static func show(topic: String? = nil) {
        shared.open(topic: topic)
    }

    /// Готова сторінка: оболонка з підставленими розділами обох мов.
    static func page(language: String, topic: String?) -> String? {
        guard let folder,
              var page = try? String(contentsOf: folder.appendingPathComponent("index.html"), encoding: .utf8) else { return nil }
        for code in ["uk", "en"] {
            let sections = (try? String(contentsOf: folder.appendingPathComponent("\(code).html"), encoding: .utf8)) ?? ""
            page = page.replacingOccurrences(of: "<!--SECTIONS-\(code)-->", with: sections)
        }
        let safeTopic = (topic ?? "").filter { $0.isLetter || $0.isNumber || $0 == "-" }
        // Адреса теки з даними — жива, з цього комп'ютера (власник: «писать
        // полный текущий адрес с данными»), а не приклад у тексті.
        return page.replacingOccurrences(of: "{{LANG}}", with: language)
            .replacingOccurrences(of: "{{TOPIC}}", with: safeTopic)
            .replacingOccurrences(of: "{{DATA}}", with: DataHome.displayPath)
    }

    func open(topic: String?) {
        let language = Self.language(for: OurWords.language)
        guard let html = Self.page(language: language, topic: topic) else {
            // Пакет без довідки (зібраний не `deploy.sh`) — хоч документація в мережі.
            if let online = URL(string: "https://github.com/roman885-85/slovo#readme") { NSWorkspace.shared.open(online) }
            return
        }
        let (panel, view) = build()
        panel.title = language == "uk" ? "Довідка «Слова»" : "Slovo Help"
        isLoaded = false
        view.loadHTMLString(html, baseURL: Self.folder)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Закрити вікно — самоперевірці, щоб не лишати його після себе.
    func close() { window?.orderOut(nil) }

    /// Знімок сторінки у файл `~/Library/Logs/<name>` — для самоперевірки:
    /// звичайний знімок вида вміст WebKit не малює.
    func snapshot(to name: String, completion: @escaping (Bool) -> Void) {
        guard let web else { completion(false); return }
        web.takeSnapshot(with: nil) { image, _ in
            guard let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                completion(false); return
            }
            let path = NSString(string: "~/Library/Logs/\(name)").expandingTildeInPath
            completion((try? png.write(to: URL(fileURLWithPath: path))) != nil)
        }
    }

    /// Виконати скрипт на сторінці довідки — для самоперевірки.
    func evaluate(_ script: String, completion: @escaping (Any?) -> Void) {
        guard let web else { completion(nil); return }
        web.evaluateJavaScript(script) { value, _ in completion(value) }
    }

    private func build() -> (NSWindow, WKWebView) {
        if let window, let web { return (window, web) }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 640, height: 420)
        panel.center()
        panel.setFrameAutosaveName("SlovoHelpWindow")
        let view = WKWebView(frame: panel.contentLayoutRect, configuration: WKWebViewConfiguration())
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        panel.contentView = view
        window = panel
        web = view
        return (panel, view)
    }

    // MARK: - WKNavigationDelegate

    /// Посилання назовні (GitHub, eBible…) — у звичайному браузері, а не в
    /// самому вікні довідки: з нього не було б дороги назад.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow); return
        }
        if ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
    }
}
