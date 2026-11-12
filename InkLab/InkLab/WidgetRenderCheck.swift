import UIKit
import WebKit

/// What a hidden test render of a generated widget found.
struct RenderHealth: Equatable, Sendable {
    /// Uncaught script errors while loading and during the first animation frames (at most a few).
    var errors: [String]
    /// Whether the page shows anything at all (text, canvas, SVG, image or video).
    var visible: Bool

    var ok: Bool { errors.isEmpty && visible }

    /// One line describing the problem, for the status toast and the retry prompt.
    var problem: String { errors.first ?? (visible ? "" : "the widget showed nothing") }
}

/// Render check for generated widgets. The model never sees what it built, so a widget can come back with a
/// syntax error (an unescaped apostrophe is enough) or a crash in its first frame and show a blank card. Before
/// a new widget is placed on the page, this loads it in a throwaway web view with the same lockdown as
/// `WebWidgetView` (CSP first, no base URL, non-persistent store, every navigation after the first cancelled,
/// no popups), lets it run briefly, and reports uncaught errors and whether anything rendered.
///
/// A hidden web view gets no animation frames, so the probe drives `requestAnimationFrame` with a timer; that
/// way errors inside a widget's draw loop surface too, not just errors at load.
@MainActor
final class WidgetRenderCheck: NSObject, WKNavigationDelegate, WKUIDelegate {
    nonisolated static let checkOrigin = URL(string: "inklab-check://widget/")

    nonisolated static let probeScript = """
    <script>(function(){var e=[];window.__inklabRenderErrors=e;\
    function note(m){if(e.length<5)e.push(String(m).slice(0,200));}\
    addEventListener('error',function(ev){if(!(ev instanceof ErrorEvent))return;note((ev.message||'Script error')+(ev.lineno?' (line '+ev.lineno+')':''));},true);\
    addEventListener('unhandledrejection',function(ev){var r=ev.reason;note('Unhandled promise rejection: '+(r&&r.message?r.message:r));});\
    window.requestAnimationFrame=function(cb){return setTimeout(function(){cb(performance.now());},16);};\
    window.cancelAnimationFrame=function(id){clearTimeout(id);};})();</script>
    """

    nonisolated static let reportScript = """
    (function(){var b=document.body;var visible=false;\
    if(b){visible=(b.innerText||'').trim().length>0||b.querySelector('canvas,svg,img,video')!==null;}\
    return JSON.stringify({errors:window.__inklabRenderErrors||[],visible:visible});})()
    """

    /// Load `html` hidden at the widget's card size, let it run for `settle`, and report what happened.
    static func run(html: String, size: CGSize,
                    settle: Duration = .milliseconds(1500), timeout: Duration = .seconds(10)) async -> RenderHealth {
        await WidgetRenderCheck().perform(html: html, size: size, settle: settle, timeout: timeout)
    }

    private var didInitialLoad = false
    private var load: Once<Bool>?

    private func perform(html: String, size: CGSize, settle: Duration, timeout: Duration) async -> RenderHealth {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        defer { web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil }

        let loaded: Bool = await withCheckedContinuation { cont in
            let once = Once(cont)
            load = once
            // A throwaway origin for the check view only: with no base URL the page's origin is "null" and WebKit
            // reports every error as just "Script error.", which gives the retry nothing to fix. The CSP still
            // blocks every load, navigations are still cancelled, and the store is non-persistent.
            web.loadHTMLString(WidgetHTML.sandboxedDocument(html, extraHead: Self.probeScript), baseURL: Self.checkOrigin)
            Task { @MainActor in try? await Task.sleep(for: timeout); once.resume(false) }
        }
        guard loaded else { return RenderHealth(errors: ["the widget didn't finish loading"], visible: false) }

        try? await Task.sleep(for: settle)

        let json: String? = await withCheckedContinuation { cont in
            let once = Once(cont)
            web.evaluateJavaScript(Self.reportScript) { result, _ in once.resume(result as? String) }
            Task { @MainActor in try? await Task.sleep(for: .seconds(3)); once.resume(nil) }   // a hung script
        }
        guard let data = json?.data(using: .utf8),
              let report = try? JSONDecoder().decode(Report.self, from: data) else {
            return RenderHealth(errors: ["the widget stopped responding"], visible: false)
        }
        return RenderHealth(errors: report.errors, visible: report.visible)
    }

    private struct Report: Decodable { var errors: [String]; var visible: Bool }

    // Same navigation lockdown as WebWidgetView: only the initial in-memory load.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if !didInitialLoad { didInitialLoad = true; decisionHandler(.allow) } else { decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { load?.resume(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { load?.resume(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        load?.resume(false)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

/// Resumes a continuation exactly once (whichever of the result or the timeout comes first).
@MainActor
private final class Once<T> {
    private var cont: CheckedContinuation<T, Never>?
    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
    func resume(_ value: T) { cont?.resume(returning: value); cont = nil }
}
