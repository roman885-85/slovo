import Foundation

/// План служіння (F2) — порядок того, що піде на екран: уривки і частини
/// пісень підряд, як їх розставив ведучий перед зібранням.
///
/// Формат зберігання свій: тека `Plans` у старій програмі порожня, розбирати нічого,
/// тому пишемо звичайний JSON, який читається і правиться в будь-якому редакторі.
///
///     {
///       "format": "slovo.plan",
///       "version": 1,
///       "title": "Воскресное служение",
///       "savedAt": "2026-08-23T09:15:00Z",
///       "items": [
///         { "type": "scripture", "title": "Ин 3:16-18",
///           "module": "RST", "book": 42, "chapter": 3, "verses": [16, 17, 18] },
///         { "type": "song", "title": "Великий Бог — Куплет 1",
///           "songBook": "Песнь возрождения.vbm", "song": 11, "part": 0 }
///       ]
///     }
///
/// Читання стійке до псування: незрозумілий пункт пропускається і рахується, а не
/// ронить весь план. Перед служінням важливіше відкрити дев'ять пунктів із десяти,
/// ніж отримати повідомлення про помилку і порожній список.
public struct ServicePlan: Sendable, Hashable {

    /// Мітка формату у файлі — за нею відрізняємо свій план від чужого JSON.
    public static let formatMarker = "slovo.plan"
    public static let formatVersion = 1
    /// Розширення навмисно `json`, а не своє: файл має відкриватися подвійним
    /// клацанням у будь-якому редакторі, читабельність тут важливіша за власний значок.
    public static let fileExtension = "json"
    /// Тека з планами всередині даних програми — та сама, що в оригіналу.
    public static let folderName = "Plans"

    public var title: String {
        didSet { if title != oldValue { hasUnsavedChanges = true } }
    }

    public private(set) var items: [PlanItem]

    /// Де стоїть подача. Не зберігається: план — це порядок, а не закладка.
    public private(set) var currentIndex: Int?

    /// Файл, з якого план відкрили або в який зберегли.
    public private(set) var fileURL: URL?

    public private(set) var hasUnsavedChanges: Bool

    public init(title: String = "План служения", items: [PlanItem] = []) {
        self.title = title
        self.items = items
        self.currentIndex = items.isEmpty ? nil : 0
        self.fileURL = nil
        self.hasUnsavedChanges = false
    }

    // MARK: - Читання списку

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    public subscript(index: Int) -> PlanItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    public var current: PlanItem? {
        guard let currentIndex, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    public var currentItemID: PlanItem.ID? { current?.id }

    public func index(of id: PlanItem.ID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    // MARK: - Правка

    public mutating func append(_ item: PlanItem) {
        items.append(item)
        if currentIndex == nil { currentIndex = items.count - 1 }
        hasUnsavedChanges = true
    }

    public mutating func append(contentsOf newItems: [PlanItem]) {
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        if currentIndex == nil { currentIndex = 0 }
        hasUnsavedChanges = true
    }

    public mutating func insert(_ item: PlanItem, at index: Int) {
        let position = min(max(index, 0), items.count)
        items.insert(item, at: position)
        if let current = currentIndex, position <= current { currentIndex = current + 1 }
        if currentIndex == nil { currentIndex = position }
        hasUnsavedChanges = true
    }

    @discardableResult
    public mutating func remove(at index: Int) -> PlanItem? {
        guard items.indices.contains(index) else { return nil }
        let removed = items.remove(at: index)
        currentIndex = Self.indexAfterRemoval(previous: currentIndex, removed: IndexSet(integer: index), count: items.count)
        hasUnsavedChanges = true
        return removed
    }

    /// Видалення за набором позицій — так його віддає список SwiftUI.
    public mutating func remove(atOffsets offsets: IndexSet) {
        let valid = offsets.filteredIndexSet { items.indices.contains($0) }
        guard !valid.isEmpty else { return }
        for index in valid.sorted(by: >) { items.remove(at: index) }
        currentIndex = Self.indexAfterRemoval(previous: currentIndex, removed: valid, count: items.count)
        hasUnsavedChanges = true
    }

    public mutating func remove(id: PlanItem.ID) {
        guard let index = index(of: id) else { return }
        remove(at: index)
    }

    public mutating func removeAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        currentIndex = nil
        hasUnsavedChanges = true
    }

    /// Перестановка перетягуванням. Поточний пункт тримаємо за самим пунктом, а
    /// не за номером: оператор тягне сусіда, а подача зобов'язана лишитися на місці.
    public mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let anchor = currentItemID
        let valid = offsets.filteredIndexSet { items.indices.contains($0) }
        guard !valid.isEmpty, destination >= 0, destination <= items.count else { return }

        // Той самий договір, що в списку SwiftUI: destination — місце вставки в
        // ще неторканому списку, тому його зсуваємо на вийняті пункти самі.
        let moved = valid.sorted().map { items[$0] }
        let insertion = destination - valid.filter { $0 < destination }.count
        var rest = items
        for index in valid.sorted(by: >) { rest.remove(at: index) }
        rest.insert(contentsOf: moved, at: min(max(insertion, 0), rest.count))
        items = rest

        if let anchor { currentIndex = index(of: anchor) ?? currentIndex }
        hasUnsavedChanges = true
    }

