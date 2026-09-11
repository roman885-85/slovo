import AppKit
import SlovoCore

/// Ключ, по которому решается, что слайд сменился и надо играть переход.
/// Смена фона — тоже смена слайда: иначе картинка подменится рывком под
/// плавно наезжающим текстом.
struct SlideIdentity: Hashable {
    let mainText: String
    let secondaryTexts: [String]
    let reference: String
    let isBlank: Bool
    let backgroundPath: String?

    init(slide: Slide, style: SlideStyle) {
        mainText = slide.mainText
        secondaryTexts = slide.secondaryTexts
        reference = slide.reference
        isBlank = slide.isBlank
        backgroundPath = style.backgroundImagePath
    }
}

/// Двадцать переходов слайда — одной таблицей на проектор, предпросмотр и
/// трансляцию. Владелец просил «20 шаблонов эффектов переходов с их
/// настройками»: у каждого перехода своя длительность и своя кривая.
///
/// Здесь — то, что нужно Core Animation: как входит новый слой, как уходит
/// старый, нужна ли маска (шторки) и какая кривая времени.
enum SlideTransitionAnimator {

    /// Кривая времени для Core Animation.
    static func timing(_ easing: SlideStyle.Easing) -> CAMediaTimingFunction {
        switch easing {
        case .linear:    return CAMediaTimingFunction(name: .linear)
        case .easeInOut: return CAMediaTimingFunction(name: .easeInEaseOut)
        case .easeOut:   return CAMediaTimingFunction(name: .easeOut)
        // Пружина: перелёт и возврат — двумя контрольными точками.
        case .spring:    return CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
        }
    }

    /// Откуда приходит новый слой (для двухслойного предпросмотра).
    static func enterTransform(_ kind: SlideStyle.Transition, size: CGSize) -> CATransform3D {
        let w = size.width, h = size.height
        switch kind {
        case .none, .fade, .fadeBlack, .blur, .wipeLeft, .wipeRight, .wipeUp, .wipeDown:
            return CATransform3DIdentity
        case .slideLeft, .coverLeft:   return CATransform3DMakeTranslation(w, 0, 0)
        case .slideRight, .coverRight: return CATransform3DMakeTranslation(-w, 0, 0)
        case .slideUp, .coverUp:       return CATransform3DMakeTranslation(0, -h, 0)
        case .slideDown, .coverDown:   return CATransform3DMakeTranslation(0, h, 0)
        case .zoom:                    return CATransform3DMakeScale(1.08, 1.08, 1)
        case .zoomOut:                 return CATransform3DMakeScale(0.9, 0.9, 1)
        case .spin:
            var t = CATransform3DMakeRotation(-.pi / 6, 0, 0, 1)
            t = CATransform3DScale(t, 0.85, 0.85, 1)
            return t
        case .flip:
            var t = CATransform3DIdentity
            t.m34 = -1 / 800
            return CATransform3DRotate(t, .pi / 2, 0, 1, 0)
        case .bounce:                  return CATransform3DMakeTranslation(0, -h * 0.35, 0)
        }
    }

    /// Куда уходит старый слой.
    static func leaveTransform(_ kind: SlideStyle.Transition, size: CGSize) -> CATransform3D {
        let w = size.width, h = size.height
        switch kind {
        case .none, .fade, .fadeBlack, .blur, .bounce,
             .coverLeft, .coverRight, .coverUp, .coverDown,
             .wipeLeft, .wipeRight, .wipeUp, .wipeDown:
            return CATransform3DIdentity
        case .slideLeft:  return CATransform3DMakeTranslation(-w, 0, 0)
        case .slideRight: return CATransform3DMakeTranslation(w, 0, 0)
        case .slideUp:    return CATransform3DMakeTranslation(0, h, 0)
        case .slideDown:  return CATransform3DMakeTranslation(0, -h, 0)
        case .zoom:       return CATransform3DMakeScale(0.94, 0.94, 1)
        case .zoomOut:    return CATransform3DMakeScale(1.1, 1.1, 1)
        case .spin:
            var t = CATransform3DMakeRotation(.pi / 6, 0, 0, 1)
            t = CATransform3DScale(t, 0.85, 0.85, 1)
            return t
        case .flip:
            var t = CATransform3DIdentity
            t.m34 = -1 / 800
            return CATransform3DRotate(t, -.pi / 2, 0, 1, 0)
        }
    }

