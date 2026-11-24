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
            var environment = await CoreWebView2Environment.CreateAsync(null, data);
            if (_closed) return;
            var controller = await environment.CreateCoreWebView2ControllerAsync(hwnd);
            if (_closed) { controller.Close(); return; }
            _controller = controller;
            controller.DefaultBackgroundColor = System.Drawing.Color.Black;
            var settings = controller.CoreWebView2.Settings;
            settings.AreDefaultContextMenusEnabled = false;
            settings.AreDevToolsEnabled = false;
            settings.IsStatusBarEnabled = false;
            settings.IsZoomControlEnabled = false;
            settings.AreBrowserAcceleratorKeysEnabled = false;
            controller.CoreWebView2.NavigationCompleted += (_, _) => Loaded?.Invoke();
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

    public void Run(string script)
    {
        if (_controller is not { } controller || script.Length == 0) return;
        _ = controller.CoreWebView2.ExecuteScriptAsync(script);
    }

    /// Підігнати браузер під дочірнє вікно (Avalonia міняє його розмір сама).
    public void Resize()
    {
        if (_controller is not { } controller || _hwnd == IntPtr.Zero || !OperatingSystem.IsWindows()) return;
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
