import Foundation

/// Turns one .emlx file's raw bytes into an ingest-ready `IngestableEmail`.
///
/// Hardening H-6: `.emlx`/MIME/HTML parsing and PDFKit text extraction all
/// operate on untrusted, attacker-reachable input (arbitrary incoming mail).
/// Production wires `XPCEmailParser`, which runs that parsing inside a
/// sandboxed child process with no Full Disk Access, no Keychain, and no
/// network — so a parser exploit lands somewhere with nothing to steal
/// instead of inside the process holding the mailbox and API keys. Tests use
/// `InProcessEmailParser`, calling the parser directly, since test fixtures
/// are synthetic and safe, and IPC would only slow the suite down.
public protocol EmailParsing: Sendable {
    func parse(fileURL: URL) async throws -> IngestableEmail
}

/// Default `EmailParsing`: parses in this process. Correct and sufficient
/// for tests (synthetic fixtures); production uses `XPCEmailParser` instead
/// (wired in `Sources/AskMailApp`, where the sandboxed service bundle path
/// is known).
public struct InProcessEmailParser: EmailParsing {
    public init() {}

    public func parse(fileURL: URL) async throws -> IngestableEmail {
        let email = try EmlxParser.parse(fileURL: fileURL)
        return Self.ingestable(from: email)
    }

    /// Shared by the in-process path and the XPC service's implementation
    /// (Sources/AskMailParserXPC) — the PDF extraction step that must happen
    /// whichever side of the boundary the .emlx parsing runs on.
    public static func ingestable(from email: ParsedEmail) -> IngestableEmail {
        let pdfTexts = email.pdfAttachments.map {
            IngestableEmail.PdfAttachmentText(filename: $0.filename, text: PdfText.extract(data: $0.data))
        }
        return IngestableEmail(messageID: email.messageID, subject: email.subject,
                               sender: email.sender, dateUnix: email.dateUnix,
                               bodyText: email.bodyText, pdfAttachments: pdfTexts,
                               skippedAttachments: email.skippedAttachments)
    }
}
