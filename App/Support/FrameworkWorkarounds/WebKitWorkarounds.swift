import Foundation
import WebKit

/// Everything the app does that depends on how WebKit behaves inside, rather than on its
/// documented API: one function per workaround, each saying what it works around. What each one
/// leans on is pinned by `FrameworkWorkaroundCanaryTests`.
nonisolated enum WebKitWorkarounds {
    /// A content rule list (JSON) that blocks every load except those under `schemes`.
    ///
    /// Works around: a `WKWebView` has no switch for "no network". The converters render files
    /// they serve themselves under their own scheme, and nothing a document links to may be
    /// fetched, so everything is blocked and each allowed scheme is then let through with its own
    /// `ignore-previous-rules` rule. One rule per scheme, because the rule-list compiler takes
    /// only a subset of regular expressions: alternation is not allowed, and `^(https?|…):` was
    /// rejected (docs/FORMAT_IMPORT_PLAN.md, "F0 findings"). `data:` URLs are not loads and are
    /// never blocked. Schemes must be lower case (WebKit requires it of a custom scheme).
    static func ruleListBlockingEverything(except schemes: [String]) -> String {
        let block = #"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#
        let allow = schemes.map { #"{"trigger":{"url-filter":"^\#($0):"},"action":{"type":"ignore-previous-rules"}}"# }
        return "[" + ([block] + allow).joined(separator: ",") + "]"
    }
}
