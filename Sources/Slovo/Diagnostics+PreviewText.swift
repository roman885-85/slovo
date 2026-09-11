import AppKit
import CoreGraphics
import SlovoCore

/// Зауваження 4 і 5: «предпросмотр путает содержимое / отстаёт на слайд».
///
/// Знімки туру показали корінь: за свого шаблону попередній перегляд малював фон
/// без жодної літери, бо тексти об'єктів брав у ЗАЛУ (`slideTexts`
/// з `liveSlide`), а не в підготовленого слайда. За вимкненого показу
/// зал порожній — і вірша в попередньому перегляді немає; за ввімкненого під
/// підготовленим віршем стояв текст того, що в залі. Тут це перевіряється за
/// пікселями: у кадрі попереднього перегляду має бути текст, і текст саме
/// підготовленого вірша, а не того, що в залі.
extension Diagnostics {

    /// Частка точок, де дві картинки одного розміру помітно розходяться.
    static func pixelDifference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data,
              let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db) else { return 1 }
        let strideA = a.bytesPerRow, strideB = b.bytesPerRow
        var differing = 0
        for y in 0..<a.height {
            let rowA = pa + y * strideA, rowB = pb + y * strideB
            for x in 0..<a.width {
                let i = x * 4
                if abs(Int(rowA[i]) - Int(rowB[i])) > 24 || abs(Int(rowA[i + 1]) - Int(rowB[i + 1])) > 24
                    || abs(Int(rowA[i + 2]) - Int(rowB[i + 2])) > 24 { differing += 1 }
            }
        }
        return Double(differing) / Double(max(1, a.width * a.height))
    }

    static func previewTextSection(state: AppState) -> [Check] {
        let area = "Передпоказ"
        let name = "У передпоказі за своїм шаблоном є текст — підготовленого вірша, а не залу"
        guard let bottom = NativeBottom.row else {
            return [Check(area: area, name: name, status: .skipped, detail: "нижнього ряду немає")]
        }
        guard let preset = state.preset(for: .preview) else {
            return [Check(area: area, name: name, status: .skipped, detail: "для передпоказу не призначено свого шаблону — шлях без шаблону малює текст шаром")]
        }
        let preview = bottom.preview
        let wasMode = state.mode
        let wasLive = state.isLive
        defer {
            state.isLive = false
            state.stepVerse(by: -1, live: false)
            state.isLive = wasLive
            state.mode = wasMode
            Signals.shared.send(.mode)
        }

        /// Кадр попереднього перегляду після того, як черга домалювала.
        func rendered() -> CGImage? {
            bottom.refreshPreview()
            wait(untilTrue: { SlideRenderQueue.shared.isIdle }, seconds: 5)
            wait(untilTrue: { false }, seconds: 0.3)
            return preview.renderedPicture
        }
        /// Еталон: той самий шаблон із даними текстами, того самого розміру в точках.
        func reference(_ texts: ConstructorSample, slide: Slide, like picture: CGImage) -> CGImage? {
            var order = SlideDrawing.Order(slide: slide, style: SlideStyle(), preset: preset, texts: texts,
                                           drawsBackground: true, clock: nil,
                                           backgroundOverride: state.previewBackgroundOverride,
                                           withSecondTranslation: !slide.secondaryTexts.isEmpty,
                                           imageURL: { [weak state] name in state?.presetImageURL(name) })
            order.resolveImages()
            return SlideDrawing.image(order, size: CGSize(width: picture.width, height: picture.height), opaque: false)
        }

        var faults: [String] = []
        var lines: [String] = []

        // 1. Показ вимкнено, вірш підготовлено: у попередньому перегляді має бути текст.
        state.isLive = false
        state.mode = .bible
        Signals.shared.send(.mode)
        state.syncSlideToMode()
        let prepared = state.slide
        guard !prepared.isBlank else {
            return [Check(area: area, name: name, status: .skipped, detail: "немає підготовленого вірша")]
        }
        if state.previewTexts.mainText != prepared.mainText { faults.append("тексти передпоказу не збігаються з підготовленим віршем") }
        guard let picture = rendered() else {
            return [Check(area: area, name: name, status: .failed, detail: "передпоказ не віддав кадру")]
        }
        guard let bare = reference(ConstructorSample(), slide: .blank, like: picture) else {
            return [Check(area: area, name: name, status: .skipped, detail: "не намалювався еталон без тексту")]
        }
        let ink = pixelDifference(picture, bare)
        lines.append(String(format: "показ вимкнено: текст займає %.1f %% кадру (%d×%d)", ink * 100, picture.width, picture.height))
        if ink < 0.005 { faults.append("при вимкненому показі передпоказ малює один фон, без вірша") }

        // 2. У залі вірш А, у попередньому перегляді підготовлено вірш Б: кадр має
        //    бути ближчим до Б, ніж до А.
        state.showCurrent()                          // А — у зал
        wait(untilTrue: { false }, seconds: 0.3)
        let hall = state.liveSlide
        state.stepVerse(by: 1, live: false)          // Б — тільки в попередній перегляд
        let next = state.slide
        guard !next.isBlank, next.mainText != hall.mainText else {
            return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                          detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; ") + "; наступний вірш не відрізняється — другу половину пропустили")]
        }
        guard let second = rendered(),
              let likeHall = reference(state.slideTextsForCheck(of: hall), slide: hall, like: second),
              let likeNext = reference(state.slideTextsForCheck(of: next), slide: next, like: second) else {
            return [Check(area: area, name: name, status: .failed, detail: "не намалювався кадр або еталони другої половини")]
        }
        let toHall = pixelDifference(second, likeHall)
        let toNext = pixelDifference(second, likeNext)
        lines.append(String(format: "у залі «%@», підготовлено «%@»: від еталона залу кадр відрізняється на %.1f %%, від еталона підготовленого — на %.1f %%",
                            String(hall.reference.prefix(14)), String(next.reference.prefix(14)), toHall * 100, toNext * 100))
        if toNext > toHall { faults.append("передпоказ показує текст із залу, а не підготовлений вірш") }
        if toNext > 0.02 { faults.append(String(format: "кадр передпоказу розходиться з еталоном підготовленого вірша на %.1f %%", toNext * 100)) }

        var checks = [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                            detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; "))]

        // 3. Зміна вкладки: у попередньому перегляді — тільки своє (зауваження 3). На
        //    вкладках показу й «Медіа» без кадру — порожньо або картинка; на
        //    «Піснях» і «Тексті» — що завгодно, крім вірша Біблії, а порожній
        //    слайд — без залишків колишнього тексту в кадрі.
        let verseText = next.mainText
        var tabLines: [String] = []
        var tabFaults: [String] = []
        func settleTab() {
            wait(untilTrue: { false }, seconds: 0.35)
            wait(untilTrue: { SlideRenderQueue.shared.isIdle }, seconds: 5)
            wait(untilTrue: { false }, seconds: 0.25)
        }
        for mode in [AppState.WorkMode.songs, .text, .media, .pictures, .presentation] {
            state.mode = mode
            Signals.shared.send(.mode)
            settleTab()
            let shown = preview.showing
            var line = "\(mode.title): \(shown.described)"
            switch mode {
            case .media, .pictures, .presentation:
                if case .slide = shown { tabFaults.append("\(mode.title): текстовий слайд"); line += " — НЕ ТАК" }
            default:
                if case .slide(let s) = shown, !verseText.isEmpty, s.mainText == verseText {
                    tabFaults.append("\(mode.title): вірш Біблії"); line += " — НЕ ТАК (вірш Біблії)"
                }
                if let picture = preview.renderedPicture,
                   let bare = reference(ConstructorSample(), slide: .blank, like: picture) {
                    let ink = pixelDifference(picture, bare)
                    line += String(format: ", тексту в кадрі %.1f %%", ink * 100)
                    if case .slide(let s) = shown, s.isBlank, ink > 0.005 {
                        tabFaults.append("\(mode.title): слайд порожній, а в кадрі лишився попередній текст"); line += " — НЕ ТАК (залишок)"
                    }
                }
            }
            tabLines.append(line)
        }
        state.mode = .bible
        Signals.shared.send(.mode)
        settleTab()
        checks.append(Check(area: area, name: "Після зміни вкладки в передпоказі лише своє",
                            status: tabFaults.isEmpty ? .ok : .failed,
                            detail: (tabFaults.isEmpty ? "" : "не так: " + tabFaults.joined(separator: "; ") + ". ")
                                + tabLines.joined(separator: " | ")))
        return checks
    }
}
