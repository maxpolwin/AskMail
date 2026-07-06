import Foundation

// MARK: - Curated model registry (the "how to choose" guidance layer)

/// One recommended model the pickers offer, whether or not it's installed yet.
/// Sizes are shown before any download (never a surprise multi-GB pull).
public struct ModelOption: Sendable, Equatable {
    public enum Kind: Sendable {
        case chat
        case embedding
    }

    public let id: String
    public let kind: Kind
    public let approxSizeMB: Int
    /// One line of guidance shown next to the model: quality/speed trade-off
    /// and rough hardware needs.
    public let blurb: String
    /// Vector width, for embedding models — the registry fallback when
    /// `/api/show` can't be asked (Phase 3 index stamp).
    public let embeddingDimensions: Int?

    public init(id: String, kind: Kind, approxSizeMB: Int, blurb: String,
                embeddingDimensions: Int? = nil) {
        self.id = id
        self.kind = kind
        self.approxSizeMB = approxSizeMB
        self.blurb = blurb
        self.embeddingDimensions = embeddingDimensions
    }

    /// "275 MB" / "4.7 GB" for buttons and blurbs.
    public var sizeLabel: String {
        approxSizeMB >= 1000
            ? String(format: "%.1f GB", Double(approxSizeMB) / 1000)
            : "\(approxSizeMB) MB"
    }
}

/// The curated lists behind the Settings pickers. Ordering is the display
/// order: the default/recommended entry first.
public enum ModelCatalog {
    public static let chat: [ModelOption] = [
        ModelOption(id: Defaults.localChatModel, kind: .chat, approxSizeMB: 4700,
                    blurb: "Balanced quality \u{00B7} 4.7 GB \u{00B7} ~8 GB RAM"),
        ModelOption(id: "llama3.2:3b", kind: .chat, approxSizeMB: 2000,
                    blurb: "Fast, lighter answers \u{00B7} 2.0 GB \u{00B7} ~4 GB RAM"),
        ModelOption(id: "qwen2.5:14b", kind: .chat, approxSizeMB: 9000,
                    blurb: "Best quality, slower \u{00B7} 9.0 GB \u{00B7} ~16 GB RAM"),
    ]

    public static let embedding: [ModelOption] = [
        ModelOption(id: Defaults.embeddingModel, kind: .embedding,
                    approxSizeMB: Defaults.embeddingModelApproxMB,
                    blurb: "Recommended \u{00B7} 275 MB \u{00B7} fast, solid retrieval",
                    embeddingDimensions: 768),
        ModelOption(id: "mxbai-embed-large", kind: .embedding, approxSizeMB: 670,
                    blurb: "Higher retrieval quality, slower \u{00B7} 670 MB",
                    embeddingDimensions: 1024),
        ModelOption(id: "all-minilm", kind: .embedding, approxSizeMB: 46,
                    blurb: "Smallest and fastest, lower quality \u{00B7} 46 MB",
                    embeddingDimensions: 384),
    ]

    /// One selectable picker row: `id` is what gets persisted (and sent to
    /// Ollama); `label` is what the row shows.
    public struct PickerChoice: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }
    }

    /// What a picker renders: rows that can be selected now, and recommended
    /// models that need a download first.
    public struct PickerGroups: Sendable, Equatable {
        public let selectable: [PickerChoice]
        public let downloadable: [ModelOption]

        public init(selectable: [PickerChoice], downloadable: [ModelOption]) {
            self.selectable = selectable
            self.downloadable = downloadable
        }
    }

    /// Merges the curated catalog with what `/api/tags` reports, pure so it's
    /// unit-testable: recommended-and-installed first (catalog order), then
    /// other suitable installed models, then — so the picker never renders a
    /// blank selection — the current choice flagged "(not installed)" if it
    /// isn't available. Recommended-but-missing models come back as
    /// `downloadable` for in-place pull buttons.
    public static func pickerGroups(kind: ModelOption.Kind,
                                    catalog: [ModelOption]? = nil,
                                    installed: [InstalledModel],
                                    selected: String,
                                    unavailableSuffix: String = "not installed") -> PickerGroups {
        let options = catalog ?? (kind == .chat ? chat : embedding)
        var selectable: [PickerChoice] = []
        var downloadable: [ModelOption] = []
        var claimed = Set<String>()

        for option in options {
            if let match = installed.first(where: { OllamaStatus.modelName($0.name, matches: option.id) }) {
                selectable.append(PickerChoice(id: option.id, label: option.id))
                claimed.insert(match.name)
            } else {
                downloadable.append(option)
            }
        }

        let others = installed
            .filter { !claimed.contains($0.name) && isSuitable($0, for: kind) }
            .sorted { $0.name < $1.name }
        selectable += others.map { PickerChoice(id: $0.name, label: $0.name) }

        if !selectable.contains(where: { $0.id == selected }) {
            selectable.append(PickerChoice(id: selected,
                                           label: "\(selected) (\(unavailableSuffix))"))
        }
        return PickerGroups(selectable: selectable, downloadable: downloadable)
    }

    /// Whether a non-catalog installed model belongs in a picker of this kind.
    /// The embedding picker must never offer a chat model (its vectors would
    /// be garbage), so it requires an explicit "embedding" capability; with an
    /// older daemon that doesn't report capabilities, unknown models stay out.
    /// The chat picker fails open on unknowns (most models chat) but excludes
    /// declared embedding-only models.
    static func isSuitable(_ model: InstalledModel, for kind: ModelOption.Kind) -> Bool {
        switch kind {
        case .embedding:
            return model.capabilities.contains("embedding")
        case .chat:
            return model.capabilities.isEmpty || model.capabilities.contains("completion")
        }
    }
}
