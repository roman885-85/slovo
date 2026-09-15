import AppKit
import SlovoCore

/// Панелі інструментів Пісенника і всі меню правої кнопки.
///
/// Винесено з робочої області окремо навмисно: кнопок і пунктів тут під
/// сотню, і тримати їх упереміш зі списками — значить потім шукати серед них
/// розкладку. Тут лише склад і підписи; усе, що вони роблять, робить
/// `SongEditorModel` — та сама модель, що й у колишньому вікні.
extension NativeSongsWorkspace {

    // MARK: - Кнопки

    /// Кнопка панелі: значок, підказка, дія.
    func button(_ symbol: String, _ hint: String,
                _ action: @escaping () -> Void) -> NativeSongButton {
        NativeSongButton(symbol: symbol, hint: hint, action: action)
    }

    /// Кнопка, що відкриває меню.
    func menuButton(_ symbol: String, _ hint: String,
                    _ menu: @escaping () -> NSMenu) -> NativeSongButton {
        let button = NativeSongButton(symbol: symbol, hint: hint)
        button.menuBuilder = menu
        return button
    }

    /// Порожнє меню, яке НЕ вмикає пункти саме.
    ///
    /// Без цього `NSMenu` перед показом питає ціль кожного пункту, та
    /// мовчить, і AppKit вмикає все підряд: «Видалити групу» була б жива і
    /// тоді, коли груп немає зовсім.
    func emptyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    /// Пункт меню із замиканням. Ціль пункту тримає сам пункт: меню будується
    /// в мить клацання і живе до його закриття.
    func item(_ title: String, enabled: Bool = true,
              _ action: @escaping () -> Void) -> NSMenuItem {
        // Амперсанд підкреслення («&Удалить») з підписів меню прибирається —
        // в автора ним позначено швидку літеру Windows.
        let item = NSMenuItem(title: title.replacingOccurrences(of: "&", with: ""),
                              action: #selector(NativeSongMenuAction.fire), keyEquivalent: "")
        let target = NativeSongMenuAction(action)
        item.target = target
        item.representedObject = target
        item.isEnabled = enabled
        return item
    }

    /// Пункт меню з поясненням, що саме він бере (формат файла).
    func hinted(_ item: NSMenuItem, _ hint: String) -> NSMenuItem {
        item.toolTip = hint
        return item
    }

    /// Підменю з готовою назвою.
    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = emptyMenu()
        for item in items { menu.addItem(item) }
        let head = NSMenuItem(title: title.replacingOccurrences(of: "&", with: ""),
                              action: nil, keyEquivalent: "")
        head.submenu = menu
        return head
    }

    // MARK: - Панель інструментів Пісенника (30)

    /// Зібрати панель (30). У режимі перегляду на ній дві кнопки і меню, у
    /// режимі правки — три і меню: «панель инструментов меняет внешний вид и
    /// функциональность» (5.3.9).
    func buildHeader() {
        // Під який режим зібрано панель — за цим і вирішують, чи треба її
        // перезбирати. Пишемо тут, а не в того, хто кличе: панель збирають
        // ще й на зміні мови, і там ознака б роз'їхалася.
        builtEditing = model.isEditing
        var buttons: [NativeSongButton] = []
        if model.isEditing {
            buttons.append(button("eye", hint("TBViewMode", "Перейти в режим просмотра")) { [weak self] in
                self?.model.leaveEditMode()
                self?.bridge.sync()
            })
            buttons.append(button("square.and.pencil",
                                  hint("TBParamEdit", "Редактировать атрибуты Песенника")) { [weak self] in
                self?.model.openBookAttributes(editable: true)
                self?.bridge.sync()
            })
            let save = button("square.and.arrow.down",
                              hint("TBSave", "Сохранить Песенник (Ctrl+S)")) { [weak self] in
                self?.model.save()
                self?.bridge.sync()
            }
            // «Кнопка становится активной после любых изменений Песенника».
            save.isEnabled = model.isModified
            saveButton = save
            buttons.append(save)
        } else {
            buttons.append(button("pencil", hint("TBEditMode", "Перейти в режим редактирования")) { [weak self] in
                self?.model.enterEditMode()
                self?.bridge.sync()
            })
            buttons.append(button("info.circle", hint("TBParamShow", "Атрибуты Песенника")) { [weak self] in
                self?.model.openBookAttributes(editable: false)
                self?.bridge.sync()
            })
            saveButton = nil
        }

        let manage = menuButton("books.vertical", hint("TBNewModule", "Песенник...")) { [weak self] in
            self?.manageMenu() ?? NSMenu()
        }
        var items: [NativeSongToolStrip.Item] = buttons.map { .button($0) }
        items.append(.divider)
        items.append(.button(manage))

        mainButtons = buttons
        header.toolbar.install(items)
        header.toolbarWidth = CGFloat(buttons.count + 1) * (NativeSongButton.size.width + 1) + 18
        header.tabs.onSelect = { [weak self] id in self?.selectBook(id: id) }
        header.tabs.onMenu = { [weak self] id in self?.bookTabMenu(id: id) }
    }

