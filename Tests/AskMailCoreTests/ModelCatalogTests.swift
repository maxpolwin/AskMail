import XCTest
@testable import AskMailCore

/// The picker-population merge: curated catalog × /api/tags. Pure logic, no
/// network (spec constraint: tests stay headless).
final class ModelCatalogTests: XCTestCase {

    private let chatCatalog = [
        ModelOption(id: "qwen2.5:7b", kind: .chat, approxSizeMB: 4700, blurb: "balanced"),
        ModelOption(id: "llama3.2:3b", kind: .chat, approxSizeMB: 2000, blurb: "fast"),
    ]
    private let embeddingCatalog = [
        ModelOption(id: "nomic-embed-text", kind: .embedding, approxSizeMB: 275,
                    blurb: "recommended", embeddingDimensions: 768),
    ]

    func testInstalledRecommendedIsSelectableMissingIsDownloadable() {
        // llama3.2 is installed under its full ":latest" tag; qwen isn't pulled.
        let installed = [
            InstalledModel(name: "llama3.2:3b", sizeBytes: 1, capabilities: ["completion"]),
        ]
        let groups = ModelCatalog.pickerGroups(kind: .chat, catalog: chatCatalog,
                                               installed: installed,
                                               selected: "llama3.2:3b")
        XCTAssertEqual(groups.selectable.map(\.id), ["llama3.2:3b"])
        XCTAssertEqual(groups.downloadable.map(\.id), ["qwen2.5:7b"])
    }

    func testOtherInstalledChatModelsAreOfferedButEmbeddingOnlyIsNot() {
        let installed = [
            InstalledModel(name: "llama3.2:3b", sizeBytes: 1, capabilities: ["completion"]),
            InstalledModel(name: "phi3:latest", sizeBytes: 1, capabilities: ["completion"]),
            InstalledModel(name: "nomic-embed-text:latest", sizeBytes: 1,
                           capabilities: ["embedding"]),
            // Older daemons report no capabilities: chat fails open on those.
            InstalledModel(name: "mystery:latest", sizeBytes: 1),
        ]
        let groups = ModelCatalog.pickerGroups(kind: .chat, catalog: chatCatalog,
                                               installed: installed,
                                               selected: "llama3.2:3b")
        XCTAssertEqual(groups.selectable.map(\.id),
                       ["llama3.2:3b", "mystery:latest", "phi3:latest"],
                       "catalog entry first, then other installed sorted; embedding-only excluded")
    }

    func testEmbeddingPickerExcludesChatAndUnknownModels() {
        // A chat model's vectors would silently corrupt retrieval, and an
        // unknown-capability model can't be trusted either: only declared
        // embedding models are offered beyond the catalog.
        let installed = [
            InstalledModel(name: "nomic-embed-text:latest", sizeBytes: 1,
                           capabilities: ["embedding"]),
            InstalledModel(name: "mxbai-embed-large:latest", sizeBytes: 1,
                           capabilities: ["embedding"]),
            InstalledModel(name: "llama3.2:3b", sizeBytes: 1, capabilities: ["completion"]),
            InstalledModel(name: "mystery:latest", sizeBytes: 1),
        ]
        let groups = ModelCatalog.pickerGroups(kind: .embedding, catalog: embeddingCatalog,
                                               installed: installed,
                                               selected: "nomic-embed-text")
        XCTAssertEqual(groups.selectable.map(\.id),
                       ["nomic-embed-text", "mxbai-embed-large:latest"])
        XCTAssertTrue(groups.downloadable.isEmpty)
    }

    func testSelectedButUninstalledModelStaysVisibleAndFlagged() {
        // The default chat model before anything is pulled: the picker must
        // show the current selection (never a blank control) and mark it.
        let groups = ModelCatalog.pickerGroups(kind: .chat, catalog: chatCatalog,
                                               installed: [],
                                               selected: "qwen2.5:7b")
        XCTAssertEqual(groups.selectable,
                       [ModelCatalog.PickerChoice(id: "qwen2.5:7b",
                                                  label: "qwen2.5:7b (not installed)")])
        XCTAssertEqual(groups.downloadable.map(\.id), ["qwen2.5:7b", "llama3.2:3b"])
    }

    func testCatalogEntriesMatchFullyTaggedInstalledNames() {
        // /api/tags reports "nomic-embed-text:latest" for the untagged catalog
        // id; that counts as installed, not downloadable.
        let installed = [
            InstalledModel(name: "nomic-embed-text:latest", sizeBytes: 1,
                           capabilities: ["embedding"]),
        ]
        let groups = ModelCatalog.pickerGroups(kind: .embedding, catalog: embeddingCatalog,
                                               installed: installed,
                                               selected: "nomic-embed-text")
        XCTAssertEqual(groups.selectable.map(\.id), ["nomic-embed-text"])
        XCTAssertTrue(groups.downloadable.isEmpty)
        XCTAssertFalse(groups.selectable[0].label.contains("not installed"))
    }

    func testShippedCatalogIsCoherent() {
        // The registry the app actually ships: right kinds, the defaults
        // present, dimensions on every embedding entry (Phase-3 stamp
        // fallback), and honest size labels.
        XCTAssertTrue(ModelCatalog.chat.allSatisfy { $0.kind == .chat })
        XCTAssertTrue(ModelCatalog.embedding.allSatisfy {
            $0.kind == .embedding && $0.embeddingDimensions != nil
        })
        XCTAssertEqual(ModelCatalog.chat.first?.id, Defaults.localChatModel)
        XCTAssertEqual(ModelCatalog.embedding.first?.id, Defaults.embeddingModel)
        XCTAssertEqual(ModelOption(id: "x", kind: .chat, approxSizeMB: 4700, blurb: "").sizeLabel,
                       "4.7 GB")
        XCTAssertEqual(ModelOption(id: "x", kind: .embedding, approxSizeMB: 275, blurb: "").sizeLabel,
                       "275 MB")
    }
}
