import AppKit
import CoreGraphics
import SlovoCore

extension SlideFrameRenderer {

    /// Промежуточный кадр перехода: старая картинка перетекает в новую.
    ///
    /// В сеть уходит поток кадров, а не живой вид, поэтому переход здесь
    /// приходится рисовать самим: на каждый такт таймера мы складываем две
    /// картинки в одну по нужной доле пути. Без этого «как сменяется слайд»
    /// работало в зале и в предпросмотре, а на микшере текст подменялся
    /// рывком — что и было видно.
    ///
    /// `nonisolated`: складывание идёт на очереди канала, в главном потоке
    /// ему делать нечего.
    nonisolated static func blend(from: CGImage?, to: CGImage,
                                  progress: Double,
                                  transition: SlideStyle.Transition,
                                  easing: SlideStyle.Easing = .easeInOut,
                                  identity: Int,
                                  alpha: FrameAlpha) -> RenderedFrame? {
        let width = to.width
        let height = to.height
        guard width > 0, height > 0 else { return nil }
        let step = easing.apply(min(1, max(0, progress)))

        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: info) else { return false }
            let whole = CGRect(x: 0, y: 0, width: width, height: height)
            context.clear(whole)

            // Уходящий слой — там, где он ещё виден.
            if let from {
                context.saveGState()
                context.setAlpha(leaveOpacity(transition, step))
                context.concatenate(leaveTransform(transition, step, size: whole.size))
                context.draw(from, in: whole)
                context.restoreGState()
            }
            // Приходящий: у шторок — только открытая часть.
            context.saveGState()
            if let clip = enterClip(transition, step, size: whole.size) { context.clip(to: clip) }
            context.setAlpha(enterOpacity(transition, step))
            context.concatenate(enterTransform(transition, step, size: whole.size))
            context.draw(to, in: whole)
            context.restoreGState()
            return true
        }
        guard drawn else { return nil }

        var transparent = false
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = bytesPerRow * height
            var index = 3
            while index < count {
                if bytes[index] != 255 { transparent = true; break }
                index += 4
            }
            if alpha == .straight && transparent { unpremultiplyBytes(bytes, count: count) }
        }

        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue:
                                    CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        return RenderedFrame(pixels: pixels, width: width, height: height,
                             bytesPerRow: bytesPerRow,
                             alpha: transparent ? alpha : .premultiplied,
                             identity: identity, image: image,
                             hasTransparency: transparent)
    }

    // MARK: Как именно расходятся два слоя

    private nonisolated static func enterOpacity(_ transition: SlideStyle.Transition, _ rawStep: Double) -> CGFloat {
        // Пружина перелетает за 1 — для прозрачности это уже «полностью».
        let step = min(1, max(0, rawStep))
        switch transition {
        case .none:                 return 1
        case .fadeBlack:            return CGFloat(max(0, step * 2 - 1))
        case .flip:                 return step >= 0.5 ? 1 : 0
        case .fade, .zoom, .zoomOut, .spin, .blur, .bounce: return CGFloat(step)
        default:                    return 1   // сдвиги, накрытия, шторки — без прозрачности
        }
    }

    private nonisolated static func leaveOpacity(_ transition: SlideStyle.Transition, _ rawStep: Double) -> CGFloat {
        let step = min(1, max(0, rawStep))
        switch transition {
        case .none:                 return 0
        case .fadeBlack:            return CGFloat(max(0, 1 - step * 2))
        case .flip:                 return step < 0.5 ? 1 : 0
        case .fade, .zoom, .zoomOut, .spin, .blur, .bounce: return CGFloat(1 - step)
        default:                    return 1
        }
    }

    /// Открытая часть кадра для шторок (ось Y у CoreGraphics — снизу вверх).
    private nonisolated static func enterClip(_ transition: SlideStyle.Transition,
                                              _ step: Double, size: CGSize) -> CGRect? {
        let s = CGFloat(min(1, max(0, step)))
        switch transition {
        case .wipeLeft:  return CGRect(x: size.width * (1 - s), y: 0, width: size.width * s, height: size.height)
        case .wipeRight: return CGRect(x: 0, y: 0, width: size.width * s, height: size.height)
        case .wipeUp:    return CGRect(x: 0, y: 0, width: size.width, height: size.height * s)
        case .wipeDown:  return CGRect(x: 0, y: size.height * (1 - s), width: size.width, height: size.height * s)
        default:         return nil
        }
    }

    private nonisolated static func enterTransform(_ transition: SlideStyle.Transition,
                                                   _ step: Double, size: CGSize) -> CGAffineTransform {
        let s = CGFloat(step)
        let w = size.width, h = size.height
        switch transition {
        case .none, .fade, .fadeBlack, .blur, .wipeLeft, .wipeRight, .wipeUp, .wipeDown:
            return .identity
        case .slideLeft, .coverLeft:   return CGAffineTransform(translationX: w * (1 - s), y: 0)
        case .slideRight, .coverRight: return CGAffineTransform(translationX: -w * (1 - s), y: 0)
        // Ось Y снизу вверх: «вверх» на экране — прибавить к y.
        case .slideUp, .coverUp:       return CGAffineTransform(translationX: 0, y: -h * (1 - s))
        case .slideDown, .coverDown:   return CGAffineTransform(translationX: 0, y: h * (1 - s))
        case .zoom:                    return zoom(0.92 + 0.08 * s, size: size)
        case .zoomOut:                 return zoom(1.1 - 0.1 * s, size: size)
        case .spin:
            return spin(scale: 0.85 + 0.15 * s, angle: -(.pi / 6) * (1 - s), size: size)
        case .flip:
            // Вторая половина: разворачивается по горизонтали из нуля.
            let open = max(0.001, s * 2 - 1)
            return CGAffineTransform(translationX: w / 2, y: 0).scaledBy(x: open, y: 1).translatedBy(x: -w / 2, y: 0)
        case .bounce:                  return CGAffineTransform(translationX: 0, y: h * 0.35 * (1 - s))
        }
    }

    private nonisolated static func leaveTransform(_ transition: SlideStyle.Transition,
                                                   _ step: Double, size: CGSize) -> CGAffineTransform {
        let s = CGFloat(step)
        let w = size.width, h = size.height
        switch transition {
        case .none, .fade, .fadeBlack, .blur, .bounce,
             .coverLeft, .coverRight, .coverUp, .coverDown,
             .wipeLeft, .wipeRight, .wipeUp, .wipeDown:
            return .identity
        case .slideLeft:  return CGAffineTransform(translationX: -w * s, y: 0)
        case .slideRight: return CGAffineTransform(translationX: w * s, y: 0)
        case .slideUp:    return CGAffineTransform(translationX: 0, y: h * s)
        case .slideDown:  return CGAffineTransform(translationX: 0, y: -h * s)
        case .zoom:       return zoom(1 + 0.08 * s, size: size)
        case .zoomOut:    return zoom(1 - 0.1 * s, size: size)
        case .spin:       return spin(scale: 1 - 0.15 * s, angle: (.pi / 6) * s, size: size)
        case .flip:
            let close = max(0.001, 1 - s * 2)
            return CGAffineTransform(translationX: w / 2, y: 0).scaledBy(x: close, y: 1).translatedBy(x: -w / 2, y: 0)
        }
    }

    /// Поворот с масштабом — тоже от середины кадра.
    private nonisolated static func spin(scale: CGFloat, angle: CGFloat, size: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .rotated(by: angle)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }

    /// Увеличение от середины кадра, а не от угла.
    private nonisolated static func zoom(_ scale: CGFloat, size: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }

    /// Делит цвет обратно на альфу — та же работа, что в `pack`.
    private nonisolated static func unpremultiplyBytes(_ bytes: UnsafeMutablePointer<UInt8>, count: Int) {
        var index = 0
        while index + 3 < count {
            let a = Int(bytes[index + 3])
            if a != 0 && a != 255 {
                for channel in 0..<3 {
                    let value = (Int(bytes[index + channel]) * 255 + a / 2) / a
                    bytes[index + channel] = UInt8(min(255, value))
                }
            } else if a == 0 {
                bytes[index] = 0; bytes[index + 1] = 0; bytes[index + 2] = 0
            }
            index += 4
        }
    }
}