    /// (30.3) «Вызывает меню для управления Песенниками».
    private func manageMenu() -> NSMenu {
        let menu = emptyMenu()
        menu.addItem(item(caption("NNewModule", "Создать новый Песенник")) { [weak self] in
            self?.model.createBook()
            self?.bridge.sync()
        })
        menu.addItem(item(caption("NCopySongsToEnotherModule", "Скопировать песни в другой Песенник"),
                          enabled: model.hasBook) { [weak self] in
            self?.model.openCopySongs()
            self?.bridge.sync()
        })
        menu.addItem(.separator())
        menu.addItem(submenu(caption("OpenImportDialog", "Импортировать Песенник из..."), [
            hinted(item(caption("NImportModuleBQ", "Импортировать из BibleQuote модуля")) { [weak self] in
                self?.model.importBibleQuote()
                self?.bridge.sync()
            }, OurWords.t("Модуль-песенник «Цитата из Библии»: папка с bibleqt.ini")),
            hinted(item(caption("NImportModuleSoftProject", "Импортировать из SoftProjector модуля")) { [weak self] in
                self?.model.importSoftProjector()
                self?.bridge.sync()
            }, OurWords.t("Песенник SoftProjector: файл .sps")),
        ]))
        menu.addItem(hinted(item(caption("NImportModuleFromText", "Импортировать Песенник из текстового файла"),
                          enabled: model.hasBook) { [weak self] in
            self?.model.importFromTextFile()
            self?.bridge.sync()
        }, OurWords.t("Текстовый файл .txt в том виде, в каком его выгружает «Экспортировать Песенник в текстовый файл»")))
        menu.addItem(item(caption("NExportModuleAsText", "Экспортировать Песенник в текстовый файл"),
                          enabled: model.hasBook) { [weak self] in
            self?.model.exportToTextFile()
        })
        return menu
    }

    // MARK: - Панелі правки над списками (5.3.9.2)

