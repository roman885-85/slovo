import AppKit
import SlovoCore

/// Пуск программы — обычный для AppKit.
///
/// Прежде это была сцена SwiftUI с заглушкой-окном: она нужна была только
/// затем, чтобы приложение вообще запустилось как приложение SwiftUI, и
/// сама себя прятала. Теперь ничего этого нет — программа поднимается так
/// же, как всякая программа AppKit, а всю работу делает делегат.
///
/// `MainActor.assumeIsolated` здесь по существу: до `NSApplication.run` мы и
/// есть главный поток, просто у компилятора нет способа это увидеть.
MainActor.assumeIsolated {
    // Дані — з пакета програми в дім даних (Application Support) — раніше за
    // все інше: стан програми вже в конструкторі делегата читає налаштування
    // й теку модулів. Власник 15.09.2026: дані поза пакетом, щоб оновлення
    // не переписувало підпис і дозволи macOS не скидалися.
    let moved = DataMigration.run()
    if !moved.isEmpty {
        NativeTrace.say("дані в \(DataHome.displayPath): " + moved.summary
            + (DataMigration.resealed.isEmpty ? "" : "; " + DataMigration.resealed))
    }
    let application = NSApplication.shared
    let delegate = SlovoDelegate()
    // Ссылка на делегата у `NSApplication` слабая — держим его сами, иначе
    // он будет освобождён сразу после этой строки.
    LaunchHolder.delegate = delegate
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}

/// Держатель делегата: он должен жить столько же, сколько программа.
enum LaunchHolder {
    @MainActor static var delegate: SlovoDelegate?
}
