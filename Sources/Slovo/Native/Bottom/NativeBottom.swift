import AppKit

/// Підняття нижнього ряду в новому вікні.
///
/// Одна точка входу на всю частину: покликали — ряд став у свій ящик і почав
/// працювати. Тримати ряд і перекладача приводів треба тут, а не в того, хто кличе:
/// відпущений перекладач мовчки зняв би всі підписки, і вікно перестало б
/// дізнаватися про зміну вірша.
@MainActor
enum NativeBottom {

    private(set) static var row: NativeBottomRow?
    private static var bridge: NativeBottomBridge?

    /// Поставити нижній ряд у головне вікно AppKit.
    @discardableResult
    static func install(state: AppState) -> NativeBottomRow {
        if let row { return row }
        let bridge = NativeBottomBridge(state: state, desk: DeskModel.shared)
        let row = NativeBottomRow.install(state: state)
        self.bridge = bridge
        self.row = row
        return row
    }

    /// Чи просили замір нижнього ряду.
    static var wantsBench: Bool {
        CommandLine.arguments.contains("--appkit-bottom-bench")
    }
}