    /// Зібрати три панелі правки.
    ///
    /// Вони стоять над списками завжди, а видно їх лише в режимі
    /// редагування: ховати треба вид, а не перезбирати по десятку кнопок
    /// на кожне перемикання режиму.
    func buildStrips() {
        groupButtons = [:]
        songButtons = [:]
        partButtons = [:]

        groupStrip.install([
            .button(group("add", "plus", hint("TBAddGroup", "Создать новую группу")) { [weak self] in
                self?.model.addGroup(); self?.bridge.sync()
            }),
            .button(group("del", "trash", hint("TBDelGroup", "Удалить группу")) { [weak self] in
                self?.model.deleteGroup(); self?.bridge.sync()
            }),
            .button(group("dup", "doc.on.doc", hint("TBCopyGroup", "Дублировать группу")) { [weak self] in
                self?.model.duplicateGroup(); self?.bridge.sync()
            }),
            .button(group("edit", "pencil", hint("TBChangeGroup", "Изменить атрибуты группы")) { [weak self] in
                self?.model.renameGroup(); self?.bridge.sync()
            }),
            .divider,
            .button(group("up", "arrow.up", hint("TBUpGroup", "Переместить выше")) { [weak self] in
                self?.model.moveGroup(by: -1); self?.bridge.sync()
            }),
            .button(group("down", "arrow.down", hint("TBDownGroup", "Переместить ниже")) { [weak self] in
                self?.model.moveGroup(by: 1); self?.bridge.sync()
            }),
        ])

        let sort = menuButton("arrow.up.arrow.down", hint("TBSongsSort", "Сортировка")) { [weak self] in
            self?.sortMenu() ?? NSMenu()
        }
        songButtons["sort"] = sort
        songStrip.install([
            .button(song("add", "plus", hint("TBNewSong", "Создать новую песню")) { [weak self] in
                self?.model.addSong(); self?.bridge.sync()
            }),
            .button(song("del", "trash", hint("TBDelSong", "Удалить песню")) { [weak self] in
                self?.model.deleteSong(); self?.bridge.sync()
            }),
            .button(song("dup", "doc.on.doc", hint("TBCopySong", "Дублировать песню")) { [weak self] in
                self?.model.duplicateSong(); self?.bridge.sync()
            }),
            .button(song("edit", "pencil", hint("TBChangeSong", "Изменить атрибуты и текст песни")) { [weak self] in
                self?.model.openSongAttributes(editable: true); self?.bridge.sync()
            }),
            .divider,
            .button(song("up", "arrow.up", hint("TBUpSong", "Переместить выше")) { [weak self] in
                self?.model.moveSong(by: -1); self?.bridge.sync()
            }),
            .button(song("down", "arrow.down", hint("TBDownSong", "Переместить ниже")) { [weak self] in
                self?.model.moveSong(by: 1); self?.bridge.sync()
            }),
            .button(song("position", "number", hint("TBSetNumSong", "Установить новую позицию песни")) { [weak self] in
                self?.model.setSongPosition(); self?.bridge.sync()
            }),
            .divider,
            .button(sort),
        ])

        let format = menuButton("textformat", hint("TBFormat", "Форматирование текста")) { [weak self] in
            self?.partFormatMenu() ?? NSMenu()
        }
        partButtons["format"] = format
        partStrip.install([
            .button(part("add", "plus", hint("TBNewBody", "Создать новую часть песни (Ins)")) { [weak self] in
                self?.model.addPart(); self?.bridge.sync()
            }),
            .button(part("del", "trash", hint("TBDelBody", "Удалить часть песни (Del)")) { [weak self] in
                self?.model.deletePart(); self?.bridge.sync()
            }),
            .button(part("dup", "doc.on.doc", hint("TBCopyBody", "Дублировать часть песни (Shift+Ins)")) { [weak self] in
                self?.model.duplicatePart(); self?.bridge.sync()
            }),
            .button(part("edit", "pencil",
                         hint("TBChangeBody", "Изменить содержимое части песни (Ctrl+Enter)")) { [weak self] in
                self?.model.openPartEditor(); self?.bridge.sync()
            }),
            .divider,
            .button(part("up", "arrow.up", hint("TBUpBody", "Переместить выше")) { [weak self] in
                self?.model.movePart(by: -1); self?.bridge.sync()
            }),
            .button(part("down", "arrow.down", hint("TBDownBody", "Переместить ниже")) { [weak self] in
                self?.model.movePart(by: 1); self?.bridge.sync()
            }),
            .divider,
            // Кнопки (9)–(12) у порядку посібника: за умовчанням, вліво,
            // по центру, вправо.
            .button(part("align0", "text.justify", hint("TBAlignDefault", "Выравнивание по умолчанию")) { [weak self] in
                self?.model.setAlign(.default); self?.bridge.sync()
            }),
            .button(part("align1", "text.alignleft", hint("TBAlignLeft", "Выравнивание по левому краю")) { [weak self] in
                self?.model.setAlign(.left); self?.bridge.sync()
            }),
            .button(part("align2", "text.aligncenter", hint("TBAlignCenter", "Выравнивание по центру")) { [weak self] in
                self?.model.setAlign(.center); self?.bridge.sync()
            }),
            .button(part("align3", "text.alignright", hint("TBAlignRight", "Выравнивание по правому краю")) { [weak self] in
                self?.model.setAlign(.right); self?.bridge.sync()
            }),
            .divider,
            .button(format),
            .button(part("unformat", "arrow.uturn.left", hint("TBUnformat", "Отмена форматирования")) { [weak self] in
                self?.model.unformatPart(); self?.bridge.sync()
            }),
        ])
    }

