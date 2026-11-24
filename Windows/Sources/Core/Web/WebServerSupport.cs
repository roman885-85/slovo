// =============================================================================
//  WebServerSupport.cs — помилки, стан і адреси мережевих виводів
//  (з SlovoCore/Web/WebServerSupport.swift)
// =============================================================================
//  Операторові в залі марне «SocketError 10048», йому треба знати, що робити:
//  змінити порт або закрити чужу програму. На Mac слухачі — NWListener, тут —
//  TcpListener; підказки — для Windows (порт у Windows закривають не права root,
//  а зарезервовані діапазони й брандмауер).
// =============================================================================

using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Slovo.Core;

/// Помилки мережевих виводів, перекладені з мови кодів сокета на людську.
public sealed record WebServerError
{
    public enum Kinds { PortForbidden, PortBusy, AddressUnavailable, MissingContentFolder, Network }

    public Kinds Kind { get; init; }
    public int Port { get; init; }
    public int Suggestion { get; init; }
    public string Text { get; init; } = "";

    public static WebServerError PortForbidden(int port, int suggestion) => new() { Kind = Kinds.PortForbidden, Port = port, Suggestion = suggestion };
    public static WebServerError PortBusy(int port, int suggestion) => new() { Kind = Kinds.PortBusy, Port = port, Suggestion = suggestion };
    public static WebServerError AddressUnavailable(string text) => new() { Kind = Kinds.AddressUnavailable, Text = text };
    public static WebServerError MissingContentFolder(string path) => new() { Kind = Kinds.MissingContentFolder, Text = path };
    public static WebServerError Network(string text) => new() { Kind = Kinds.Network, Text = text };

    public string Description => Kind switch
    {
        // На Mac тут «порт нижче 1024 — лише з правами root»; у Windows такий порт
        // відмовляють, коли його зарезервувала система (Hyper-V, WSL) або інша служба.
        Kinds.PortForbidden => OurWords.T("Порт %s в Windows сейчас недоступен — его зарезервировала система или запретил брандмауэр. Укажите другой — например, %s.",
                                          Port.ToString(), Suggestion.ToString()),
        Kinds.PortBusy => OurWords.T("Порт %s уже занят другой программой. Освободите его или укажите другой — например, %s.",
                                     Port.ToString(), Suggestion.ToString()),
        Kinds.AddressUnavailable => OurWords.T("Не удалось занять сетевой адрес: %s.", Text),
        Kinds.MissingContentFolder => OurWords.T("Папка веб-страниц не найдена: %s.", Text),
        _ => Text,
    };

    /// Такі помилки самі не розсмокчуться.
    public bool IsFatal => Kind != Kinds.Network;

    /// Чи можна для цієї помилки мовчки перейти на запасний порт.
    public bool AllowsPortFallback => Kind is Kinds.PortForbidden or Kinds.PortBusy;

    public static WebServerError From(Exception error, int port, int suggestion)
    {
        if (error is SocketException socket)
        {
            switch (socket.SocketErrorCode)
            {
                case SocketError.AccessDenied: return PortForbidden(port, suggestion);
                case SocketError.AddressAlreadyInUse: return PortBusy(port, suggestion);
                case SocketError.AddressNotAvailable:
                    return AddressUnavailable(OurWords.T("адрес не принадлежит этому компьютеру (порт %s)", port.ToString()));
            }
        }
        return Network(OurWords.T("Сетевая ошибка на порту %s: %s", port.ToString(), error.Message));
    }
}

/// Спільні налаштування слухача: на якому порту і кого пускати.
public sealed record WebListenerOptions(int Port, int FallbackPort, bool AllowsFallback = true, bool LoopbackOnly = false)
{
    /// З'єднання прийшло з цього самого комп'ютера?
    internal static bool IsLoopback(EndPoint? endpoint) => endpoint is IPEndPoint ip && IPAddress.IsLoopback(ip.Address);
}

/// IPv4-адреси комп'ютера в локальній мережі — щоб показати операторові посилання,
/// яке можна набрати на телефоні.
public static class LocalNetwork
{
    public static List<string> Addresses()
    {
        var found = new List<string>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(unicast.Address)) continue;
                    var text = unicast.Address.ToString();
                    // 169.254.* — самопризначена адреса, нею в зал не потрапиш.
                    if (text.Length > 0 && !text.StartsWith("169.254.", StringComparison.Ordinal) && !found.Contains(text)) found.Add(text);
                }
            }
        }
        catch { /* без списку */ }
        return found;
    }

    /// Найімовірніша адреса для телефонів у залі.
    public static string? PreferredAddress() => Addresses().FirstOrDefault();
}
