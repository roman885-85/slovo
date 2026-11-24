// =============================================================================
//  HttpServer.cs — маленький HTTP поверх TcpListener
// =============================================================================
//  Свій, а не HttpListener: той у Windows без прав адміністратора слухає
//  лише localhost, а пульт має доходити з телефона в мережі. Тут — рівно те,
//  що робить NWListener у «Слові» на Mac: прочитати запит цілком (заголовки й
//  тіло за Content-Length), віддати відповідь і закрити з'єднання. Довгий
//  опит стану тримає з'єднання відкритим — відповідь іде з першою зміною.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Slovo.App;

public sealed class HttpRequest
{
    public string Method = "GET";
    public string Path = "/";
    public Dictionary<string, string> Query = new();
    public Dictionary<string, string> Headers = new();
    public byte[] Body = Array.Empty<byte>();
    /// Прийшов портом браузерного пульта.
    public bool Web;
    public IPAddress? Remote;

    public string Q(string name) => Query.TryGetValue(name, out var value) ? value : "";
    public int? QInt(string name) => int.TryParse(Q(name), out var value) ? value : null;
}

/// Одне з'єднання: відповідь пишеться один раз, потім з'єднання закривається.
public sealed class HttpConnection
{
    readonly TcpClient _client;
    readonly NetworkStream _stream;
    int _answered;

    internal HttpConnection(TcpClient client, NetworkStream stream) { _client = client; _stream = stream; }

    public bool IsAnswered => _answered != 0;

    public Task Respond(int status, string contentType, byte[] body, Dictionary<string, string>? extra = null)
    {
        if (Interlocked.Exchange(ref _answered, 1) != 0) return Task.CompletedTask;
        return Task.Run(async () =>
        {
            try
            {
                var reason = status switch { 200 => "OK", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", _ => "Error" };
                var head = new StringBuilder();
                head.Append("HTTP/1.1 ").Append(status).Append(' ').Append(reason).Append("\r\n");
                head.Append("Content-Type: ").Append(contentType).Append("\r\n");
                if (extra != null) foreach (var (name, value) in extra) head.Append(name).Append(": ").Append(value).Append("\r\n");
                head.Append("Content-Length: ").Append(body.Length).Append("\r\n");
                head.Append("Access-Control-Allow-Origin: *\r\n");
                head.Append("Cache-Control: no-store\r\n");
                head.Append("Connection: close\r\n\r\n");
                var bytes = Encoding.ASCII.GetBytes(head.ToString());
                await _stream.WriteAsync(bytes);
                await _stream.WriteAsync(body);
                await _stream.FlushAsync();
            }
            catch { /* клієнт пішов */ }
            finally
            {
                try { _client.Close(); } catch { /* уже закрито */ }
            }
        });
    }

    public Task RespondJson(int status, string json) => Respond(status, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json));

    public void Close()
    {
        if (Interlocked.Exchange(ref _answered, 1) != 0) return;
        try { _client.Close(); } catch { /* уже закрито */ }
    }
}

public sealed class HttpServer
{
    readonly TcpListener _listener;
    readonly bool _web;
    readonly Func<HttpRequest, HttpConnection, Task> _handler;
    CancellationTokenSource? _stopping;
    public int Port { get; private set; }
    public string? Error { get; private set; }
    public bool IsRunning => _stopping != null && !_stopping.IsCancellationRequested;

    public HttpServer(int port, bool web, Func<HttpRequest, HttpConnection, Task> handler)
    {
        _listener = new TcpListener(IPAddress.Any, port);
        _web = web;
        _handler = handler;
        Port = port;
    }

