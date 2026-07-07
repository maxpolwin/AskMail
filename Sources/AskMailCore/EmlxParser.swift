import Foundation

public enum EmlxParseError: Error, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self {
        case .malformed(let reason): return "malformed emlx: \(reason)"
        }
    }
}

/// Parses Apple Mail .emlx files: a byte-count first line, the raw RFC 5322
/// message, then a trailing plist (which is ignored; its dates are read from
/// the envelope index instead, see Tests/Fixtures/README.md).
public enum EmlxParser {

    public static func parse(fileURL: URL) throws -> ParsedEmail {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw EmlxParseError.malformed("unreadable file \(fileURL.lastPathComponent): \(error)")
        }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> ParsedEmail {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
            throw EmlxParseError.malformed("no byte-count line")
        }
        guard let countLine = String(data: data[..<newline], encoding: .utf8),
              let count = Int(countLine.trimmingCharacters(in: .whitespaces)),
              count > 0 else {
            throw EmlxParseError.malformed("invalid byte-count line")
        }
        let messageStart = data.index(after: newline)
        guard data.count - messageStart >= count else {
            throw EmlxParseError.malformed("declared \(count) bytes, only \(data.count - messageStart) present")
        }
        let messageData = data.subdata(in: messageStart..<(messageStart + count))
        return try parseMessage(messageData)
    }

    // MARK: RFC 5322 message

    static func parseMessage(_ messageData: Data) throws -> ParsedEmail {
        guard let raw = String(data: messageData, encoding: .utf8)
                ?? String(data: messageData, encoding: .isoLatin1) else {
            throw EmlxParseError.malformed("undecodable message bytes")
        }
        let (headerText, bodyText) = Mime.splitHeadersAndBody(raw)
        let root = Mime.Part(headers: Mime.parseHeaders(headerText), rawBody: bodyText)

        guard let rawMessageID = root.header("Message-ID") ?? root.header("Message-Id") else {
            throw EmlxParseError.malformed("missing Message-ID")
        }
        let messageID = normalizeMessageID(rawMessageID)

        // Thread linking (Draft-Modus §3): normalized the same way as
        // messageID above so `ThreadResolver` can join on plain string
        // equality against `messages.message_id` — a raw, bracket-included
        // value here would never match.
        let inReplyTo = root.header("In-Reply-To").map(normalizeMessageID)
        let references = (root.header("References") ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalizeMessageID(String($0)) }
            .filter { !$0.isEmpty }

        var texts: [String] = []
        var pdfs: [PdfAttachment] = []
        var skipped: [String] = []
        collectContent(from: root, texts: &texts, pdfs: &pdfs, skipped: &skipped)

        let extractedText = texts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Detect before stripping: the original sender comes from the header
        // block that stripHeaderBlock is about to remove.
        let originalSender = ForwardedEmail.detectOriginalSender(in: extractedText)
        let cleanedText = ForwardedEmail.stripHeaderBlock(from: extractedText)

        return ParsedEmail(
            messageID: messageID,
            subject: root.header("Subject") ?? "",
            sender: root.header("From") ?? "",
            originalSender: originalSender,
            recipient: root.header("To") ?? "",
            date: root.header("Date").flatMap(parseRFC5322Date),
            bodyText: cleanedText,
            pdfAttachments: pdfs,
            skippedAttachments: skipped,
            inReplyTo: inReplyTo,
            references: references,
            listUnsubscribe: root.header("List-Unsubscribe"),
            listId: root.header("List-Id"),
            precedence: root.header("Precedence"),
            autoSubmitted: root.header("Auto-Submitted")
        )
    }

    /// Trims whitespace and strips the surrounding `<>` from a Message-ID
    /// (or an In-Reply-To/References token) — the same normalization for
    /// every Message-ID-shaped value so they compare equal by plain string
    /// equality, regardless of which header they came from.
    static func normalizeMessageID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// Walks the MIME tree collecting body text and PDF attachments.
    private static func collectContent(from part: Mime.Part,
                                       texts: inout [String],
                                       pdfs: inout [PdfAttachment],
                                       skipped: inout [String]) {
        let contentType = part.contentType

        if contentType.isMultipart {
            guard let boundary = contentType.boundary else { return }  // fail closed
            let children = Mime.multipartParts(body: part.rawBody, boundary: boundary)
            if contentType.mimeType == "multipart/alternative" {
                // Prefer the plain-text alternative; fall back to HTML.
                if let plain = children.first(where: { $0.contentType.mimeType == "text/plain" }) {
                    collectContent(from: plain, texts: &texts, pdfs: &pdfs, skipped: &skipped)
                } else if let html = children.first(where: { $0.contentType.mimeType == "text/html" }) {
                    collectContent(from: html, texts: &texts, pdfs: &pdfs, skipped: &skipped)
                }
            } else {
                for child in children {
                    collectContent(from: child, texts: &texts, pdfs: &pdfs, skipped: &skipped)
                }
            }
            return
        }

        let filename = part.attachmentFilename
        let isPdf = contentType.mimeType == "application/pdf"
            || (filename?.lowercased().hasSuffix(".pdf") ?? false)

        if isPdf {
            let data = part.decodedBody
            if data.count > Defaults.maxAttachmentBytes {
                skipped.append(filename ?? "attachment.pdf")
            } else if !data.isEmpty {
                pdfs.append(PdfAttachment(filename: filename ?? "attachment.pdf", data: data))
            }
            return
        }

        switch contentType.mimeType {
        case "text/plain":
            let text = part.decodedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { texts.append(HtmlText.stripBoilerplate(text)) }
        case "text/html":
            let text = HtmlText.stripBoilerplate(HtmlText.plainText(html: part.decodedText))
            if !text.isEmpty { texts.append(text) }
        default:
            break  // non-PDF attachments are out of scope in v1
        }
    }

    // MARK: Date

    private static let dateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
    ]

    static func parseRFC5322Date(_ value: String) -> Date? {
        // Strip trailing comments like "(CET)".
        var cleaned = value
        if let parenthesis = cleaned.firstIndex(of: "(") {
            cleaned = String(cleaned[..<parenthesis])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}
