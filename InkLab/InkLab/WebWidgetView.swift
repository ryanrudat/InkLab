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
/// Generated HTML is never loaded verbatim: stray model text is stripped and our CSP is always placed ahead
/// of the widget's own markup (`WidgetHTML.sandboxedDocument`).
final class WebWidgetView: UIView, WKNavigationDelegate, WKUIDelegate, UIGestureRecognizerDelegate {
    /// Report real user interaction to the overlay so it can maintain its bounded LRU working set.
    var onInteraction: (() -> Void)?

    /// Created only while this host is visible/selected. Keeping the UIView wrapper cheap means a page may
    /// contain many generated objects without eagerly starting a WebContent process for every one.
    private var web: WKWebView?
    private let snapshotView = UIImageView()
    private let placeholderLabel = UILabel()
    private var sourceHTML: String?
    private var renderedHTML: String?
    private var pendingInput: String?
    private var didInitialLoad = false
    private var documentIsReady = false
    private var lifecycleGeneration: UInt = 0
    private(set) var isActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.card
        clipsToBounds = true

        snapshotView.contentMode = .scaleAspectFill
        snapshotView.clipsToBounds = true
        snapshotView.isUserInteractionEnabled = false
        addSubview(snapshotView)

        placeholderLabel.text = "Tap to resume widget"
        placeholderLabel.font = Theme.ui(13, .medium)
        placeholderLabel.textColor = Theme.inkSecondary
        placeholderLabel.textAlignment = .center
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)

        // Passive and simultaneous: observing a tap must never cancel a button/input interaction inside
        // WebKit. When the renderer is unloaded, the same tap promotes the wrapper back into the live set.
        let interactionTap = UITapGestureRecognizer(target: self, action: #selector(noteInteraction))
        interactionTap.cancelsTouchesInView = false
        interactionTap.delaysTouchesBegan = false
        interactionTap.delegate = self
        addGestureRecognizer(interactionTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        snapshotView.frame = bounds
        placeholderLabel.frame = bounds.insetBy(dx: 12, dy: 8)
        web?.frame = bounds
        loadIfReady()
    }

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
        guard bodyHTML != sourceHTML else { return }
        // A journal update can arrive while an inactive renderer is finishing its old snapshot. Cancel and
        // release that renderer so the old document can neither leak nor replace the new placeholder.
        if !isActive, let web {
            lifecycleGeneration &+= 1
            tearDown(web)
        }
        sourceHTML = bodyHTML
        // A snapshot of the previous document is misleading after a journal update.
        snapshotView.image = nil
        placeholderLabel.text = isActive ? "Loading widget…" : "Tap to resume widget"
        placeholderLabel.isHidden = false
        loadIfReady()
    }

    /// Promote this lightweight wrapper to a live renderer. Repeated activation is cheap and also cancels
    /// an in-flight snapshot/unload requested just before the widget became visible again.
    func activate() {
        isActive = true
        lifecycleGeneration &+= 1
        snapshotView.isHidden = false
        let web = ensureWebView()
        web.isUserInteractionEnabled = true
        loadIfReady()
    }

    /// Demote to a screenshot and release WebKit. Normal viewport eviction captures an image; memory
    /// pressure skips that allocation and tears down immediately. Source HTML and queued input stay small
    /// and are retained so reactivation can recover.
    func deactivate(captureSnapshot: Bool) {
        if !captureSnapshot {
            snapshotView.image = nil
            snapshotView.isHidden = false
            placeholderLabel.isHidden = false
        }
        guard isActive || web != nil else { return }
        isActive = false
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        snapshotView.isHidden = false
        placeholderLabel.text = "Tap to resume widget"
        guard let web else { return }
        web.endEditing(true)
        web.isUserInteractionEnabled = false

        guard captureSnapshot, window != nil, bounds.width > 1, bounds.height > 1 else {
            tearDown(web)
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = web.bounds
        web.takeSnapshot(with: configuration) { [weak self, weak web] image, _ in
            guard let self, let web,
                  self.lifecycleGeneration == generation, !self.isActive, self.web === web else { return }
            if let image { self.snapshotView.image = image }
            self.snapshotView.isHidden = false
            self.placeholderLabel.isHidden = self.snapshotView.image != nil
            self.tearDown(web)
        }
        // Snapshotting is best-effort. Never let a wedged WebContent process defeat the lifecycle cap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak web] in
            guard let self, let web,
                  self.lifecycleGeneration == generation, !self.isActive, self.web === web else { return }
            self.tearDown(web)
        }
    }

    @objc private func noteInteraction() { onInteraction?() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    private func ensureWebView() -> WKWebView {
        if let web { return web }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: bounds, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        addSubview(web)
        self.web = web
        renderedHTML = nil
        didInitialLoad = false
        documentIsReady = false
        return web
    }

    private func tearDown(_ web: WKWebView) {
        guard self.web === web else { return }
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.removeFromSuperview()
        self.web = nil
        renderedHTML = nil
        didInitialLoad = false
        documentIsReady = false
        snapshotView.isHidden = false
        placeholderLabel.isHidden = snapshotView.image != nil
    }

    /// True once the view can paint crisply: on the real screen (correct scale) and sized.
    private var canPaintCrisply: Bool { isActive && window != nil && bounds.width > 1 && bounds.height > 1 }

    /// Paint the pending HTML the moment the view is ready, exactly once per distinct HTML.
    private func loadIfReady() {
        guard let html = sourceHTML, let web, renderedHTML != html, canPaintCrisply else { return }
        renderedHTML = html
        didInitialLoad = false
        documentIsReady = false
        snapshotView.isHidden = false
        placeholderLabel.text = "Loading widget…"
        placeholderLabel.isHidden = snapshotView.image != nil
        web.frame = bounds
        web.stopLoading()
        web.loadHTMLString(Self.document(wrapping: html), baseURL: nil)
    }

    /// Feed text (e.g. a handwritten formula) into the widget's primary input. Prefers the InkLab
    /// contract `window.inklab.setInput(text)` that the generator is asked to expose; falls back to a
    /// best-effort "fill the first input + click a plot/compute button" for widgets generated before it.
    func setInput(_ text: String) {
        pendingInput = text
        applyPendingInputIfReady()
    }

    private func applyPendingInputIfReady() {
        guard documentIsReady, let web, let text = pendingInput else { return }
        pendingInput = nil
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
        web.evaluateJavaScript(js) { [weak self, weak web] _, error in
            guard let self, let web, self.web === web else { return }
            // A process termination or interrupted reload can race this evaluation. Keep the input queued
            // for the recovered document, but never overwrite a newer input that arrived in the meantime.
            if error != nil, self.pendingInput == nil { self.pendingInput = text }
        }
    }

    /// Strip any stray model text and apply our strict CSP (see `WidgetHTML.sandboxedDocument`). Either way
    /// the sandbox (CSP default-src 'none' + the WKWebView lockdown) applies.
    private static func document(wrapping html: String) -> String { WidgetHTML.sandboxedDocument(html) }

    // Allow only the initial in-memory load; cancel any subsequent navigation (link taps, redirects).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if !didInitialLoad { didInitialLoad = true; decisionHandler(.allow) } else { decisionHandler(.cancel) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web, isActive else { return }
        documentIsReady = true
        snapshotView.image = nil
        snapshotView.isHidden = true
        placeholderLabel.isHidden = true
        applyPendingInputIfReady()
    }

    /// WebKit may kill a content process under pressure without destroying WKWebView. Reload the same
    /// CSP-wrapped in-memory document when active; an inactive wrapper is torn down and will recover lazily.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { return }
        renderedHTML = nil
        didInitialLoad = false
        documentIsReady = false
        snapshotView.isHidden = false
        placeholderLabel.text = isActive ? "Reloading widget…" : "Tap to resume widget"
        placeholderLabel.isHidden = snapshotView.image != nil
        if isActive { loadIfReady() } else { tearDown(webView) }
    }

    // Deny window.open / target=_blank popups.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}
