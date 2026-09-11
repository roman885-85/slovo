import AppKit
import SlovoCore

/// Мелочи, оставшиеся от прежних видов слайда.
///
/// Сами виды (`SlideView`, `PresetSlideView`) убраны: зал, предпросмотр и
/// трансляция рисуются `SlideDrawing` на CoreGraphics. Здесь лежит то, чем
/// пользуются другие места программы, — и лежит отдельно, чтобы это не
/// пришлось выкапывать из удалённого файла.

/// Что считать сменой слайда: сам текст, а не оформление. Смена шрифта или
/// кегля не должна запускать растворение — иначе настройка ползунком
/// превращается в мигание.
struct TextIdentity: Hashable {
    let mainText: String
    let secondaryTexts: [String]
    let reference: String

    init(slide: Slide) {
        mainText = slide.mainText
        secondaryTexts = slide.secondaryTexts
        reference = slide.reference
    }
}

extension ConstructorSample {

    /// Что стоит на слайде прямо сейчас: тот же набор строк, что показывает
    /// холст Конструктора, только не выдуманный, а настоящий.
    init(slide: Slide, songTitle: String = "",
         moduleNameFirst: String = "", moduleShortNameFirst: String = "",
         moduleNameSecond: String = "", moduleShortNameSecond: String = "") {
        self.init()
        mainText = slide.mainText
        secondaryText = slide.secondaryTexts.first ?? ""
        reference = slide.reference
        primaryReference = slide.reference
        secondaryReference = slide.secondaryTexts.isEmpty ? "" : slide.reference
        self.songTitle = songTitle
        self.moduleNameFirst = moduleNameFirst
        self.moduleShortNameFirst = moduleShortNameFirst
        self.moduleNameSecond = moduleNameSecond
        self.moduleShortNameSecond = moduleShortNameSecond
    }
}
