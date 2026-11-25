// =============================================================================
//  YouTubeHostServer.cs — крихітний HTTP-сервер однієї сторінки (YouTubeHostServer Mac)
// =============================================================================
//  Сторінку-обгортку вбудованого програвача YouTube приймає тільки зі справжньої
//  адреси — із заголовком Referer і однаковим origin; сторінка з рядка відповідає
//  «помилкою конфігурації відеопрогравача» (коди 152/153, вимога YouTube з 2025 року;
//  перевірено на Mac 03.09.2026). Тож віддаємо її самі: лише петля (127.0.0.1) і
//  випадковий вільний порт — ззовні не видно, з портами веб-виводу не сперечається.
// =============================================================================

using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Slovo.App;

public sealed class YouTubeHostServer
{
    public static YouTubeHostServer Shared { get; } = new();

    TcpListener? _listener;
    public int Port { get; private set; }

    /// Запустити (раз) і віддати порт; 0 — не вдалося.
    public int Ensure()
    {
        if (_listener != null) return Port;
        try
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            _listener = listener;
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            _ = Accept(listener);
            return Port;
        }
        catch (Exception error)
        {
            Journal.Say("YouTube: сервер сторінки не запустився — " + error.Message);
            return 0;
        }
    }

    async Task Accept(TcpListener listener)
    {
        while (true)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(); } catch { return; }
            _ = Serve(client);
        }
    }

    static async Task Serve(TcpClient client)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var buffer = new byte[4096];
                var read = await stream.ReadAsync(buffer);
                var request = Encoding.ASCII.GetString(buffer, 0, read);
                var line = request.Split("\r\n", 2)[0].Split(' ');
                var target = line.Length > 1 ? line[1] : "/";
                var (status, body) = Answer(target);
                var bytes = Encoding.UTF8.GetBytes(body);
                var head = $"HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {bytes.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
                await stream.WriteAsync(Encoding.ASCII.GetBytes(head));
                await stream.WriteAsync(bytes);
            }
            catch { }
        }
    }

    static (string Status, string Body) Answer(string target)
    {
        var path = target.Split('?', 2)[0];
        if (path != "/player") return ("404 Not Found", "");
        var query = target.Contains('?') ? target.Split('?', 2)[1] : "";
        string? id = null;
        var autoplay = false;
        foreach (var pair in query.Split('&'))
        {
            var parts = pair.Split('=', 2);
            if (parts.Length != 2) continue;
            if (parts[0] == "v") id = Uri.UnescapeDataString(parts[1]);
            if (parts[0] == "autoplay") autoplay = parts[1] == "1";
        }
        return id != null && IsVideoId(id) ? ("200 OK", Page(id, autoplay)) : ("404 Not Found", "");
    }

    static bool IsVideoId(string id) => id.Length == 11 && id.All(c => c < 128 && (char.IsLetterOrDigit(c) || c is '-' or '_'));

    /// Обгортка: один iframe YouTube на весь екран, керування й стан — через їхній IFrame
    /// Player API, повідомлення — у програму через chrome.webview (WebKit на Mac).
    static string Page(string id, bool autoplay) => $$"""
        <!doctype html><html><head><meta charset="utf-8"><title>Слово · YouTube</title>
        <style>html,body{margin:0;background:#000;height:100%;overflow:hidden}
        #player{position:absolute;left:0;top:0;width:100%;height:100%}</style></head>
        <body><div id="player"></div>
        <script>
        var player, ticker;
        function say(m){ try { window.chrome.webview.postMessage(JSON.stringify(m)); } catch (e) {} }
        function tick(){
          if (!player || !player.getCurrentTime) return;
          say({kind:'time', cur: player.getCurrentTime() || 0, dur: player.getDuration() || 0, m: (player.isMuted && player.isMuted()) ? 1 : 0, v: player.getVolume ? player.getVolume() : -1});
        }
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('player', {
            videoId: '{{id}}', width: '100%', height: '100%',
            playerVars: {autoplay: {{(autoplay ? 1 : 0)}}, controls: 0, rel: 0, playsinline: 1,
                         iv_load_policy: 3, fs: 0, disablekb: 1, origin: location.origin},
            events: {
              onReady: function(){ say({kind:'ready'}); if (!ticker) ticker = setInterval(tick, 250); },
              onStateChange: function(e){ say({kind:'state', value: e.data}); tick(); },
              onError: function(e){ say({kind:'error', value: e.data}); }
            }
          });
        }
        var tag = document.createElement('script');
        tag.src = 'https://www.youtube.com/iframe_api';
        tag.onerror = function(){ say({kind:'error', value: -1}); };
        document.head.appendChild(tag);
        </script></body></html>
        """;
}
