import AppKit
import SlovoCore

/// Хвиля фонограми — увесь трек одним поглядом, як в Audacity.
///
/// Власник: «графический просмотр трека (как в audacity), для визуального
/// контроля и быстрого перехода на нужное место… показывает позицию текущего
/// проигрывания и имеет возможность играть с указанного пользователем места».
/// Зіграна частина — кольором акценту, решта — сірим; вертикальна риска —
/// де звук зараз. Клацання чи протягування — грати з цього місця.
@MainActor
final class NativeWaveformView: NSView {

    var waveform: BackingWaveform? { didSet { needsDisplay = true } }
    /// Де звук зараз, частка від 0 до 1.
    var progress: Double = 0 {
        didSet { if abs(progress - oldValue) > 0.0005 { needsDisplay = true } }
    }
    var duration: Double = 0 { didSet { needsDisplay = true } }
    /// Файл відкрито, але хвиля ще будується.
    var isLoading = false { didSet { needsDisplay = true } }
    /// Людина відпустила мишу на цій частці треку.
    var onSeek: ((Double) -> Void)?

    /// Куди тягнуть просто зараз — курсор іде за мишею, звук ще ні.
    private var dragProgress: Double?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Хвиля лежить на темній картці (як передпоказ і живий екран), тому
        // кольори свої, не системні: світле на темному в обох темах.
        let rect = bounds
        let middle = rect.midY
        let half = rect.height / 2 - 2
        guard let waveform, !waveform.maxs.isEmpty else {
            NSColor(white: 1, alpha: 0.12).setFill()
            NSRect(x: rect.minX, y: middle - 0.5, width: rect.width, height: 1).fill()
            let text = isLoading ? OurWords.t("Строю волну…") : OurWords.t("Перетащите сюда музыку")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor(white: 1, alpha: 0.45),
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let box = NSRect(x: rect.midX - size.width / 2 - 6, y: middle - size.height / 2 - 1,
                             width: size.width + 12, height: size.height + 2)
            NSColor(white: 0.08, alpha: 1).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            (text as NSString).draw(at: NSPoint(x: box.minX + 6, y: box.minY + 1), withAttributes: attributes)
            return
        }

