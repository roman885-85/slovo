import AppKit
import SlovoCore

/// Зауваження 6: «хаотичная, непредсказуемая и рывкообразная работа ползунков
/// в редакторе веб-страниц».
///
/// Один рух повзунка шле десятки значень. Раніше кожне цілком
/// переписувало HTML сторінки й одразу розбирало його заново — на великій
/// сторінці це й давало ривки. Тепер на трансляцію значення йде одразу
/// (дешево), а важкий перезапис тексту відкладається й склеюється.
///
/// Перевіряємо саме це: женемо пачку швидких значень, як при перетягуванні,
/// і дивимося — на трансляцію пішли всі (одразу), а текст сторінки за час
/// «перетягування» не переписано жодного разу; переписався один раз, коли
/// повзунок «завмер», і в ньому останнє значення.
extension Diagnostics {

    static func webKnobSection(state: AppState) -> [Check] {
        let area = "Веб-редактор"
        let name = "Перетягування повзунка не смикає сторінку"
        guard let template = WebSlideTemplates.template(id: "plain") else {
            return [Check(area: area, name: name, status: .skipped, detail: "не знайшлася заготовка «plain»")]
        }

        let model = WebSlideEditorModel()
        // Своя сторінка для правки під тимчасовим ім'ям — її й видалимо наприкінці.
        let pageName = "проверка-ползунка-\(UUID().uuidString.prefix(8))"
        model.create(from: template, name: String(pageName))
        guard model.current?.isEditable == true else {
            return [Check(area: area, name: name, status: .skipped, detail: "не вдалося завести правиму сторінку")]
        }
        defer { if let page = model.current { model.delete(page) } }

        guard let size = model.sheet.knobs.first(where: { $0.name == "--sl-size" }) else {
            return [Check(area: area, name: name, status: .skipped, detail: "у заготовки немає повзунка розміру")]
        }

        var broadcasts = 0
        model.broadcast = { _ in broadcasts += 1 }

        let sourceBefore = model.source
        // «Перетягуємо»: сорок значень поспіль, як за один рух миші.
        let steps = 40
        let started = Date()
        for i in 1...steps {
            model.change(size, to: size.text(from: Double(9 + i)))
        }
        let dragMillis = Date().timeIntervalSince(started) * 1000
        // Поки повзунок «рухається», текст сторінки не має переписуватися:
        // важку роботу ми відклали. На трансляцію ж пішли всі значення.
        let rewroteDuringDrag = model.source != sourceBefore
        let broadcastsDuringDrag = broadcasts

        // Повзунок «завмер» — дописуємо відкладене.
        model.flushApply()
        let rewroteOnce = model.source != sourceBefore
        let finalValue = model.sheet.value(size)
        let wantedValue = size.text(from: Double(9 + steps))

        var faults: [String] = []
        if rewroteDuringDrag { faults.append("текст сторінки переписувався просто під час перетягування") }
        if broadcastsDuringDrag != steps { faults.append("на трансляцію пішло \(broadcastsDuringDrag) значень із \(steps) — не всі або із затримкою") }
        if !rewroteOnce { faults.append("після «завмер» текст сторінки так і не оновився") }
        if finalValue != wantedValue { faults.append("у сторінці лишилося «\(finalValue)», а чекали останнє «\(wantedValue)»") }

        let detail = faults.isEmpty
            ? String(format: "40 кроків за %.0f мс: на трансляцію пішло %d, текст переписано 1 раз, значення «%@»",
                     dragMillis, broadcastsDuringDrag, finalValue)
            : faults.joined(separator: "; ")
        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed, detail: detail)]
    }
}