    private func group(_ name: String, _ symbol: String, _ hint: String,
                       _ action: @escaping () -> Void) -> NativeSongButton {
        let made = button(symbol, hint, action)
        groupButtons[name] = made
        return made
    }

    private func song(_ name: String, _ symbol: String, _ hint: String,
                      _ action: @escaping () -> Void) -> NativeSongButton {
        let made = button(symbol, hint, action)
        songButtons[name] = made
        return made
    }

    private func part(_ name: String, _ symbol: String, _ hint: String,
                      _ action: @escaping () -> Void) -> NativeSongButton {
        let made = button(symbol, hint, action)
        partButtons[name] = made
        return made
    }

    /// Кнопка (8): «Сортировка возможна по номеру и по названию».
    private func sortMenu() -> NSMenu {
        let menu = emptyMenu()
        menu.addItem(item(caption("NSortByNum", "По Номеру")) { [weak self] in
            self?.model.sortSongs(.byNumber); self?.bridge.sync()
        })
        menu.addItem(item(caption("NSortByLiter", "По Названию")) { [weak self] in
            self?.model.sortSongs(.byTitle); self?.bridge.sync()
        })
        return menu
    }

    /// Кнопка (13) — «меню форматирования текста выделенной части песни».
    private func partFormatMenu() -> NSMenu {
        let menu = emptyMenu()
        menu.addItem(item(caption("NFormatByLiters", "Разбиение по Заглавным Буквам"),
                          enabled: model.hasPart) { [weak self] in
            self?.model.formatPart(.byLiters); self?.bridge.sync()
        })
        menu.addItem(item(caption("NFormatByOptimalSize", "Оптимальное размещение на экране"),
                          enabled: model.hasPart) { [weak self] in
            self?.model.formatPart(.byOptimalSize); self?.bridge.sync()
        })
        return menu
    }

    // MARK: - Режим правки

    /// Показати або сховати панелі правки і погасити кнопки, яким нема чого
    /// робити. Роботи тут на два десятки присвоєнь, і йде вона на зміну
    /// режиму, а не на вибір куплета.
    func applyEditMode() {
        let editing = model.isEditing
        groupColumn?.setVisible(editing, at: 1)
        songColumn?.setVisible(editing, at: 1)
        partColumn?.setVisible(editing, at: 1)

        for (name, button) in groupButtons {
            button.isEnabled = name == "add" || model.hasGroup
        }
        for (name, button) in songButtons {
            button.isEnabled = name == "add" || name == "sort" || model.hasSong
        }
        for (name, button) in partButtons {
            if name.hasPrefix("align") {
                button.isEnabled = model.hasPart
                button.isOn = model.hasPart && align(named: name) == model.currentAlign
            } else {
                button.isEnabled = name == "add" ? model.hasSong : model.hasPart
            }
        }
        for button in mainButtons where button !== saveButton {
            button.isEnabled = model.hasBook
        }
        saveButton?.isEnabled = model.isModified
        header.isModified = model.isModified
    }

    private func align(named name: String) -> SongPartAlign {
        switch name {
        case "align1": return .left
        case "align2": return .center
        case "align3": return .right
        default:       return .default
        }
    }

    // MARK: - Меню правої кнопки

