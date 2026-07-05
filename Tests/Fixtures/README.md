# Test Fixtures

Synthetic `.emlx` files in the real Apple Mail on-disk format: a byte-count
first line, then the raw RFC 5322 message, then a trailing plist. Use these
for headless ingestion and retrieval tests so no test ever touches the live
mailbox.

| File | Tests |
|---|---|
| `msg-0001-plain.emlx` | Baseline. Plain-text English body. Message-ID `<fixture-0001@acme.example>`. Ingestion should extract the body and the correct Message-ID. |
| `msg-0002-html-de.emlx` | HTML body in German with unsubscribe link and a tracking-pixel img. Tests HTML-to-text and boilerplate stripping: the chunk should keep "EU-Omnibus-Zeitplan" and drop the unsubscribe/pixel block. Message-ID `<fixture-0002@anbieter.example>`. |
| `msg-0003-pdf.emlx` | multipart/mixed with a base64 PDF attachment. Tests MIME parse + attachment decode + PDF text extraction. Extracted text contains "INV-2026-0473" and "1,340.00 EUR", both must attach to the parent Message-ID `<fixture-0003@acme.example>` with source=pdf. |

## Notes
- Dates in the raw messages are RFC 5322 header dates. The envelope-index
  path (Cocoa epoch) is exercised separately against a synthetic index in
  the Store tests, not here.
- The trailing plist `date-received` values (1740000000) are deliberately
  NOT consistent with the header dates and are never asserted on. Do not
  write tests that read the plist date from these fixtures; the plist is
  present only so parsers handle the real on-disk emlx shape.
- These fixtures are safe to commit: no real personal data.
- The `generation.jsonl` eval mirrors the invoice figures from
  `msg-0003-pdf.emlx`, so the two can be cross-checked.
