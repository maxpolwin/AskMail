import Foundation

/// Hardening H-14: the LLM answer is untrusted text. It is built from the
/// question plus retrieved mail content with no instruction/data separation
/// (docs/hardening.md), so a prompt-injected email can induce the model to
/// emit a Markdown link with an attacker-chosen destination — including a
/// non-http(s) scheme (`javascript:`, `file:`, a custom app scheme, ...).
/// That link then renders as clickable text in the panel (`answerMarkdown` in
/// AskView).
///
/// `LinkPolicy` is the single place that decides what happens when a link
/// coming from model output is activated, so every open sink (the rendered
/// answer text, the keyboard-reachable citation button, any future consumer)
/// enforces the same rule instead of each sink deciding for itself.
public enum LinkPolicy {
    public enum Action: Equatable {
        /// A scheme AskMail itself generates (the `message://` deep link from
        /// `CitationRenderer`) — always safe to open immediately.
        case open
        /// A scheme a legitimate answer might reasonably link to, but whose
        /// destination came from model output — require the user to
        /// explicitly confirm before the app opens anything external.
        case confirmThenOpen
        /// Any other scheme (`javascript:`, `file:`, `data:`, `ftp:`, a bare
        /// custom scheme, or no scheme at all) — never opened.
        case block
    }

    /// Schemes AskMail itself generates; nothing attacker-controlled can
    /// produce one because `CitationRenderer.messageURL` is the only source.
    private static let trustedSchemes: Set<String> = ["message"]

    /// Schemes worth offering the user a path to, gated behind confirmation
    /// since the destination is otherwise untrusted.
    private static let confirmSchemes: Set<String> = ["https", "http"]

    public static func action(for url: URL) -> Action {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return .block }
        if trustedSchemes.contains(scheme) { return .open }
        if confirmSchemes.contains(scheme) { return .confirmThenOpen }
        return .block
    }
}
