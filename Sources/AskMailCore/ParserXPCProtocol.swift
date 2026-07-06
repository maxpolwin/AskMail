import Foundation

/// XPC contract for the sandboxed parser service (hardening H-6). The main
/// app (holding Full Disk Access) reads raw `.emlx` bytes and hands them
/// across this boundary; the sandboxed, non-FDA, no-network child does all
/// untrusted MIME/HTML/PDF parsing — including the PDFKit call, the
/// highest-risk single component, since PDF/CoreGraphics parsers have a long
/// history of memory-corruption bugs — and hands back only extracted text.
///
/// Payloads cross as opaque JSON `Data` (`IngestableEmail`, `Codable`), not
/// native Swift types directly, since `NSXPCConnection` requires `@objc`-
/// compatible signatures. Shared by the XPC service (AskMailParserXPC,
/// which implements it) and the client (`XPCEmailParser` in AskMailCore,
/// which calls it).
@objc public protocol ParserXPCProtocol {
    /// Parses one .emlx file's raw bytes. `reply` carries either the
    /// JSON-encoded `IngestableEmail` or an error description, never both.
    func parseEmlx(_ data: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

public enum ParserXPC {
    /// The mach service name the XPC service registers under, matching
    /// `Contents/XPCServices/<this>.xpc`'s own `CFBundleIdentifier` inside
    /// the app bundle (Packaging/build-app.sh, Packaging/AskMailParserXPC-Info.plist).
    public static let serviceName = "com.askmail.app.parser"
}
