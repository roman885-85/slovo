import AppKit
import SlovoCore

/// Список книг після зміни перекладу.
///
/// Власник: «при смене перевода Библии, список книг не всегда подтягивается
/// от перевода и частично остается от предыдущего». Перевіряємо не наміри, а
/// те, що НАМАЛЬОВАНО: міняємо переклад і дивимося, чи не лишилися на екрані
/// назви, яких у новому перекладі немає зовсім.
extension Diagnostics {

    @MainActor
    static func bibleBooksSection(state: AppState) -> [Check] {
        let area = "Біблія"
        let name = "Список книг переходить за перекладом"
        guard let list = NativeBibleWorkspace.shared.bookColumn?.bookList else {
            return [Check(area: area, name: name, status: .skipped, detail: "списку книг немає")]
        }
        let modules = (state.library?.modules ?? []).map(\.identifier)
        guard modules.count >= 2 else {
            return [Check(area: area, name: name, status: .skipped,
                          detail: "для проби треба два переклади, а є \(modules.count)")]
        }

        let wasModule = state.primaryModuleID
        defer {
            state.primaryModuleID = wasModule
            wait(untilTrue: { false }, seconds: 0.4)
        }

        /// Що зараз НАМАЛЬОВАНО в списку книг — одним рядком.
        func drawnNow() -> String {
            list.materializeVisibleForCheck()
            wait(untilTrue: { false }, seconds: 0.15)
            return list.visibleRows
                .map { list.textForCheck(ofRow: $0) }
                .filter { $0 != "клітинки немає" }
                .joined(separator: " ")
        }

        var trouble: [String] = []
        var checked = 0
        // Кілька перекладів поспіль: саме на переході й губилися назви.
        for id in modules.prefix(4) where id != state.primaryModuleID {
            let before = Set(state.visibleBooks.map(\.fullName))
            state.primaryModuleID = id
            wait(untilTrue: { false }, seconds: 0.7)
            let after = state.visibleBooks.map(\.fullName)
            guard !after.isEmpty else { continue }
            let drawn = drawnNow()
            guard !drawn.isEmpty else { continue }
            checked += 1
            // Назви, яких у новому перекладі немає зовсім: якщо така ще на
            // екрані — рядок лишився від минулого перекладу.
            // Береться лише те, чого в новому перекладі немає ЗОВСІМ —
            // навіть як частини іншої назви. Інакше «Марка» зарахується за
            // залишок, хоч на екрані стоїть «Вiд Марка» нового перекладу.
            let onlyOld = before.subtracting(after).filter { old in
                old.count > 4 && !after.contains { $0.contains(old) }
            }
            let leftovers = onlyOld.filter { drawn.contains($0) }
            if !leftovers.isEmpty {
                trouble.append("«\(id)»: лишилися назви з минулого перекладу — "
                               + leftovers.sorted().prefix(3).joined(separator: ", "))
            }
            // І навпаки: хоч одна назва нового перекладу має бути видна.
            let newOnes = Set(after).subtracting(before).filter { $0.count > 4 }
            if !newOnes.isEmpty, !newOnes.contains(where: { drawn.contains($0) }) {
                trouble.append("«\(id)»: жодної назви нового перекладу на екрані немає")
            }
            if trouble.count > 2 { break }
        }

        return [Check(area: area, name: name,
                      status: trouble.isEmpty ? .ok : .failed,
                      detail: trouble.isEmpty
                          ? "звірено перемикань \(checked): назв із минулого перекладу не лишилося"
                          : trouble.joined(separator: "; "))]
    }
}
