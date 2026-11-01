import Foundation
import Testing

@testable import Paperdesk

struct RemovalSafetyTests {
    @Test @MainActor func successArchivesLatestDeferredNotesAndSidecars() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.directory)
        await store.loadIfNeeded()
        let id = try store.importPDF(fixture.url)
        let item = try #require(store.documents.first)
        let drawing = Data("drawing recovery".utf8)
        let ocr = Data("OCR recovery".utf8)
        try drawing.write(to: fixture.directory.appendingPathComponent("\(id).drawing"))
        try ocr.write(to: fixture.directory.appendingPathComponent("\(id).ocr.json"))
        store.update(id, notes: "Newest notes, before debounce", deferred: true)

        try store.remove(id)

        #expect(store.documents.isEmpty)
        let archive = fixture.directory.appendingPathComponent("Removed")
        #expect(!FileManager.default.fileExists(atPath: store.url(for: item).path))
        #expect(FileManager.default.fileExists(atPath: archive.appendingPathComponent(item.filename).path))
        #expect(try Data(contentsOf: archive.appendingPathComponent("\(id).drawing")) == drawing)
        #expect(try Data(contentsOf: archive.appendingPathComponent("\(id).ocr.json")) == ocr)
        let recovered = try JSONDecoder().decode(
            LibraryDocument.self, from: Data(contentsOf: archive.appendingPathComponent("\(id).json")))
        #expect(recovered.notes == "Newest notes, before debounce")
        let saved = try JSONDecoder().decode(
            [LibraryDocument].self,
            from: Data(contentsOf: fixture.directory.appendingPathComponent("library.json")))
        #expect(saved.isEmpty)
    }

    @Test @MainActor func repeatRemovalPreservesEarlierArchive() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.directory)
        await store.loadIfNeeded()
        let id = try store.importPDF(fixture.url)
        store.update(id, notes: "First recovery notes")
        let backup = try LibraryBackup(documents: store.documents, directory: fixture.directory)
        let item = try #require(store.documents.first)
        try store.remove(id)
        let removed = fixture.directory.appendingPathComponent("Removed")
        let oldPDF = try Data(contentsOf: removed.appendingPathComponent(item.filename))
        let oldMetadata = try Data(contentsOf: removed.appendingPathComponent("\(id).json"))

        _ = try await store.restoreBackupData(JSONEncoder().encode(backup))
        store.update(id, notes: "Second removal notes", deferred: true)
        try store.remove(id)

        #expect(store.documents.isEmpty)
        #expect(try Data(contentsOf: removed.appendingPathComponent(item.filename)) == oldPDF)
        #expect(try Data(contentsOf: removed.appendingPathComponent("\(id).json")) == oldMetadata)
        let attempts = try FileManager.default.contentsOfDirectory(
            at: removed, includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { $0.lastPathComponent.hasPrefix("\(id)-") }
        let secondArchive = try #require(attempts.first)
        #expect(attempts.count == 1)
        #expect(
            FileManager.default.fileExists(atPath: secondArchive.appendingPathComponent(item.filename).path))
        let recovered = try JSONDecoder().decode(
            LibraryDocument.self, from: Data(contentsOf: secondArchive.appendingPathComponent("\(id).json")))
        #expect(recovered.notes == "Second removal notes")
        #expect(!FileManager.default.fileExists(atPath: store.url(for: item).path))
    }

    @Test @MainActor func failedIndexCommitRestoresFilesAndRetainsNewestNotes() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.directory)
        await store.loadIfNeeded()
        let id = try store.importPDF(fixture.url)
        let item = try #require(store.documents.first)
        let source = store.url(for: item)
        let originalPDF = try Data(contentsOf: source)
        let drawing = Data("Do not lose this drawing".utf8)
        let drawingURL = fixture.directory.appendingPathComponent("\(id).drawing")
        try drawing.write(to: drawingURL)
        store.update(id, notes: "Latest unsaved notes survive failure", deferred: true)
        // A nonempty directory cannot be replaced by an atomic index-file write.
        // This forces a real commit failure after the archive moves, without hooks.
        let indexURL = fixture.directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)
        try Data("block replacement".utf8).write(to: indexURL.appendingPathComponent("blocker"))

        var failed = false
        do { try store.remove(id) } catch {
            failed = true
            #expect(error.localizedDescription.contains("remains in your library"))
        }

        #expect(failed)
        #expect(store.documents.first?.id == id)
        #expect(store.documents.first?.notes == "Latest unsaved notes survive failure")
        #expect(try Data(contentsOf: source) == originalPDF)
        #expect(try Data(contentsOf: drawingURL) == drawing)
        #expect(store.saveStatus == "Not saved")
        let removed = fixture.directory.appendingPathComponent("Removed")
        #expect(!FileManager.default.fileExists(atPath: removed.appendingPathComponent(item.filename).path))
        #expect(!FileManager.default.fileExists(atPath: removed.appendingPathComponent("\(id).drawing").path))
        let recovered = try JSONDecoder().decode(
            LibraryDocument.self, from: Data(contentsOf: removed.appendingPathComponent("\(id).json")))
        #expect(recovered.notes == "Latest unsaved notes survive failure")
    }
}
