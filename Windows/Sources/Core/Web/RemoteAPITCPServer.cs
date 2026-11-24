// =============================================================================
//  RemoteAPITCPServer.cs — TCP-сервер Remote API (за умовчанням порт 8101)
// =============================================================================
//  За RemoteAPITCPServer.swift Mac 1.3.9. Другий із трьох транспортів протоколу:
//  команди й пакети ті самі, що у WebSocket, різниться лише рамка — пакет іде одним
//  рядком і закінчується байтами 0x0D 0x0A. Потрібен відеомікшерам, світловим
//  пультам і саморобним приставкам на мікроконтролері: WebSocket уміє браузер, а
//  вони — лише звичайний сокет.
// =============================================================================

using System.Net;
using System.Net.Sockets;

namespace Slovo.Core;

public sealed class RemoteAPITCPServer
{
    public sealed record Configuration(WebListenerOptions Listener, string InstanceGUID, string InstallGUID);

    /// Межа накопиченого без роздільника: клієнт, що шле сміття без «\r\n», не має
    /// з'їсти всю пам'ять програми посеред служіння.
    const int BufferLimit = 1 << 20;
    static readonly byte[] Terminator = { 0x0D, 0x0A };

    readonly Configuration _configuration;
    readonly object _lock = new();
    readonly List<Client> _clients = new();
    TcpListener? _listener;
    CancellationTokenSource? _stopping;
    RemoteSlidePayload? _lastPayload;

    public event Action<int, int>? ClientsChanged;
    public int? Port { get; private set; }

    public RemoteAPITCPServer(Configuration configuration) => _configuration = configuration;

