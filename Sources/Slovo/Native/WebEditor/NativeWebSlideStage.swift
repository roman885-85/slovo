import AppKit
import WebKit
import SlovoCore

/// Живой предпросмотр страницы — на AppKit.
///
/// Два правила, ради которых он написан отдельно.
///
/// Первое: перезагрузка только при изменении разметки. Значение переменной
/// доезжает до страницы скриптом `setProperty` — инлайновый стиль на
/// `documentElement` бьёт любое правило `:root`, поэтому картинка меняется
/// сразу и целиком. Перезагружать страницу на каждый шаг ползунка нельзя:
/// она успевает моргнуть белым, заново проиграть появление слайда и сбить
/// человеку глаз.
///
/// Второе: мышь над предпросмотром принадлежит редактору, а не странице.
/// Веб-вид событий не берёт вовсе, и всё, что делает мышь, — перетаскивает
/// блок текста. Иначе случайный щелчок по ссылке внутри страницы увёл бы
/// предпросмотр неизвестно куда.
@MainActor
final class NativeWebSlideStage: NSView, WKNavigationDelegate {

    private let model: WebSlideEditorModel
    private let web: WKWebView
    private var key = ""
    private var applied: [String: String] = [:]
    private var tick = 0
    private var isLoading = false
    private var dragTo: CGPoint?
    private var lastPlaced: String?
    /// Своя картинка под страницей: с ней видно, что перекрывает титр.
    private let backdrop = CALayer()

    /// Подложить свой файл (или убрать, если `nil`).
    func setBackdrop(_ url: URL?) {
        guard let url, let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            backdrop.contents = nil
            return
        }
        backdrop.contents = cg
        needsLayout = true
    }

    init(model: WebSlideEditorModel) {
        self.model = model
        web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        layer?.addSublayer(backdrop)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    /// Веб-вид не должен перехватывать мышь: она принадлежит редактору.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func layout() {
        super.layout()
        web.frame = stageFrame
        // Картинка ровно под кадром страницы, а не под всей панелью.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = stageFrame
        CATransaction.commit()
    }

    /// Кадр 16:9 внутри панели — те же пропорции, что у экрана в зале.
    private var stageFrame: NSRect {
        let side = WebSlidePlacement.frame(in: bounds.size)
        return NSRect(x: (bounds.width - side.width) / 2,
                      y: (bounds.height - side.height) / 2,
                      width: side.width, height: side.height)
    }

    // MARK: - Обновление

    func refresh() {
        if key != model.previewReloadKey {
            key = model.previewReloadKey
            // После перезагрузки страница возьмёт значения из собственного
            // блока — они уже те же самые, дописывать нечего.
            applied = model.previewValues
            isLoading = true
            load()
            return
        }
        push()
        if tick != model.command.tick {
            tick = model.command.tick
            run(model.command.script)
        }
    }

    private func load() {
        let html = model.previewHTML
        if let folder = model.previewFolder {
            let file = folder.appendingPathComponent("preview.html")
            try? html.write(to: file, atomically: true, encoding: .utf8)
            web.loadFileURL(file, allowingReadAccessTo: folder)
        } else {
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Дописать странице только изменившиеся значения.
    private func push() {
        guard !isLoading else { return }
        var script = ""
        for (name, value) in model.previewValues where applied[name] != value {
            script += "document.documentElement.style.setProperty('\(name)','\(value)');"
        }
        guard !script.isEmpty else { return }
        applied = model.previewValues
        // Після кожної правки просимо сторінку перерахувати кегль. Без цього
        // підібраний розмір лишався від попереднього показу: ползунок
        // «Розмір тексту» рухався, а сторінка стояла — і навіть зняття
        // галочки «підбирати розмір» нічого не міняло.
        script += "if (window.slovoRefit) window.slovoRefit();"
        run(script)
    }

    private func run(_ script: String) {
        guard !script.isEmpty, !isLoading else { return }
        web.evaluateJavaScript(script)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        push()
    }

    // MARK: - Перетаскивание блока

    override func mouseDown(with event: NSEvent) {
        guard model.sheet.placement.canDrag else { return }
        dragTo = fraction(of: event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard model.sheet.placement.canDrag else { return }
        let point = fraction(of: event)
        dragTo = point
        let title = model.placementTitle(at: point)
        // Пока точка привязки та же — файл трогать незачем.
        if title != lastPlaced {
            lastPlaced = title
            model.place(at: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragTo = nil
        lastPlaced = nil
        needsDisplay = true
    }

    private func fraction(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let stage = stageFrame
        guard stage.width > 0, stage.height > 0 else { return .zero }
        return CGPoint(x: (point.x - stage.minX) / stage.width,
                       y: (point.y - stage.minY) / stage.height)
    }

    /// Девять точек привязки — видно, куда встанет блок.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let dragTo else { return }
        let stage = stageFrame
        let target = WebSlidePlacement.drop(at: dragTo)
        for index in 0..<9 {
            let column = index % 3, row = index / 3
            let point = WebSlidePlacement.fraction(column: column, row: row)
            let live = target.column == column && target.row == row
            let centre = NSPoint(x: stage.minX + point.x * stage.width,
                                 y: stage.minY + point.y * stage.height)
            let size: CGFloat = live ? 14 : 8
            let dot = NSBezierPath(ovalIn: NSRect(x: centre.x - size / 2, y: centre.y - size / 2,
                                                  width: size, height: size))
            (live ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.35)).setFill()
            dot.fill()
        }
    }
}
