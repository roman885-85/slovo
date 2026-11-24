// =============================================================================
//  HTTPStaticServer.cs — HTTP-сервер веб-слайдів (з SlovoCore/Web/HTTPStaticServer.swift)
// =============================================================================
//  Віддає теку `RemoteAPI` як є (сторінки автора — без правок, лише з адресою
//  цього комп'ютера, щоб сторінка знайшла WebSocket) і свою теку сторінок
//  власника; збирає стартовий список за `index.tpl`; свою сторінку «як на
//  проекторі» малює кодом. Відповідь — одна на з'єднання з `Connection: close`:
//  файли маленькі, keep-alive виграє мілісекунди, а коштує цілого класу помилок
//  із «завислими» сокетами посеред служіння.
//
//  На Mac — NWListener; тут — TcpListener (HttpListener у Windows без прав
//  адміністратора слухає лише localhost, а сторінки відкривають з телефона в залі).
// =============================================================================

using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Slovo.Core;

public sealed class HTTPStaticServer
{
    public sealed record Configuration
    {
        /// Тека з авторськими сторінками (зазвичай `<дані>/RemoteAPI`).
        public string Root { get; init; } = "";
        /// Свої теки: сторінки, намальовані в майстерні, лежать окремо від авторських.
        public IReadOnlyList<string> ExtraRoots { get; init; } = Array.Empty<string>();
        public WebListenerOptions Listener { get; init; } = new(82, 8082);
        public WebIndexModel Index { get; init; } = new();
        /// Куди сторінкам стукатися за слайдами.
        public int WebSocketPort { get; init; } = 8100;
        /// Чи підміняти вшиті в сторінки адреси WebSocket.
        public bool RetargetsWebSocket { get; init; } = true;
        /// Картинки й шрифти нинішнього шаблону — закритим списком.
        public WebSlideImages? Images { get; init; }
        public WebSlideImages? Fonts { get; init; }
        /// Значок вкладки (PNG): свій сильніший за `favicon.ico` старої програми в теці.
        public byte[]? Favicon { get; init; }
    }

    /// Більше за це в заголовках запиту бути не може — отже, це не браузер.
    const int MaxRequestSize = 64 * 1024;
    /// Браузери люблять відкрити сокет заздалегідь і нічого в нього не написати.
    static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(15);

    readonly Configuration _configuration;
    readonly object _lock = new();
    TcpListener? _listener;
    CancellationTokenSource? _stopping;

    public HTTPStaticServer(Configuration configuration) => _configuration = configuration;

    /// Порт, який сервер зайняв насправді (при порту 0 його призначає система).
    public int? BoundPort { get; private set; }

    // ── Життєвий цикл ─────────────────────────────────────────────────────────