    /// Підняти слухач; false — порт зайнятий (причина в `Error`).
    public bool Start()
    {
        try
        {
            _listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, false);
            _listener.Start(64);
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _stopping = new CancellationTokenSource();
            _ = AcceptLoop(_stopping.Token);
            Error = null;
            return true;
        }
        catch (SocketException error)
        {
            Error = error.SocketErrorCode == SocketError.AddressAlreadyInUse
                ? Captions.T("порт %s занят другой программой — выберите другой", Port)
                : error.Message;
            return false;
        }
        catch (Exception error)
        {
            Error = error.Message;
            return false;
        }
    }

    public void Stop()
    {
        try { _stopping?.Cancel(); } catch { /* уже */ }
        try { _listener.Stop(); } catch { /* уже */ }
        _stopping = null;
    }

    async Task AcceptLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(token); }
            catch { break; }
            _ = Task.Run(() => Serve(client, token), token);
        }
    }

    async Task Serve(TcpClient client, CancellationToken token)
    {
        client.NoDelay = true;
        var stream = client.GetStream();
        var connection = new HttpConnection(client, stream);
        try
        {
            var request = await Read(stream, token);
            if (request == null) { connection.Close(); return; }
            request.Web = _web;
            request.Remote = (client.Client.RemoteEndPoint as IPEndPoint)?.Address;
            await _handler(request, connection);
        }
        catch (Exception error)
        {
            Journal.Say("пульт: запит не розібрався — " + error);
            connection.Close();
        }
    }

    /// Прочитати запит цілком. Командам вистачає 256 КБ; завантаження файла
    /// оголошує довжину заздалегідь — йому даємо стільки, скільки сказано, але
    /// не більше 256 МБ.
    static async Task<HttpRequest?> Read(NetworkStream stream, CancellationToken token)
    {
        var buffer = new MemoryStream();
        var chunk = new byte[65536];
        var headerEnd = -1;
        var declared = 0L;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromMinutes(15));
        while (true)
        {
            var read = await stream.ReadAsync(chunk, timeout.Token);
            if (read <= 0) return null;
            buffer.Write(chunk, 0, read);
            if (headerEnd < 0)
            {
                headerEnd = IndexOf(buffer.GetBuffer(), (int)buffer.Length, "\r\n\r\n"u8.ToArray());
                if (headerEnd < 0) { if (buffer.Length > 262_144) return null; continue; }
                var headText = Encoding.UTF8.GetString(buffer.GetBuffer(), 0, headerEnd);
                foreach (var line in headText.Split("\r\n"))
                    if (line.StartsWith("content-length:", StringComparison.OrdinalIgnoreCase))
                        long.TryParse(line[15..].Trim(), out declared);
                if (declared > 268_435_456) return null;
            }
            if (buffer.Length >= headerEnd + 4 + declared) break;
        }
        var all = buffer.GetBuffer();
        var head = Encoding.UTF8.GetString(all, 0, headerEnd);
        var lines = head.Split("\r\n");
        var requestLine = lines[0].Split(' ');
        if (requestLine.Length < 2) return null;
        var request = new HttpRequest { Method = requestLine[0].ToUpperInvariant() };
        for (var i = 1; i < lines.Length; i++)
        {
            var colon = lines[i].IndexOf(':');
            if (colon <= 0) continue;
            request.Headers[lines[i][..colon].Trim().ToLowerInvariant()] = lines[i][(colon + 1)..].Trim();
        }
        var target = requestLine[1];
        var mark = target.IndexOf('?');
        request.Path = Uri.UnescapeDataString(mark < 0 ? target : target[..mark]);
        if (mark >= 0)
            foreach (var pair in target[(mark + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var eq = pair.IndexOf('=');
                var name = Uri.UnescapeDataString(eq < 0 ? pair : pair[..eq]);
                var value = eq < 0 ? "" : Uri.UnescapeDataString(pair[(eq + 1)..].Replace('+', ' '));
                request.Query[name] = value;
            }
        var bodyStart = headerEnd + 4;
        var length = (int)Math.Min(declared, buffer.Length - bodyStart);
        request.Body = new byte[length];
        Array.Copy(all, bodyStart, request.Body, 0, length);
        return request;
    }

    static int IndexOf(byte[] data, int length, byte[] pattern)
    {
        for (var i = 0; i <= length - pattern.Length; i++)
        {
            var ok = true;
            for (var j = 0; j < pattern.Length; j++) if (data[i + j] != pattern[j]) { ok = false; break; }
            if (ok) return i;
        }
        return -1;
    }
}
