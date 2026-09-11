import AppKit
import WebKit
import SlovoCore

/// Живий попередній перегляд сторінки — на AppKit.
///
/// Два правила, заради яких його написано окремо.
///
/// Перше: перезавантаження тільки при зміні розмітки. Значення змінної
/// доїжджає до сторінки скриптом `setProperty` — інлайновий стиль на
/// `documentElement` б'є будь-яке правило `:root`, тому картинка міняється
/// одразу й цілком. Перезавантажувати сторінку на кожен крок повзунка не можна:
/// вона встигає блимнути білим, заново програти появу слайда й збити
/// людині око.
///
/// Друге: миша над попереднім переглядом належить редакторові, а не сторінці.
/// Веб-вид подій не бере зовсім, і все, що робить миша, — перетягує
/// блок тексту. Інакше випадкове клацання по посиланню всередині сторінки
/// завело б попередній перегляд невідомо куди.
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
    /// Своя картинка під сторінкою: з нею видно, що перекриває титр.
    private let backdrop = CALayer()

    /// Підкласти свій файл (або прибрати, якщо `nil`).
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

    /// Веб-вид не має перехоплювати мишу: вона належить редакторові.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func layout() {
        super.layout()
        web.frame = stageFrame
        // Картинка рівно під кадром сторінки, а не під усією панеллю.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = stageFrame
        CATransaction.commit()
    }

    /// Кадр 16:9 усередині панелі — ті самі пропорції, що в екрана в залі.
    private var stageFrame: NSRect {
        let side = WebSlidePlacement.frame(in: bounds.size)
        return NSRect(x: (bounds.width - side.width) / 2,
                      y: (bounds.height - side.height) / 2,
                      width: side.width, height: side.height)
    }

    // MARK: - Оновлення

    func refresh() {
        if key != model.previewReloadKey {
            key = model.previewReloadKey
            // Після перезавантаження сторінка візьме значення з власного
            // блоку — вони вже ті самі, дописувати нічого.
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

    /// Дописати сторінці тільки значення, що змінилися.
    private func push() {
        guard !isLoading else { return }
        var script = ""
        for (name, value) in model.previewValues where applied[name] != value {
            script += "document.documentElement.style.setProperty('\(name)','\(value)');"
        }
        guard !script.isEmpty else { return }
        applied = model.previewValues
        // Після кожної правки просимо сторінку перерахувати кегль. Без цього
        // підібраний розмір лишався від попереднього показу: повзунок
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

    // MARK: - Перетягування блоку

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
        // Поки точка прив'язки та сама — файл чіпати нема чого.
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

    /// Дев'ять точок прив'язки — видно, куди стане блок.
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