    /// Меню вкладки Пісенника (33) — 5.3.7. Пункти ті самі, що й у вкладки
    /// перекладу, і лежать вони прямо в `MainForm`: своїх ключів у пісенника немає.
    func bookTabMenu(id: String) -> NSMenu? {
        guard let entry = state?.songLibrary?.entry(id) else { return nil }
        let menu = emptyMenu()
        menu.addItem(item(mark(longBookNames) + captions.mainForm("N_LongName", "Длинное название")) { [weak self] in
            self?.setLongBookNames(true)
        })
        menu.addItem(item(mark(!longBookNames) + captions.mainForm("N_ShortName", "Короткое название")) { [weak self] in
            self?.setLongBookNames(false)
        })
        menu.addItem(.separator())
        menu.addItem(item(captions.mainForm("NReloadModule", "Перезагрузить модуль")) { [weak self] in
            // Перечитуємо саме той Пісенник, по вкладці якого клацнули:
            // спершу робимо його поточним, потім читаємо файл.
            guard let self else { return }
            if id != self.model.bookID { self.selectBook(id: id) }
            self.model.reloadBook()
            self.bridge.sync()
        })
        menu.addItem(item(captions.mainForm("NOpenModuleFolder", "Открыть папку с модулем")) {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        })
        return menu
    }

    /// Меню рядка групи (26). Усе воно живе лише в режимі правки —
    /// «в режиме редактирования при щелчке правой кнопкой мыши на любой
    /// группе песен появляется выпадающее меню» (5.3.9.2).
    func groupMenu(at row: Int) -> NSMenu? {
        guard model.isEditing else { return nil }
        model.groupIndex = row == 0 ? nil : row - 1
        bridge.sync()
        let menu = emptyMenu()
        menu.addItem(item(caption("NDoubleRefrainAll", "Дублировать припевы во ВСЕХ песнях!")) { [weak self] in
            self?.model.duplicateRefrainsEverywhere(byMarker: false); self?.bridge.sync()
        })
        menu.addItem(item(caption("NDoubleRefrainByPrizAll",
                                  "Дублировать припевы по признаку во ВСЕХ песнях!")) { [weak self] in
            self?.model.duplicateRefrainsEverywhere(byMarker: true); self?.bridge.sync()
        })
        menu.addItem(.separator())
        menu.addItem(submenu(caption("N8", "Форматирование ВСЕХ песен"), [
            item(caption("NFormatAllSongByLiters", "Разбиение по Заглавным Буквам")) { [weak self] in
                self?.model.formatAllSongs(.byLiters); self?.bridge.sync()
            },
            item(caption("NFormatAllSongByOptimalSize", "Оптимальное размещение на экране")) { [weak self] in
                self?.model.formatAllSongs(.byOptimalSize); self?.bridge.sync()
            },
            .separator(),
            item(caption("NAllSongUnformat", "Отмена форматирования")) { [weak self] in
                self?.model.unformatAllSongs(); self?.bridge.sync()
            },
        ]))
        menu.addItem(.separator())
        menu.addItem(item(caption("N15", "Очистить поле \"Номер в сборнике\" во ВСЕХ песнях")) { [weak self] in
            self?.model.clearCatalogNumbers(); self?.bridge.sync()
        })
        menu.addItem(item(caption("N16", "Установить поле \"Номер в сборнике\" во ВСЕХ песнях равным порядковому номеру")) { [weak self] in
            self?.model.setCatalogNumbersToOrdinal(); self?.bridge.sync()
        })
        return menu
    }

