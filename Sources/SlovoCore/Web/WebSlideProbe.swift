import AppKit
import WebKit

/// Спитати в самої сторінки, як вона виглядає.
///
/// Переводити чужий CSS у наші змінні руками — гадання: в автора вигляд
/// збирається зі спадкування, кількох правил і атрибута `style`, і будь-яка
/// наша вибірка правил виявиться то повнішою, то біднішою за справжню. А браузер
/// знає точну відповідь: `getComputedStyle` повертає рівно те, що видно на
/// екрані, уже в загальному вигляді — `rgb(r, g, b)`, `24px`, `700`.
///
/// Тому перед тим, як надягти на чужу сторінку блок налаштувань, ми вантажимо
/// її в невидимий `WKWebView` розміром у кадр 1920×1080 і питаємо. Кадр
/// саме такий, щоб пікселі переводилися в частки екрана без домислів.
///
/// Відповіді може й не бути — сторінка не завантажилася, браузер зайнятий, перевірка
/// іде без циклу подій. Тоді повертаємо `nil`, і той, хто кличе, обходиться
/// розбором CSS: гірше, але не порожньо.
@MainActor
public final class WebSlideProbe: NSObject, WKNavigationDelegate {

    private let web: WKWebView
    private var answer: ((WebSlideSettings?) -> Void)?
    private var done = false
    /// Тримаємо себе самі, поки не відповімо: тому, хто кличе, нема чого пам'ятати про нас.
    private var keepAlive: WebSlideProbe?

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                        configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    /// Значення, якими сторінка живе зараз.
    public static func computedSettings(html: String, folder: URL?,
                                        completion: @escaping (WebSlideSettings?) -> Void) {
        let probe = WebSlideProbe()
        probe.answer = completion
        probe.keepAlive = probe
        probe.web.loadHTMLString(html, baseURL: folder)
        // Сторінка може не довантажитися ніколи — чужий файл тягне картинки
        // і шрифти з мережі. Чекаємо недовго і відповідаємо тим, що є.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak probe] in
            probe?.ask()
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ask() }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(nil)
    }

    private func ask() {
        guard !done else { return }
        let roles = WebSlideParameters.RoleSelectors.standard
        let script = """
        (function () {
          function pick(selector) {
            var el = null;
            try { el = document.querySelector(selector); } catch (e) { return null; }
            if (!el) return null;
            var s = getComputedStyle(el);
            return {
              "color": s.color,
              "background-color": s.backgroundColor,
              "background-image": s.backgroundImage,
              "background-size": s.backgroundSize,
              "background-position": s.backgroundPosition,
              "background-repeat": s.backgroundRepeat,
              "font-family": s.fontFamily,
              "font-size": s.fontSize,
              "font-weight": s.fontWeight,
              "font-style": s.fontStyle,
              "font-stretch": s.fontStretch,
              "text-transform": s.textTransform,
              "letter-spacing": s.letterSpacing,
              "line-height": s.lineHeight,
              "text-align": s.textAlign,
              "text-shadow": s.textShadow,
              "-webkit-text-stroke-width": s.webkitTextStrokeWidth,
              "-webkit-text-stroke-color": s.webkitTextStrokeColor,
              "display": s.display,
              "width": s.width,
              "border-radius": s.borderTopLeftRadius,
              "flex-direction": s.flexDirection,
              "align-items": s.alignItems,
              "justify-content": s.justifyContent,
              "padding-top": s.paddingTop,
              "padding-left": s.paddingLeft,
              "transition-duration": s.transitionDuration
            };
          }
          // Де текст стоїть насправді. Властивості розкладки про положення
          // мовчать: в автора шар із текстом лежить абсолютно, і `align-items`
          // батька нічого про нього не каже. А місце на екрані — каже.
          function place(selector) {
            var el = null;
            try { el = document.querySelector(selector); } catch (e) { return null; }
            if (!el) return null;
            var display = el.style.display, text = el.innerHTML;
            if (getComputedStyle(el).display === "none") { el.style.display = "block"; }
            if (!el.textContent.trim()) { el.innerHTML = "Проба положения текста"; }
            var r = el.getBoundingClientRect();
            el.style.display = display; el.innerHTML = text;
            if (!r.width && !r.height) return null;
            return {
              "x": String((r.left + r.width / 2) / Math.max(1, window.innerWidth)),
              "y": String((r.top + r.height / 2) / Math.max(1, window.innerHeight))
            };
          }
          return JSON.stringify({
            "page": pick(\(quoted(roles.page))),
            "stage": pick(\(quoted(roles.stage))),
            "text": pick(\(quoted(roles.quote))),
            "reference": pick(\(quoted(roles.reference))),
            "место": place(\(quoted(roles.quote)))
          });
        })()
        """
        web.evaluateJavaScript(script) { [weak self] value, _ in
            guard let self, !self.done else { return }
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.finish(nil)
                return
            }
            var found: [String: [String: String]] = [:]
            for (role, value) in raw {
                guard let table = value as? [String: String] else { continue }
                found[role] = table
            }
            self.finish(WebSlideParameters.settings(fromComputed: found))
        }
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func quoted(_ text: String) -> String { Self.quoted(text) }

    private func finish(_ settings: WebSlideSettings?) {
        guard !done else { return }
        done = true
        let answer = self.answer
        self.answer = nil
        keepAlive = nil
        answer?(settings)
    }
}
