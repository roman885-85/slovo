import AppKit
import SlovoCore

/// «Предпросмотр» (6.3.6) — холст конструктора, на AppKit.
///
/// Сам слайд рисует общий `SlideDrawing` — тот же, что показывает зал: холст
/// обязан показывать ровно то, что увидят люди, и второй отрисовки для этого
/// заводить нельзя.
///
/// Выделенный объект обведён рамкой, а размер и положение меняются мышью за
/// активные зоны: по центру каждой стороны и в середине объекта. Ровно эти
/// пять зон названы в руководстве, поэтому углов здесь нет.
@MainActor
final class NativeConstructorCanvas: NSView {

    private let model: SlideConstructorModel
    var sample = ConstructorSample()
    var missingFileLabel = "Не найден файл:"

    private enum Handle { case move, left, right, top, bottom }
    private var dragging: Handle?
    private var startRect: CGRect?
    private var startPoint: CGPoint?

    init(model: SlideConstructorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    /// Кадр слайда в своих пропорциях, вписанный в панель.
    private var stage: NSRect {
        let ratio = model.preset.aspectRatio
        guard ratio > 0 else { return bounds }
        var size = NSSize(width: bounds.width, height: bounds.width / ratio)
        if size.height > bounds.height {
            size = NSSize(width: bounds.height * ratio, height: bounds.height)
        }
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    // MARK: - Отрисовка

    /// Последний нарисованный кадр и отпечаток того, что в нём. Кадр
    /// готовит очередь в фоне: пока идёт протяжка ползунка, холст показывает
    /// прежний кадр и подменяет его, как только подоспеет новый. Раньше кадр
    /// рисовался прямо в `draw(_:)`, и каждое движение ползунка держало окно.
    private var rendered: (identity: Int, image: CGImage)?
    private var requestedIdentity = 0
    private var renderGeneration = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let stage = self.stage
        guard stage.width > 8, stage.height > 8,
              let context = NSGraphicsContext.current?.cgContext else { return }

        // Слайд рисуем в тот же кадр, что уходит в зал.
        let slide = Slide(mainText: sample.mainText,
                          secondaryTexts: [sample.secondaryText],
                          reference: sample.reference)
        var identity = SlideFrameRenderer.identity(slide: slide, style: model.baseStyle, size: stage.size,
                                                   preset: model.preset, drawsBackground: true)
        identity = identity &+ (model.scene == .dual ? 1 : 0)
            &+ sample.songTitle.hashValue &+ sample.moduleNameFirst.hashValue
            &+ sample.moduleShortNameFirst.hashValue &+ sample.moduleNameSecond.hashValue
            &+ sample.moduleShortNameSecond.hashValue &+ sample.primaryReference.hashValue
            &+ sample.secondaryReference.hashValue
        if let rendered, rendered.identity != identity || requestedIdentity != identity,
           requestedIdentity != identity {
            _ = rendered
        }
        if requestedIdentity != identity {
            requestedIdentity = identity
            var order = SlideDrawing.Order(slide: slide,
                                           style: model.baseStyle,
                                           preset: model.preset,
                                           texts: sample,
                                           drawsBackground: true,
                                           withSecondTranslation: model.scene == .dual,
                                           imageURL: { [model] name in model.imageURL(name) },
                                           missingFileLabel: missingFileLabel)
            order.resolveImages()
            renderGeneration &+= 1
            let wanted = renderGeneration
            SlideRenderQueue.shared.render(key: "конструктор", generation: wanted, order: order,
                                           size: stage.size, opaque: true) { [weak self] image, done in
                guard let self, done == self.renderGeneration, let image else { return }
                self.rendered = (identity, image)
                self.needsDisplay = true
            }
        }
        if let image = rendered?.image {
            context.saveGState()
            context.translateBy(x: stage.minX, y: stage.minY + stage.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: stage.size))
            context.restoreGState()
        }

        guard let object = model.selectedObject else { return }
        let rect = frame(of: object).offsetBy(dx: stage.minX, dy: stage.minY)
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: rect)
        outline.lineWidth = 1
        outline.stroke()

