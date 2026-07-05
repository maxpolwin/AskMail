import Foundation
import PDFKit

/// PDF text extraction via the system PDFKit framework (SECURITY.md prefers
/// system frameworks over third-party). Operates on untrusted input: parse
/// errors return nil, never throw into ingestion.
public enum PdfText {

    /// Extracts plain text from PDF data. Returns nil when the data is not a
    /// readable PDF, exceeds the size cap, or contains no extractable text.
    public static func extract(data: Data, maxBytes: Int = Defaults.maxAttachmentBytes) -> String? {
        guard data.count <= maxBytes else { return nil }
        guard let document = PDFDocument(data: data) else { return nil }
        guard !document.isLocked else { return nil }
        let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
