import Foundation
import SlovoCore

// Еталон розділу `outputs` — дзеркало CoreCheck.Outputs.cs.

func styleDigest(_ style: SlideStyle) -> String {
    var portable = style
    if let path = portable.backgroundImagePath { portable.backgroundImagePath = (path as NSString).lastPathComponent }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return fnv(String(data: try! enc.encode(portable), encoding: .utf8)!)
}

func printOutputs(_ name: String, _ configuration: OutputConfiguration) {
    let slide = Slide(mainText: "Текст", secondaryTexts: ["Другий", "Третій"], reference: "Ів 3:16")
    for kind in OutputKind.allCases {
        let r = configuration[kind]
        print("\(name) \(kind.rawValue) enabled \(r.isEnabled) bg \(r.drawsBackground) ref \(r.showsReference) sec \(r.showsSecondaryTranslations) nums \(r.showsVerseNumbers) fps \(r.frameRate) video \(r.sendsVideo) changed \(r.sendsOnlyChanged) audio \(r.sendsAudio) height \(r.frameHeight) style \(styleDigest(r.style)) effective \(styleDigest(r.effectiveStyle)) bgimage \(r.effectiveStyle.backgroundImagePath.map { ($0 as NSString).lastPathComponent } ?? "-") dim \(r.effectiveStyle.dimBackground) alpha \(r.effectiveStyle.backgroundColor.alpha)")
        let composed = r.compose(slide)
        let blank = r.compose(.blank)
        print("  compose «\(composed.mainText)» sec \(composed.secondaryTexts.joined(separator: "|")) ref «\(composed.reference)» blank \(composed.isBlank) | blank \(blank.isBlank) «\(blank.reference)»")
    }
    let web = configuration.web
    print("\(name) web http \(web.httpEnabled):\(web.httpPort) ws \(web.webSocketEnabled):\(web.webSocketPort) tcp \(web.tcpEnabled):\(web.tcpPort) udp \(web.udpEnabled):\(web.udpPort) pages \(web.pages.count): \(web.pages.map { "\($0.fileName)=\($0.title)" }.joined(separator: ","))")
}

func checkOutputs(_ data: URL) {
    print("# outputs")
    let config = try! IniSettings(fileAt: data.appendingPathComponent("Slovo.ini"))
    printOutputs("data", OutputConfiguration(config: config, dataRoot: data))
    printOutputs("none", OutputConfiguration(config: nil, dataRoot: nil))
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("slovo-check-outputs-" + UUID().uuidString)
    try! fm.createDirectory(at: root.appendingPathComponent("RemoteAPI"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    for name in ["b.html", "A.HTML", ".hidden.html", "x.txt", "BIBLE-FOREST.html", "сторінка.html"] {
        try! Data("<html></html>".utf8).write(to: root.appendingPathComponent("RemoteAPI").appendingPathComponent(name))
    }
    for (label, text) in [
        ("custom", "[OutScreen]\nShowVersNum=1\nNdiSendSlide=1\nNdiTransparentBackGr=1\nNdiSendVideo=1\nNdiSendOnlyChanged=0\nNdiSendAudio=0\nNdiFrameHeight=720\nNdiFpsId=2\n[RemoteApi]\nWEBEnabled=1\nWEBPort=8080\nWSEnabled=1\nWSPort=9000\nTCPEnabled=1\nTCPPort=9001\nUDPEnabled=1\nUDPPort=9002\n"),
        ("fps99", "[OutScreen]\nNdiFpsId=99\nNdiTransparentBackGr=0\n"),
        ("fps4", "[OutScreen]\nNdiFpsId=4\n"),
        ("fps-1", "[OutScreen]\nNdiFpsId=-1\n[Bible]\nBackColor=255\n"),
        ("fps5", "[OutScreen]\nNdiFpsId=5\n"),
        ("fps12", "[OutScreen]\nNdiFpsId=12\n"),
    ] {
        printOutputs(label, OutputConfiguration(config: IniSettings(text: text), dataRoot: root))
    }
    let configuration = OutputConfiguration(config: config, dataRoot: data)
    var copy = configuration
    copy[.stage] = OutputRules(isEnabled: true, frameRate: 5)
    print("copy stage \(copy[.stage].isEnabled) \(copy[.stage].frameRate) original \(configuration[.stage].isEnabled) \(configuration[.stage].frameRate) rules \(configuration.rules.count)")
    let defaults = OutputRules()
    print("default rules enabled \(defaults.isEnabled) bg \(defaults.drawsBackground) fps \(defaults.frameRate) audio \(defaults.sendsAudio) style \(styleDigest(defaults.style))")
    let made = WebOutputSettings.make()
    print("make http \(made.httpEnabled):\(made.httpPort) ws \(made.webSocketEnabled):\(made.webSocketPort) tcp \(made.tcpEnabled):\(made.tcpPort) udp \(made.udpEnabled):\(made.udpPort) pages \(made.pages.count) page \(WebOutputSettings.WebPage.make(fileName: "a.html", title: "a").id)")
    print("kinds " + OutputKind.allCases.map { "\($0.rawValue)=\($0.title)" }.joined(separator: ","))
    print("rates " + OutputConfiguration.ndiFrameRates.map { "\($0)" }.joined(separator: ",") + " | " + OutputConfiguration.ndiFrameRateTitles.joined(separator: "|"))
}
