import AppKit
import AskMailCore
import SwiftUI

/// Read-only window listing ready Draft-Modus drafts, newest first. Per
/// `docs/draft-contract.md`'s hard constraint, nothing here ever sends,
/// inserts, or writes a draft into Apple Mail: "Copy" puts the body on the
/// clipboard, "Open thread in Mail" is a `message://` deep link (the same
/// trusted, app-generated scheme `AskView`'s citations already use), and
/// "Discard" only deletes AskMail's own local copy in `drafts.db`.
struct DraftsView: View {
    @StateObject private var model = DraftsViewModel()

    var body: some View {
        Group {
            if model.drafts.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.drafts, id: \.pk) { draft in
                        draftRow(draft)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 560, height: 640)
        .background(.ultraThinMaterial)
        .onAppear { model.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No drafts yet")
                .font(.headline)
            Text("Draft-Modus quietly drafts replies to ordinary inbox mail in the background. Ready drafts show up here for you to review, copy, or discard \u{2014} nothing is ever sent or inserted automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    @ViewBuilder
    private func draftRow(_ draft: DraftRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.sender)
                        .font(.subheadline.weight(.medium))
                    Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Date(timeIntervalSince1970: TimeInterval(draft.generatedAt)),
                     format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(draft.draftText)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 12) {
                Button("Copy") { model.copy(draft) }
                Button("Open thread in Mail") { model.openInMail(draft) }
                Spacer()
                Button("Discard", role: .destructive) { model.discard(draft) }
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }
}

/// Owns the `DraftStore` connection this window reads/writes -- a separate
/// instance from `DraftEngine`'s counts-only cache and a tick's own session,
/// opened on demand while the window is open. Standard SQLite/WAL supports
/// several concurrent connections to the same file fine (same pattern the
/// rest of Draft-Modus already relies on).
@MainActor
final class DraftsViewModel: ObservableObject {
    @Published private(set) var drafts: [DraftRecord] = []
    private var store: DraftStore?

    func refresh() {
        if store == nil {
            store = try? DraftStore(path: SettingsStore.draftsDatabasePath)
        }
        guard let store else {
            drafts = []
            return
        }
        drafts = (try? store.readyDrafts(limit: 200)) ?? []
    }

    func copy(_ draft: DraftRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft.draftText, forType: .string)
    }

    /// `latestMessageID` -> a `message://` deep link, mirroring
    /// `CitationRenderer.messageURL` exactly (it's the one source of that
    /// scheme app-wide — see `LinkPolicy`) so this always-safe-to-open
    /// button reuses the same trusted construction rather than re-deriving
    /// it.
    func openInMail(_ draft: DraftRecord) {
        guard let url = CitationRenderer.messageURL(messageID: draft.latestMessageID) else { return }
        NSWorkspace.shared.open(url)
    }

    func discard(_ draft: DraftRecord) {
        guard let store else { return }
        do {
            try store.deleteDraft(pk: draft.pk)
            refresh()
            // Keep the menu bar "Drafts (n)" badge in sync immediately
            // instead of waiting for the next scheduled tick.
            DraftEngine.shared.refreshCounts()
        } catch {
            RollingLog.shared.log("discard draft failed: \(error)", level: .error)
        }
    }
}

#Preview("Drafts \u{2014} light") {
    DraftsView().preferredColorScheme(.light)
}

#Preview("Drafts \u{2014} dark") {
    DraftsView().preferredColorScheme(.dark)
}
