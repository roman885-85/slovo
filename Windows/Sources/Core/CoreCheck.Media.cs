// =============================================================================
//  CoreCheck.Media.cs — перевірка ядра: посилання YouTube (`--section media`)
// =============================================================================

namespace Slovo.Core;

public static partial class CoreCheck
{
    internal static readonly string[] YouTubeSamples =
    [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://youtube.com/watch?feature=share&v=dQw4w9WgXcQ&t=42",
        "https://m.youtube.com/watch?v=dQw4w9WgXcQ#t=1",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD",
        "https://youtu.be/dQw4w9WgXcQ?si=abc",
        "https://www.youtu.be/dQw4w9WgXcQ",
        "https://youtu.be/",
        "https://youtu.be/dQw4w9WgXcQ/extra",
        "https://www.youtube.com/live/abcdefghijk?feature=share",
        "https://www.youtube.com/shorts/ABCDEFGHIJK",
        "https://www.youtube.com/embed/a_b-c_d-e_f",
        "https://www.youtube-nocookie.com/embed/a_b-c_d-e_f?rel=0",
        "https://www.youtube.com/v/dQw4w9WgXcQ",
        "https://www.youtube.com/LIVE/dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=short",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQX",
        "https://www.youtube.com/watch?v=dQw4w9WgXc%21",
        "https://www.youtube.com/watch?v=dQw4w9WgXc%2D",
        "https://www.youtube.com/watch?v",
        "https://www.youtube.com/watch?v=&v=dQw4w9WgXcQ",
        "https://www.youtube.com/live/dQw4w9WgXcQ?v=",
        "https://www.youtube.com/channel/UC123",
        "https://www.youtube.com/",
        "https://www.youtube.com/playlist?list=PL123",
        "https://WWW.YOUTUBE.COM/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com:443/watch?v=dQw4w9WgXcQ",
        "http://youtube.com//shorts//dQw4w9WgXcQ",
        "https://vimeo.com/123456",
        "https://notyoutube.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=дQw4w9WgXcQ",
        "https://www.youtube.com/shorts/dQw4w9WgXc%D1%8F",
        "youtube.com/watch?v=dQw4w9WgXcQ",
        "file:///Users/x/video.mp4",
        "https://www.youtube.com/watch?x=1&v=a%2Bb-c_d-e_f",
        "https://user:pass@youtube.com/watch?v=dQw4w9WgXcQ",
    ];

    private static void Media()
    {
        P("# media");
        P("hosts " + Join(YouTubeLink.Hosts.OrderBy(host => host, StringComparer.Ordinal)));
        foreach (var sample in YouTubeSamples)
            P($"youtube {sample} → {B(YouTubeLink.IsYouTube(sample))} {YouTubeLink.VideoID(sample) ?? "nil"}");
        P($"watch {YouTubeLink.WatchURL("dQw4w9WgXcQ")?.AbsoluteUri ?? "nil"}");
    }
}
