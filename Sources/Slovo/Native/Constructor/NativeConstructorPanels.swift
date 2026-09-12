import AppKit
import SlovoCore

/// Панели «Параметры» (6.3.7) и «Анимация» — на AppKit.
///
/// Порядок и формулировки повторяют форму `SlideConstructorForm`: имя,
/// разрешение сцены 2, видимость, размеры, отступы, привязки, прозрачность,
/// тень, выключка и оформление текста — или файлы картинки и маски, если
/// объект графический. Всё, что зависит от сцены, правится для той сцены,
/// что выбрана в «Отобразить для:».
///
/// Панель пересобирается на каждую смену объекта: полей три десятка, и
/// держать их живыми ради окна, которое открывают раз в месяц, незачем.
@MainActor
final class NativeConstructorPanels: NSView {

    private let model: SlideConstructorModel
    private let text: ConstructorText
    private let scroll = NSScrollView()
    private let body = Body()
    /// Что перерисовать холст — панель об этом сообщает, а не знает сама.
    var onChange: (() -> Void)?

    final class Body: NSView {
        var groups: [NativeForm.Group] = []
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            var top: CGFloat = 8
            for group in groups {
                let height = group.neededHeight
                group.frame = NSRect(x: 8, y: top, width: max(0, bounds.width - 16), height: height)
                top += height + 8
            }
            if abs(frame.height - top) > 0.5 {
                setFrameSize(NSSize(width: bounds.width, height: top + 8))
            }
        }
    }

    init(model: SlideConstructorModel, text: ConstructorText) {
        self.model = model
        self.text = text
        super.init(frame: .zero)
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        body.setFrameSize(NSSize(width: scroll.contentSize.width, height: body.frame.height))
        body.needsLayout = true
    }

    // MARK: - Сборка

    /// Перечитать значения в уже стоящих полях — когда объект тот же, а
    /// поменялось число: движение ползунка, протяжка на холсте.
    func refreshValues() {
        NativeForm.refreshValues(in: body)
    }

    func rebuild() {
        for group in body.groups { group.removeFromSuperview() }
        body.groups = []
        guard let object = model.selectedObject else {
            let empty = NativeForm.Group("", [NativeForm.Row("", [
                NativeForm.label(OurWords.t("Объект не выбран")),
            ])])
            body.groups = [empty]
            body.addSubview(empty)
            body.needsLayout = true
            return
        }

        var groups: [NativeForm.Group] = [common(object), geometry, shadowGroup]
        groups.append(object.kind == .image ? imageFiles(object) : appearance(object))
        groups.append(animation())
        body.groups = groups
        for group in groups { body.addSubview(group) }
        body.needsLayout = true
        needsLayout = true
    }

    // MARK: Имя, сцена 2, видимость

    private func common(_ object: SlideObject) -> NativeForm.Group {
        NativeForm.Group(text("Panel2", "Параметры"), [
            NativeForm.Row(text("Label31", "Имя:"), width: 120, [
                NativeForm.text(changing(model.tie(\.name, default: "")), width: 170),
            ]),
            NativeForm.Row("", [
                NativeForm.check(text("CBEnableVariant", "Разрешить сцену 2"),
                                 NativeForm.Tie(get: { [model] in model.secondSceneEnabled.get() },
                                                set: { [model, weak self] value in
                                                    model.secondSceneEnabled.set(value)
                                                    self?.changed()
                                                }),
                                 hint: text.hint("CBEnableVariant",
                                     "Активировать независимые настройки сцен для объекта (Вкл/Выкл)")),
            ]),
            NativeForm.Row(text("Label46", "Видимость:"), width: 120, [
                NativeForm.popup(SlideConstructorModel.Personalization.allCases.map {
                    text($0.languageKey, $0.fallbackTitle)
                }, NativeForm.Tie(get: { [model] in
                    SlideConstructorModel.Personalization.allCases
                        .firstIndex(of: model.personalization.get()) ?? 0
                }, set: { [model, weak self] index in
                    let all = SlideConstructorModel.Personalization.allCases
                    guard all.indices.contains(index) else { return }
                    model.personalization.set(all[index])
                    self?.changed()
                }), width: 170),
            ]),
        ])
    }

    // MARK: Размеры, отступы, привязки, прозрачность

    private var geometry: NativeForm.Group {
        NativeForm.Group(OurWords.t("Размеры и место"), [
            percentRow(text("Label17", "Ширина:"), \.frame.width, 0, range: 0...400),
            percentRow(text("Label18", "Высота:"), \.frame.height, 0, range: 0...400),
            // Отступ бывает и отрицательным: объект специально уводят за
            // край, чтобы из-за него выглядывала только часть украшения.
            percentRow(text("Label19", "Отст. X:"), \.frame.x, 0, range: -200...200),
            percentRow(text("Label20", "Отст. Y:"), \.frame.y, 0, range: -200...200),
            NativeForm.Row(text("Label21", "Привязка по X:"), width: 120, [
                NativeForm.popup([text("AlignXText0", "Левая"), text("AlignXText2", "Центр"),
                                  text("AlignXText1", "Правая")],
                                 anchorTie(\.frame.anchorX,
                                           values: [.left, .center, .right], fallback: .center),
                                 width: 150),
            ]),
            // У автора вертикальная привязка ровно двузначная: в `.sch` это
            // один бит поля `Align`, третьего значения там не выразить.
            NativeForm.Row(text("Label22", "Привязка по Y:"), width: 120, [
                NativeForm.popup([text("AlignYObjText0", "Верх"), text("AlignYObjText1", "Низ")],
                                 anchorTie(\.frame.anchorY, values: [.top, .bottom], fallback: .top),
                                 width: 150),
            ]),
            // Прозрачность у автора — байт 0…255, а не проценты.
            NativeForm.Row(text("Label23", "Прозрачность:"), width: 120, [
                NativeForm.slider(scaledTie(\.opacity, default: 1, by: 255), range: 0...255,
                                  format: { String(Int($0)) }, width: 130),
            ]),
        ])
    }

    // MARK: Тень

    /// Заголовок группы — сама галочка «Тень» (CBObjShadowActive): у автора
    /// над этими строками нет отдельной подписи, а `Label32` в его форме —
    /// знак процента у соседнего поля, и в украинском переводе группа
    /// называлась «%».
    private var shadowGroup: NativeForm.Group {
        NativeForm.Group("", [
            NativeForm.Row("", [
                NativeForm.check(text("CBObjShadowActive", "Тень"),
                                 changing(model.sceneTie(\.shadow.isEnabled, default: false))),
            ]),
            // Заготовки м'якості: цілими відсотками тінь виходила або
            // непомітною, або різкою плямою — власник просив «м'якше й
            // різноманітніше». Кнопка ставить усі чотири числа разом, а
            // довести до свого смаку можна повзунками нижче.
            NativeForm.Row(OurWords.t("Заготовка:"), width: 120, [
                shadowPreset("Без тени", offset: 0, blur: 0, opacity: 1, on: false),
                shadowPreset("Лёгкая", offset: 1.5, blur: 8, opacity: 0.45),
                shadowPreset("Мягкая", offset: 2.7, blur: 14, opacity: 0.6),
                shadowPreset("Глубокая", offset: 4.5, blur: 20, opacity: 0.8),
            ]),
            // Дробові десяті: на кеглі 60 пт один відсоток — це більше за
            // півпункту, і «на волосину м'якше» цілими не набиралося.
            NativeForm.Row(text("Label33", "Смещение (%):"), width: 120, [
                NativeForm.slider(doubleTie(\.shadow.offsetPercent, default: 2.7), range: -20...20,
                                  format: { String(format: "%.1f", $0) }, width: 130),
                NativeForm.decimal(doubleTie(\.shadow.offsetPercent, default: 2.7),
                                   range: -50...50, step: 0.1, width: 60),
            ]),
            NativeForm.Row(text("Label34", "Сглаживание(%):"), width: 120, [
                NativeForm.slider(doubleTie(\.shadow.blurPercent, default: 3), range: 0...40,
                                  format: { String(format: "%.1f", $0) }, width: 130),
                NativeForm.decimal(doubleTie(\.shadow.blurPercent, default: 3),
                                   range: 0...60, step: 0.1, width: 60),
            ]),
            NativeForm.Row(OurWords.t("Направление:"), width: 120, [
                NativeForm.slider(doubleTie(\.shadow.angleDegrees, default: 45), range: 0...360,
                                  format: { Self.direction($0) }, width: 130),
            ]),
            NativeForm.Row(text("Label35", "Прозрачность:"), width: 120, [
                NativeForm.slider(scaledTie(\.shadow.opacity, default: 1, by: 255), range: 0...255,
                                  format: { String(Int($0)) }, width: 130),
            ]),
            NativeForm.Row(text("Label42", "Цвет:"), width: 120, [
                NativeForm.colour(changing(model.sceneTie(\.shadow.color, default: .black))),
            ]),
        ])
    }

    /// Стрілка й градуси: «↘ 45°». Куди саме падає тінь, числом не видно.
    private static func direction(_ degrees: Double) -> String {
        let arrows = ["→", "↘", "↓", "↙", "←", "↖", "↑", "↗"]
        let index = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360) / 45).rounded()) % 8
        return arrows[index] + " " + String(Int(degrees.rounded())) + "°"
    }

    /// Кнопка заготовки тіні.
    private func shadowPreset(_ title: String, offset: Double, blur: Double,
                              opacity: Double, on: Bool = true) -> NSView {
        NativeForm.button(OurWords.t(title), hint: nil) { [weak self] in
            guard let self else { return }
            model.sceneTie(\.shadow.isEnabled, default: false).set(on)
            if on {
                model.sceneTie(\.shadow.offsetPercent, default: 2.7).set(offset)
                model.sceneTie(\.shadow.blurPercent, default: 7).set(blur)
                model.sceneTie(\.shadow.opacity, default: 1).set(opacity)
            }
            changed()
            rebuild()
        }
    }

    // MARK: Выключка и текст

    private func appearance(_ object: SlideObject) -> NativeForm.Group {
        // Список семей — тот же, что был в панели: все шрифты системы.
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        return NativeForm.Group(OurWords.t("Текст"), [
            NativeForm.Row(text("Label36", "Выравн. по X:"), width: 120, [
                NativeForm.popup([text("AlignXText0", "Левая"), text("AlignXText2", "Центр"),
                                  text("AlignXText1", "Правая")],
                                 anchorTie(\.alignment, values: [.leading, .center, .trailing],
                                           fallback: .center), width: 150),
            ]),
            NativeForm.Row(text("Label37", "Выравн. по Y:"), width: 120, [
                NativeForm.popup([text("AlignYText0", "Верх"), text("AlignYText1", "Центр"),
                                  text("AlignYText2", "Низ")],
                                 anchorTie(\.verticalAlignment, values: [.top, .center, .bottom],
                                           fallback: .center), width: 150),
            ]),
            NativeForm.Row(OurWords.t("Шрифт:"), width: 120, [
                NativeForm.popup(families, NativeForm.Tie(get: { [model] in
                    families.firstIndex(of: model.selectedObject?.text.fontName ?? "") ?? 0
                }, set: { [model, weak self] index in
                    guard families.indices.contains(index) else { return }
                        model.tie(\.text.fontName, default: "").set(families[index])
                    self?.changed()
                }), width: 170),
            ]),
            NativeForm.Row(OurWords.t("Размер:"), width: 120, [
                NativeForm.number(objectPercent(\.text.fontSize, default: 0.06), range: 1...40),
            ]),
            NativeForm.Row("", [
                NativeForm.check(text("JvgSBObjBold", "Ж"),
                                 changing(model.tie(\.text.isBold, default: false))),
                NativeForm.check(text("JvgSBObjItalik", "К"),
                                 changing(model.tie(\.text.isItalic, default: false))),
                NativeForm.check(text("JvgSBObjUnderline", "Ч"),
                                 changing(model.tie(\.isUnderlined, default: false))),
            ]),
            NativeForm.Row(text("Label40", "Текст:"), width: 120, [
                NativeForm.colour(changing(model.tie(\.text.color, default: .white))),
            ]),
            NativeForm.Row("", [
                NativeForm.check(text("CBObjOutLineActive", "Контур"),
                                 changing(model.tie(\.text.isOutlined, default: false))),
                NativeForm.colour(changing(model.tie(\.text.outlineColor, default: .black))),
            ]),
            // В пунктах кадра высотой 1080, как QuoteOutLineWidth у автора
            // (2,25; 1,5): целые проценты высоты давали шаг в 11 пикселей.
            NativeForm.Row(text("Label39", "Толщина контура:") + " " + OurWords.t("(пт)"), width: 120, [
                NativeForm.slider(objectPoints(\.text.outlineThickness, default: 0.004), range: 0...20,
                                  format: { String(format: "%.2f", $0) }, width: 130),
                NativeForm.decimal(objectPoints(\.text.outlineThickness, default: 0.004),
                                   range: 0...60, step: 0.25, width: 60),
            ]),
            // Напівпрозорий контур — те саме «м'якше»: літера дістає межу, але
            // не обведення тушшю. Прозорість лежить у самому кольорі контуру.
            NativeForm.Row(OurWords.t("Прозрачность контура:"), width: 120, [
                NativeForm.slider(outlineAlpha(), range: 0...255,
                                  format: { String(Int($0)) }, width: 130),
            ]),
        ])
    }

    // MARK: Картинка и маска

    private func imageFiles(_ object: SlideObject) -> NativeForm.Group {
        NativeForm.Group(OurWords.t("Изображение"), [
            fileRow(text("Label15", "Имя файла изображения:"), path: object.imagePath) {
                [model, weak self] url in
                model.tie(\.imagePath, default: nil as String?).set(url?.path)
                self?.changed()
            },
            fileRow(text("Label16", "Имя файла маски:"), path: object.maskPath) {
                [model, weak self] url in
                model.tie(\.maskPath, default: nil as String?).set(url?.path)
                self?.changed()
            },
        ])
    }

    private func fileRow(_ title: String, path: String?,
                         apply: @escaping (URL?) -> Void) -> NSView {
        let name = NativeForm.label(path.map { URL(fileURLWithPath: $0).lastPathComponent }
                                    ?? text("TextMessages10", "Нет"))
        return NativeForm.Row(title, width: 170, [
            name,
            NativeForm.button("…") { [weak self] in
                guard let url = self?.model.chooseImageFile(message: title) else { return }
                apply(url)
                name.stringValue = url.lastPathComponent
            },
            NativeForm.button("✕") {
                apply(nil)
                name.stringValue = "—"
            },
        ])
    }

    // MARK: Анимация

    private func animation() -> NativeForm.Group {
        let directions = ObjectAnimation.Direction.allCases
        return NativeForm.Group(text("Panel5", "Анимация"), [
            NativeForm.Row("", [
                NativeForm.check(text("CBAnimEnabl", "Включить"),
                                 NativeForm.Tie(get: { [model] in
                                     model.selectedValues?.animation.isAnimated ?? false
                                 }, set: { [model, weak self] value in
                                     // Выключенная анимация — это «никуда не
                                     // летит, не растёт и не проявляется».
                                     // Длительность и задержку не стираем:
                                     // человек выключил показ на пробу, а не
                                     // отказался от подобранных чисел.
                                     guard let object = model.selectedObject else { return }
                                     var values = object.values(in: model.scene)
                                     if value {
                                         if values.animation.duration <= 0 { values.animation.duration = 350 }
                                         if values.animation.direction == .none
                                             && !values.animation.animatesScale
                                             && !values.animation.animatesOpacity {
                                             values.animation.animatesOpacity = true
                                         }
                                     } else {
                                         values.animation.direction = .none
                                         values.animation.animatesScale = false
                                         values.animation.animatesOpacity = false
                                     }
                                     model.setSelectedValues(values)
                                     self?.changed()
                                 })),
            ]),
            NativeForm.Row(text("Label24", "Перемещение:"), width: 120, [
                NativeForm.popup(directions.enumerated().map { index, item in
                    text("FXDirectText\(index)", item.title)
                }, NativeForm.Tie(get: { [model] in
                    directions.firstIndex(of: model.selectedValues?.animation.direction ?? .none) ?? 0
                }, set: { [model, weak self] index in
                    guard directions.indices.contains(index) else { return }
                    model.sceneTie(\.animation.direction, default: .none).set(directions[index])
                    self?.changed()
                }), width: 150),
            ]),
            NativeForm.Row(text("Label2", "Отст. X:"), width: 120, [
                NativeForm.number(percentTie(\.animation.pointX, default: 0.5), range: -200...200),
            ]),
            NativeForm.Row(text("Label4", "Отст. Y:"), width: 120, [
                NativeForm.number(percentTie(\.animation.pointY, default: 0.5), range: -200...200),
            ]),
            NativeForm.Row("", [
                NativeForm.check(text("CBFXScale", "Масштаб"),
                                 changing(model.sceneTie(\.animation.animatesScale, default: false))),
                NativeForm.check(text("CBFXOpacity", "Прозрачность"),
                                 changing(model.sceneTie(\.animation.animatesOpacity, default: false))),
            ]),
            NativeForm.Row(text("Label6", "Начальный:"), width: 120, [
                NativeForm.number(percentTie(\.animation.startScale, default: 1), range: 0...400),
            ]),
            NativeForm.Row(text("Label8", "Начальная:"), width: 120, [
                NativeForm.number(scaledIntTie(\.animation.startOpacity, default: 0, by: 255),
                                  range: 0...255),
            ]),
            NativeForm.Row(text("Label9", "Длительность:"), width: 120, [
                NativeForm.number(intTie(\.animation.duration, default: 0), range: 0...10000),
                NativeForm.label(text("Label10", "мс")),
            ]),
            NativeForm.Row(text("Label11", "Задержка:"), width: 120, [
                NativeForm.number(intTie(\.animation.delay, default: 0), range: 0...10000),
                NativeForm.label(text("Label12", "мс")),
            ]),
        ])
    }

    // MARK: - Связки

    private func changed() {
        onChange?()
    }

    /// Та же связка, но с перерисовкой холста после записи.
    private func changing<Value>(_ tie: NativeForm.Tie<Value>) -> NativeForm.Tie<Value> {
        NativeForm.Tie(get: tie.get, set: { [weak self] value in
            tie.set(value)
            self?.changed()
        })
    }

    /// Доля холста в поле процентов — так их показывает автор.
    private func percentRow(_ title: String, _ path: WritableKeyPath<ObjectVariant, Double>,
                            _ fallback: Double, range: ClosedRange<Int>) -> NSView {
        NativeForm.Row(title, width: 120, [
            NativeForm.number(percentTie(path, default: fallback), range: range),
        ])
    }

    private func percentTie(_ path: WritableKeyPath<ObjectVariant, Double>,
                            default fallback: Double) -> NativeForm.Tie<Int> {
        let tie = model.sceneTie(path, default: fallback)
        return NativeForm.Tie(get: { Int((tie.get() * 100).rounded()) },
                              set: { [weak self] value in
                                  tie.set(Double(value) / 100)
                                  self?.changed()
                              })
    }

    /// Доля высоты ↔ пункты кадра 1080: так думает и автор, и владелец.
    private func objectPoints(_ path: WritableKeyPath<SlideObject, Double>,
                              default fallback: Double) -> NativeForm.Tie<Double> {
        let tie = model.tie(path, default: fallback)
        return NativeForm.Tie(get: { (tie.get() * 1080 * 4).rounded() / 4 },
                              set: { [weak self] value in
                                  tie.set(value / 1080)
                                  self?.changed()
                              })
    }

    private func objectPercent(_ path: WritableKeyPath<SlideObject, Double>,
                               default fallback: Double) -> NativeForm.Tie<Int> {
        let tie = model.tie(path, default: fallback)
        return NativeForm.Tie(get: { Int((tie.get() * 100).rounded()) },
                              set: { [weak self] value in
                                  tie.set(Double(value) / 100)
                                  self?.changed()
                              })
    }

    private func intTie(_ path: WritableKeyPath<ObjectVariant, Double>,
                        default fallback: Double) -> NativeForm.Tie<Int> {
        let tie = model.sceneTie(path, default: fallback)
        return NativeForm.Tie(get: { Int(tie.get().rounded()) },
                              set: { [weak self] value in
                                  tie.set(Double(value))
                                  self?.changed()
                              })
    }

    private func scaledTie(_ path: WritableKeyPath<ObjectVariant, Double>,
                           default fallback: Double, by scale: Double) -> NativeForm.Tie<Double> {
        let tie = model.sceneTie(path, default: fallback)
        return NativeForm.Tie(get: { tie.get() * scale },
                              set: { [weak self] value in
                                  tie.set(value / scale)
                                  self?.changed()
                              })
    }

    /// Прозорість контуру живе в альфі його ж кольору: окремого поля для неї
    /// в оригіналі немає, а малюють контур саме кольором.
    private func outlineAlpha() -> NativeForm.Tie<Double> {
        let tie = model.tie(\.text.outlineColor, default: SlideStyle.RGBA.black)
        return NativeForm.Tie(get: { tie.get().alpha * 255 },
                              set: { [weak self] value in
                                  var colour = tie.get()
                                  colour.alpha = min(max(value / 255, 0), 1)
                                  tie.set(colour)
                                  self?.changed()
                              })
    }

    private func doubleTie(_ path: WritableKeyPath<ObjectVariant, Double>,
                           default fallback: Double) -> NativeForm.Tie<Double> {
        scaledTie(path, default: fallback, by: 1)
    }

    private func scaledIntTie(_ path: WritableKeyPath<ObjectVariant, Double>,
                              default fallback: Double, by scale: Double) -> NativeForm.Tie<Int> {
        let tie = model.sceneTie(path, default: fallback)
        return NativeForm.Tie(get: { Int((tie.get() * scale).rounded()) },
                              set: { [weak self] value in
                                  tie.set(Double(value) / scale)
                                  self?.changed()
                              })
    }

    private func anchorTie<Value: Equatable>(_ path: WritableKeyPath<ObjectVariant, Value>,
                                             values: [Value], fallback: Value) -> NativeForm.Tie<Int> {
        let tie = model.sceneTie(path, default: fallback)
        return NativeForm.Tie(get: { values.firstIndex(of: tie.get()) ?? 0 },
                              set: { [weak self] index in
                                  guard values.indices.contains(index) else { return }
                                  tie.set(values[index])
                                  self?.changed()
                              })
    }
}
