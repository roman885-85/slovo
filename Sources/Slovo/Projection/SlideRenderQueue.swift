import AppKit
import ImageIO
import SlovoCore

/// Картинки с диска для рисовальщика слайда — из любого потока.
///
/// `ImageCache` держит `NSImage` и живёт на главном акторе. Рисовальщик
/// теперь работает в стороне от главного потока, и ему нужен `CGImage`,
/// который можно взять откуда угодно: раскодировка через ImageIO, склад под
/// замком. Раскодированный кадр держим уже готовым — иначе каждый слайд
/// заново разжимал бы фотографию фона.
final class SlideImageStore: @unchecked Sendable {

    static let shared = SlideImageStore()

    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    /// Фонов в ходу два-три, картинок шаблона — единицы; больше держать
    /// незачем, каждая — мегабайты.
    private let limit = 16

    func image(atPath path: String) -> CGImage? {
        lock.lock()
        if let ready = images[path] { lock.unlock(); return ready }
        lock.unlock()

        let options = [kCGImageSourceShouldCache: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }

        lock.lock()
        if images.count >= limit { images.removeAll() }
        images[path] = image
        lock.unlock()
        return image
    }

    func clear() {
        lock.lock()
        images.removeAll()
        lock.unlock()
    }
}

/// Очередь отрисовки слайдов в стороне от главного потока.
///
/// Зачем. Слайд в зал рисуется размером с проектор, и текст с тенью на таком
/// холсте — это размывка большого слоя: сто миллисекунд и больше. Пока это
/// делалось на главном потоке, каждое движение ползунка в Конструкторе или
/// «Параметрах» замораживало окно на полсекунды: зал, кадр NDI, холст и
/// предпросмотр рисовались один за другим, и оператор ждал их все.
///
/// Здесь у каждого заказчика (зал, кадр NDI, холст Конструктора, предпросмотр)
/// свой ключ, и на ключ живёт не больше одного заказа в работе и одного в
/// ожидании: пришёл новый — прежний ожидающий выбрасывается. Так при
/// протяжке ползунка рисуется не каждое положение, а последнее, а главный
/// поток занят только тем, чтобы собрать заказ.
final class SlideRenderQueue: @unchecked Sendable {

    static let shared = SlideRenderQueue()

    private struct Job {
        let order: SlideDrawing.Order
        let size: CGSize
        let opaque: Bool
        let generation: Int
        let completion: @MainActor (CGImage?, Int) -> Void
    }

    /// Параллельная очередь: зал и кадр NDI рисуются одновременно на разных
    /// ядрах, а порядок внутри одного ключа держат `busy` и `pending`.
    private let queue = DispatchQueue(label: "ua.church.slovo.render", qos: .userInteractive,
                                      attributes: .concurrent)
    private let lock = NSLock()
    private var busy: Set<String> = []
    private var pending: [String: Job] = [:]

    /// Сколько кадров нарисовано и сколько заказов выброшено, не дождавшись
    /// очереди. Читает самопроверка: по ним видно, что склейка работает.
    private(set) var renderedCount = 0
    private(set) var droppedCount = 0

    /// Заказать кадр. `generation` возвращается в ответ: заказчик сверяет его
    /// со своим последним и устаревший кадр не показывает. Заказ обязан быть
    /// готов к фону: картинки в нём разрешены заранее (`Order.resolveImages`).
    func render(key: String, generation: Int, order: SlideDrawing.Order, size: CGSize, opaque: Bool,
                completion: @escaping @MainActor (CGImage?, Int) -> Void) {
        let job = Job(order: order, size: size, opaque: opaque, generation: generation, completion: completion)
        lock.lock()
        if busy.contains(key) {
            if pending[key] != nil { droppedCount += 1 }
            pending[key] = job
            lock.unlock()
            return
        }
        busy.insert(key)
        lock.unlock()
        run(key: key, job: job)
    }

    private func run(key: String, job: Job) {
        queue.async { [self] in
            let image = SlideDrawing.image(job.order, size: job.size, opaque: job.opaque)
            DispatchQueue.main.async { job.completion(image, job.generation) }
            lock.lock()
            renderedCount += 1
            if let next = pending.removeValue(forKey: key) {
                lock.unlock()
                run(key: key, job: next)
            } else {
                busy.remove(key)
                lock.unlock()
            }
        }
    }

    /// Занята ли очередь хоть чем-то — самопроверке, чтобы дождаться кадра.
    var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return busy.isEmpty && pending.isEmpty
    }
}
