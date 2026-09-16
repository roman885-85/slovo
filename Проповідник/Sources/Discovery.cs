// =============================================================================
//  Discovery.cs — пошук «Слова» в локальній мережі
// =============================================================================
//  Як у пульта: розсилка «SLOVO?» на UDP-порт 8104, програма відповідає
//  JSON-ом {"app":"Slovo","name":…,"port":8103}. Bonjour у Windows без
//  окремої служби не зробиш, а розсилка працює скрізь, де працює Wi-Fi.
//  Три заходи: один пакет по бездротовій мережі губиться легко, три — майже ніколи.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Propovidnyk;

public sealed record Found(string Name, string Host, int Port);

public static class Discovery
{
    public const int BeaconPort = 8104;

    public static async Task<List<Found>> Search(CancellationToken cancel = default)
    {
        var found = new List<Found>();
        var seen = new HashSet<string>();
        using var socket = new UdpClient(AddressFamily.InterNetwork);
        socket.EnableBroadcast = true;
        var question = Encoding.UTF8.GetBytes("SLOVO?");
        for (var round = 0; round < 3 && !cancel.IsCancellationRequested; round++)
        {
            foreach (var target in Targets())
            {
                try { await socket.SendAsync(question, question.Length, new IPEndPoint(target, BeaconPort)); }
                catch { /* мережа без розсилки — пробуємо наступну */ }
            }
            var until = DateTime.UtcNow.AddMilliseconds(1200);
            while (DateTime.UtcNow < until && !cancel.IsCancellationRequested)
            {
                var left = until - DateTime.UtcNow;
                if (left <= TimeSpan.Zero) break;
                using var wait = CancellationTokenSource.CreateLinkedTokenSource(cancel);
                wait.CancelAfter(left);
                UdpReceiveResult reply;
                try { reply = await socket.ReceiveAsync(wait.Token); }
                catch { break; }
                try
                {
                    var json = JsonNode.Parse(Encoding.UTF8.GetString(reply.Buffer)) as JsonObject;
                    if ((string?)json?["app"] != "Slovo") continue;
                    var host = reply.RemoteEndPoint.Address.ToString();
                    var port = (int?)json!["port"] ?? 8103;
                    if (!seen.Add(host + ":" + port)) continue;
                    found.Add(new Found((string?)json["name"] ?? "Слово", host, port));
                }
                catch
                {
                    // Чужий пакет — пропускаємо.
                }
            }
        }
        return found;
    }

    /// Загальна розсилка й розсилка кожної мережі комп'ютера: у Windows
    /// 255.255.255.255 часто йде не в той адаптер (VPN, віртуальні мережі).
    static IEnumerable<IPAddress> Targets()
    {
        var targets = new HashSet<IPAddress> { IPAddress.Broadcast };
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up) continue;
            if (adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var unicast in adapter.GetIPProperties().UnicastAddresses)
            {
                if (unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var mask = unicast.IPv4Mask;
                if (mask == null || mask.Equals(IPAddress.Any)) continue;
                var address = unicast.Address.GetAddressBytes();
                var bits = mask.GetAddressBytes();
                var broadcast = new byte[4];
                for (var i = 0; i < 4; i++) broadcast[i] = (byte)(address[i] | ~bits[i]);
                targets.Add(new IPAddress(broadcast));
            }
        }
        return targets;
    }
}