    public (int? Port, WebServerError? Error) Start()
    {
        lock (_lock)
        {
            if (_listener != null) return (null, WebServerError.Network(OurWords.T("TCP-сервер уже запущен")));
            var options = _configuration.Listener;
            var listener = new TcpListener(IPAddress.Any, options.Port);
            try
            {
                listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, false);
                listener.Start(32);
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

    // ── Розсилка ──────────────────────────────────────────────────────────────

    public void Broadcast(RemoteSlidePayload payload)
    {
        lock (_lock)
        {
            _lastPayload = payload;
            foreach (var client in _clients) if (client.IsSubscribed) Send(payload, client);
        }
    }

    public void BroadcastHidden()
    {
        lock (_lock)
        {
            var payload = (_lastPayload ?? new RemoteSlidePayload()) with { IsVisible = false };
            _lastPayload = payload;
            foreach (var client in _clients) if (client.IsSubscribed) Send(payload, client);
        }
    }

    void Send(RemoteSlidePayload payload, Client client) =>
        Send(RemoteAPIPacket.SlideEvent(payload, _configuration.InstanceGUID, client.SessionGUID, client.NextSequence(), client.WantsProjectorContent), client);

    /// Пакет іде одним рядком і закінчується «\r\n» — так вимагає протокол.
    void Send(byte[] data, Client client)
    {
        if (client.IsFinished) return;
        var framed = new byte[data.Length + Terminator.Length];
        Buffer.BlockCopy(data, 0, framed, 0, data.Length);
        Buffer.BlockCopy(Terminator, 0, framed, data.Length, Terminator.Length);
        client.Enqueue(framed, () => Drop(client));
    }

    // ── Клієнти ───────────────────────────────────────────────────────────────

    sealed class Client
    {
        public readonly TcpClient Socket;
        public readonly string SessionGUID = RemoteAPIIdentity.MakeGUID();
        int _sequence;
        public bool IsSubscribed, WantsProjectorContent, WantsNextSlide, IsFinished;
        readonly SemaphoreSlim _writing = new(1, 1);

        public Client(TcpClient socket) { Socket = socket; }

        public int NextSequence() => Interlocked.Increment(ref _sequence);

        /// Писати по черзі: пакети одного клієнта не мають перемішатися.
        public void Enqueue(byte[] data, Action onFailure)
        {
            _ = Task.Run(async () =>
            {
                await _writing.WaitAsync().ConfigureAwait(false);
                try { await Socket.GetStream().WriteAsync(data).ConfigureAwait(false); }
                catch { onFailure(); }
                finally { _writing.Release(); }
            });
        }

        public void Close()
        {
            if (IsFinished) return;
            IsFinished = true;
            try { Socket.Close(); } catch { }
        }
    }

    async Task AcceptLoop(TcpListener listener, CancellationToken stop)
    {
        while (!stop.IsCancellationRequested)
        {
            TcpClient socket;
            try { socket = await listener.AcceptTcpClientAsync(stop).ConfigureAwait(false); }
            catch { return; }
            if (_configuration.Listener.LoopbackOnly && !WebListenerOptions.IsLoopback(socket.Client.RemoteEndPoint))
            {
                socket.Close();
                continue;
            }
            socket.NoDelay = true;
            var client = new Client(socket);
            lock (_lock) _clients.Add(client);
            PublishCounters();
            _ = Receive(client, stop);
        }
    }

    void Drop(Client client)
    {
        client.Close();
        bool removed;
        lock (_lock) removed = _clients.Remove(client);
        if (removed) PublishCounters();
    }

    void PublishCounters()
    {
        int connected, subscribed;
        lock (_lock)
        {
            connected = _clients.Count;
            subscribed = _clients.Count(c => c.IsSubscribed);
        }
        ClientsChanged?.Invoke(connected, subscribed);
    }

    /// Набрати потік і розібрати з нього закінчені пакети. Самотній 0x0A теж кінець
    /// пакета: клієнта на мікроконтролері легко написати з одним «\n».
    async Task Receive(Client client, CancellationToken stop)
    {
        var buffer = new List<byte>();
        var chunk = new byte[64 * 1024];
        try
        {
            var stream = client.Socket.GetStream();
            while (!stop.IsCancellationRequested && !client.IsFinished)
            {
                var read = await stream.ReadAsync(chunk, stop).ConfigureAwait(false);
                if (read <= 0) break;
                buffer.AddRange(new ArraySegment<byte>(chunk, 0, read));
                if (buffer.Count > BufferLimit) break;
                int end;
                while ((end = buffer.IndexOf(0x0A)) >= 0)
                {
                    var line = buffer.GetRange(0, end);
                    buffer.RemoveRange(0, end + 1);
                    if (line.Count > 0 && line[^1] == 0x0D) line.RemoveAt(line.Count - 1);
                    if (line.Count == 0) continue;
                    Handle(line.ToArray(), client);
                    if (client.IsFinished) return;
                }
            }
        }
        catch { }
        Drop(client);
    }

    void Handle(byte[] data, Client client)
    {
        var instance = _configuration.InstanceGUID;
        if (RemoteAPIRequest.Parse(data) is not { } request)
        {
            Send(RemoteAPIPacket.Answer("", instance, client.SessionGUID, client.NextSequence(), RemoteAPICode.BadRequest), client);
            return;
        }
        switch (request.Command.ToLowerInvariant())
        {
            case "subscribetoslidechanges":
                client.IsSubscribed = true;
                client.WantsProjectorContent = request.WantsProjectorContent;
                client.WantsNextSlide = request.WantsNextSlide;
                PublishCounters();
                Send(RemoteAPIPacket.Answer(request.Command, instance, client.SessionGUID, client.NextSequence()), client);
                // Тому, хто підключився посеред служіння, — те, що вже на екрані.
                RemoteSlidePayload? last;
                lock (_lock) last = _lastPayload;
                if (last != null) Send(last, client);
                break;
            case "unsubscribefromslidechanges":
                client.IsSubscribed = false;
                PublishCounters();
                Send(RemoteAPIPacket.Answer(request.Command, instance, client.SessionGUID, client.NextSequence()), client);
                break;
            case "getsenderinfo":
                Send(RemoteAPIPacket.Answer(request.Command, instance, client.SessionGUID, client.NextSequence(), null,
                     new Dictionary<string, System.Text.Json.Nodes.JsonNode> { ["Sender"] = RemoteAPIIdentity.SenderInfo(_configuration.InstallGUID) }), client);
                break;
            default:
                Send(RemoteAPIPacket.Answer(request.Command, instance, client.SessionGUID, client.NextSequence(), RemoteAPICode.NotAllowed), client);
                break;
        }
    }
}
