import Foundation
import SlovoCore

// Еталон розділу `media` — дзеркало CoreCheck.Media.cs.
let youTubeSamples = [
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
]

func checkMedia() {
    print("# media")
    print("hosts " + YouTubeLink.hosts.sorted().joined(separator: ","))
    for sample in youTubeSamples {
        let url = URL(string: sample)
        print("youtube \(sample) → \(url.map { YouTubeLink.isYouTube($0) } ?? false) \(url.flatMap { YouTubeLink.videoID(from: $0) } ?? "nil")")
    }
    print("watch \(YouTubeLink.watchURL(id: "dQw4w9WgXcQ")?.absoluteString ?? "nil")")
}