        // Тихий трек не має виглядати рискою: масштаб від найгучнішого місця,
        // але не більш як учетверо.
        let scale = CGFloat(1 / max(0.25, min(1, waveform.peak)))
        let shown = dragProgress ?? progress
        let cursorX = rect.minX + CGFloat(shown) * rect.width
        let count = waveform.maxs.count
        let step: CGFloat = 2
        let columns = max(1, Int(rect.width / step))
        let played = NSColor.controlAccentColor
        let rest = NSColor(white: 1, alpha: 0.32)
        for column in 0..<columns {
            let from = column * count / columns
            let to = max(from + 1, (column + 1) * count / columns)
            var low: Float = 0, high: Float = 0
            for bucket in from..<min(to, count) {
                low = min(low, waveform.mins[bucket])
                high = max(high, waveform.maxs[bucket])
            }
            let top = middle - min(half, max(0.75, CGFloat(high) * scale * half))
            let bottom = middle - max(-half, min(-0.75, CGFloat(low) * scale * half))
            let x = rect.minX + CGFloat(column) * step
            (x < cursorX ? played : rest).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: top, width: step - 0.6, height: max(1.5, bottom - top)),
                         xRadius: 0.6, yRadius: 0.6).fill()
        }

        // Курсор: біла риска з трикутничком угорі, як головка в Audacity.
        let x = min(rect.maxX - 1, max(rect.minX + 1, cursorX))
        NSColor.white.setFill()
        NSRect(x: x - 0.75, y: rect.minY, width: 1.5, height: rect.height).fill()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: x - 4, y: rect.minY))
        head.line(to: NSPoint(x: x + 4, y: rect.minY))
        head.line(to: NSPoint(x: x, y: rect.minY + 5))
        head.close()
        head.fill()
        if let dragProgress, duration > 0 {
            let text = MediaPlayerModel.timeText(dragProgress * duration)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let labelX = min(rect.maxX - size.width - 8, max(rect.minX + 2, cursorX + 5))
            let box = NSRect(x: labelX - 3, y: rect.maxY - size.height - 3, width: size.width + 6, height: size.height + 2)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            (text as NSString).draw(at: NSPoint(x: labelX, y: box.minY + 1), withAttributes: attributes)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func fraction(for event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else { return 0 }
        return Double(min(1, max(0, (point.x - bounds.minX) / bounds.width)))
    }

    override func mouseDown(with event: NSEvent) {
        guard waveform != nil || duration > 0 else { return }
        dragProgress = fraction(for: event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragProgress != nil else { return }
        dragProgress = fraction(for: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragProgress != nil else { return }
        let target = fraction(for: event)
        dragProgress = nil
        progress = target
        needsDisplay = true
        onSeek?(target)
    }

    /// Клацання в частку треку — самоперевірці: миші в перевірці немає.
    func clickForCheck(at target: Double) {
        progress = target
        onSeek?(target)
    }
}

/// Пік-метр фонограми: лівий і правий канали смугами, шкала в децибелах.
///
/// Власник 16.09.2026: «пик метр более сделай мягким и плавным». Досі смуга
/// була з різких сегментів, злітала миттєво й падала сходинками по кадрах
/// (30 на секунду, а між порціями звуку — нуль). Тепер:
///  • балістика як у звукорежисерських індикаторів: підйом м'який (стала
///    часу 70 мс), спад повільний (400 мс) — смуга «дихає» за музикою, а не
///    смикається;
///  • 60 кадрів і рух між порціями звуку без провалів;
///  • суцільна заокруглена смуга з м'яким переходом зелене → жовте → червоне
///    і ледь помітною доріжкою під нею;
///  • найвищий пік — тонка риска, що тримається секунду й плавно гасне.
@MainActor
final class NativeLevelMeter: NSView {

    private static let floor: Float = -48
    /// Стала часу підйому й спаду, секунди.
    private static let attack: Float = 0.07
    private static let release: Float = 0.4
    /// Скільки тримається риска найвищого піку, і за скільки гасне.
    private static let holdTime: TimeInterval = 1.0
    private static let fadeTime: TimeInterval = 0.6

    /// Куди смуга йде (останній пік) і де вона зараз.
    private var target: [Float] = [floor, floor]
    private var shown: [Float] = [floor, floor]
    private var held: [Float] = [floor, floor]
    private var heldAt: [TimeInterval] = [0, 0]
    private var last = ProcessInfo.processInfo.systemUptime

    override var isFlipped: Bool { true }

    /// Чи ще є що показувати: смуга й риска опустилися до дна.
    var isQuiet: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let dark = heldAt.allSatisfy { now - $0 > Self.holdTime + Self.fadeTime }
        return shown.allSatisfy { $0 <= Self.floor + 0.5 } && (dark || held.allSatisfy { $0 <= Self.floor + 0.5 })
    }

    /// Нові піки (лінійно, 0…1).
    func update(left: Float, right: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        for (index, value) in [left, right].enumerated() {
            let decibels = value > 0 ? max(Self.floor, 20 * log10(value)) : Self.floor
            target[index] = decibels
            if decibels >= held[index] || now - heldAt[index] > Self.holdTime + Self.fadeTime {
                if decibels > Self.floor + 0.5 {
                    held[index] = decibels
                    heldAt[index] = now
                }
            }
        }
        advance()
    }

    /// Кадр без нових порцій звуку: смуга продовжує рух до останньої цілі,
    /// а ціль потроху опускається — щоб застиглий звук не висів угорі.
    func advance() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = Float(min(0.25, max(0, now - last)))
        last = now
        for index in 0..<2 {
            let goal = target[index]
            let constant = goal > shown[index] ? Self.attack : Self.release
            let step = 1 - exp(-elapsed / constant)
            shown[index] += (goal - shown[index]) * step
            if abs(shown[index] - goal) < 0.05 { shown[index] = goal }
            target[index] = max(Self.floor, target[index] - 6 * elapsed)
        }
        needsDisplay = true
    }

    /// Показані рівні в дБ — самоперевірці.
    var decibelsForCheck: [Float] { shown }

    /// Частка шкали для рівня в дБ.
    private static func fraction(_ decibels: Float) -> CGFloat {
        CGFloat(min(1, max(0, (decibels - floor) / -floor)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let gap: CGFloat = 2
        let rowHeight = max(2, (rect.height - gap) / 2)
        let radius = min(rowHeight / 2, 3)
        let now = ProcessInfo.processInfo.systemUptime
        // Кольори м'якші за системні: трохи приглушені, щоб смуга не різала
        // очі на темній картці поруч із хвилею.
        let gradient = NSGradient(colorsAndLocations:
            (NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.45, alpha: 1), 0),
            (NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.46, alpha: 1), Self.fraction(-18)),
            (NSColor(calibratedRed: 0.93, green: 0.80, blue: 0.30, alpha: 1), Self.fraction(-9)),
            (NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.32, alpha: 1), Self.fraction(-2)),
            (NSColor(calibratedRed: 0.95, green: 0.32, blue: 0.30, alpha: 1), 1))
        for channel in 0..<2 {
            let y = rect.minY + CGFloat(channel) * (rowHeight + gap)
            let track = NSRect(x: rect.minX, y: y, width: rect.width, height: rowHeight)
            NSColor(white: 1, alpha: 0.07).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

            let width = rect.width * Self.fraction(shown[channel])
            if width > 0.5 {
                let bar = NSRect(x: rect.minX, y: y, width: max(width, radius * 2), height: rowHeight)
                let clip = NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius)
                NSGraphicsContext.saveGraphicsState()
                clip.addClip()
                // Градієнт на всю шкалу, а видно лише пройдене: колір залежить
                // від рівня, а не від довжини смуги.
                gradient?.draw(in: track, angle: 0)
                NSGraphicsContext.restoreGraphicsState()
            }

            // Риска найвищого піку: тримається, потім плавно гасне.
            let age = now - heldAt[channel]
            if held[channel] > Self.floor + 0.5, age < Self.holdTime + Self.fadeTime {
                let alpha = age <= Self.holdTime ? 1 : CGFloat(1 - (age - Self.holdTime) / Self.fadeTime)
                let x = rect.minX + rect.width * Self.fraction(held[channel])
                let colour: NSColor = held[channel] > -2 ? NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.30, alpha: 1)
                    : held[channel] > -9 ? NSColor(calibratedRed: 0.93, green: 0.80, blue: 0.30, alpha: 1)
                    : NSColor(white: 1, alpha: 1)
                colour.withAlphaComponent(0.85 * max(0, alpha)).setFill()
                NSBezierPath(roundedRect: NSRect(x: min(rect.maxX - 2, max(rect.minX, x - 1)), y: y, width: 2, height: rowHeight),
                             xRadius: 1, yRadius: 1).fill()
            }
        }
    }
}
