// =============================================================================
//  WebSlideSocketServer.cs — WebSocket-сервер Remote API (з SlovoCore/Web/WebSlideSocketServer.swift)
// =============================================================================
//  Роздає слайд сторінкам із теки `RemoteAPI` і нашим заготовкам. Сторінки
//  підключаються до `ws://<адреса>:8100/ws`, одразу шлють
//  `SubscribeToSlideChanges` і далі лише слухають. Шлях `/ws` сервер не
//  перевіряє — оригінал теж цього не робить.
//
//  На Mac — NWListener із протоколом WebSocket; тут — TcpListener, рукостискання
//  HTTP → 101 вручну і далі `WebSocket.CreateFromStream` (.NET сам відповідає на
//  пінги й ріже кадри). Кожен клієнт має свою чергу відправки: пакети слайда
//  мусять іти рівно в тому порядку, в якому їх зібрано.
// =============================================================================

using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace Slovo.Core;

public sealed class WebSlideSocketServer
{
    public sealed record Configuration(WebListenerOptions Listener, string InstanceGUID, string InstallGUID)
    {
        public static Configuration Make(WebListenerOptions listener) =>
            new(listener, RemoteAPIIdentity.MakeGUID(), RemoteAPIIdentity.MakeGUID());
    }

    readonly Configuration _configuration;
    readonly object _lock = new();
    readonly HashSet<Client> _clients = new();
    TcpListener? _listener;
    CancellationTokenSource? _stopping;
    /// Останній стан слайда: сторінці, що підключилася посеред служіння, треба
    /// показати те, що вже на екрані, а не чекати наступного вірша.
    RemoteSlidePayload? _lastPayload;
    (int Connected, int Subscribed) _counters;

    /// Кличеться з фонового потоку сервера.
    public event Action<int, int>? ClientsChanged;
    public int? Port { get; private set; }

    public WebSlideSocketServer(Configuration configuration) => _configuration = configuration;

    // ── Життєвий цикл ─────────────────────────────────────────────────────────

    /// Зайняти порт. Відповідь — одразу: TcpListener або слухає, або ні.
    public (int? Port, WebServerError? Error) Start()
    {
        lock (_lock)
        {
            if (_listener != null) return (null, WebServerError.Network(OurWords.T("WebSocket-сервер уже запущен")));
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
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            _ = AcceptLoop(listener, _stopping.Token);
            return (Port, null);
        }
    }

    public void Stop()
    {
        List<Client> clients;
        lock (_lock)
        {
            try { _stopping?.Cancel(); } catch { }
            try { _listener?.Stop(); } catch { }
            _listener = null;
            _stopping = null;
            Port = null;
            clients = _clients.ToList();
            _clients.Clear();
            _lastPayload = null;
        }
        foreach (var client in clients) client.Close();
        PublishCounters();
    }

    public int ConnectedClients { get { lock (_lock) return _counters.Connected; } }
    public int SubscribedClients { get { lock (_lock) return _counters.Subscribed; } }

    // ── Розсилка ──────────────────────────────────────────────────────────────

    /// Віддає слайд усім підписникам. Можна кликати з будь-якого потоку.
    public void Broadcast(RemoteSlidePayload payload)
    {
        lock (_lock)
        {
            _lastPayload = payload;
            foreach (var client in _clients) if (client.IsSubscribed) Send(payload, client);
        }
    }

