// =============================================================================
//  RemoteAPIUDPServer.cs — UDP-сервер Remote API (за умовчанням порт 8100)
// =============================================================================
//  За RemoteAPIUDPServer.swift Mac 1.3.9. Третій транспорт протоколу і єдиний зі
//  своїм господарством: у UDP немає з'єднання, тож «хто підписаний» пам'ятаємо самі.
//   • клієнт упізнається за SessionGUID; на один GUID — одна пара «адреса — порт»;
//   • відповідаємо на порт UDPPort із самого пакета (клієнт може слухати окремим сокетом);
//   • CSeq запиту мусить рости: номер не більший за колишній — повтор, удруге не виконуємо;
//   • сесія живе Expires секунд, клієнт продовжує її повторним Register; мовчазній
//     сесії шлемо CloseSession (410) і забуваємо її;
//   • Ack приймаємо мовчки — це лише знак, що клієнт живий.
// =============================================================================

using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;

namespace Slovo.Core;

public sealed class RemoteAPIUDPServer
{
    public sealed record Configuration(WebListenerOptions Listener, string InstanceGUID, string InstallGUID, int Expires = 600);

    readonly Configuration _configuration;
    readonly object _lock = new();
    readonly Dictionary<string, Session> _sessions = new();
    UdpClient? _socket;
    CancellationTokenSource? _stopping;
    Timer? _reaper;
    RemoteSlidePayload? _lastPayload;

    public event Action<int, int>? ClientsChanged;
    public int? Port { get; private set; }

    public RemoteAPIUDPServer(Configuration configuration) => _configuration = configuration;

    sealed class Session
    {
        public readonly string Guid;
        public IPEndPoint Target;
        int _sequence;
        /// Останній прийнятий номер запиту — за ним відсіюємо повтори.
        public int LastRequestSequence;
        public bool IsSubscribed, WantsProjectorContent, WantsNextSlide;
        public DateTime LastSeen = DateTime.UtcNow;

        public Session(string guid, IPEndPoint target) { Guid = guid; Target = target; }
        public int NextSequence() => Interlocked.Increment(ref _sequence);
    }

