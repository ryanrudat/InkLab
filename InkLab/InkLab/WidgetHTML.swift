import Foundation
import CoreGraphics

/// The card shape a generated widget declares with `<meta name="inklab-layout" content="…">` (the proxy
/// reads it and returns `layout`). These content sizes must match the make-real system prompt in
/// `Server/src/makeReal.ts`, which tells the model which size it is designing for.
enum WidgetLayout: String, Sendable, Equatable {
    case portrait, landscape, square

    var contentSize: CGSize {
        switch self {
        case .portrait:  return CGSize(width: 360, height: 540)
        case .landscape: return CGSize(width: 560, height: 360)
        case .square:    return CGSize(width: 440, height: 440)
        }
    }
}

/// The chrome around a widget's content: a header bar (title, ✏️ 🧽 ƒ, ✕) on top and a footer bar that holds
/// the resize grip, so no chrome ever sits on top of the widget's own controls.
enum WidgetCard {
    static let headerHeight: CGFloat = 28
    static let footerHeight: CGFloat = 22

    /// The full card size for a given content area.
    static func size(content: CGSize) -> CGSize {
        CGSize(width: content.width, height: content.height + headerHeight + footerHeight)
    }
}

/// Turns generated widget HTML into the exact document the sandboxed WKWebView loads.
enum WidgetHTML {
    /// `default-src 'none'` keeps the widget fully offline. `'unsafe-eval'` lets graphers/calculators
    /// evaluate a user-typed expression (`new Function`/`eval`); it can compute but can't reach the network.
    static let contentSecurityPolicy =
        "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline' 'unsafe-eval'; img-src data:; font-src data:; media-src data:;"

    private static let injectedHead =
        "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">"
        + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, maximum-scale=1\">"

    /// The HTML a model reply actually contains, without any preamble, ```html fence, closing remark or
    /// completion marker. The proxy already does this (`extractWidgetHtml`); doing it again here repairs
    /// widgets that were saved before it did, whose stray text would otherwise render inside the card.
    static func extractDocument(_ raw: String) -> String {
        if let start = raw.range(of: #"<!doctype\s+html|<html[\s>]"#, options: [.regularExpression, .caseInsensitive]) {
            let doc = raw[start.lowerBound...]
            if let end = doc.range(of: "</html>", options: [.caseInsensitive, .backwards]) {
                return String(doc[..<end.upperBound])
            }
            return stripTrailingFenceAndMarker(String(doc))
        }
        let fence = try? NSRegularExpression(pattern: #"```[ \t]*(?:html?)?[ \t]*\r?\n([\s\S]*?)(?:\r?\n[ \t]*```|$)"#,
                                             options: [.caseInsensitive])
        let ns = raw as NSString
        if let match = fence?.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
           match.range(at: 1).location != NSNotFound {
            return stripTrailingFenceAndMarker(ns.substring(with: match.range(at: 1)))
        }
        return stripTrailingFenceAndMarker(raw)
    }

    /// The full, CSP-locked document to load. A full document gets our CSP as the very first element after a
    /// standards-mode doctype — before any of the widget's own markup, so no widget script can run ahead of
    /// the policy, and a missing or late doctype can't drop the page into quirks mode. (The widget's own
    /// `<html>`/`<head>` tags that follow are merged into the implied ones by the HTML parser.) A body-level
    /// fragment is wrapped in our own document.
    static func sandboxedDocument(_ raw: String) -> String {
        let html = extractDocument(raw)
        if html.range(of: #"^(<!doctype\s+html|<html[\s>])"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let body = html.replacingOccurrences(of: #"^<!doctype[^>]*>"#, with: "",
                                                 options: [.regularExpression, .caseInsensitive])
            return "<!doctype html>\(injectedHead)\(body)"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">\(injectedHead)
        <style>html,body{margin:0;padding:10px;font-family:-apple-system,system-ui,sans-serif;color:#111;background:#fff;-webkit-text-size-adjust:100%;}*{box-sizing:border-box;}</style>
        </head><body>\(html)</body></html>
        """
    }

    /// The widget's `<title>` (from the document head, never an SVG `<title>` in the body), cleaned for the
    /// card's header bar. Nil when there is none.
    static func title(in html: String) -> String? {
        let headEnd = html.range(of: "</head>", options: .caseInsensitive)?.lowerBound
            ?? html.range(of: "<body", options: .caseInsensitive)?.lowerBound
            ?? html.endIndex
        let head = html[..<headEnd]
        guard let tag = head.range(of: #"<title[^>]*>[\s\S]*?</title>"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        var text = String(head[tag])
            .replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                               ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > 48 ? String(text.prefix(47)) + "…" : text
    }

    private static func stripTrailingFenceAndMarker(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*```\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<!--\s*INKLAB_DONE\s*-->\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
