package ua.church.slovo.remote;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Handler;
import android.os.Looper;

import org.json.JSONObject;

import java.io.InputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.net.Socket;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/// Пошук «Слова» в локальній мережі — чотирма шляхами одразу.
///
/// Власник: «программа при поиске не находит слово в локальной сети». Один
/// шлях завжди десь та й не спрацює, тож ідуть усі відразу:
///   1. Bonjour (`_slovo._tcp`) — правильний, але його глушать деякі роутери
///      й «ізоляція клієнтів» у гостьових мережах;
///   2. UDP-розсилка «SLOVO?» на порт 8104 — грубо, але живуче; її теж
///      ріжуть окремі точки доступу;
///   3. ім'я `slovo.local` — коли працює mDNS самого телефона;
///   4. перебір своєї підмережі — стук у порт 8103 на всі адреси /24.
/// Четвертий шлях знаходить програму навіть тоді, коли в мережі глушать і
/// розсилку, і Bonjour: він нікого не питає, а сам стукає в двері.
/// Хто відповів першим — той і в списку; повтори за адресою й портом
/// відсіюються.
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
        running.set(3);          // розсилка, ім'я, перебір: Bonjour іде без кінця
        acquireMulticast();
        startBonjour();
        startBeacon();
        startByName();
        startSweep();
    }

    /// Скільки шляхів ще шукає: «нічого не знайшли» кажемо, коли скінчилися всі.
    private final AtomicInteger running = new AtomicInteger();

    private void pathDone() {
        if (running.decrementAndGet() > 0) return;
        main.post(() -> { if (!stopped) listener.finished(); });
    }

    void stop() {
        stopped = true;
        if (nsd != null && nsdListener != null) {
            try { nsd.stopServiceDiscovery(nsdListener); } catch (Exception ignored) { }
        }
        nsdListener = null;
        if (multicast != null && multicast.isHeld()) multicast.release();
    }

    /// Без цього замка Android відкидає багатоадресні пакети заради
    /// економії батареї — і ні Bonjour, ні відповідь на розсилку не доходять.
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
                // Перетворення імен на адресу йде по одному: другий запит,
                // поки йде перший, Android відкидає — тому свій
                // слухач на кожен виклик.
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

    // MARK: Розсилка

    private void startBeacon() {
        Thread thread = new Thread(() -> {
            DatagramSocket socket = null;
            try {
                socket = new DatagramSocket();
                socket.setBroadcast(true);
                socket.setSoTimeout(600);
                byte[] question = BEACON_QUESTION.getBytes(StandardCharsets.UTF_8);
                // Три заходи по секунді з невеликим: один пакет по Wi-Fi
                // губиться легко, три поспіль — майже ніколи.
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
                pathDone();
            }
        }, "slovo-beacon");
        thread.setDaemon(true);
        thread.start();
    }

    // MARK: За іменем

    /// `slovo.local` — ім'я, яке програма оголошує в мережі. Коли mDNS у
    /// телефона живий, це найшвидший шлях; коли ні — просто нічого не дасть.
    private void startByName() {
        Thread thread = new Thread(() -> {
            try {
                for (String name : new String[] { "slovo.local", "slovo" }) {
                    if (stopped) break;
                    try {
                        for (InetAddress address : InetAddress.getAllByName(name)) {
                            if (!(address instanceof Inet4Address)) continue;
                            knock(address.getHostAddress());
                        }
                    } catch (Exception ignored) { }
                }
            } finally {
                pathDone();
            }
        }, "slovo-by-name");
        thread.setDaemon(true);
        thread.start();
    }

    // MARK: Перебір підмережі

    /// Останній шлях: постукати в порт 8103 на кожну адресу своєї мережі.
    /// Так «Слово» знаходиться й тоді, коли точка доступу глушить і розсилку,
    /// і Bonjour. Стукаємо в 48 потоків по чверті секунди — уся /24
    /// перевіряється секунд за три.
    private void startSweep() {
        Thread thread = new Thread(() -> {
            ExecutorService pool = Executors.newFixedThreadPool(48);
            try {
                for (String prefix : subnets()) {
                    for (int last = 1; last <= 254; last++) {
                        final String host = prefix + last;
                        pool.submit(() -> {
                            if (stopped) return;
                            try (Socket socket = new Socket()) {
                                socket.connect(new InetSocketAddress(host, 8103), 250);
                            } catch (Exception closed) {
                                return;
                            }
                            knock(host);
                        });
                    }
                }
                pool.shutdown();
                pool.awaitTermination(25, TimeUnit.SECONDS);
            } catch (Exception ignored) {
            } finally {
                pool.shutdownNow();
                pathDone();
            }
        }, "slovo-sweep");
        thread.setDaemon(true);
        thread.start();
    }

    /// Мережі телефона виду «192.168.1.» — тільки /24 і тільки свої.
    private static List<String> subnets() {
        List<String> prefixes = new ArrayList<>();
        try {
            for (NetworkInterface network : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!network.isUp() || network.isLoopback()) continue;
                for (InterfaceAddress address : network.getInterfaceAddresses()) {
                    if (!(address.getAddress() instanceof Inet4Address)) continue;
                    if (address.getNetworkPrefixLength() < 22) continue;   // /21 і ширші не перебираємо
                    String own = address.getAddress().getHostAddress();
                    int dot = own.lastIndexOf('.');
                    if (dot > 0) {
                        String prefix = own.substring(0, dot + 1);
                        if (!prefixes.contains(prefix)) prefixes.add(prefix);
                    }
                }
            }
        } catch (Exception ignored) { }
        return prefixes;
    }

    /// Чи це справді «Слово»: питаємо стан. 401/403 — теж воно, просто з PIN.
    private void knock(String host) {
        if (stopped) return;
        HttpURLConnection link = null;
        try {
            link = (HttpURLConnection) new URL("http://" + host + ":8103/api/state?since=0").openConnection();
            link.setConnectTimeout(1500);
            link.setReadTimeout(2500);
            int code = link.getResponseCode();
            if (code == 401 || code == 403) {
                report(context.getString(R.string.found_needs_pin), host, 8103);
                return;
            }
            if (code != 200) return;
            StringBuilder body = new StringBuilder();
            try (InputStream from = link.getInputStream()) {
                byte[] chunk = new byte[4096];
                int read;
                while ((read = from.read(chunk)) > 0 && body.length() < 8192) {
                    body.append(new String(chunk, 0, read, StandardCharsets.UTF_8));
                }
            }
            JSONObject json = new JSONObject(body.toString());
            if (json.opt("app") == null && json.opt("mode") == null) return;
            String name = json.optString("name", "");
            report(name.isEmpty() ? "Слово" : name, host, 8103);
        } catch (Exception ignored) {
        } finally {
            if (link != null) link.disconnect();
        }
    }

    /// Куди кричати: загальна розсилка й розсилка кожної мережі телефона —
    /// на деяких прошивках 255.255.255.255 іде не в той інтерфейс.
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