    public (int? Port, WebServerError? Error) Start()
    {
        lock (_lock)
        {
            if (_socket != null) return (null, WebServerError.Network(OurWords.T("UDP-сервер уже запущен")));
            var options = _configuration.Listener;
            UdpClient socket;
            try
            {
                socket = new UdpClient(AddressFamily.InterNetwork);
                socket.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, false);
                socket.Client.Bind(new IPEndPoint(IPAddress.Any, options.Port));
            }
            catch (Exception error) { return (null, WebServerError.From(error, options.Port, options.FallbackPort)); }
            _socket = socket;
            _stopping = new CancellationTokenSource();
            Port = ((IPEndPoint)socket.Client.LocalEndPoint!).Port;
            _ = ReceiveLoop(socket, _stopping.Token);
            // Раз на десять секунд: сесія живе хвилинами, частіше перевіряти нема чого.
            _reaper = new Timer(_ => ReapExpired(), null, TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(10));
            return (Port, null);
        }
    }

    public void Stop()
    {
        lock (_lock)
        {
            try { _stopping?.Cancel(); } catch { }
            _reaper?.Dispose();
            _reaper = null;
            try { _socket?.Close(); } catch { }
            _socket = null;
            _stopping = null;
            Port = null;
            _sessions.Clear();
            _lastPayload = null;
        }
        PublishCounters();
    }

    // ── Прийом ────────────────────────────────────────────────────────────────

    async Task ReceiveLoop(UdpClient socket, CancellationToken stop)
    {
        while (!stop.IsCancellationRequested)
        {
            UdpReceiveResult received;
            try { received = await socket.ReceiveAsync(stop).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { continue; } // ICMP «порт недоступний» від колишнього клієнта — не причина зупинятися
            if (_configuration.Listener.LoopbackOnly && !IPAddress.IsLoopback(received.RemoteEndPoint.Address)) continue;
            try { Handle(received.Buffer, received.RemoteEndPoint.Address); } catch { }
        }
    }

    void Handle(byte[] data, IPAddress host)
    {
        if (RemoteAPIRequest.Parse(data) is not { } request) return;
        // Порт відповіді обов'язковий: без нього відповідати нікуди, і мовчання чесніше за вигадану адресу.
        if (request.UdpPort is not { } replyPort || replyPort <= 0 || replyPort > 65535) return;
        var target = new IPEndPoint(host, replyPort);
        var command = request.Command.ToLowerInvariant();
        var instance = _configuration.InstanceGUID;
        if (command == "register") { HandleRegister(request, target); return; }

        Session? session;
        lock (_lock) session = request.SessionGUID is { } guid && _sessions.TryGetValue(guid, out var known) ? known : null;
        if (session == null)
        {
            SendTo(RemoteAPIPacket.Answer(request.Command, instance, request.SessionGUID ?? "", 0, RemoteAPICode.NotFound, Echo(request)), target);
            return;
        }
        session.Target = target;
        session.LastSeen = DateTime.UtcNow;
        if (command == "ack") return;
        if (request.Sequence is { } sequence)
        {
            if (sequence <= session.LastRequestSequence) return;
            session.LastRequestSequence = sequence;
        }
        switch (command)
        {
            case "unregister":
                Reply(request, session, RemoteAPICode.Ok);
                lock (_lock) _sessions.Remove(session.Guid);
                PublishCounters();
                break;
            case "subscribetoslidechanges":
                session.IsSubscribed = true;
                session.WantsProjectorContent = request.WantsProjectorContent;
                session.WantsNextSlide = request.WantsNextSlide;
                PublishCounters();
                Reply(request, session, RemoteAPICode.Ok);
                RemoteSlidePayload? last;
                lock (_lock) last = _lastPayload;
                if (last != null) Send(last, session);
                break;
            case "unsubscribefromslidechanges":
                session.IsSubscribed = false;
                PublishCounters();
                Reply(request, session, RemoteAPICode.Ok);
                break;
            case "getsenderinfo":
                Reply(request, session, RemoteAPICode.Ok, new Dictionary<string, JsonNode> { ["Sender"] = RemoteAPIIdentity.SenderInfo(_configuration.InstallGUID) });
                break;
            default:
                Reply(request, session, RemoteAPICode.NotAllowed);
                break;
        }
    }

    /// Register — єдина команда без сесії. З GUID — продовжити названу; без — нову,
    /// а колишні з тією самою парою «адреса — порт» закрити (щоб не копичились привиди).
    void HandleRegister(RemoteAPIRequest request, IPEndPoint target)
    {
        var expires = new Dictionary<string, JsonNode> { ["Expires"] = _configuration.Expires };
        if (request.SessionGUID is { Length: > 0 } guid)
        {
            Session? existing;
            lock (_lock) existing = _sessions.TryGetValue(guid, out var known) ? known : null;
            if (existing == null)
            {
                SendTo(RemoteAPIPacket.Answer(request.Command, _configuration.InstanceGUID, guid, 0, RemoteAPICode.NotFound, Echo(request)), target);
                return;
            }
            existing.Target = target;
            existing.LastSeen = DateTime.UtcNow;
            if (request.Sequence is { } s) existing.LastRequestSequence = s;
            Reply(request, existing, RemoteAPICode.Ok, expires);
            return;
        }
        var session = new Session(RemoteAPIIdentity.MakeGUID(), target);
        if (request.Sequence is { } sequence) session.LastRequestSequence = sequence;
        lock (_lock)
        {
            foreach (var key in _sessions.Where(pair => pair.Value.Target.Equals(target)).Select(pair => pair.Key).ToList()) _sessions.Remove(key);
            _sessions[session.Guid] = session;
        }
        PublishCounters();
        Reply(request, session, RemoteAPICode.Ok, expires);
    }

    /// Відповідь на команду — з луною номера запиту, як вимагає протокол.
    void Reply(RemoteAPIRequest request, Session session, (int Code, string Text) code, Dictionary<string, JsonNode>? extra = null)
    {
        var fields = extra ?? new Dictionary<string, JsonNode>();
        foreach (var (key, value) in Echo(request)) fields[key] = value;
        SendTo(RemoteAPIPacket.Answer(request.Command, _configuration.InstanceGUID, session.Guid, session.NextSequence(), code, fields), session.Target);
    }

    static Dictionary<string, JsonNode> Echo(RemoteAPIRequest request) =>
        request.Sequence is { } sequence ? new Dictionary<string, JsonNode> { ["RequestCSeq"] = sequence } : new Dictionary<string, JsonNode>();

    // ── Видача слайдів ────────────────────────────────────────────────────────

    public void Broadcast(RemoteSlidePayload payload)
    {
        List<Session> subscribed;
        lock (_lock)
        {
            _lastPayload = payload;
            subscribed = _sessions.Values.Where(s => s.IsSubscribed).ToList();
        }
        foreach (var session in subscribed) Send(payload, session);
    }

    public void BroadcastHidden()
    {
        RemoteSlidePayload payload;
        List<Session> subscribed;
        lock (_lock)
        {
            payload = (_lastPayload ?? new RemoteSlidePayload()) with { IsVisible = false };
            _lastPayload = payload;
            subscribed = _sessions.Values.Where(s => s.IsSubscribed).ToList();
        }
        foreach (var session in subscribed) Send(payload, session);
    }

    void Send(RemoteSlidePayload payload, Session session) =>
        SendTo(RemoteAPIPacket.SlideEvent(payload, _configuration.InstanceGUID, session.Guid, session.NextSequence(), session.WantsProjectorContent), session.Target);

    void SendTo(byte[] data, IPEndPoint target)
    {
        var socket = _socket;
        if (socket == null) return;
        try { socket.Send(data, data.Length, target); } catch { }
    }

    // ── Тайм-аут сесій ────────────────────────────────────────────────────────

    void ReapExpired()
    {
        var deadline = DateTime.UtcNow.AddSeconds(-_configuration.Expires);
        List<Session> expired;
        lock (_lock)
        {
            expired = _sessions.Values.Where(s => s.LastSeen < deadline).ToList();
            foreach (var session in expired) _sessions.Remove(session.Guid);
        }
        if (expired.Count == 0) return;
        // Мовчазному клієнтові кажемо, чому він більше нічого не отримає.
        foreach (var session in expired)
            SendTo(RemoteAPIPacket.SessionClosed(_configuration.InstanceGUID, session.Guid, session.NextSequence()), session.Target);
        PublishCounters();
    }

    void PublishCounters()
    {
        int connected, subscribed;
        lock (_lock)
        {
            connected = _sessions.Count;
            subscribed = _sessions.Values.Count(s => s.IsSubscribed);
        }
        ClientsChanged?.Invoke(connected, subscribed);
    }
}
