import Foundation

/// Перенос авторского шаблона `.sch` в нашу преднастройку.
///
/// В конструкторе это «взять за основу»: список объектов, их рамки, цвета,
/// картинки и анимация приходят из готового шаблона VisioBible, а дальше
/// правятся и сохраняются уже своим файлом. Авторские `.sch` мы не
/// переписываем: программа-оригинал у пользователя остаётся рабочей, и её
/// шаблоны должны пережить любые наши эксперименты.
public extension SlidePreset {

    init(template: SchemeLibrary.Template,
         base: SlideStyle,
         designHeight: Double = SchemeLibrary.defaultDesignHeight) {

        let scheme = template.scheme
        let height = max(designHeight, 1)

        // Обводка в шаблоне записана в пикселях того слайда, под который её
        // подбирали; у нас она в долях высоты — делим на неё.
        let outline = scheme.outlineEnabled ? scheme.outlineWidth / height : 0

        var objects: [SlideObject] = []
        for element in scheme.elements {
            let kind = Self.kind(of: element)
            var object = SlideObject(kind: kind, text: Self.layer(for: kind, base: base))
            object.name = element.name.isEmpty ? kind.shortTitle : element.name

            if let color = element.textColor { object.text.color = color }
            object.text.outlineColor = scheme.outlineColor
            object.text.outlineWidth = outline
            // Тень объекта теперь своя у каждой сцены и приходит из его же
            // атрибутов `Shadow…Perc`. Общая для слайда `QuoteShadow…` в них
            // просто продублирована, и если оставить её ещё и в слое текста,
            // тень нарисуется дважды.
            object.text.shadowRadius = 0
            object.lineSpacing = base.lineSpacing

            if kind == .image {
                object.imagePath = template.imageURL(named: element.imageName)?.path
                object.maskPath = template.imageURL(named: element.imageMaskName)?.path
            }

            let single = Self.variant(element, .single)
            object.frame = single.frame
            object.opacity = single.opacity
            object.isVisible = single.isVisible
            object.alignment = single.alignment
            object.verticalAlignment = single.verticalAlignment
            object.shadow = single.shadow
            object.animation = single.animation

            // `Enabled` и `Enabled_2` в шаблоне самостоятельны и от
            // `EnableParamsVariant` не зависят: в «Beautiful Gold», «Beautiful
            // Orange», «Beautiful Pink» и «Beautiful Violet» линия `DownLine`
            // записана как Enabled="false" Enabled_2="true"
            // EnableParamsVariant="false" — она видна только при двух
            // переводах. Поэтому второй набор заводим и тогда, когда
            // отличается одна лишь видимость; в остальном он повторяет
            // первый, и «Сцена 2» в списке объектов остаётся «Нет».
            let dualVisible = element.placement(.dual).isEnabled
            if element.hasVariantParameters {
                object.secondVariant = Self.variant(element, .dual)
            } else if dualVisible != single.isVisible {
                var mirror = single
                mirror.isVisible = dualVisible
                object.secondVariant = mirror
            }
            objects.append(object)
        }

        var background = Background(color: base.backgroundColor,
                                    imagePath: template.backgroundURL?.path,
                                    fillMode: .fill,
                                    dim: 0)
        background.isTransparent = false

        self.init(name: scheme.name.isEmpty ? template.name : scheme.name,
                  background: background,
                  objects: objects,
                  transition: base.transition,
                  transitionDuration: base.transitionDuration)
    }

    // MARK: - Разбор одного объекта

    private static func variant(_ element: SlideScheme.Element,
                                _ scene: SlideScheme.Variant) -> ObjectVariant {
        let placement = element.placement(scene)

        let frame = ObjectFrame(x: placement.indentX / 100,
                                y: placement.indentY / 100,
                                width: placement.width / 100,
                                height: placement.height / 100,
                                anchorX: horizontal(placement.anchor.horizontal),
                                anchorY: vertical(placement.anchor.vertical))

        // Тень в шаблоне посценная: у каждого объекта есть `ShadowOffsetPerc`
        // и его двойник с хвостом `_2`. Отдельного флажка в файле нет —
        // выключенной тенью там служат нули, их и считаем выключателем.
        let shadow = ObjectShadow(isEnabled: placement.shadowOpacity > 0
                                      && (placement.shadowOffset != 0 || placement.shadowBlur > 0),
                                  offsetPercent: placement.shadowOffset,
                                  blurPercent: placement.shadowBlur,
                                  opacity: placement.shadowOpacity,
                                  color: placement.shadowColor)

        return ObjectVariant(frame: frame,
                             opacity: placement.opacity,
                             isVisible: placement.isEnabled,
                             alignment: alignment(placement.textAlignment),
                             verticalAlignment: layout(placement.textLayout),
                             shadow: shadow,
                             animation: animation(element.scene(scene)))
    }

