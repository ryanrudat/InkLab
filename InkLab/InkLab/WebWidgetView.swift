import UIKit
import WebKit

/// Renders generated HTML/JS as a live widget inside a locked-down WKWebView. This is the renderer
/// for ALL make-real output (the generator is swappable — stub today, Claude-via-proxy later); the
/// safety boundary lives HERE, not in the generator, so untrusted/AI-written code is safe by
/// construction on a minor's device:
///   • CSP `default-src 'none'` — no network, no external scripts/styles/images/frames (only inline).
///     `script-src` allows `'unsafe-inline'` + `'unsafe-eval'` so widgets can evaluate a user-typed
///     expression (graphers/calculators use `new Function`/`eval`). This does NOT widen the boundary:
///     the widget already runs arbitrary inline JS, and `default-src 'none'` + no base URL keep it
///     fully offline, so eval is contained to the user's own formula inside the card.
///   • non-persistent data store, no base URL → no origin, nothing can be fetched.
///   • navigation delegate cancels every navigation except the initial in-memory load.
///   • window.open / target=_blank denied.
/// The generator is asked for BODY-level HTML only; we always wrap it in our own document + CSP.
final class WebWidgetView: UIView, WKNavigationDelegate, WKUIDelegate {
    private let web: WKWebView
    private var loadedHTML: String?
    /// HTML waiting to be painted: held until the view is on-screen at full size (see `loadIfReady`).
    private var pendingHTML: String?
    private var didInitialLoad = false

    override init(frame: CGRect) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init(frame: frame)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        addSubview(web)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() { super.layoutSubviews(); web.frame = bounds; loadIfReady() }

    // A view created off-screen (e.g. when the canvas rebuilds every object in `viewDidLoad`, before it is
    // in a window) reports a 1× `contentScaleFactor` and a zero frame — so WebKit's first paint rasterizes
    // at the wrong size/scale and stays blurry until something forces a re-composite. Waiting for the window
    // makes the one-and-only paint happen on the real screen at full size, so generated widgets are crisp on
    // first appearance and after relaunch.
    override func didMoveToWindow() { super.didMoveToWindow(); loadIfReady() }

    /// Load generated body-level HTML (idempotent — re-loading the same HTML is a no-op). The actual paint
    /// is deferred to `loadIfReady` so it never happens off-screen or at a zero size (which is what made
    /// reopened widgets blurry).
    func loadHTML(_ bodyHTML: String) {
        guard bodyHTML != loadedHTML else { return }
        pendingHTML = bodyHTML
        loadIfReady()
    }

    /// True once the view can paint crisply: on the real screen (correct scale) and sized.
    private var canPaintCrisply: Bool { window != nil && bounds.width > 1 && bounds.height > 1 }

    /// Paint the pending HTML the moment the view is ready, exactly once per distinct HTML.
    private func loadIfReady() {
        guard let html = pendingHTML, canPaintCrisply else { return }
        pendingHTML = nil
        loadedHTML = html
        didInitialLoad = false
        web.frame = bounds
        web.loadHTMLString(Self.document(wrapping: html), baseURL: nil)
    }

    /// Feed text (e.g. a handwritten formula) into the widget's primary input. Prefers the InkLab
    /// contract `window.inklab.setInput(text)` that the generator is asked to expose; falls back to a
    /// best-effort "fill the first input + click a plot/compute button" for widgets generated before it.
    func setInput(_ text: String) {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)   // safely quoted JSON string literal
        let json = String(data: data, encoding: .utf8) ?? "\"\""
        let js = """
        (function(){
          var t = \(json);
          try {
            if (window.inklab && typeof window.inklab.setInput === 'function') { window.inklab.setInput(t); return 'protocol'; }
            var el = document.querySelector('input[type=text],input[type=search],input[type=number],input:not([type]),textarea');
            if (!el) return 'noinput';
            el.focus(); el.value = t;
            el.dispatchEvent(new Event('input', {bubbles:true}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
            var btns = Array.prototype.slice.call(document.querySelectorAll('button,input[type=submit],input[type=button]'));
            var b = btns.filter(function(x){ return /plot|graph|draw|compute|calc|run|update|go|=/i.test((x.textContent||x.value||'')); })[0];
            if (b) b.click();
            else if (el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
            else { el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', keyCode:13, bubbles:true})); }
            return 'fallback';
          } catch (e) { return 'error:' + e.message; }
        })();
        """
        web.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Apply our strict CSP to the generated HTML. Claude returns a FULL document, so we inject the
    /// CSP into its <head> and render it as-is; the on-device stub returns a BODY-level fragment, so
    /// we wrap it. Either way the sandbox (CSP default-src 'none' + the WKWebView lockdown) applies.
    private static func document(wrapping html: String) -> String {
        // `'unsafe-eval'`: lets graphers/calculators evaluate a user-typed expression (`new Function`/
        // `eval`). Safe here because `default-src 'none'` + baseURL nil keep the widget fully offline —
        // eval can compute but can't reach the network or escape the card.
        let csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline' 'unsafe-eval'; img-src data:; font-src data:; media-src data:;"
        let injected = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=1\">"
        // Full document (Claude): inject our CSP into the existing <head> and render natively.
        if html.range(of: "<head>", options: .caseInsensitive) != nil {
            return html.replacingOccurrences(of: "<head>", with: "<head>\(injected)", options: .caseInsensitive)
        }
        // Body-level fragment (stub / partials): wrap it in our own CSP'd document.
        return """
        <!doctype html><html><head><meta charset="utf-8">\(injected)
        <style>html,body{margin:0;padding:10px;font-family:-apple-system,system-ui,sans-serif;color:#111;-webkit-text-size-adjust:100%;}*{box-sizing:border-box;}</style>
        </head><body>\(html)</body></html>
        """
    }

    // Allow only the initial in-memory load; cancel any subsequent navigation (link taps, redirects).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !didInitialLoad { didInitialLoad = true; decisionHandler(.allow) } else { decisionHandler(.cancel) }
    }

    // Deny window.open / target=_blank popups.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}
