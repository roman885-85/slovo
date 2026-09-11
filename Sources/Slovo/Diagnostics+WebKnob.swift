import AppKit
import SlovoCore

/// Замечание 6: «хаотичная, непредсказуемая и рывкообразная работа ползунков
/// в редакторе веб-страниц».
///
/// Одно движение ползунка шлёт десятки значений. Раньше каждое целиком
/// переписывало HTML страницы и тут же разбирало его заново — на большой
/// странице это и давало рывки. Теперь на трансляцию значение уходит сразу
/// (дёшево), а тяжёлая перезапись текста откладывается и склеивается.
///
/// Проверяем ровно это: гоним пачку быстрых значений, как при перетаскивании,
/// и смотрим — на трансляцию ушли все (сразу), а текст страницы за время
/// «перетаскивания» не переписан ни разу; переписался один раз, когда
/// ползунок «замер», и в нём последнее значение.
extension Diagnostics {

    static func webKnobSection(state: AppState) -> [Check] {
        let area = "Веб-редактор"
        let name = "Перетягування повзунка не смикає сторінку"
        guard let template = WebSlideTemplates.template(id: "plain") else {
            return [Check(area: area, name: name, status: .skipped, detail: "не знайшлася заготовка «plain»")]
        }

        let model = WebSlideEditorModel()
        // Своя правимая страница во временном имени — её и удалим в конце.
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
        // «Перетаскиваем»: сорок значений подряд, как за одно движение мыши.
        let steps = 40
        let started = Date()
        for i in 1...steps {
            model.change(size, to: size.text(from: Double(9 + i)))
        }
        let dragMillis = Date().timeIntervalSince(started) * 1000
        // Пока ползунок «движется», текст страницы переписываться не должен:
        // тяжёлую работу мы отложили. На трансляцию же ушли все значения.
        let rewroteDuringDrag = model.source != sourceBefore
        let broadcastsDuringDrag = broadcasts

        // Ползунок «замер» — дописываем отложенное.
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
