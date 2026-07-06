import Foundation

/// Where a chunk's text came from within its email.
public enum ChunkSource: String, Sendable, Codable {
    case body
    case pdf
}

/// A PDF attachment as decoded from MIME, before text extraction.
public struct PdfAttachment: Sendable {
    public var filename: String
    public var data: Data

    public init(filename: String, data: Data) {
        self.filename = filename
        self.data = data
    }
}

/// The result of parsing one .emlx file.
public struct ParsedEmail: Sendable {
    /// Message-ID header value without the surrounding angle brackets.
    public var messageID: String
    public var subject: String
    public var sender: String
    /// The embedded `From:` of a forwarded message's original author, when
    /// `bodyText` contains a recognized forward marker (see `ForwardedEmail`).
    /// Nil for non-forwarded mail or unrecognized forward formats.
    public var originalSender: String?
    public var recipient: String
    /// From the RFC 5322 Date header. The envelope-index date path is separate.
    public var date: Date?
    /// Body text after HTML-to-text conversion and boilerplate stripping.
    public var bodyText: String
    public var pdfAttachments: [PdfAttachment]
    /// Attachments skipped (e.g. over the size cap), for logging.
    public var skippedAttachments: [String]

    public var dateUnix: Int64 { Int64(date?.timeIntervalSince1970 ?? 0) }
}

/// The result of parsing one .emlx file, ready for ingestion: unlike
/// `ParsedEmail`, PDF attachments are already reduced to extracted text (or
/// nil, mirroring `PdfText.extract`'s contract) rather than raw bytes.
///
/// This is the hardening-H-6 boundary type: the sandboxed parser XPC service
/// runs `EmlxParser.parse` *and* `PdfText.extract` (the PDFKit call) inside
/// itself and returns this, so raw untrusted PDF bytes never cross back into
/// the FDA-holding main process to be parsed there. `Codable` because it
/// crosses the XPC boundary as JSON (`ParserXPCProtocol`).
public struct IngestableEmail: Sendable, Codable, Equatable {
    /// One PDF attachment's extracted text, or nil if PDFKit found none
    /// (locked, image-only, or unreadable) — mirrors `PdfText.extract`.
    public struct PdfAttachmentText: Sendable, Codable, Equatable {
        public var filename: String
        public var text: String?

        public init(filename: String, text: String?) {
            self.filename = filename
            self.text = text
        }
    }

    public var messageID: String
    public var subject: String
    public var sender: String
    /// See `ParsedEmail.originalSender`.
    public var originalSender: String?
    public var dateUnix: Int64
    public var bodyText: String
    public var pdfAttachments: [PdfAttachmentText]
    /// Attachments skipped (e.g. over the size cap), for logging.
    public var skippedAttachments: [String]

    public init(messageID: String, subject: String, sender: String, originalSender: String? = nil,
               dateUnix: Int64, bodyText: String, pdfAttachments: [PdfAttachmentText], skippedAttachments: [String]) {
        self.messageID = messageID
        self.subject = subject
        self.sender = sender
        self.originalSender = originalSender
        self.dateUnix = dateUnix
        self.bodyText = bodyText
        self.pdfAttachments = pdfAttachments
        self.skippedAttachments = skippedAttachments
    }
}

/// A retrieval-ready chunk with the email metadata needed for prompt assembly
/// and citation rendering.
public struct ContextChunk: Sendable, Equatable {
    public var chunkID: Int64
    public var messageID: String
    public var subject: String
    public var sender: String
    /// See `ParsedEmail.originalSender`.
    public var originalSender: String?
    public var dateUnix: Int64
    public var source: ChunkSource
    public var text: String
    /// Reciprocal-rank-fusion score from retrieval (higher = more relevant).
    /// Carried through to `SourceRef` for the relevance bar; 0 when unranked.
    public var score: Double

    public init(chunkID: Int64, messageID: String, subject: String, sender: String, originalSender: String? = nil,
                dateUnix: Int64, source: ChunkSource, text: String, score: Double = 0) {
        self.chunkID = chunkID
        self.messageID = messageID
        self.subject = subject
        self.sender = sender
        self.originalSender = originalSender
        self.dateUnix = dateUnix
        self.source = source
        self.text = text
        self.score = score
    }
}

/// One numbered source email, the value side of the `N -> message_id` map.
public struct SourceRef: Sendable, Equatable {
    public var messageID: String
    public var subject: String
    /// The account holder whose mailbox holds this message (the raw `From`
    /// header) — the forwarder, for a forwarded message.
    public var sender: String
    /// See `ParsedEmail.originalSender`. Nil unless the message is a
    /// recognized forward.
    public var originalSender: String?
    public var dateUnix: Int64
    /// Retrieval relevance (best RRF score among this email's chunks); nil when
    /// unranked. Raw and unnormalized — the UI scales it per answer.
    public var relevance: Double?
    /// The exact chunk text retrieved for this source (the best-scoring
    /// chunk's `ContextChunk.text`) — what the model actually saw, shown on
    /// hover and included in the clipboard export so the citation is
    /// checkable against its real source text.
    public var excerpt: String

    /// Who should be cited as the source: the original author when this is a
    /// forwarded message, else the raw sender.
    public var attributedSender: String { originalSender ?? sender }

    public init(messageID: String, subject: String, sender: String, originalSender: String? = nil,
                dateUnix: Int64, relevance: Double? = nil, excerpt: String = "") {
        self.messageID = messageID
        self.subject = subject
        self.sender = sender
        self.originalSender = originalSender
        self.dateUnix = dateUnix
        self.relevance = relevance
        self.excerpt = excerpt
    }
}

/// One completed Q&A pair in the ephemeral in-memory session buffer.
public struct SessionTurn: Sendable, Equatable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// Crude token estimate used for context budgeting: ~4 characters per token.
public enum TokenEstimator {
    public static func tokens(_ text: String) -> Int {
        (text.count + 3) / 4
    }
}