    /// Меню рядка пісні (27) — порядок пунктів з опису вікна.
    func songMenu(song index: Int) -> NSMenu? {
        // Праве клацання по невибраній пісні спершу вибирає її: інакше
        // «Змінити атрибути» відкрило б чужу пісню.
        if model.songIndex != index {
            model.songIndex = index
            model.partIndex = nil
            bridge.sync()
        }
        guard let song = model.song else { return nil }
        let menu = emptyMenu()
        menu.addItem(item(caption("MIAddToPlan", "Добавить в План")) { [weak self] in
            self?.model.onAddToPlan?(song, nil)
        })
        menu.addItem(.separator())
        menu.addItem(item(caption("N18", "Изменить атрибуты и текст песни")) { [weak self] in
            self?.model.enterEditMode()
            self?.model.openSongAttributes(editable: true)
            self?.bridge.sync()
        })
        menu.addItem(item(caption("N19", "Просмотр атрибутов и текста песни")) { [weak self] in
            self?.model.openSongAttributes(editable: false)
            self?.bridge.sync()
        })
        menu.addItem(.separator())
        menu.addItem(item(caption("NShowNumPP", "Показать номер по порядку")) { [weak self] in
            self?.model.showsCatalogNumber = false
            self?.bridge.sync()
        })
        menu.addItem(item(caption("NShowNumLog", "Показать номер в сборнике")) { [weak self] in
            self?.model.showsCatalogNumber = true
            self?.bridge.sync()
        })
        guard model.isEditing else { return menu }

        if !model.groups.isEmpty {
            menu.addItem(.separator())
            // «Если пункт с названием группы не активен, то это означает, что
            // песня уже добавлена в эту группу» (5.3.9.5).
            let items = model.groups.enumerated().map { offset, group in
                item(group.name, enabled: !model.isSongInGroup(offset)) { [weak self] in
                    self?.model.addSongToGroup(offset); self?.bridge.sync()
                }
            }
            menu.addItem(submenu(caption("NAddToGroup", "Добавить в Группу"), items))
        }

        menu.addItem(.separator())
        menu.addItem(item(caption("NDoubleRefrain", "Дублировать припев")) { [weak self] in
            self?.model.duplicateRefrainInSong(byMarker: false); self?.bridge.sync()
        })
        menu.addItem(item(caption("NDoubleRefrainByPrizn", "Дублировать припев по признаку")) { [weak self] in
            self?.model.duplicateRefrainInSong(byMarker: true); self?.bridge.sync()
        })
        menu.addItem(submenu(caption("NSongFormat", "Форматировать песню"), [
            item(caption("NFormatSongByLiters", "Разбиение по Заглавным Буквам")) { [weak self] in
                self?.model.formatSong(.byLiters); self?.bridge.sync()
            },
            item(caption("NFormatSongByOptimalSize", "Оптимальное размещение на экране")) { [weak self] in
                self?.model.formatSong(.byOptimalSize); self?.bridge.sync()
            },
            .separator(),
            item(caption("NSongUnformat", "Отмена форматирования")) { [weak self] in
                self?.model.unformatSong(); self?.bridge.sync()
            },
        ]))
        menu.addItem(submenu(caption("N13", "Номера в сборнике"), [
            item(caption("NLogNumAddBy", "Увеличить от этой песни и до конца на...")) { [weak self] in
                self?.model.shiftCatalogNumbers(increase: true); self?.bridge.sync()
            },
            item(caption("NLogNumSubBy", "Уменьшить от этой песни и до конца на...")) { [weak self] in
                self?.model.shiftCatalogNumbers(increase: false); self?.bridge.sync()
            },
        ]))
        return menu
    }

    /// Меню рядка частини пісні (28).
    func partMenu(number: Int) -> NSMenu? {
        guard let song = model.song,
              let position = song.parts.firstIndex(where: { $0.index == number }) else { return nil }
        let part = song.parts[position]
        let menu = emptyMenu()
        menu.addItem(item(caption("MenuItem1", "Добавить в План")) { [weak self] in
            self?.model.onAddToPlan?(song, part)
        })
        guard model.isEditing else { return menu }
        menu.addItem(item(hint("TBChangeBody", "Изменить содержимое части песни")) { [weak self] in
            self?.model.partIndex = position
            self?.model.openPartEditor()
            self?.bridge.sync()
        })
        return menu
    }

    private func mark(_ isOn: Bool) -> String { isOn ? "✓ " : "" }
}

/// Приймач пункту меню. Меню будується в мить клацання, тому ціль пункту
/// тримається самим пунктом через `representedObject`.
@MainActor
final class NativeSongMenuAction: NSObject {

    private let action: () -> Void

    init(_ action: @escaping () -> Void) { self.action = action }

    @objc func fire() { action() }
}
