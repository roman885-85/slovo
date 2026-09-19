import AppKit
import Network
import SlovoCore

/// Ресурси з пульта: переклади, пісенники, фони, шаблони, шрифти, сторінки.
///
/// Власник: «доступ к загрузке ресурсов с программы и всех источников,
/// которые есть в распоряжении программы». Досі ресурси завантажувалися лише
/// з вікна «Ресурси з GitHub…» на комп'ютері; тепер той самий `ResourceHub`
/// (свій каталог, «Цитата з Біблії», MyBible, eBible.org, SoftProjector)
/// доступний і з телефона, планшета чи «Проповідника».
///
/// Завантаження йде в програмі, а не в телефоні: там і мережа швидша, і
/// файли одразу лягають на місце. Пульт лише каже, що взяти, і бачить хід —
/// `/api/resources/progress` повертає, на чому програма зараз.
extension RemoteControlServer {

    /// Хід завантаження — один на програму: два одночасних не буває.
    @MainActor
    final class ResourceWork {
        static let shared = ResourceWork()
        var busy = false
        var title = ""
        var done = 0
        var total = 0
        var fraction: Double = 0
        var installed: [String] = []
        var failures: [String] = []
        var finishedAt: Date?

        var json: [String: Any] {
            [
                "busy": busy,
                "title": title,
                "done": done,
                "total": total,
                "percent": Int((fraction * 100).rounded()),
                "installed": installed,
                "failures": failures,
                "finished": finishedAt != nil && !busy,
            ]
        }
    }

    // MARK: - Читання

    /// Маршрути ресурсів. `true` — відповідь уже пішла.
    func resourcesGET(_ request: Request, state: AppState, on connection: NWConnection) -> Bool {
        switch request.path {
        case "/api/resources/sources":
            respond(connection, 200, ["sources": Self.sourcesJSON()])
        case "/api/resources/progress":
            respond(connection, 200, ResourceWork.shared.json)
        case "/api/resources":
            answerResourceCatalog(request, state: state, on: connection)
        default:
            return false
        }
        return true
    }

    /// Джерела й що в кожного брати — рід ресурсу пульт показує окремо, щоб
    /// переклади й пісенники не змішувалися.
    static func sourcesJSON() -> [[String: Any]] {
        ResourceHub.Source.allCases.map { source in
            [
                "id": source.rawValue,
                "name": Self.sourceName(source),
                "kinds": source.kinds.map(\.rawValue).sorted(),
            ]
        }
    }

    static func sourceName(_ source: ResourceHub.Source) -> String {
        switch source {
        case .slovo: return OurWords.t("Слово: готовые ресурсы")
        case .bibleQuote: return "«Цитата з Біблії»"
        case .myBible: return "MyBible"
        case .eBible: return "eBible.org"
        case .softProjector: return "SoftProjector"
        }
    }

    /// Каталог джерела: `?source=slovo&kind=bible`. Довгі каталоги (MyBible,
    /// eBible) відсікаються пошуком `?q=`, щоб телефон не отримав півтори
    /// тисячі рядків одним куснем.
    private func answerResourceCatalog(_ request: Request, state: AppState, on connection: NWConnection) {
        let sourceName = request.query["source"] ?? ResourceHub.Source.slovo.rawValue
        guard let source = ResourceHub.Source(rawValue: sourceName) else {
            respond(connection, 400, ["error": OurWords.t("нет такого источника")])
            return
        }
        let kind = (request.query["kind"]).flatMap(ResourceItem.Kind.init(rawValue:))
        let needle = (request.query["q"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let limit = min(500, max(10, Int(request.query["limit"] ?? "") ?? 300))
        let hub = ResourceHub(layout: ResourceLayout(modulesFolder: state.modulesFolder))
        hub.fetchCatalog(source) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.respond(connection, 502, ["error": "\(error)"])
                case .success(let catalog):
                    var items = catalog.items
                    if let kind { items = items.filter { $0.kind == kind } }
                    if !needle.isEmpty {
                        items = items.filter {
                            $0.title.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
                        }
                    }
                    let shown = items.prefix(limit).map { item -> [String: Any] in
                        [
                            "id": item.id,
                            "kind": item.kind.rawValue,
                            "title": item.title,
                            "subtitle": item.subtitle,
                            "size": item.size,
                            "version": item.version,
                            "language": item.language ?? "",
                            "installed": hub.layout.isPresent(item),
                        ]
                    }
                    self.respond(connection, 200, [
                        "source": source.rawValue,
                        "name": Self.sourceName(source),
                        "total": items.count,
                        "shown": shown.count,
                        "items": shown,
                    ])
                }
            }
        }
    }

    // MARK: - Завантаження

    /// Команда `resource-install`: `{"source": "slovo", "ids": ["…", "…"]}`.
    /// Відповідає одразу — хід питають окремо, щоб телефон не тримав з'єднання.
    @MainActor
    func startResourceInstall(body: [String: Any], state: AppState, answer: inout [String: Any]) -> String? {
        let work = ResourceWork.shared
        if work.busy { return OurWords.t("уже идёт загрузка") }
        let sourceName = (body["source"] as? String) ?? ResourceHub.Source.slovo.rawValue
        guard let source = ResourceHub.Source(rawValue: sourceName) else {
            return OurWords.t("нет такого источника")
        }
        let wanted = Set((body["ids"] as? [String]) ?? [])
        guard !wanted.isEmpty else { return OurWords.t("нечего загружать") }
        let hub = ResourceHub(layout: ResourceLayout(modulesFolder: state.modulesFolder))
        work.busy = true
        work.title = OurWords.t("читаю каталог")
        work.done = 0
        work.total = wanted.count
        work.fraction = 0
        work.installed = []
        work.failures = []
        work.finishedAt = nil
        NativeTrace.say("пульт: ресурси — беру \(wanted.count) з «\(sourceName)»")
        hub.fetchCatalog(source) { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    work.busy = false
                    work.finishedAt = Date()
                    work.failures = ["\(error)"]
                }
            case .success(let catalog):
                let items = catalog.items.filter { wanted.contains($0.id) }
                guard !items.isEmpty else {
                    DispatchQueue.main.async {
                        work.busy = false
                        work.finishedAt = Date()
                        work.failures = [OurWords.t("нечего загружать")]
                    }
                    return
                }
                DispatchQueue.main.async { work.total = items.count }
                hub.install(items, progress: { progress in
                    DispatchQueue.main.async {
                        work.title = progress.item.title
                        work.done = progress.index
                        work.fraction = Double(progress.index) / Double(max(1, progress.total))
                            + (progress.fraction ?? 0) / Double(max(1, progress.total))
                    }
                }, completion: { outcome in
                    DispatchQueue.main.async {
                        work.busy = false
                        work.finishedAt = Date()
                        work.done = outcome.installed.count
                        work.fraction = 1
                        work.installed = outcome.installed.map(\.title)
                        work.failures = outcome.failures.map { "\($0.0.title): \($0.1)" }
                        work.title = outcome.failures.isEmpty
                            ? OurWords.t("готово")
                            : OurWords.t("не всё получилось")
                        NativeTrace.say("пульт: ресурси — поставлено \(outcome.installed.count), помилок \(outcome.failures.count)")
                        // Нові модулі мають з'явитися у списках програми.
                        state.reloadLibrary()
                    }
                })
            }
        }
        answer["started"] = true
        return nil
    }
}
