import AskMailCore
import Foundation

/// Sandboxed parser XPC service (hardening H-6). Runs untrusted .emlx/MIME/
/// HTML parsing (`EmlxParser`) and PDF text extraction (`PdfText`, via
/// PDFKit — the single highest-risk component, given PDF/CoreGraphics
/// parsers' history of memory-corruption bugs) entirely inside this
/// process, which the app bundle embeds sandboxed and with no Full Disk
/// Access, Keychain, or network entitlement (Packaging/AskMailParserXPC.entitlements).
///
/// Never run directly — macOS launches it on demand when the host app
/// (AskMail.app) opens an `NSXPCConnection(serviceName: ParserXPC.serviceName)`
/// to it, and tears it down when idle. See docs/hardening.md.
final class ParserXPCService: NSObject, ParserXPCProtocol {
    func parseEmlx(_ data: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        do {
            let email = try EmlxParser.parse(data: data)
            let ingestable = InProcessEmailParser.ingestable(from: email)
            reply(try JSONEncoder().encode(ingestable), nil)
        } catch {
            reply(nil, String(describing: error))
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ParserXPCProtocol.self)
        newConnection.exportedObject = ParserXPCService()
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
