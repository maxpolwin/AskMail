import Foundation

/// Minimal RFC 5322 / MIME parsing, sufficient for Apple Mail .emlx bodies.
/// Operates on untrusted input: fails closed, never executes or follows
/// embedded content (SECURITY.md).
enum Mime {

    struct ContentType {
        var mimeType: String          // e.g. "text/plain", lowercased
        var parameters: [String: String]  // keys lowercased, values unquoted

        var isMultipart: Bool { mimeType.hasPrefix("multipart/") }
        var boundary: String? { parameters["boundary"] }
        var charset: String? { parameters["charset"]?.lowercased() }
        var name: String? { parameters["name"] }
    }

    struct Part {
        var headers: [(name: String, value: String)]
        var rawBody: String

        func header(_ name: String) -> String? {
            let lower = name.lowercased()
            return headers.first { $0.name.lowercased() == lower }?.value
        }

        var contentType: ContentType {
            Mime.parseContentType(header("Content-Type") ?? "text/plain")
        }

        /// Decoded body bytes per Content-Transfer-Encoding.
        var decodedBody: Data {
            let encoding = (header("Content-Transfer-Encoding") ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            switch encoding {
            case "base64":
                let compact = rawBody.filter { !$0.isWhitespace }
                return Data(base64Encoded: compact) ?? Data()
            case "quoted-printable":
                return Mime.decodeQuotedPrintable(rawBody)
            default:
                return Data(rawBody.utf8)
            }
        }

        /// Decoded body as text, honoring the declared charset where possible.
        var decodedText: String {
            let data = decodedBody
            let charset = contentType.charset ?? "utf-8"
            let encoding: String.Encoding
            switch charset {
            case "utf-8", "us-ascii": encoding = .utf8
            case "iso-8859-1", "latin1": encoding = .isoLatin1
            case "windows-1252": encoding = .windowsCP1252
            default: encoding = .utf8
            }
            return String(data: data, encoding: encoding)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        }

        var attachmentFilename: String? {
            if let disposition = header("Content-Disposition"),
               let filename = Mime.parameter("filename", in: disposition) {
                return filename
            }
            return contentType.name
        }
    }

    // MARK: Header parsing

    /// Splits a raw message into (headerText, bodyText) at the first blank line.
    static func splitHeadersAndBody(_ message: String) -> (String, String) {
        let normalized = message.replacingOccurrences(of: "\r\n", with: "\n")
        if let range = normalized.range(of: "\n\n") {
            return (String(normalized[..<range.lowerBound]),
                    String(normalized[range.upperBound...]))
        }
        return (normalized, "")
    }

    /// Parses and unfolds header lines. Preserves order; duplicate names kept.
    static func parseHeaders(_ headerText: String) -> [(name: String, value: String)] {
        var headers: [(String, String)] = []
        for line in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                // Continuation of the previous header (unfolding).
                if var last = headers.popLast() {
                    last.1 += " " + line.trimmingCharacters(in: .whitespaces)
                    headers.append(last)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        return headers
    }

    static func parseContentType(_ value: String) -> ContentType {
        let segments = value.split(separator: ";")
        let mimeType = segments.first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? "text/plain"
        var params: [String: String] = [:]
        for segment in segments.dropFirst() {
            let pair = segment.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            var val = pair[1].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            params[key] = val
        }
        return ContentType(mimeType: mimeType, parameters: params)
    }

    static func parameter(_ key: String, in headerValue: String) -> String? {
        parseContentType(headerValue).parameters[key.lowercased()]
    }

    // MARK: Multipart

    /// Splits a multipart body into parts by boundary. Returns [] when the
    /// boundary never occurs (fail closed on malformed input).
    static func multipartParts(body: String, boundary: String) -> [Part] {
        let delimiter = "--" + boundary
        let terminator = delimiter + "--"
        var sections: [[Substring]] = []
        var current: [Substring]? = nil

        for line in body.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == terminator {
                if let section = current { sections.append(section) }
                current = nil
                break
            }
            if trimmed == delimiter {
                if let section = current { sections.append(section) }
                current = []
                continue
            }
            current?.append(line)
        }
        if let section = current { sections.append(section) }

        return sections.compactMap { lines in
            let text = lines.joined(separator: "\n")
            let (headerText, bodyText) = splitHeadersAndBody(text)
            let headers = parseHeaders(headerText)
            guard !headers.isEmpty || !bodyText.isEmpty else { return nil }
            return Part(headers: headers, rawBody: bodyText)
        }
    }

    // MARK: Quoted-printable

    static func decodeQuotedPrintable(_ text: String) -> Data {
        var out = Data()
        var iterator = text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.makeIterator()
        var pending: [Unicode.Scalar] = []

        func next() -> Unicode.Scalar? {
            if pending.isEmpty { return iterator.next() }
            return pending.removeFirst()
        }

        while let scalar = next() {
            if scalar == "=" {
                guard let a = next() else { break }
                if a == "\n" { continue }  // soft line break
                guard let b = next() else { break }
                let hex = String(a) + String(b)
                if let byte = UInt8(hex, radix: 16) {
                    out.append(byte)
                } else {
                    out.append(contentsOf: Array("=\(hex)".utf8))
                }
            } else {
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        return out
    }
}
