import Foundation
import AVFoundation
import SlovoCore

/// Совместимость с macOS 11 Big Sur.
///
/// Старой системы на этой машине нет, и увидеть на ней запуск нельзя. Зато
/// можно проверить то, из-за чего запуск там сорвался бы наверняка: пакет
/// обязан объявлять macOS 11, нести библиотеку Swift Concurrency (в Big Sur
/// её нет в системе) — и ветки кода для старой системы обязаны работать,
/// для чего их гоняют здесь через `Compat.pretendsBigSur`.
extension Diagnostics {

    /// Вывод системной утилиты одной строкой.
    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func compatSection(state: AppState) -> [Check] {
        let area = "Сумісність із macOS 11"
        var checks: [Check] = []
        let bundle = Bundle.main
        let isBundle = bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") != nil

        let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "немає"
        checks.append(Check(area: area, name: "Пакет оголошує macOS 11",
                            status: !isBundle ? .skipped : (minimum == "11.0" ? .ok : .failed),
                            detail: !isBundle ? "запуск не з пакета" : "LSMinimumSystemVersion = \(minimum)"))

        // Библиотека Swift Concurrency: на macOS 12+ она в системе, а в
        // Big Sur её нет, и без копии в пакете dyld не даст программе
        // запуститься — ещё до первой нашей строки.
        let library = bundle.bundleURL
            .appendingPathComponent("Contents/Frameworks/libswift_Concurrency.dylib")
        let shipped = FileManager.default.fileExists(atPath: library.path)
        checks.append(Check(area: area, name: "Swift Concurrency лежить у пакеті",
                            status: !isBundle ? .skipped : (shipped ? .ok : .failed),
                            detail: !isBundle ? "запуск не з пакета"
                                : (shipped ? library.path : "немає \(library.lastPathComponent) — на macOS 11 програма не запуститься")))

        // Сам двоичный файл: какую систему он объявляет и на каких
        // процессорах идёт. Info.plist может обещать что угодно — dyld смотрит
        // в заголовок файла, и Big Sur на M1 без слоя arm64 запустит нас
        // только через Rosetta.
        if let executable = bundle.executableURL {
            let archs = run("/usr/bin/lipo", ["-archs", executable.path])
            let load = run("/usr/bin/otool", ["-l", executable.path])
            var minos = "?"
            if let range = load.range(of: "LC_BUILD_VERSION") {
                let tail = load[range.upperBound...]
                if let m = tail.range(of: "minos ") {
                    minos = String(tail[m.upperBound...].prefix(while: { !$0.isNewline }))
                }
            }
            let universal = archs.contains("x86_64") && archs.contains("arm64")
            checks.append(Check(area: area, name: "Двійковий файл: macOS 11 і обидві архітектури",
                                status: !isBundle ? .skipped : (minos == "11.0" && universal ? .ok : .failed),
                                detail: !isBundle ? "запуск не з пакета"
                                    : "мінімальна система \(minos), архітектури: \(archs)"))
        }

        // Что на самом деле загрузилось на ЭТОЙ системе — не что лежит в
        // пакете, а что взял загрузчик и кого отверг. На Big Sur это и есть
        // ответ на «NDI не работает».
        let running = ProcessInfo.processInfo.operatingSystemVersionString
        let availability = NDIRuntime.availability
        let refused = NDIRuntime.refusedCandidates
            .map { "\(($0.path as NSString).lastPathComponent): \($0.reason)" }
        checks.append(Check(area: area, name: "Бібліотека NDI на цій системі",
                            status: availability.isReady ? .ok : .failed,
                            detail: running + "; " + availability.summary
                                + (refused.isEmpty ? "" : "; відкинуті — " + refused.joined(separator: " · "))))

        // Swift Concurrency и правда загружена, и откуда: на macOS 12+ из
        // системы, на Big Sur — из нашего пакета. Без неё первый же `Task`
        // уронил бы программу.
        var info = Dl_info()
        let task = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_task_create")
        let image = task.flatMap { dladdr($0, &info) != 0 ? String(cString: info.dli_fname) : nil }
        checks.append(Check(area: area, name: "Swift Concurrency завантажено",
                            status: task == nil ? .failed : .ok,
                            detail: image ?? "swift_task_create не знайдено — Task упаде"))

        // Библиотеки NDI в пакете и их требования к системе. Владелец увидел
        // на Big Sur «NDI не работает и не определяется в сети»: наша
        // libndi 6.x собрана для macOS 13, и dyld её там не загружает.
        if isBundle {
            let frameworks = bundle.bundleURL.appendingPathComponent("Contents/Frameworks")
            var lines: [String] = []
            var oldest = 99.0
            for name in ["libndi.dylib", "libndi.6.dylib", "libndi.5.dylib", "libndi.4.dylib"] {
                let file = frameworks.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let load = run("/usr/bin/otool", ["-arch", "x86_64", "-l", file.path])
                var minos = "?"
                for key in ["minos ", "version "] {
                    if let cut = load.range(of: "LC_BUILD_VERSION") ?? load.range(of: "LC_VERSION_MIN_MACOSX"),
                       let m = load[cut.upperBound...].range(of: key) {
                        minos = String(load[m.upperBound...].prefix(while: { $0.isNumber || $0 == "." }))
                        break
                    }
                }
                oldest = min(oldest, Double(minos) ?? 99)
                lines.append("\(name): вимагає macOS \(minos)")
            }
            let coversBigSur = oldest <= 11.0
            checks.append(Check(area: area, name: "NDI у пакеті є і для macOS 11",
                                status: lines.isEmpty ? .failed : (coversBigSur ? .ok : .warning),
                                detail: lines.isEmpty
                                    ? "у пакеті немає libndi"
                                    : lines.joined(separator: "; ")
                                        + (coversBigSur ? ""
                                           : " — на Big Sur NDI не запрацює: покладіть libndi 5.x на стіл як libndi-bigsur.dylib і зберіть заново")))
        }

        // Разбор файла старой дорогой: дорожки, длина — как их видит Big Sur.
        guard let movie = makeMovie(withSound: true) else {
            checks.append(Check(area: area, name: "Розбір файлу як на macOS 11",
                                status: .skipped, detail: "не зібрався пробний фільм"))
            return checks
        }
        let asset = AVURLAsset(url: movie)
        var facts: MediaPlayerModel.AssetFacts?
        Task { @MainActor in
            facts = await MediaPlayerModel.assetFacts(of: asset, pretendingBigSur: true)
        }
        wait(untilTrue: { facts != nil }, seconds: 10)
        let seconds = facts.map { CMTimeGetSeconds($0.duration) } ?? 0
        let good = facts.map { $0.video.count == 1 && $0.audio.count == 1 } ?? false
            && seconds > 0.5 && seconds < 5
        checks.append(Check(area: area, name: "Розбір файлу як на macOS 11",
                            status: facts == nil ? .failed : (good ? .ok : .failed),
                            detail: facts == nil
                                ? "стара дорога не відповіла за 10 с"
                                : "відео \(facts!.video.count), звук \(facts!.audio.count), довжина "
                                    + String(format: "%.2f", seconds) + " с"
                                    + (facts!.group == nil ? ", групи мов немає" : ", група мов є")))
        return checks
    }
}