        // Маркеры разносим по раздутой рамке: у объектов шириной «по
        // содержимому» настоящая рамка выходит уже трёх маркеров подряд, и
        // они сходились в одну точку — тянуть было нечем.
        let zones = ConstructorHandles.zones(around: rect)
        for point in [CGPoint(x: zones.midX, y: zones.midY),
                      CGPoint(x: zones.minX, y: zones.midY),
                      CGPoint(x: zones.maxX, y: zones.midY),
                      CGPoint(x: zones.midX, y: zones.minY),
                      CGPoint(x: zones.midX, y: zones.maxY)] {
            let side = ConstructorHandles.size
            let box = NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
            NSColor.controlAccentColor.setFill()
            box.fill()
            NSColor.white.setStroke()
            NSBezierPath(rect: box).stroke()
        }
    }

    /// Рамка объекта на холсте — уже с раскрытой «нулевой» стороной.
    private func frame(of object: SlideObject) -> CGRect {
        let values = object.values(in: model.scene)
        let size = stage.size
        let auto = ConstructorAutoSize.size(of: object, values: values, sample: sample,
                                            canvas: size, imageURL: { [model] in model.imageURL($0) })
        return values.frame.resolved(auto: auto, in: size).rect(in: size)
    }

    // MARK: - Мышь

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let stage = self.stage
        if let object = model.selectedObject {
            let rect = frame(of: object).offsetBy(dx: stage.minX, dy: stage.minY)
            if let handle = handle(at: point, around: rect) {
                dragging = handle
                startRect = rect
                startPoint = point
                return
            }
        }
        // Щелчок по объекту выбирает его — как в оригинале.
        let inStage = CGPoint(x: point.x - stage.minX, y: point.y - stage.minY)
        if let hit = model.preset.objects.reversed().first(where: {
            $0.values(in: model.scene).isVisible && frame(of: $0).contains(inStage)
        }) {
            model.selection = hit.id
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging, let startRect, let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - startPoint.x, dy = point.y - startPoint.y
        // Минимум в 10 точек: схлопнутую в нить рамку уже не за что взять.
        let minimum: CGFloat = 10
        var rect = startRect
        switch dragging {
        case .move:
            rect = startRect.offsetBy(dx: dx, dy: dy)
        case .left:
            let maxX = startRect.maxX
            let x = min(startRect.minX + dx, maxX - minimum)
            rect = CGRect(x: x, y: startRect.minY, width: maxX - x, height: startRect.height)
        case .right:
            rect = CGRect(x: startRect.minX, y: startRect.minY,
                          width: max(startRect.width + dx, minimum), height: startRect.height)
        case .top:
            let maxY = startRect.maxY
            let y = min(startRect.minY + dy, maxY - minimum)
            rect = CGRect(x: startRect.minX, y: y, width: startRect.width, height: maxY - y)
        case .bottom:
            rect = CGRect(x: startRect.minX, y: startRect.minY,
                          width: startRect.width, height: max(startRect.height + dy, minimum))
        }
        apply(rect)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        startRect = nil
        startPoint = nil
    }

    private func handle(at point: CGPoint, around rect: CGRect) -> Handle? {
        let zones = ConstructorHandles.zones(around: rect)
        let side = ConstructorHandles.size + 4
        let places: [(Handle, CGPoint)] = [
            (.move, CGPoint(x: zones.midX, y: zones.midY)),
            (.left, CGPoint(x: zones.minX, y: zones.midY)),
            (.right, CGPoint(x: zones.maxX, y: zones.midY)),
            (.top, CGPoint(x: zones.midX, y: zones.minY)),
            (.bottom, CGPoint(x: zones.midX, y: zones.maxY)),
        ]
        for (handle, centre) in places {
            let box = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
            if box.contains(point) { return handle }
        }
        return nil
    }

    private func apply(_ rect: CGRect) {
        guard let object = model.selectedObject else { return }
        let stage = self.stage
        guard stage.width > 0, stage.height > 0 else { return }
        var values = object.values(in: model.scene)
        // Потянули мышью — размер стал заданным: «по содержимому» здесь уже
        // не выразить, и оригинал в этом месте поступает так же.
        values.frame = ObjectFrame(rect: rect.offsetBy(dx: -stage.minX, dy: -stage.minY),
                                   in: stage.size,
                                   anchorX: values.frame.anchorX,
                                   anchorY: values.frame.anchorY)
        model.setSelectedValues(values)
        needsDisplay = true
    }
}
