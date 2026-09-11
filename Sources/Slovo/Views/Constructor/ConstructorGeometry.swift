import AppKit
import SlovoCore

/// Что подставлять в объекты слайда, пока идёт настройка.
///
/// Оригинал показывает в конструкторе не «рыбу», а тот текст, что сейчас
/// выбран в программе: только так видно, влезает ли длинный стих и не
/// налезает ли адрес на второй перевод.
struct ConstructorSample: Hashable {
    var mainText = ""
    var secondaryText = ""
    var reference = ""
    var primaryReference = ""
    var secondaryReference = ""
    var moduleNameFirst = ""
    var moduleShortNameFirst = ""
    var moduleNameSecond = ""
    var moduleShortNameSecond = ""
    var songTitle = ""

    func text(for object: SlideObject) -> String {
        switch object.kind {
        case .quote:                 return mainText
        case .secondaryQuote:        return secondaryText
        case .reference:             return reference
        case .primaryReference:      return primaryReference
        case .secondaryReference:    return secondaryReference
        case .moduleNameFirst:       return moduleNameFirst
        case .moduleShortNameFirst:  return moduleShortNameFirst
        case .moduleNameSecond:      return moduleNameSecond
        case .moduleShortNameSecond: return moduleShortNameSecond
        case .songTitle:             return songTitle
        // Указатели страниц — это значки «есть что листать», а не текст.
        case .previousPage:          return "▲"
        case .nextPage:              return "▼"
        case .staticText:            return object.staticText
        case .image:                 return ""
        }
    }
}

/// «Предпросмотр» (6.3.6) — холст конструктора.
///
/// Выделенный объект обведён рамкой, а размер и положение меняются мышью
/// за активные зоны: по центру каждой стороны и в середине объекта. Ровно
/// эти пять зон названы в руководстве, поэтому углов здесь нет.
// MARK: - Активные зоны рамки

/// Где стоят пять активных зон рамки выделения (6.3.6).
///
/// Рамку рисуем настоящую, а маркеры разносим по раздутой: у объектов с
/// шириной «по содержимому» (указатели `Up` и `Down` во всех 22 авторских
/// шаблонах записаны как `Width="0"`) рамка выходит уже трёх маркеров подряд,
/// и левый, средний и правый сходились в одну точку — менять размер и
/// положение мышью было нечем.
///
/// Вынесено из вида отдельным типом, чтобы самопроверка могла посчитать эти
/// зоны на настоящих шаблонах, не поднимая окно.
enum ConstructorHandles {

    /// Сторона квадратика активной зоны.
    static let size: CGFloat = 9

    /// Наименьшая рамка, в которую три зоны подряд встают не впритык.
    static var minimumSpan: CGFloat { size * 3 + 8 }

    static func zones(around rect: CGRect) -> CGRect {
        let width = max(rect.width, minimumSpan)
        let height = max(rect.height, minimumSpan)
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                      width: width, height: height)
    }
}

// MARK: - Размер «по содержимому»

/// Раскрытие нулевой стороны объекта.
///
/// В шаблонах оригинала ширина «0» значит не «нет ширины», а «столько,
/// сколько нужно содержимому»: так записаны указатели `Up` и `Down` во всех
/// 22 авторских шаблонах (`<Object Name="Up" Type="2" Width="0" Height="16">`).
/// Меряем тем же шрифтом, каким объект и рисуется, — иначе рамка выделения
/// не совпадёт с тем, что видно.
enum ConstructorAutoSize {

    /// Без привязки к главному потоку: зовётся и из фоновой отрисовки слайда.
    static func size(of object: SlideObject,
                     values: ObjectVariant,
                     sample: ConstructorSample,
                     canvas: CGSize,
                     imageURL: (String?) -> URL?) -> CGSize {
        let needsWidth = values.frame.width <= 0
        let needsHeight = values.frame.height <= 0
        guard needsWidth || needsHeight, canvas.width > 0, canvas.height > 0 else { return .zero }

        if object.kind == .image {
            return imageSize(object: object, values: values, canvas: canvas, imageURL: imageURL)
        }
        return textSize(object: object, values: values, sample: sample, canvas: canvas)
    }

