// =============================================================================
//  CoreCheck.Outputs.cs — перевірка ядра: правила виводів (`--section outputs`)
// =============================================================================
//  Дзеркало еталона на Mac (slovo-ref, Outputs.swift).
// =============================================================================

using System.Text;

namespace Slovo.Core;

public static partial class CoreCheck
{
    /// Стиль без шляху до теки даних (у C# дані — тимчасова копія).
    private static string StyleDigest(SlideStyle style)
    {
        var portable = style;
        if (portable.BackgroundImagePath is { } path) portable.BackgroundImagePath = SwiftPath.LastComponent(path);
        return Fnv(Json(portable));
    }

    private static void PrintOutputs(string name, OutputConfiguration configuration)
    {
        var slide = new Slide("Текст", ["Другий", "Третій"], "Ів 3:16");
        foreach (var kind in OutputKinds.All)
        {
            var r = configuration[kind];
            P($"{name} {kind.RawValue()} enabled {B(r.IsEnabled)} bg {B(r.DrawsBackground)} ref {B(r.ShowsReference)} sec {B(r.ShowsSecondaryTranslations)} nums {B(r.ShowsVerseNumbers)} fps {r.FrameRate} video {B(r.SendsVideo)} changed {B(r.SendsOnlyChanged)} audio {B(r.SendsAudio)} height {r.FrameHeight} style {StyleDigest(r.Style)} effective {StyleDigest(r.EffectiveStyle)} bgimage {(r.EffectiveStyle.BackgroundImagePath is { } p ? SwiftPath.LastComponent(p) : "-")} dim {D(r.EffectiveStyle.DimBackground)} alpha {D(r.EffectiveStyle.BackgroundColor.Alpha)}");
            var composed = r.Compose(slide);
            var blank = r.Compose(Slide.Blank);
            P($"  compose «{composed.MainText}» sec {Join(composed.SecondaryTexts, "|")} ref «{composed.Reference}» blank {B(composed.IsBlank)} | blank {B(blank.IsBlank)} «{blank.Reference}»");
        }
        var web = configuration.Web;
        P($"{name} web http {B(web.HttpEnabled)}:{web.HttpPort} ws {B(web.WebSocketEnabled)}:{web.WebSocketPort} tcp {B(web.TcpEnabled)}:{web.TcpPort} udp {B(web.UdpEnabled)}:{web.UdpPort} pages {web.Pages.Count}: {Join(web.Pages.Select(page => $"{page.FileName}={page.Title}"))}");
    }

    private static void Outputs(string dataPath)
    {
        P("# outputs");
        var config = IniSettings.FromFile(Path.Combine(dataPath, "Slovo.ini"));
        PrintOutputs("data", new OutputConfiguration(config, dataPath));
        PrintOutputs("none", new OutputConfiguration(null, null));
        var root = Path.Combine(Path.GetTempPath(), "slovo-check-outputs-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(root, "RemoteAPI"));
        try
        {
            foreach (var name in new[] { "b.html", "A.HTML", ".hidden.html", "x.txt", "BIBLE-FOREST.html", "сторінка.html" })
                File.WriteAllText(Path.Combine(root, "RemoteAPI", name), "<html></html>");
            foreach (var (label, text) in new[]
                     {
                         ("custom", "[OutScreen]\nShowVersNum=1\nNdiSendSlide=1\nNdiTransparentBackGr=1\nNdiSendVideo=1\nNdiSendOnlyChanged=0\nNdiSendAudio=0\nNdiFrameHeight=720\nNdiFpsId=2\n[RemoteApi]\nWEBEnabled=1\nWEBPort=8080\nWSEnabled=1\nWSPort=9000\nTCPEnabled=1\nTCPPort=9001\nUDPEnabled=1\nUDPPort=9002\n"),
                         ("fps99", "[OutScreen]\nNdiFpsId=99\nNdiTransparentBackGr=0\n"),
                         ("fps4", "[OutScreen]\nNdiFpsId=4\n"),
                         ("fps-1", "[OutScreen]\nNdiFpsId=-1\n[Bible]\nBackColor=255\n"),
                         ("fps5", "[OutScreen]\nNdiFpsId=5\n"),
                         ("fps12", "[OutScreen]\nNdiFpsId=12\n"),
                     })
                PrintOutputs(label, new OutputConfiguration(new IniSettings(text), root));
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
        var configuration = new OutputConfiguration(config, dataPath);
        var copy = configuration;
        copy[OutputKind.Stage] = new OutputRules(isEnabled: true, frameRate: 5);
        P($"copy stage {B(copy[OutputKind.Stage].IsEnabled)} {copy[OutputKind.Stage].FrameRate} original {B(configuration[OutputKind.Stage].IsEnabled)} {configuration[OutputKind.Stage].FrameRate} rules {configuration.Rules.Count}");
        var defaults = new OutputRules();
        P($"default rules enabled {B(defaults.IsEnabled)} bg {B(defaults.DrawsBackground)} fps {defaults.FrameRate} audio {B(defaults.SendsAudio)} style {StyleDigest(defaults.Style)}");
        var made = WebOutputSettings.Make();
        P($"make http {B(made.HttpEnabled)}:{made.HttpPort} ws {B(made.WebSocketEnabled)}:{made.WebSocketPort} tcp {B(made.TcpEnabled)}:{made.TcpPort} udp {B(made.UdpEnabled)}:{made.UdpPort} pages {made.Pages.Count} page {WebOutputSettings.WebPage.Make("a.html", "a").Id}");
        P("kinds " + Join(OutputKinds.All.Select(kind => $"{kind.RawValue()}={kind.Title()}")));
        P("rates " + Join(OutputConfiguration.NdiFrameRates.Select(D)) + " | " + Join(OutputConfiguration.NdiFrameRateTitles, "|"));
    }
}