    public (int? Port, WebServerError? Error) Start()
    {
        lock (_lock)
        {
            if (_listener != null) return (null, WebServerError.Network(OurWords.T("HTTP-сервер уже запущен")));
            // Теки сторінок може не бути зовсім — і це не привід не вмикатися: свої
            // сторінки (слайд і перелік) ми малюємо кодом. Теку просто заводимо.
            try { if (!Directory.Exists(_configuration.Root)) Directory.CreateDirectory(_configuration.Root); } catch { }
            var options = _configuration.Listener;
            var listener = new TcpListener(IPAddress.Any, options.Port);
            try
            {
                listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, false);
                listener.Start(64);
            }
            catch (Exception error)
            {
                try { listener.Stop(); } catch { }
                return (null, WebServerError.From(error, options.Port, options.FallbackPort));
            }
            _listener = listener;
            _stopping = new CancellationTokenSource();
            BoundPort = ((IPEndPoint)listener.LocalEndpoint).Port;
            _ = AcceptLoop(listener, _stopping.Token);
            return (BoundPort, null);
        }
    }

    public void Stop()
    {
        lock (_lock)
        {
            try { _stopping?.Cancel(); } catch { }
            try { _listener?.Stop(); } catch { }
            _listener = null;
            _stopping = null;
            BoundPort = null;
        }
    }

    async Task AcceptLoop(TcpListener listener, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(token); }
            catch { break; }
            _ = Task.Run(() => Session(client, token), CancellationToken.None);
        }
    }

    async Task Session(TcpClient client, CancellationToken token)
    {
        using (client)
        {
            // Режим «лише локально»: чужих відсікаємо тут.
            if (_configuration.Listener.LoopbackOnly && !WebListenerOptions.IsLoopback(client.Client.RemoteEndPoint)) return;
            client.NoDelay = true;
            try
            {
                var stream = client.GetStream();
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                timeout.CancelAfter(RequestTimeout);
                var buffer = new MemoryStream();
                var chunk = new byte[16 * 1024];
                HTTPRequestHead? request = null;
                while (request == null)
                {
                    var read = await stream.ReadAsync(chunk, timeout.Token);
                    if (read <= 0) return;
                    buffer.Write(chunk, 0, read);
                    if (buffer.Length > MaxRequestSize)
                    {
                        await Respond(stream, 431, "Request Header Fields Too Large", "text/plain; charset=utf-8",
                                      Encoding.UTF8.GetBytes("Слишком большой запрос"), false);
                        return;
                    }
                    request = HTTPRequestHead.Parse(buffer.ToArray());
                }
                await Serve(request, stream);
            }
            catch { /* мовчазне або обірване з'єднання — не привід тримати дескриптор */ }
        }
    }

    // ── Відповіді ─────────────────────────────────────────────────────────────

    async Task Serve(HTTPRequestHead request, NetworkStream stream)
    {
        var headOnly = request.Method == "HEAD";
        if (request.Method != "GET" && !headOnly)
        {
            await Respond(stream, 405, "Method Not Allowed", "text/plain; charset=utf-8",
                          Encoding.UTF8.GetBytes(OurWords.T("Поддерживаются только GET и HEAD")), false);
            return;
        }

        var host = SanitizedHost(request.Host);
        // Рядок запиту відрізаємо одразу: на диску йому відповідності немає.
        var path = request.Path.Split('?', 2)[0].ToLowerInvariant();

        // Значок вкладки: свій, а не той, що лишився в теці від старої програми.
        if (path is "/favicon.ico" or "/favicon.png" or "/apple-touch-icon.png" or "/apple-touch-icon-precomposed.png"
            && _configuration.Favicon is { Length: > 0 } icon)
        {
            await Respond(stream, 200, "OK", "image/png", icon, headOnly);
            return;
        }

        // «Відео по Wi-Fi» (живий потік HLS) — окрема частина, у Windows-версії її ще немає.
        if (path == "/wifi" || path.StartsWith("/wifi/", StringComparison.Ordinal))
        {
            await Respond(stream, 503, "Service Unavailable", "text/plain; charset=utf-8",
                          Encoding.UTF8.GetBytes(OurWords.T("Видео по Wi-Fi выключено")), headOnly);
            return;
        }

        // Своя сторінка «як на проекторі». Живе в коді, а не файлом у чужій теці.
        if (path is "/slovo-slide-overlay.html" or "/slovo-slide-overlay")
        {
            // Той самий слайд, але без фону — для накладання поверх відео.
            var page = WebSlovoSlidePage.Html(_configuration.WebSocketPort, host)
                .Replace("<html lang=\"uk\">", "<html lang=\"uk\" class=\"overlay\">");
            await Respond(stream, 200, "OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(page), headOnly);
            return;
        }
        if (path == "/" + WebSlovoSlidePage.FileName || path == "/slovo-slide")
        {
            var page = WebSlovoSlidePage.Html(_configuration.WebSocketPort, host);
            await Respond(stream, 200, "OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(page), headOnly);
            return;
        }

        // Картинки й шрифти шаблону: ім'я коротке, віддаємо лише названі в нинішньому шаблоні.
        if (path.StartsWith("/slide-image/", StringComparison.Ordinal))
        {
            var id = path["/slide-image/".Length..];
            if (_configuration.Images?.File(id) is { } file && TryRead(file) is { } data)
                await Respond(stream, 200, "OK", ContentType(file), data, headOnly);
            else
                await Respond(stream, 404, "Not Found", "text/plain; charset=utf-8",
                              Encoding.UTF8.GetBytes(OurWords.T("Такой картинки в шаблоне нет")), headOnly);
            return;
        }
        if (path.StartsWith("/slide-font/", StringComparison.Ordinal))
        {
            var id = path["/slide-font/".Length..];
            if (_configuration.Fonts?.File(id) is { } file && TryRead(file) is { } data)
                await Respond(stream, 200, "OK", "font/ttf", data, headOnly);
            else
                await Respond(stream, 404, "Not Found", "text/plain; charset=utf-8",
                              Encoding.UTF8.GetBytes(OurWords.T("Такого шрифта в шаблоне нет")), headOnly);
            return;
        }

        if (path is "" or "/" or "/index.html" or "/index.htm" or "/index.tpl")
        {
            await Respond(stream, 200, "OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(RenderIndex(host)), headOnly);
            return;
        }

        if (Resolve(request.Path) is not { } found || TryRead(found) is not { } content)
        {
            await Respond(stream, 404, "Not Found", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(NotFoundPage), headOnly);
            return;
        }

        var type = ContentType(found);
        if (IsMarkup(found))
        {
            // Сторінки автора бувають і в UTF-8, і у Windows-1251.
            var text = CodePage.Decode(content, CodePage.IsValidUtf8(content) ? CodePage.Utf8 : null);
            var page = WebTemplate.RenderPage(text, _configuration.Index, host);
            page = WebTemplate.ReplaceAuthorPhrases(page);
            if (_configuration.RetargetsWebSocket) page = WebTemplate.RetargetWebSocket(page, host, _configuration.WebSocketPort);
            await Respond(stream, 200, "OK", type, Encoding.UTF8.GetBytes(page), headOnly);
        }
        else await Respond(stream, 200, "OK", type, content, headOnly);
    }

    string RenderIndex(string host)
    {
        // У переліку — лише те, що програма справді віддасть: на чистій машині
        // файлів чужих сторінок немає, і посилання вели в 404. Свої сторінки
        // малюються кодом — вони лишаються завжди.
        var mineNames = new HashSet<string>(StringComparer.Ordinal) { WebSlovoSlidePage.FileName, "slovo-slide-overlay.html" };
        var entries = _configuration.Index.Entries.Where(entry =>
        {
            if (mineNames.Contains(entry.Name)) return true;
            var shortName = entry.Name.Replace(".html", "").Replace(".htm", "");
            return Resolve("/" + entry.Name) != null || Resolve("/" + shortName.ToLowerInvariant()) != null;
        }).ToList();
        // Своя сторінка — першою: по неї приходять найчастіше.
        var mine = new WebIndexModel.Entry(WebSlovoSlidePage.FileName, OurWords.T("Слово: как на проекторе — объекты шаблона, фон и шрифты"));
        if (!entries.Any(entry => entry.Name == mine.Name)) entries.Insert(0, mine);
        var model = _configuration.Index with { Entries = entries };
        var templateFile = Path.Combine(_configuration.Root, "index.tpl");
        if (TryRead(templateFile) is not { } data) return FallbackIndex(model);
        var text = CodePage.Decode(data, CodePage.IsValidUtf8(data) ? CodePage.Utf8 : null);
        return WebTemplate.RenderIndex(text, model, host);
    }

    static async Task Respond(NetworkStream stream, int status, string reason, string contentType, byte[] body, bool headOnly)
    {
        var head = new StringBuilder();
        head.Append("HTTP/1.1 ").Append(status).Append(' ').Append(reason).Append("\r\n");
        head.Append("Server: Slovo\r\n");
        head.Append("Content-Type: ").Append(contentType).Append("\r\n");
        head.Append("Content-Length: ").Append(body.Length).Append("\r\n");
        // Слайд міняється щохвилини — кеш браузера тут лише шкодить.
        head.Append("Cache-Control: no-store\r\n");
        head.Append("Connection: close\r\n\r\n");
        await stream.WriteAsync(Encoding.UTF8.GetBytes(head.ToString()));
        if (!headOnly) await stream.WriteAsync(body);
        await stream.FlushAsync();
    }

    static byte[]? TryRead(string file)
    {
        try { return File.Exists(file) ? File.ReadAllBytes(file) : null; } catch { return null; }
    }

    // ── Файли ─────────────────────────────────────────────────────────────────

    /// Зводить шлях запиту до файла всередині кореня — або відмовляє.
    string? Resolve(string requestPath)
    {
        var withoutQuery = requestPath.Split('?', 2)[0];
        var decoded = SwiftUrl.RemovingPercentEncoding(withoutQuery) ?? withoutQuery;
        var components = decoded.Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
        // «..» і «.» — єдиний спосіб вийти з теки RemoteAPI. У Windows ще й зворотна
        // скісна та двокрапка («..\\», «C:») — їх у назві сторінки не буває.
        if (components.Any(part => part is ".." or ".") || components.Count == 0) return null;
        if (components.Any(part => part.Contains('\\') || part.Contains(':'))) return null;

        // Авторська тека йде першою: її сторінки головніші.
        foreach (var root in new[] { _configuration.Root }.Concat(_configuration.ExtraRoots))
        {
            if (root.Length == 0) continue;
            string full, rootFull;
            try
            {
                rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
                full = Path.GetFullPath(Path.Combine(new[] { rootFull }.Concat(components).ToArray()));
            }
            catch { continue; }
            if (full != rootFull && !full.StartsWith(rootFull + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) continue;
            if (File.Exists(full)) return full;
        }
        // Імені файлу в адресі не знайшлося — шукаємо за коротким ім'ям
        // («/vbwebslide-kopiia» замість «/VBWebSlide%20копія.html»).
        return ByShortName(components);
    }

    /// Сторінка за коротким ім'ям — і за ім'ям файлу без розширення.
    string? ByShortName(List<string> components)
    {
        if (components.Count != 1) return null;
        var wanted = components[0].ToLowerInvariant();
        var slug = WebPageAddress.Slug(components[0]);
        foreach (var root in new[] { _configuration.Root }.Concat(_configuration.ExtraRoots))
        {
            string[] files;
            try { files = Directory.Exists(root) ? Directory.GetFiles(root) : Array.Empty<string>(); } catch { continue; }
            foreach (var file in files)
            {
                if (!IsMarkup(file)) continue;
                var name = Path.GetFileName(file);
                var stem = SwiftPath.DeletingExtension(name);
                if (stem.ToLowerInvariant() == wanted || WebPageAddress.Slug(name) == slug) return file;
            }
        }
        return null;
    }

    static bool IsMarkup(string file) => SwiftPath.Extension(file).ToLowerInvariant() is "html" or "htm" or "tpl";

    static string ContentType(string file) => SwiftPath.Extension(file).ToLowerInvariant() switch
    {
        "html" or "htm" or "tpl" => "text/html; charset=utf-8",
        "js" or "mjs" => "application/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" or "map" => "application/json; charset=utf-8",
        "txt" => "text/plain; charset=utf-8",
        "ico" => "image/x-icon",
        "png" => "image/png",
        "jpg" or "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "webp" => "image/webp",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "mp3" => "audio/mpeg",
        "mp4" => "video/mp4",
        _ => "application/octet-stream",
    };

    /// Заголовок `Host` приходить від клієнта, а ми вставляємо його просто в
    /// JavaScript сторінки — пропускаємо лише те, з чого складаються імена й адреси.
    internal static string SanitizedHost(string? raw)
    {
        var host = raw?.TrimWhitespaces() ?? "";
        if (host.Length == 0) return "localhost";
        if (host.StartsWith('[') && host.IndexOf(']') is var close and >= 0) host = host[..(close + 1)];   // IPv6
        else if (host.IndexOf(':') is var colon and >= 0) host = host[..colon];
        if (host.Length == 0 || host.Length > 253) return "localhost";
        const string allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]";
        return host.All(allowed.Contains) ? host : "localhost";
    }

    static readonly string NotFoundPage = """
        <!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><title>404</title></head>
        <body style="font-family: -apple-system, sans-serif; padding: 40px">
        <h1>404</h1><p>Такой страницы в папке RemoteAPI нет.</p>
        <p><a href="/">К списку страниц</a></p></body></html>
        """;

    /// Якщо авторського `index.tpl` поруч немає, список усе одно має відкритися.
    static string FallbackIndex(WebIndexModel model)
    {
        var rows = string.Concat(model.Entries.Select(entry =>
        {
            var address = WebTemplate.Escape(WebPageAddress.Slug(entry.Name));
            return $"<li><a href=\"{address}\">{WebTemplate.Escape(entry.Name)}</a> — "
                   + WebTemplate.Escape(entry.Description) + $" <code>/{address}</code></li>";
        }));
        return $$"""
            <!DOCTYPE html><html lang="{{WebTemplate.Escape(model.LanguageCode)}}"><head><meta charset="UTF-8">
            <title>{{WebTemplate.Escape(model.Title)}}</title></head>
            <body style="font-family: -apple-system, sans-serif; padding: 40px">
            <h1>{{WebTemplate.Escape(model.Title)}}</h1><ul>{{rows}}</ul></body></html>
            """;
    }
}

/// Початок HTTP-запиту. Тіло нам не потрібне: сервер віддає файли і тільки.
internal sealed record HTTPRequestHead(string Method, string Path, string? Host)
{
    /// null — заголовки ще не дочитано; чекаємо наступну порцію байтів.
    public static HTTPRequestHead? Parse(byte[] buffer)
    {
        if (HeaderEnd(buffer) is not { } separator) return null;
        var headBytes = buffer[..separator];
        string text;
        try { text = new UTF8Encoding(false, true).GetString(headBytes); }
        catch { text = Encoding.Latin1.GetString(headBytes); }

        var lines = text.Split("\r\n").SelectMany(line => line.Split('\n')).Where(line => line.Length > 0).ToList();
        if (lines.Count == 0) return null;
        var parts = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return null;
        var host = lines.Skip(1).FirstOrDefault(line => line.ToLowerInvariant().StartsWith("host:", StringComparison.Ordinal));
        return new HTTPRequestHead(parts[0].ToUpperInvariant(), parts[1], host?["host:".Length..].TrimWhitespaces());
    }

    static int? HeaderEnd(byte[] bytes)
    {
        for (var index = 0; index + 1 < bytes.Length; index++)
        {
            if (bytes[index] == 0x0D && index + 3 < bytes.Length && bytes[index + 1] == 0x0A && bytes[index + 2] == 0x0D && bytes[index + 3] == 0x0A)
                return index;
            if (bytes[index] == 0x0A && bytes[index + 1] == 0x0A) return index;
        }
        return null;
    }
}
