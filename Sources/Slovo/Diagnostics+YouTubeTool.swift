import Foundation
import SlovoCore

/// Свій yt-dlp оновлюється сам: звірка з GitHub, завантаження зі звіркою SHA-256,
/// повторна перевірка — «остання версія». Мережа справжня (як у людини).
extension Diagnostics {

    static func youTubeToolSection(state: AppState) -> [Check] {
        let area = "Медіаплеєр"
        func wait(_ limit: TimeInterval) -> String? {
            var answer: String?
            YouTubeToolUpdater.check { answer = $0 }
            let deadline = Date().addingTimeInterval(limit)
            while answer == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            return answer
        }
        guard let first = wait(300), YouTubeToolUpdater.lastOutcome != .failed else {
            return [Check(area: area, name: "Свій yt-dlp: звірка з GitHub", status: .failed, detail: YouTubeToolUpdater.status)]
        }
        let path = YouTubeToolUpdater.managedURL.path
        let present = FileManager.default.isExecutableFile(atPath: path)
        let firstOutcome = YouTubeToolUpdater.lastOutcome
        let second = wait(120) ?? "—"
        let current = YouTubeToolUpdater.lastOutcome == .upToDate
        let located = YouTubeResolver.locate(fresh: true)
        var checks = [
            Check(area: area, name: "Свій yt-dlp: завантажено чи свіжий", status: present ? .ok : .failed,
                  detail: first + " (\(firstOutcome)) — " + path),
            Check(area: area, name: "Повторна звірка — остання версія", status: current ? .ok : .failed, detail: second),
        ]
        if case .executable(let url)? = located.tool, url.path == path {
            checks.append(Check(area: area, name: "Ролики беруть свою копію", status: .ok, detail: located.note))
        } else {
            checks.append(Check(area: area, name: "Ролики беруть свою копію", status: .failed, detail: located.note))
        }
        return checks
    }
}