    /// Розіслати значення налаштувань усім сторінкам: правка повзунка доходить до
    /// залу без перезавантаження сторінки (вона зазвичай відкрита в OBS).
    public void BroadcastStyle(IReadOnlyDictionary<string, string> values)
    {
        if (values.Count == 0) return;
        var pairs = values.OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => $"\"{pair.Key}\":\"{pair.Value.Replace("\\", "\\\\").Replace("\"", "\\\"")}\"");
        var data = Encoding.UTF8.GetBytes("{\"SlovoVars\":{" + string.Join(",", pairs) + "}}");
        lock (_lock)
            foreach (var client in _clients) client.Enqueue(data);
    }

    /// Сховати слайд, не міняючи його вмісту (F12 і «порожній слайд»).
    public void BroadcastHidden()
    {
        lock (_lock)
        {
            var payload = (_lastPayload ?? new RemoteSlidePayload()) with { IsVisible = false };
            _lastPayload = payload;
            foreach (var client in _clients) if (client.IsSubscribed) Send(payload, client);
        }
    }

    /// Під замком: номер пакета береться в мить збирання, і черга клієнта тримає порядок.
    void Send(RemoteSlidePayload payload, Client client) =>
        client.Enqueue(RemoteAPIPacket.SlideEvent(payload, _configuration.InstanceGUID, client.SessionGUID,
                                                  client.NextSequence(), client.WantsProjectorContent));

    // ── Клієнти ───────────────────────────────────────────────────────────────

    sealed class Client
    {
        public readonly TcpClient Tcp;
        public WebSocket? Socket;
        /// Живе до закриття каналу — за ним сторінки відрізняють наш потік від чужого.
        public readonly string SessionGUID = RemoteAPIIdentity.MakeGUID();
        public bool IsSubscribed, WantsProjectorContent, WantsNextSlide, IsFinished;
        readonly Channel<byte[]> _outbox = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
        int _sequence;

        public Client(TcpClient tcp) => Tcp = tcp;
        public int NextSequence() => ++_sequence;
        public void Enqueue(byte[] data) { if (!IsFinished) _outbox.Writer.TryWrite(data); }
        public ChannelReader<byte[]> Outbox => _outbox.Reader;

        public void Close()
        {
            if (IsFinished) return;
            IsFinished = true;
            _outbox.Writer.TryComplete();
            try { Socket?.Abort(); } catch { }
            try { Tcp.Close(); } catch { }
        }
    }

    async Task AcceptLoop(TcpListener listener, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient tcp;
            try { tcp = await listener.AcceptTcpClientAsync(token); }
            catch { break; }
            _ = Task.Run(() => Serve(tcp, token), CancellationToken.None);
        }
    }

    async Task Serve(TcpClient tcp, CancellationToken token)
    {
        // Режим «лише локально»: чужих відсікаємо тут — інакше слайд видно всій мережі.
        if (_configuration.Listener.LoopbackOnly && !WebListenerOptions.IsLoopback(tcp.Client.RemoteEndPoint))
        {
            tcp.Close();
            return;
        }
        tcp.NoDelay = true;
        try { tcp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true); } catch { }
        var client = new Client(tcp);
        try
        {
            var stream = tcp.GetStream();
            if (!await Handshake(stream, token)) { client.Close(); return; }
            client.Socket = WebSocket.CreateFromStream(stream, new WebSocketCreationOptions
            {
                IsServer = true,
                KeepAliveInterval = TimeSpan.FromSeconds(30),
            });
            lock (_lock)
            {
                if (token.IsCancellationRequested) { client.Close(); return; }
                _clients.Add(client);
            }
            PublishCounters();
            _ = WriteLoop(client);
            await ReadLoop(client, token);
        }
        catch { /* клієнт пішов */ }
        Drop(client);
    }

    /// Рукостискання: запит GET з `Upgrade: websocket` → `101 Switching Protocols`.
    /// Читаємо по байту, щоб не з'їсти перший кадр, який клієнт міг надіслати впритул.
    static async Task<bool> Handshake(NetworkStream stream, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(15));
        var head = new List<byte>(1024);
        var one = new byte[1];
        while (true)
        {
            var read = await stream.ReadAsync(one, timeout.Token);
            if (read <= 0) return false;
            head.Add(one[0]);
            if (head.Count > 64 * 1024) return false;
            var n = head.Count;
            if (n >= 4 && head[n - 4] == '\r' && head[n - 3] == '\n' && head[n - 2] == '\r' && head[n - 1] == '\n') break;
        }
        var lines = Encoding.UTF8.GetString(head.ToArray()).Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        string? key = null;
        var upgrade = false;
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0) continue;
            var name = line[..colon].Trim().ToLowerInvariant();
            var value = line[(colon + 1)..].Trim();
            if (name == "sec-websocket-key") key = value;
            if (name == "upgrade" && value.Contains("websocket", StringComparison.OrdinalIgnoreCase)) upgrade = true;
        }
        if (!upgrade || key == null)
        {
            var body = Encoding.UTF8.GetBytes("WebSocket only");
            var refusal = Encoding.ASCII.GetBytes($"HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n");
            await stream.WriteAsync(refusal, timeout.Token);
            await stream.WriteAsync(body, timeout.Token);
            return false;
        }
        var accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
        var answer = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                                             + $"Sec-WebSocket-Accept: {accept}\r\n\r\n");
        await stream.WriteAsync(answer, timeout.Token);
        return true;
    }

    async Task WriteLoop(Client client)
    {
        try
        {
            await foreach (var data in client.Outbox.ReadAllAsync())
            {
                if (client.Socket is not { State: WebSocketState.Open } socket) break;
                await socket.SendAsync(data, WebSocketMessageType.Text, true, CancellationToken.None);
            }
        }
        catch { /* помилка запису — клієнт уже пішов; чекати від нього закриття нема чого */ }
        Drop(client);
    }

    async Task ReadLoop(Client client, CancellationToken token)
    {
        var buffer = new byte[16 * 1024];
        using var message = new MemoryStream();
        while (!token.IsCancellationRequested && client.Socket is { } socket)
        {
            var result = await socket.ReceiveAsync(buffer, token);
            if (result.MessageType == WebSocketMessageType.Close) return;
            message.Write(buffer, 0, result.Count);
            if (message.Length > 1024 * 1024) return;
            if (!result.EndOfMessage) continue;
            if (message.Length > 0) Handle(message.ToArray(), client);
            message.SetLength(0);
        }
    }

    void Drop(Client client)
    {
        bool removed;
        lock (_lock) removed = _clients.Remove(client);
        client.Close();
        if (removed) PublishCounters();
    }

    void PublishCounters()
    {
        int connected, subscribed;
        lock (_lock)
        {
            connected = _clients.Count;
            subscribed = _clients.Count(client => client.IsSubscribed);
            _counters = (connected, subscribed);
        }
        ClientsChanged?.Invoke(connected, subscribed);
    }

    void Handle(byte[] data, Client client)
    {
        var instance = _configuration.InstanceGUID;
        if (RemoteAPIRequest.Parse(data) is not { } request)
        {
            lock (_lock)
                client.Enqueue(RemoteAPIPacket.Answer("", instance, client.SessionGUID, client.NextSequence(), RemoteAPICode.BadRequest));
            return;
        }
        var countersChanged = false;
        lock (_lock)
        {
            switch (request.Command.ToLowerInvariant())
            {
                case "subscribetoslidechanges":
                    client.IsSubscribed = true;
                    client.WantsProjectorContent = request.WantsProjectorContent;
                    client.WantsNextSlide = request.WantsNextSlide;
                    countersChanged = true;
                    client.Enqueue(RemoteAPIPacket.Answer(request.Command, instance, client.SessionGUID, client.NextSequence()));
                    // Доганяємо сторінку поточним слайдом — інакше до наступного вірша вона порожня.
                    if (_lastPayload is { } payload) Send(payload, client);
                    break;
                case "unsubscribefromslidechanges":
                    client.IsSubscribed = false;
                    countersChanged = true;
                    client.Enqueue(RemoteAPIPacket.Answer(request.Command, instance, client.SessionGUID, client.NextSequence()));
                    break;
                case "getsenderinfo":
                    client.Enqueue(RemoteAPIPacket.Answer(request.Command, instance, client.SessionGUID, client.NextSequence(),
                        extra: new Dictionary<string, JsonNode> { ["Sender"] = RemoteAPIIdentity.SenderInfo(_configuration.InstallGUID) }));
                    break;
                default:
                    client.Enqueue(RemoteAPIPacket.Answer(request.Command, instance, client.SessionGUID, client.NextSequence(), RemoteAPICode.NotAllowed));
                    break;
            }
        }
        if (countersChanged) PublishCounters();
    }
}