    /// Гаснет ли старый слой (у сдвигов и накрытий он просто уезжает или
    /// остаётся под новым).
    static func fadesOut(_ kind: SlideStyle.Transition) -> Bool {
        switch kind {
        case .slideLeft, .slideRight, .slideUp, .slideDown,
             .coverLeft, .coverRight, .coverUp, .coverDown,
             .wipeLeft, .wipeRight, .wipeUp, .wipeDown, .flip:
            return false
        default:
            return true
        }
    }

    /// Появляется ли новый слой из прозрачности.
    static func fadesIn(_ kind: SlideStyle.Transition) -> Bool {
        switch kind {
        case .slideLeft, .slideRight, .slideUp, .slideDown,
             .coverLeft, .coverRight, .coverUp, .coverDown,
             .wipeLeft, .wipeRight, .wipeUp, .wipeDown, .flip:
            return false
        default:
            return true
        }
    }

    /// Шторка: откуда и куда растёт маска нового слоя.
    static func wipe(_ kind: SlideStyle.Transition, size: CGSize) -> (from: CGRect, to: CGRect)? {
        let whole = CGRect(origin: .zero, size: size)
        switch kind {
        case .wipeLeft:  return (CGRect(x: size.width, y: 0, width: 0, height: size.height), whole)
        case .wipeRight: return (CGRect(x: 0, y: 0, width: 0, height: size.height), whole)
        case .wipeUp:    return (CGRect(x: 0, y: 0, width: size.width, height: 0), whole)
        case .wipeDown:  return (CGRect(x: 0, y: size.height, width: size.width, height: 0), whole)
        default:         return nil
        }
    }

    /// Переход через чёрное: половина времени гаснет старое, половина —
    /// проявляется новое.
    static func isThroughBlack(_ kind: SlideStyle.Transition) -> Bool { kind == .fadeBlack }

    /// Размытие уходящего слоя.
    static func blurs(_ kind: SlideStyle.Transition) -> Bool { kind == .blur }

    /// Переход в окне проектора: старый и новый кадры кладутся ДВУМЯ
    /// отдельными слоями поверх содержимого и анимируются каждый по своим
    /// правилам; по окончании оба снимаются, а в слое остаётся новый кадр.
    ///
    /// Раньше новый кадр «въезжал» преобразованием самого слоя окна — но
    /// уходящий кадр лежал в нём подслоем и ехал вместе с ним, поэтому
    /// сдвиги и накрытия гасили сами себя, и владелец видел, что часть
    /// эффектов не работает. Все анимации — явные: неявных на слое, пока он
    /// не в окне, не возникает вовсе.
    @MainActor
    static func play(on layer: CALayer, from old: CGImage?, to new: CGImage?,
                     kind: SlideStyle.Transition, duration: Double, easing: SlideStyle.Easing) {
        let size = layer.bounds.size
        guard kind != .none, duration > 0.01, let old, size.width > 1, size.height > 1 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = new
            CATransaction.commit()
            return
        }
        // Остатки прошлого перехода — прочь.
        layer.sublayers?.filter { ["уходящий", "входящий", "чёрное"].contains($0.name ?? "") }
            .forEach { $0.removeFromSuperlayer() }

        func makeLayer(_ image: CGImage?, _ name: String, _ z: CGFloat) -> CALayer {
            let sub = CALayer()
            sub.name = name
            sub.frame = layer.bounds
            sub.contents = image
            sub.contentsGravity = layer.contentsGravity
            sub.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            sub.position = CGPoint(x: size.width / 2, y: size.height / 2)
            sub.zPosition = z
            sub.isOpaque = false
            layer.addSublayer(sub)
            return sub
        }
        // Накрытия и шторки: новый кадр сверху. Прочие: уходящий сверху.
        let newOnTop = [.coverLeft, .coverRight, .coverUp, .coverDown,
                        .wipeLeft, .wipeRight, .wipeUp, .wipeDown].contains(kind)
        let outgoing = makeLayer(old, "уходящий", newOnTop ? 1 : 2)
        let incoming = makeLayer(new, "входящий", newOnTop ? 2 : 1)