    public mutating func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        move(fromOffsets: IndexSet(integer: source),
             toOffset: destination > source ? destination + 1 : destination)
    }

    public mutating func replace(at index: Int, with item: PlanItem) {
        guard items.indices.contains(index) else { return }
        items[index] = item
        hasUnsavedChanges = true
    }

    // MARK: - Подача

    public mutating func select(at index: Int?) {
        guard let index, items.indices.contains(index) else {
            currentIndex = nil
            return
        }
        currentIndex = index
    }

    public mutating func select(id: PlanItem.ID) {
        if let index = index(of: id) { currentIndex = index }
    }

    /// Наступний пункт. По колу навмисно не ходимо: на служінні «далі» після
    /// останнього пункту має нічого не робити, а не стрибати на початок.
    @discardableResult
    public mutating func goToNext() -> PlanItem? {
        guard !items.isEmpty else { currentIndex = nil; return nil }
        let next = currentIndex.map { $0 + 1 } ?? 0
        guard items.indices.contains(next) else { return nil }
        currentIndex = next
        return items[next]
    }

    @discardableResult
    public mutating func goToPrevious() -> PlanItem? {
        guard !items.isEmpty else { currentIndex = nil; return nil }
        let previous = currentIndex.map { $0 - 1 } ?? items.count - 1
        guard items.indices.contains(previous) else { return nil }
        currentIndex = previous
        return items[previous]
    }

    public var canGoToNext: Bool {
        guard !items.isEmpty else { return false }
        return items.indices.contains(currentIndex.map { $0 + 1 } ?? 0)
    }

    public var canGoToPrevious: Bool {
        guard let currentIndex else { return !items.isEmpty }
        return items.indices.contains(currentIndex - 1)
    }

    /// Куди стає подача після видалення: тримаємося за те саме місце в списку,
    /// а не за номер, який зсунувся разом із видаленими пунктами.
    private static func indexAfterRemoval(previous: Int?, removed: IndexSet, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let previous else { return nil }
        let shifted = previous - removed.count { $0 < previous }
        return min(max(shifted, 0), count - 1)
    }

    // MARK: - Файли

    public static func plansDirectory(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Плани в теці, свіжі зверху — відкривати зазвичай хочуть учорашній.
    public static func savedPlans(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == fileExtension }
            .sorted { left, right in
                let l = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let r = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let l, let r else {
                    return left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
                }
                return l > r
            }
    }

    /// Ім'я файлу з назви плану: в імені не має бути того, що зламає
    /// шлях, а все інше хай лишається як написав користувач.
    public static func fileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = title
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "План" : cleaned
        return "\(name).\(fileExtension)"
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        // Кирилиця лишається кирилицею, ключі в сталому порядку — файл
        // має читатися очима і не шуміти в системі контролю версій.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public mutating func save(to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jsonData().write(to: url, options: .atomic)
        fileURL = url
        hasUnsavedChanges = false
    }

    /// Збереження поверх відкритого файла.
    public mutating func save() throws {
        guard let fileURL else { throw PlanError.noFile }
        try save(to: fileURL)
    }

    /// План прив'язаний до файла і з ним збігається.
    ///
    /// Потрібно запису у форматі оригіналу (`ServicePlan+Journal.swift`): він
    /// живе в іншому файлі, а `fileURL` і `hasUnsavedChanges` закриті на
    /// запис — і правильно, що закриті: їх міняє лише збереження.
    public mutating func markSaved(as url: URL) {
        fileURL = url
        hasUnsavedChanges = false
    }

    /// Що вдалося прочитати і скільки пунктів довелося пропустити.
    public struct LoadResult: Sendable {
        public let plan: ServicePlan
        public let skippedItems: Int

        public var hasSkippedItems: Bool { skippedItems > 0 }

        /// Готове попередження для вікна — або nil, якщо все прочиталося.
        public var warning: String? {
            guard skippedItems > 0 else { return nil }
            return OurWords.t("Пропущено пунктов, которые не удалось прочитать: %s.", "\(skippedItems)")
        }
    }

    public static func read(contentsOf url: URL) throws -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PlanError.unreadable(url.lastPathComponent, "\(error.localizedDescription)")
        }

        let counter = SkippedItems()
        let decoder = JSONDecoder()
        decoder.userInfo[.planSkippedItems] = counter

        var plan: ServicePlan
        do {
            plan = try decoder.decode(ServicePlan.self, from: data)
        } catch let error as PlanError {
            throw error
        } catch {
            throw PlanError.unreadable(url.lastPathComponent, OurWords.t("файл не разбирается как JSON"))
        }

        // Назва плану у файлі може бути відсутня — тоді її заміняє ім'я
        // файлу: у списку планів порожній рядок виглядає як загублений план.
        if plan.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plan.title = url.deletingPathExtension().lastPathComponent
        }
        plan.fileURL = url
        plan.hasUnsavedChanges = false
        return LoadResult(plan: plan, skippedItems: counter.value)
    }

    /// Короткий шлях, коли лічильник пропущених пунктів не потрібен.
    public static func load(contentsOf url: URL) throws -> ServicePlan {
        try read(contentsOf: url).plan
    }
}

