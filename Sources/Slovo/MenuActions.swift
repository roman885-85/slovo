import AppKit
import SlovoCore

/// Приёмник команд меню. AppKit требует `@objc`-цель с селекторами,
/// поэтому состояние приложения оборачивается вот таким тонким адаптером.
@MainActor
final class MenuActions: NSObject {
    private let state: AppState

    init(state: AppState) {
        self.state = state
        super.init()
    }

    /// N24 «Показать слайд». В режиме «Текст» показывать надо подготовленную
    /// страницу набора, а не прежний слайд зала, — за это отвечает
    /// `showCurrent()`, у него же и условие режима.
    @objc func showSlide()        { state.showCurrent() }
    @objc func hideSlide()        { state.isLive = false }
    @objc func blankSlide()       { state.showBlankSlide() }
    @objc func blackScreen()      { state.showBlackScreen() }
    @objc func toggleBackground() { state.toggleBackground() }
    @objc func screenshot()       { state.saveScreenshot() }
    @objc func openSettings()     { state.isSettingsOpen = true }

    /// N22 «Установить фокус на Стихи/Текст» (F6). Название пункта не
    /// случайно двойное: в режиме «Библия» клавиша прокручивает список к
    /// текущему стиху, а в режиме «Текст» ставит курсор в поле текста (25).
    @objc func focusVerses() {
        if state.mode == .text {
            TextModuleModel.shared.focusBody()
        } else {
            state.scrollToCurrentVerse += 1
        }
    }

    /// «Перечитати налаштування»: бібліотека й файл умовчань читаються заново.
    @objc func rereadSettings() {
        state.reloadLibrary()
        let alert = NSAlert()
        alert.messageText = OurWords.t("Настройки перечитаны")
        alert.informativeText = state.configPath.map { OurWords.t("Из файла:") + "\n\($0)" }
            ?? OurWords.t("Файл настроек не найден — оставлены прежние значения.")
        alert.addButton(withTitle: OurWords.t("Закрыть"))
        alert.runModal()
    }

    @objc func chooseModules() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = OurWords.t("Выбрать")
        panel.message = OurWords.t("Папка Modules с модулями «Цитаты из Библии»")
        if panel.runModal() == .OK, let url = panel.url { state.modulesFolder = url }
    }

    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        state.setLanguage(code: code)
    }

    @objc func openHelp() {
        // Довідка — документація на GitHub: вона одна для всіх і завжди свіжа.
        if let online = URL(string: "https://github.com/roman885-85/slovo#readme") {
            NSWorkspace.shared.open(online)
            return
        }
        guard let url = state.helpFileURL else {
            let alert = NSAlert()
            alert.messageText = OurWords.t("Справка не найдена")
            alert.informativeText = OurWords.t("В папке данных нет файла справки. Он лежит в подпапке Help вместе с модулями.")
            alert.addButton(withTitle: OurWords.t("Закрыть"))
            alert.runModal()
            return
        }
        // Файлы .chm macOS открыть не умеет — тогда хотя бы покажем в Finder.
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Показывает отчёт самопроверки и кладёт его же в файл — чтобы можно
    /// было переслать, а не переписывать с экрана.
    @objc func showDiagnostics() {
        let report = Diagnostics.report(Diagnostics.runAll(state: state))
        try? report.write(to: Diagnostics.reportURL, atomically: true, encoding: .utf8)

        let alert = NSAlert()
        alert.messageText = OurWords.t("Диагностика")
        alert.informativeText = report
        alert.addButton(withTitle: OurWords.t("Закрыть"))
        alert.addButton(withTitle: OurWords.t("Показать файл"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.reportURL])
        }
    }

    /// «Про програму»: назва з версією й кнопка перевірки оновлень (власник:
    /// «в пункте о программе указывать версию и добавить туда кнопку
    /// проверить обновление»).
    @objc func about() {
        let alert = NSAlert()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        alert.messageText = "Слово " + AppUpdater.currentVersion
        alert.informativeText = OurWords.t("Версия %s", AppUpdater.currentVersion + (build.isEmpty ? "" : " (\(build))")) + "\n\n"
            + OurWords.t("Программа для показа Библии, песен, медиа и презентаций на служении — macOS. "
            + "Читает модули «Цитаты из Библии» и MyBible, песенники .vbm, шаблоны слайдов; "
            + "умеет NDI, веб-слайды и ролики YouTube по ссылке.")
        alert.addButton(withTitle: OurWords.t("Закрыть"))
        alert.addButton(withTitle: OurWords.t("Проверить обновление"))
        if alert.runModal() == .alertSecondButtonReturn {
            // Після модального вікна — наступним проходом циклу подій: перевірка
            // сама показує свої вікна.
            let state = self.state
            AppUpdater.onMain { AppUpdater.checkNow(state: state) }
        }
    }
}
