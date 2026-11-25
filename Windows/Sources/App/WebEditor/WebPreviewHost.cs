// =============================================================================
//  WebPreviewHost.cs — справжній браузер у вікні редактора (Microsoft Edge WebView2)
// =============================================================================
//  На Mac передпоказ сторінки — WKWebView. У Windows 10/11 рівний відповідник —
//  WebView2 (рушій Edge, той самий Chromium, що в OBS): він стоїть у системі
//  разом з Edge, а з програмою їде лише тонка обгортка й завантажувач
//  (WebView2Loader.dll — вбудованим ресурсом, щоб «Слово» лишалося одним .exe).
//  Вид — дочірнє вікно Win32 усередині вікна Avalonia (NativeControlHost).
//
//  Миша над передпоказом належить редакторові, а не сторінці (як hitTest на
//  Mac): сторінці в передпоказі підкладено прозору завісу, що ловить мишу й
//  пересилає її сюди (`chrome.webview.postMessage`) — блок тексту тягнеться, а
//  випадкове клацання по посиланню не заведе передпоказ невідомо куди.
//  Не Windows (знімки на Mac без екрана) — цього виду немає зовсім: сцена
//  лишається чорною, як знімок туру Mac.
// =============================================================================

using System.Reflection;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Platform;
using Avalonia.Threading;
using Microsoft.Web.WebView2.Core;

namespace Slovo.App;

public sealed class WebPreviewHost : NativeControlHost
{
    IntPtr _hwnd;
    CoreWebView2Controller? _controller;
    bool _closed;
    string? _pending;

    /// Сторінка довантажилася (і після кожного перезавантаження).
    public event Action? Loaded;
    /// Повідомлення сторінки: «down|move|up x y» від завіси миші.
    public event Action<string>? Message;
    /// Ctrl+S, поки клавіатура в передпоказі.
    public Action? SaveShortcut;
    /// Чому браузера немає (рушій не встановлено тощо) — показати людині.
    public event Action<string>? Failed;

    public bool IsReady => _controller != null;

    /// Посилання, які треба відкрити не тут, а у звичайному браузері (довідка: GitHub, eBible…) —
    /// true: перехід скасовано, адресу віддано назовні. null — усе відкривається тут.
    public Func<string, bool>? OpenOutside;

    /// Ключі рушія — однакові для всіх видів (одне середовище на теку даних): звук без клацання
    /// (у вікні залу клацати нікому) і малювання в схованому за краєм екрана вікні — інакше Edge
    /// вважає його затуленим і перестає малювати, а знімки для панелі, NDI й Wi-Fi застигають.
    const string BrowserArguments = "--autoplay-policy=no-user-gesture-required --disable-features=CalculateNativeWinOcclusion --disable-backgrounding-occluded-windows";

    /// Чуже вікно, де зараз стоїть браузер (вікно залу), або нуль — удома.
    IntPtr _guest;
    public bool IsAway => _guest != IntPtr.Zero;
    public string GuestSize => _controller is { } c && _guest != IntPtr.Zero ? $"{c.Bounds.Width}×{c.Bounds.Height}" : "";

    /// Перенести браузер у чуже вікно (вікно залу) на весь його розмір: той самий контролер,
    /// сторінка не перезавантажується, ролик грає далі (hostWeb на Mac ставить у зал сам вид).
    public bool MoveTo(IntPtr parent, int width, int height)
    {
        if (_controller is not { } controller || parent == IntPtr.Zero || !OperatingSystem.IsWindows()) return false;
        try
        {
            if (_guest != parent) { controller.ParentWindow = parent; _guest = parent; }
            // Розмір — зі справжньої клієнтської частини вікна: щойно створене вікно Avalonia ще
            // називає свій розмір за замовчанням (у Windows 11 так вийшло 800×600 у вікні 1786×1004).
            if (GetClientRect(parent, out var client) && client.Right > client.Left && client.Bottom > client.Top)
                (width, height) = (client.Right - client.Left, client.Bottom - client.Top);
            controller.Bounds = new System.Drawing.Rectangle(0, 0, Math.Max(1, width), Math.Max(1, height));
            controller.IsVisible = true;
            return true;
        }
        catch (Exception error)
        {
            Journal.Say("WebView2: не перейшов у вікно залу — " + error.Message);
            return false;
        }
    }