// MARK: - JSON

extension ServicePlan: Codable {

    private enum CodingKeys: String, CodingKey {
        case format, version, title, savedAt, items
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.formatMarker, forKey: .format)
        try container.encode(Self.formatVersion, forKey: .version)
        try container.encode(title, forKey: .title)
        // Позначка часу лише для людини: при читанні вона не потрібна, але за
        // нею видно, який зі схожих файлів свіжіший, не відкриваючи програму.
        try container.encode(ISO8601DateFormatter().string(from: Date()), forKey: .savedAt)
        try container.encode(items, forKey: .items)
    }

    public init(from decoder: Decoder) throws {
        var skipped = 0
        var items: [PlanItem] = []
        var title = ""

        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.items) || container.contains(.format) || container.contains(.title) {
            title = (try? container.decode(String.self, forKey: .title)) ?? ""
            let raw = (try? container.decode([LenientItem].self, forKey: .items)) ?? []
            items = raw.compactMap(\.item)
            skipped = raw.count - items.count
        } else if let raw = try? decoder.singleValueContainer().decode([LenientItem].self) {
            // Файл може бути просто списком пунктів — так коротше писати руками.
            items = raw.compactMap(\.item)
            skipped = raw.count - items.count
        } else {
            throw PlanError.notAPlan
        }

        self.init(title: title, items: items)
        if let counter = decoder.userInfo[.planSkippedItems] as? SkippedItems {
            counter.value += skipped
        }
    }
}

/// Обгортка, яка гасить помилку розбору одного пункту.
///
/// Масив декодується цілком, тому один невдалий елемент інакше потягнув би
/// за собою весь план; тут він просто стає `nil`.
private struct LenientItem: Decodable {
    let item: PlanItem?

    init(from decoder: Decoder) throws {
        item = try? PlanItem(from: decoder)
    }
}

/// Лічильник пропущених пунктів: `init(from:)` не може повернути нічого понад
/// саме значення, тому підсумок кладемо в спільний для розбору об'єкт.
private final class SkippedItems: @unchecked Sendable {
    var value = 0
}

private extension CodingUserInfoKey {
    static let planSkippedItems = CodingUserInfoKey(rawValue: "slovo.plan.skippedItems")!
}

public enum PlanError: Error, CustomStringConvertible, Equatable {
    case notAPlan
    case unreadable(String, String)
    case unsupportedItem(String)
    case noFile

    public var description: String {
        switch self {
        case .notAPlan:
            return OurWords.t("Это не файл плана служения")
        case .unreadable(let name, let reason):
            return "\(name): \(reason)"
        case .unsupportedItem(let reason):
            return "Пункт плана пропущен: \(reason)"
        case .noFile:
            return OurWords.t("План ещё ни разу не сохраняли — нужно выбрать файл")
        }
    }

    public var localizedDescription: String { description }
}