    /// `Layout` шаблона — это Delphi `TTextLayout`: 0 верх, 1 центр, 2 низ.
    private static func layout(_ value: SlideScheme.TextLayout?) -> SlideStyle.VerticalAlignment {
        switch value {
        case .top:    return .top
        case .bottom: return .bottom
        case .center: return .center
        case nil:     return .center
        }
    }

    private static func horizontal(_ value: SlideScheme.Anchor.Horizontal) -> HorizontalAnchor {
        switch value {
        case .left:   return .left
        case .right:  return .right
        case .center: return .center
        }
    }

    /// В шаблоне вертикальная привязка только «сверху» или «снизу»:
    /// середины там нет, отступ всегда отмеряется от края.
    private static func vertical(_ value: SlideScheme.Anchor.Vertical) -> VerticalAnchor {
        value == .top ? .top : .bottom
    }

    private static func alignment(_ value: SlideScheme.TextAlignment?) -> ParagraphAlignment {
        switch value {
        case .left:   return .leading
        case .right:  return .trailing
        case .center: return .center
        case nil:     return .center
        }
    }

    /// Номера эффектов оригинала не расшифрованы, поэтому направление
    /// восстанавливаем по стартовому сдвигу `MoveFromX` / `MoveFromY`:
    /// именно он и задаёт, с какой стороны объект влетает.
    private static func animation(_ scene: SlideScheme.Scene?) -> ObjectAnimation {
        guard let scene, scene.isAnimated else { return .instant }

        let threshold = 0.001
        let sx = scene.moveFromX > threshold ? 1 : (scene.moveFromX < -threshold ? -1 : 0)
        let sy = scene.moveFromY > threshold ? 1 : (scene.moveFromY < -threshold ? -1 : 0)

        let direction = ObjectAnimation.Direction.allCases.first { candidate in
            candidate != .point
                && Int(candidate.offset.x) == sx
                && Int(candidate.offset.y) == sy
        } ?? .none

        return ObjectAnimation(direction: direction,
                               startScale: scene.isScaling ? scene.fromScale : 1,
                               startOpacity: scene.fromOpacity,
                               duration: scene.duration * 1000,
                               delay: scene.delay * 1000,
                               animatesScale: scene.isScaling,
                               animatesOpacity: scene.fromOpacity < 0.999)
    }

    /// Все четырнадцать видов объекта, а не восемь: в авторских шаблонах
    /// встречаются только восемь номеров, но принесённый со стороны шаблон
    /// (4.2.3) может содержать любой, и превращать его в пустую надпись
    /// нельзя.
    static func kind(of element: SlideScheme.Element) -> SlideObjectKind {
        switch element.kind {
        case .quote:                 return .quote
        case .secondQuote:           return .secondaryQuote
        case .reference:             return .reference
        case .firstReference:        return .primaryReference
        case .secondReference:       return .secondaryReference
        case .moduleShortNameFirst:  return .moduleShortNameFirst
        case .moduleNameFirst:       return .moduleNameFirst
        case .moduleShortNameSecond: return .moduleShortNameSecond
        case .moduleNameSecond:      return .moduleNameSecond
        case .previousPage:          return .previousPage
        case .nextPage:              return .nextPage
        case .songTitle:             return .songTitle
        case .staticText:            return .staticText
        case .decoration:            return .image
        // Незнакомый номер `Type` — скорее украшение с картинкой, чем текст;
        // если картинки нет, пусть будет надпись, которую видно и можно
        // поправить руками.
        case nil:                    return element.imageName == nil ? .staticText : .image
        }
    }

    private static func layer(for kind: SlideObjectKind, base: SlideStyle) -> SlideStyle.TextLayer {
        switch kind {
        case .quote:          return base.main
        case .secondaryQuote: return base.secondary
        default:              return base.reference
        }
    }
}