        let curve = timing(easing)
        func animate(_ target: CALayer, _ keyPath: String, _ from: Any, _ to: Any, key: String,
                     duration: Double = duration, begin: Double = 0) {
            let step = CABasicAnimation(keyPath: keyPath)
            step.fromValue = from
            step.toValue = to
            step.duration = duration
            step.beginTime = begin > 0 ? CACurrentMediaTime() + begin : 0
            step.timingFunction = curve
            step.fillMode = .both
            step.isRemovedOnCompletion = false
            target.add(step, forKey: key)
        }

        switch kind {
        case .fadeBlack:
            // Через чёрное: гаснет старое, затем проявляется новое.
            let black = makeLayer(nil, "чёрное", 3)
            black.backgroundColor = NSColor.black.cgColor
            black.contents = nil
            let keys = CAKeyframeAnimation(keyPath: "opacity")
            keys.values = [0, 1, 1, 0]
            keys.keyTimes = [0, 0.45, 0.55, 1]
            keys.duration = duration
            keys.fillMode = .both
            keys.isRemovedOnCompletion = false
            black.add(keys, forKey: "чёрное")
            animate(outgoing, "opacity", 1, 0, key: "гаснет", duration: duration * 0.5)
            incoming.opacity = 0
            animate(incoming, "opacity", 0, 1, key: "проявляется", duration: duration * 0.5, begin: duration * 0.5)

        case .flip:
            // Переворот: старое схлопывается по горизонтали, новое раскрывается.
            var flat = CATransform3DIdentity
            flat.m34 = -1 / 800
            let quarter = CATransform3DRotate(flat, .pi / 2, 0, 1, 0)
            let backQuarter = CATransform3DRotate(flat, -.pi / 2, 0, 1, 0)
            animate(outgoing, "transform", NSValue(caTransform3D: CATransform3DIdentity),
                    NSValue(caTransform3D: backQuarter), key: "закрывается", duration: duration * 0.5)
            incoming.opacity = 0
            animate(incoming, "opacity", 0, 1, key: "виден", duration: 0.01, begin: duration * 0.5)
            animate(incoming, "transform", NSValue(caTransform3D: quarter),
                    NSValue(caTransform3D: CATransform3DIdentity), key: "раскрывается",
                    duration: duration * 0.5, begin: duration * 0.5)

        default:
            if let mask = wipe(kind, size: size) {
                // Шторка: маска нового кадра растёт в сторону открытия.
                let shutter = CALayer()
                shutter.backgroundColor = NSColor.black.cgColor
                shutter.frame = mask.from
                incoming.mask = shutter
                animate(shutter, "frame", NSValue(rect: mask.from), NSValue(rect: mask.to), key: "шторка")
            }
            if blurs(kind), let filter = CIFilter(name: "CIGaussianBlur") {
                filter.name = "blur"
                filter.setValue(0, forKey: kCIInputRadiusKey)
                outgoing.filters = [filter]
                animate(outgoing, "filters.blur.inputRadius", 0, 24, key: "размытие")
            }
            let enter = enterTransform(kind, size: size)
            if !CATransform3DIsIdentity(enter) {
                animate(incoming, "transform", NSValue(caTransform3D: enter),
                        NSValue(caTransform3D: CATransform3DIdentity), key: "вход")
            }
            let leave = leaveTransform(kind, size: size)
            if !CATransform3DIsIdentity(leave) {
                animate(outgoing, "transform", NSValue(caTransform3D: CATransform3DIdentity),
                        NSValue(caTransform3D: leave), key: "уход")
            }
            if fadesIn(kind) {
                incoming.opacity = 0
                animate(incoming, "opacity", 0, 1, key: "проявляется")
            }
            if fadesOut(kind) {
                animate(outgoing, "opacity", 1, 0, key: "гаснет")
            }
        }

        // По окончании: новый кадр в самом слое, служебные слои прочь.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = new
            layer.sublayers?.filter { ["уходящий", "входящий", "чёрное"].contains($0.name ?? "") }
                .forEach { $0.removeFromSuperlayer() }
            CATransaction.commit()
        }
    }
}
