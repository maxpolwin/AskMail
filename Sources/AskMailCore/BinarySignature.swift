import Foundation
import Security

/// Verifies a binary's code signature before it's trusted to run as a child
/// process (H-20). `OllamaEngine.startOllama()` uses this to gate spawning
/// the `ollama` CLI: `/usr/local/bin` is admin-writable without root on many
/// Macs, so a planted binary must never run just because a file with the
/// right name exists at a candidate path.
public enum BinarySignature {

    /// Apple-signed OR Developer ID. Notarization is deliberately not
    /// required here — the H-20 threat is a planted/unsigned/ad-hoc-signed
    /// binary, not an un-notarized-but-otherwise-legitimate one. The OID
    /// `1.2.840.113635.100.6.1.13` is Apple's "Developer ID Application"
    /// leaf marker.
    private static let requirementString =
        "anchor apple or (anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13])"

    /// Whether the binary at `url` satisfies the requirement above. Any
    /// Security-framework failure — missing file, no signature, ad-hoc
    /// signature, requirement mismatch — returns `false`. Never throws, so a
    /// call site can't accidentally treat a framework error as "trusted" by
    /// mishandling an exception.
    public static func isTrusted(url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [],
                                             &requirement) == errSecSuccess,
              let requirement else {
            return false
        }

        return SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