    private static func imageSize(object: SlideObject,
                                  values: ObjectVariant,
                                  canvas: CGSize,
                                  imageURL: (String?) -> URL?) -> CGSize {
        guard let url = imageURL(object.imagePath),
              let image = SlideImageStore.shared.image(atPath: url.path),
              image.width > 0, image.height > 0 else {
            // Картинки нет — показываем заглушку заметного размера, иначе
            // объект пропадёт с холста вместе с возможностью его выбрать.
            return CGSize(width: canvas.width * 0.1, height: canvas.height * 0.1)
        }
        let size = CGSize(width: Double(image.width), height: Double(image.height))
        let ratio = size.width / size.height
        if values.frame.height > 0 {
            let height = values.frame.height * canvas.height
            return CGSize(width: height * ratio, height: height)
        }
        if values.frame.width > 0 {
            let width = values.frame.width * canvas.width
            return CGSize(width: width, height: width / ratio)
        }
        return size
    }

    private static func textSize(object: SlideObject,
                                 values: ObjectVariant,
                                 sample: ConstructorSample,
                                 canvas: CGSize) -> CGSize {
        let content = sample.text(for: object)
        guard !content.isEmpty else {
            return CGSize(width: canvas.width * 0.06, height: canvas.height * 0.06)
        }

        // Кегль считается от высоты слайда — так же, как в `OutlinedText`.
        let points = max(object.text.fontSize * canvas.height, 1)
        let font = OutlinedText.styled(NSFont(name: object.text.fontName, size: points) ?? .systemFont(ofSize: points),
                                       bold: object.text.isBold, italic: object.text.isItalic)

        let measured = (content as NSString).size(withAttributes: [.font: font])
        // Запас на контур и тень: без него у обведённой надписи срезается край.
        let padding = points * 0.25
        return CGSize(width: measured.width + padding, height: measured.height + padding)
    }
}

extension ObjectFrame {

    /// Рамка, в которой нулевая сторона заменена измеренной.
    func resolved(auto: CGSize, in size: CGSize) -> ObjectFrame {
        guard size.width > 0, size.height > 0 else { return self }
        var frame = self
        if frame.width <= 0, auto.width > 0 { frame.width = min(auto.width / size.width, 1) }
        if frame.height <= 0, auto.height > 0 { frame.height = min(auto.height / size.height, 1) }
        return frame
    }
}

// MARK: - Обратный пересчёт рамки

extension ObjectFrame {

    /// Рамка из точек холста обратно в доли и отступы от привязки.
    ///
    /// Обратная операция к `rect(in:)`: мышь двигает прямоугольник в точках,
    /// а хранить его нужно в долях — иначе разметка развалится на другом
    /// разрешении проектора.
    init(rect: CGRect, in size: CGSize, anchorX: HorizontalAnchor, anchorY: VerticalAnchor) {
        let width = size.width > 0 ? rect.width / size.width : 0
        let height = size.height > 0 ? rect.height / size.height : 0

        let dx: CGFloat
        switch anchorX {
        case .left:   dx = rect.minX
        case .center: dx = rect.minX - (size.width - rect.width) / 2
        case .right:  dx = size.width - rect.width - rect.minX
        }

        let dy: CGFloat
        switch anchorY {
        case .top:    dy = rect.minY
        case .middle: dy = rect.minY - (size.height - rect.height) / 2
        case .bottom: dy = size.height - rect.height - rect.minY
        }

        self.init(x: size.width > 0 ? dx / size.width : 0,
                  y: size.height > 0 ? dy / size.height : 0,
                  width: width,
                  height: height,
                  anchorX: anchorX,
                  anchorY: anchorY)
    }
}
