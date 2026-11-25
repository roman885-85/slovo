// swift-tools-version: 5.9
// slovo-ref — еталон для звірки ядра Windows-«Слова» з Mac: друкує те саме й у тому самому
// вигляді, що `Slovo.exe --core-check`, але поверх справжнього SlovoCore (Sources/SlovoCore —
// посилання на живі вихідні коди). Звірка: diff двох виводів на тій самій копії даних.
//   swift build -c release --package-path Windows/tools/slovo-ref
//   .build/release/slovo-ref <тека даних> [розділ]
import PackageDescription

let package = Package(
    name: "SlovoRef",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "SlovoCore"),
        .executableTarget(name: "slovo-ref", dependencies: ["SlovoCore"]),
    ]
)
