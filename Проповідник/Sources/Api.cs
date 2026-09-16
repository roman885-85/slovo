// =============================================================================
//  Api.cs — розмова зі «Словом» каналом пульта: HTTP і JSON
// =============================================================================
//  Той самий канал, що в телефонного пульта й планшета (Пульт/Api.java): порт
//  8103, PIN — заголовком X-Slovo-Pin. Кожен запит — своє з'єднання з
//  «Connection: close»: після паузи залежане з'єднання з запасу мовчки падає.
// =============================================================================

using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Propovidnyk;

public sealed class PinRejectedException : IOException
{
    public PinRejectedException() : base("PIN") { }
}

public sealed class Api
{
    readonly string _base;
    readonly string _pin;

    static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.Zero,
        ConnectTimeout = TimeSpan.FromSeconds(6),
        UseProxy = false,
    })
    {
        Timeout = Timeout.InfiniteTimeSpan,
    };

    public Api(string host, int port, string pin)
    {
        var clean = host.Trim();
        // IPv6 у квадратних дужках, як велить адреса URL.
        if (clean.Contains(':') && !clean.StartsWith('[')) clean = "[" + clean + "]";
        _base = "http://" + clean + ":" + port;
        _pin = pin ?? "";
    }

    public static Api From(Settings settings) => new(settings.Host, settings.Port, settings.Pin);

    public string Base => _base;

    /// Причина обриву — словами, а не «немає зв'язку».
    public static string Describe(Exception error)
    {
        var inner = error;
        while (inner.InnerException != null && inner is HttpRequestException or TaskCanceledException) inner = inner.InnerException;
        // «Unable to read data from the transport connection» — це обгортка;
        // людині корисніше знати, що саме сталося під нею.
        if (inner is IOException { InnerException: SocketException socket } && socket.SocketErrorCode != SocketError.OperationAborted) inner = socket;
        return inner switch
        {
            PinRejectedException => Lang.T("«Слово» не прийняло PIN — перевірте його в підключенні", "Slovo rejected the PIN — check it in the connection settings"),
            TaskCanceledException or OperationCanceledException or TimeoutException =>
                Lang.T("«Слово» не відповіло вчасно — комп'ютер зайнятий чи мережа повільна; спробуйте ще раз",
                       "Slovo did not answer in time — the computer is busy or the network is slow; try again"),
            IOException { InnerException: SocketException { SocketErrorCode: SocketError.OperationAborted } } =>
                Lang.T("з'єднання перервано — «Слово» не відповіло вчасно; спробуйте ще раз",
                       "the connection was interrupted — Slovo did not answer in time; try again"),
            SocketException { SocketErrorCode: SocketError.ConnectionRefused } =>
                Lang.T("з'єднання відхилено — «Слово» закрите чи пульт вимкнено", "connection refused — Slovo is closed or the remote is off"),
            SocketException { SocketErrorCode: SocketError.HostUnreachable or SocketError.NetworkUnreachable } =>
                Lang.T("немає шляху до комп'ютера — інша мережа?", "no route to the computer — a different network?"),
            SocketException { SocketErrorCode: SocketError.HostNotFound } => Lang.T("адресу не знайдено", "address not found"),
            _ => string.IsNullOrWhiteSpace(inner.Message) ? inner.GetType().Name : inner.Message,
        };
    }

    // MARK: Читання й команди

    public Task<JsonObject> Get(string path, int seconds = 60) => Send(HttpMethod.Get, path, null, seconds);

    public Task<JsonObject> Command(string name, JsonObject? body = null, int seconds = 10) =>
        Send(HttpMethod.Post, "/api/" + name, body ?? new JsonObject(), seconds);

    public Task<JsonObject> Command(string name, int index) =>
        Command(name, new JsonObject { ["index"] = index }, 8);

    /// Стан програми довгим опитом: сервер тримає відповідь, доки не з'явиться новий.
    public Task<JsonObject> State(long since, CancellationToken cancel) =>
        Send(HttpMethod.Get, "/api/state?since=" + since, null, 40, cancel);

    /// Картинка залу; null — картинки немає (у залі відео чи порожньо).
    public async Task<byte[]?> HallImage(int width, CancellationToken cancel = default)
    {
        using var request = NewRequest(HttpMethod.Get, "/api/hall.jpg?w=" + width);
        using var timeout = Deadline(20, cancel);
        using var response = await Client.SendAsync(request, timeout.Token);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden) throw new PinRejectedException();
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        if ((int)response.StatusCode >= 400) throw new IOException("HTTP " + (int)response.StatusCode);
        return await response.Content.ReadAsByteArrayAsync(timeout.Token);
    }

    /// Сирі байти: переклад рядками SLOVO-BIBLE чи пісенник .vbm.
    public async Task<byte[]> Bytes(string path, int seconds = 900)
    {
        using var request = NewRequest(HttpMethod.Get, path);
        using var timeout = Deadline(seconds);
        using var response = await Client.SendAsync(request, timeout.Token);
        await Check(response, timeout.Token);
        return await response.Content.ReadAsByteArrayAsync(timeout.Token);
    }

    // MARK: План проповіді

    /// Файл плану — лише зберегти в програмі. Відповідь — ім'я, під яким він там лежить.
    public async Task<string> StoreFile(string name, byte[] bytes)
    {
        var json = await PostBytes("/api/upload?store=1&name=" + Uri.EscapeDataString(name), bytes, 900);
        return (string?)json["file"] ?? name;
    }

    /// Модуль, якого в програмі немає: програма ставить його собі й вмикає.
    public Task<JsonObject> ImportModule(string name, byte[] bytes) =>
        PostBytes("/api/module-import?name=" + Uri.EscapeDataString(name), bytes, 900);

    /// План проповіді. Програма відповідає, коли дочитає бібліотеку після імпорту.
    public Task<JsonObject> SermonPlan(JsonObject plan) => Send(HttpMethod.Post, "/api/sermon-plan", plan, 300);

    // MARK: Внутрішнє

    HttpRequestMessage NewRequest(HttpMethod method, string path)
    {
        var request = new HttpRequestMessage(method, _base + path);
        request.Headers.ConnectionClose = true;
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (_pin.Length > 0) request.Headers.Add("X-Slovo-Pin", _pin);
        return request;
    }

    static CancellationTokenSource Deadline(int seconds, CancellationToken outer = default)
    {
        var source = CancellationTokenSource.CreateLinkedTokenSource(outer);
        source.CancelAfter(TimeSpan.FromSeconds(seconds));
        return source;
    }

    async Task<JsonObject> Send(HttpMethod method, string path, JsonObject? body, int seconds,
                                CancellationToken cancel = default)
    {
        using var request = NewRequest(method, path);
        if (body != null)
            request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var timeout = Deadline(seconds, cancel);
        using var response = await Client.SendAsync(request, timeout.Token);
        await Check(response, timeout.Token);
        var text = await response.Content.ReadAsStringAsync(timeout.Token);
        if (string.IsNullOrWhiteSpace(text)) return new JsonObject();
        try
        {
            return JsonNode.Parse(text) as JsonObject ?? new JsonObject();
        }
        catch
        {
            return new JsonObject();
        }
    }

    async Task<JsonObject> PostBytes(string path, byte[] bytes, int seconds)
    {
        using var request = NewRequest(HttpMethod.Post, path);
        request.Content = new ByteArrayContent(bytes);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        using var timeout = Deadline(seconds);
        using var response = await Client.SendAsync(request, timeout.Token);
        await Check(response, timeout.Token);
        var text = await response.Content.ReadAsStringAsync(timeout.Token);
        try
        {
            return JsonNode.Parse(text) as JsonObject ?? new JsonObject();
        }
        catch
        {
            return new JsonObject();
        }
    }

    static async Task Check(HttpResponseMessage response, CancellationToken cancel)
    {
        var code = (int)response.StatusCode;
        if (code is 401 or 403) throw new PinRejectedException();
        if (code < 400) return;
        var text = await response.Content.ReadAsStringAsync(cancel);
        var reason = text;
        try
        {
            if (JsonNode.Parse(text) is JsonObject json && (string?)json["error"] is { } error) reason = error;
        }
        catch
        {
            // Не JSON — показуємо як є.
        }
        throw new IOException(string.IsNullOrWhiteSpace(reason) ? "HTTP " + code : reason);
    }
}