    /// Повернути браузер у своє вікно.
    public void ReturnHome()
    {
        if (_guest == IntPtr.Zero) return;
        _guest = IntPtr.Zero;
        if (_controller is not { } controller || _hwnd == IntPtr.Zero) return;
        try { controller.ParentWindow = _hwnd; } catch { }
        Resize();
    }

    /// Процес рушія WebView2 (браузерний) — перевірці звуку: чи він у дереві процесу «Слова».
    public int BrowserProcessId { get { try { return _controller != null ? (int)_controller.CoreWebView2.BrowserProcessId : 0; } catch { return 0; } } }

    /// Чи є в цій системі рушій WebView2 (лише Windows).
    public static string? RuntimeVersion()
    {
        if (!OperatingSystem.IsWindows()) return null;
        try
        {
            PrepareLoader();
            return CoreWebView2Environment.GetAvailableBrowserVersionString();
        }
        catch { return null; }
    }

    static bool _loaderReady;

    /// Завантажувач лежить у програмі ресурсом: кладемо його в теку поруч із даними
    /// браузера й кажемо обгортці, де він.
    static void PrepareLoader()
    {
        if (_loaderReady) return;
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Slovo", "WebView2", "loader");
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, "WebView2Loader.dll");
        using (var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("WebView2Loader-x64.dll"))
        {
            if (resource != null)
            {
                using var memory = new MemoryStream();
                resource.CopyTo(memory);
                var bytes = memory.ToArray();
                if (!File.Exists(file) || new FileInfo(file).Length != bytes.Length) File.WriteAllBytes(file, bytes);
            }
        }
        CoreWebView2Environment.SetLoaderDllFolderPath(folder);
        _loaderReady = true;
    }

    protected override IPlatformHandle CreateNativeControlCore(IPlatformHandle parent)
    {
        if (!OperatingSystem.IsWindows()) return base.CreateNativeControlCore(parent);
        const uint WS_CHILD = 0x40000000, WS_VISIBLE = 0x10000000, WS_CLIPCHILDREN = 0x02000000, WS_CLIPSIBLINGS = 0x04000000;
        _hwnd = CreateWindowEx(0, "Static", "", WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
                               0, 0, 1, 1, parent.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        _ = Start(_hwnd);
        return new PlatformHandle(_hwnd, "HWND");
    }

    protected override void DestroyNativeControlCore(IPlatformHandle control)
    {
        _closed = true;
        try { _controller?.Close(); } catch { }
        _controller = null;
        if (OperatingSystem.IsWindows() && control.Handle != IntPtr.Zero) DestroyWindow(control.Handle);
        _hwnd = IntPtr.Zero;
    }

    async Task Start(IntPtr hwnd)
    {
        try
        {
            PrepareLoader();
            // Дані браузера — у локальній теці користувача: поруч із .exe писати не можна,
            // а теку даних «Слова» переносять між комп'ютерами.
            var data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Slovo", "WebView2", "data");
            // Одне середовище на теку даних: параметри мусять бути однакові в усіх видах програми.
            // Звук без клацання — для вбудованого програвача YouTube (у вікні залу клацати нікому).
            var environment = await CoreWebView2Environment.CreateAsync(null, data,
                new CoreWebView2EnvironmentOptions(BrowserArguments));
            if (_closed) return;
            var controller = await environment.CreateCoreWebView2ControllerAsync(hwnd);
            if (_closed) { controller.Close(); return; }
            // Звук сторінок (вбудований YouTube) грає процес рушія — захоплення звуку програми бере і його.
            try { AppAudioCapture.WebViewProcessId = (int)controller.CoreWebView2.BrowserProcessId; } catch { }
            _controller = controller;
            controller.DefaultBackgroundColor = System.Drawing.Color.Black;
            var settings = controller.CoreWebView2.Settings;
            settings.AreDefaultContextMenusEnabled = false;
            settings.AreDevToolsEnabled = false;
            settings.IsStatusBarEnabled = false;
            settings.IsZoomControlEnabled = false;
            settings.AreBrowserAcceleratorKeysEnabled = false;
            controller.CoreWebView2.NavigationCompleted += (_, _) => Loaded?.Invoke();
            controller.CoreWebView2.NavigationStarting += (_, e) => { if (OpenOutside?.Invoke(e.Uri) == true) e.Cancel = true; };
            controller.CoreWebView2.NewWindowRequested += (_, e) => { if (OpenOutside != null) { e.Handled = true; OpenOutside(e.Uri); } };
            controller.CoreWebView2.WebMessageReceived += (_, e) =>
            {
                string? text = null;
                try { text = e.TryGetWebMessageAsString(); } catch { }
                if (text != null) Message?.Invoke(text);
            };
            controller.AcceleratorKeyPressed += (_, e) =>
            {
                // Ctrl+S — «Зберегти», хоч клавіатура зараз і в передпоказі.
                if (e.KeyEventKind == CoreWebView2KeyEventKind.KeyDown && e.VirtualKey == 0x53 && (GetKeyState(0x11) & 0x8000) != 0)
                {
                    e.Handled = true;
                    Dispatcher.UIThread.Post(() => SaveShortcut?.Invoke());
                }
            };
            Resize();
            if (_pending is { } url) { _pending = null; controller.CoreWebView2.Navigate(url); }
        }
        catch (Exception error)
        {
            Journal.Say("веб-редактор: WebView2 не запустився — " + error.Message);
            Failed?.Invoke(OurWordsMissing(error));
        }
    }

    static string OurWordsMissing(Exception error) => error is WebView2RuntimeNotFoundException
        ? Captions.T("Предпросмотр недоступен: в Windows нет Microsoft Edge WebView2 Runtime. Установите его с сайта Microsoft — или откройте страницу в браузере.")
        : Captions.T("Предпросмотр недоступен: %s", error.Message);

    /// Відкрити сторінку (файл у теці передпоказу).
    public void Navigate(string url)
    {
        if (_controller is { } controller) controller.CoreWebView2.Navigate(url);
        else _pending = url;
    }

    /// Знімок того, що зараз у виді (JPEG) — кадр вбудованого програвача YouTube для
    /// панелі, NDI й «Відео по Wi-Fi» (takeSnapshot на Mac). null — виду ще немає.
    public async Task<byte[]?> Capture()
    {
        if (_controller is not { } controller) return null;
        using var stream = new MemoryStream();
        await controller.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Jpeg, stream);
        return stream.ToArray();
    }

    public void Run(string script)
    {
        if (_controller is not { } controller || script.Length == 0) return;
        _ = controller.CoreWebView2.ExecuteScriptAsync(script);
    }

    /// Підігнати браузер під дочірнє вікно (Avalonia міняє його розмір сама).
    public void Resize()
    {
        if (_controller is not { } controller || _hwnd == IntPtr.Zero || !OperatingSystem.IsWindows() || _guest != IntPtr.Zero) return;
        if (!GetClientRect(_hwnd, out var rect)) return;
        controller.Bounds = new System.Drawing.Rectangle(0, 0, Math.Max(1, rect.Right - rect.Left), Math.Max(1, rect.Bottom - rect.Top));
    }

    protected override void OnSizeChanged(SizeChangedEventArgs e)
    {
        base.OnSizeChanged(e);
        // Дочірнє вікно Avalonia пересуває після розкладки — підганяємо на наступному проході.
        Dispatcher.UIThread.Post(Resize, DispatcherPriority.Background);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateWindowEx(uint exStyle, string className, string windowName, uint style, int x, int y, int width, int height,
                                        IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern short GetKeyState(int key);
}
