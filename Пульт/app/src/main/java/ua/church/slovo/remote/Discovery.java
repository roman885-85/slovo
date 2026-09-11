package ua.church.slovo.remote;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONObject;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/// Поиск «Слова» в локальной сети — двумя путями сразу.
///
/// Bonjour (`_slovo._tcp`) — правильный путь, но его блокируют некоторые
/// роутеры и «изоляция клиентов» в гостевых сетях. UDP-рассылка на порт 8104
/// — грубый, но живучий: телефон кричит «SLOVO?», программа отвечает своим
/// именем и портом. Кто ответил первым — тот и в списке; повторы по адресу
/// и порту отсеиваются.
final class Discovery {

    interface Listener {
        void found(String name, String host, int port);
        void finished();
    }

    static final String SERVICE_TYPE = "_slovo._tcp.";
    static final int BEACON_PORT = 8104;
    static final String BEACON_QUESTION = "SLOVO?";

    private final Context context;
    private final Listener listener;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Set<String> seen = new HashSet<>();
    private NsdManager nsd;
    private NsdManager.DiscoveryListener nsdListener;
    private WifiManager.MulticastLock multicast;
    private volatile boolean stopped;

    Discovery(Context context, Listener listener) {
        this.context = context.getApplicationContext();
        this.listener = listener;
    }

    void start() {
        stopped = false;
        seen.clear();
        acquireMulticast();
        startBonjour();
        startBeacon();
    }

    void stop() {
        stopped = true;
        if (nsd != null && nsdListener != null) {
            try { nsd.stopServiceDiscovery(nsdListener); } catch (Exception ignored) { }
        }
        nsdListener = null;
        if (multicast != null && multicast.isHeld()) multicast.release();
    }

    /// Без этого замка Android отбрасывает многоадресные пакеты ради
    /// экономии батареи — и ни Bonjour, ни ответ на рассылку не доходят.
    private void acquireMulticast() {
        WifiManager wifi = (WifiManager) context.getSystemService(Context.WIFI_SERVICE);
        if (wifi == null) return;
        multicast = wifi.createMulticastLock("slovo-remote");
        multicast.setReferenceCounted(false);
        multicast.acquire();
    }

    private void report(String name, String host, int port) {
        String key = host + ":" + port;
        main.post(() -> {
            if (stopped || !seen.add(key)) return;
            listener.found(name, host, port);
        });
    }

    // MARK: Bonjour

    private void startBonjour() {
        nsd = (NsdManager) context.getSystemService(Context.NSD_SERVICE);
        if (nsd == null) return;
        nsdListener = new NsdManager.DiscoveryListener() {
            @Override public void onStartDiscoveryFailed(String type, int code) { }
            @Override public void onStopDiscoveryFailed(String type, int code) { }
            @Override public void onDiscoveryStarted(String type) { }
            @Override public void onDiscoveryStopped(String type) { }
            @Override public void onServiceLost(NsdServiceInfo info) { }

            @Override public void onServiceFound(NsdServiceInfo info) {
                if (!SERVICE_TYPE.startsWith(info.getServiceType())) return;
                // Разрешение имён в адрес идёт по одному: второй запрос,
                // пока идёт первый, Android отвергает — поэтому свой
                // слушатель на каждый вызов.
                try {
                    nsd.resolveService(info, new NsdManager.ResolveListener() {
                        @Override public void onResolveFailed(NsdServiceInfo service, int code) { }
                        @Override public void onServiceResolved(NsdServiceInfo service) {
                            InetAddress address = service.getHost();
                            if (address == null) return;
                            report(service.getServiceName(), address.getHostAddress(), service.getPort());
                        }
                    });
                } catch (Exception ignored) { }
            }
        };
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, nsdListener);
        } catch (Exception ignored) {
            nsdListener = null;
        }
    }

    // MARK: Рассылка

    private void startBeacon() {
        Thread thread = new Thread(() -> {
            DatagramSocket socket = null;
            try {
                socket = new DatagramSocket();
                socket.setBroadcast(true);
                socket.setSoTimeout(600);
                byte[] question = BEACON_QUESTION.getBytes(StandardCharsets.UTF_8);
                // Три захода по секунде с небольшим: один пакет по Wi-Fi
                // теряется запросто, три подряд — почти никогда.
                for (int round = 0; round < 3 && !stopped; round++) {
                    for (InetAddress target : broadcastTargets()) {
                        try {
                            socket.send(new DatagramPacket(question, question.length, target, BEACON_PORT));
                        } catch (Exception ignored) { }
                    }
                    long until = System.currentTimeMillis() + 1200;
                    while (!stopped && System.currentTimeMillis() < until) {
                        byte[] buffer = new byte[1024];
                        DatagramPacket reply = new DatagramPacket(buffer, buffer.length);
                        try {
                            socket.receive(reply);
                        } catch (Exception timeout) {
                            continue;
                        }
                        String text = new String(reply.getData(), 0, reply.getLength(), StandardCharsets.UTF_8);
                        try {
                            JSONObject json = new JSONObject(text);
                            if (!"Slovo".equals(json.optString("app"))) continue;
                            report(json.optString("name", "Слово"), reply.getAddress().getHostAddress(),
                                   json.optInt("port", 8103));
                        } catch (Exception ignored) { }
                    }
                }
            } catch (Exception ignored) {
            } finally {
                if (socket != null) socket.close();
                main.post(() -> { if (!stopped) listener.finished(); });
            }
        }, "slovo-beacon");
        thread.setDaemon(true);
        thread.start();
    }

    /// Куда кричать: общая рассылка и рассылка каждой сети телефона —
    /// на некоторых прошивках 255.255.255.255 уходит не в тот интерфейс.
    private static Set<InetAddress> broadcastTargets() {
        Set<InetAddress> targets = new HashSet<>();
        try { targets.add(InetAddress.getByName("255.255.255.255")); } catch (Exception ignored) { }
        try {
            for (NetworkInterface network : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!network.isUp() || network.isLoopback()) continue;
                for (InterfaceAddress address : network.getInterfaceAddresses()) {
                    InetAddress broadcast = address.getBroadcast();
                    if (broadcast instanceof Inet4Address) targets.add(broadcast);
                }
            }
        } catch (Exception ignored) { }
        return targets;
    }
}
