import Foundation
import CoreGraphics
import PDFKit
import Testing
@testable import Paperdesk

@MainActor struct HistoryFeatureTests {
    @Test func restoreVersionPreservesActivePDFAndNotes() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.directory.appendingPathComponent("Library"))
        await store.loadIfNeeded()
        let id = try await store.importPDFAsync(fixture.url)
        store.update(id, notes: "Earlier notes")
        let original = try #require(store.documents.first(where: { $0.id == id }))
        let version = try await DocumentHistoryService.shared.capture(document: original, library: store.directory, reason: "Test checkpoint", force: true)
        let pdf = try #require(PDFDocument(url: store.url(for: original)))
        pdf.page(at: 0)!.addAnnotation(PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 40, height: 20), forType: .highlight, withProperties: nil))
        #expect(pdf.write(to: store.url(for: original)))
        store.update(id, notes: "Active edits")
        let restoredID = try await store.restoreHistoryVersion(version)
        #expect(restoredID != id)
        #expect(store.documents.first(where: { $0.id == id })?.notes == "Active edits")
        let recovered = try #require(store.documents.first(where: { $0.id == restoredID }))
        #expect(recovered.notes == "Earlier notes")
        #expect(PDFDocument(url: store.url(for: original))?.page(at: 0)?.annotations.count == 1)
        #expect(PDFDocument(url: store.url(for: recovered))?.page(at: 0)?.annotations.isEmpty == true)
        let versions = try await DocumentHistoryService.shared.versions(documentID: id, library: store.directory)
        #expect(versions.contains(version))
    }

    @Test func recoveryKeepsRemovedArchiveAndRestoresFreshIdentity() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.directory.appendingPathComponent("Library"))
        await store.loadIfNeeded()
        let id = try await store.importPDFAsync(fixture.url)
        store.update(id, notes: "Recovery note", deferred: true)
        try store.remove(id)
        let snapshots = try await DocumentHistoryService.shared.removedDocuments(library: store.directory)
        let archived = try #require(snapshots.first(where: { $0.document.id == id }))
        let recoveredID = try await store.recoverRemovedDocument(archived)
        #expect(recoveredID != id)
        #expect(store.documents.first(where: { $0.id == recoveredID })?.notes == "Recovery note")
        #expect(FileManager.default.fileExists(atPath: archived.pdfURL.path))
        #expect(try await DocumentHistoryService.shared.removedDocuments(library: store.directory).contains(archived))
    }

    @Test func journalAndWorkspaceSurviveHistoryRecovery() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.directory.appendingPathComponent("Library"))
        await store.loadIfNeeded()
        let id = try await store.importPDFAsync(fixture.url)
        let document = try #require(store.documents.first)
        let url = store.url(for: document)
        let pdf = try #require(PDFDocument(url: url))
        let page = try #require(pdf.page(at: 0))
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 20, width: 50, height: 20), forType: .highlight, withProperties: nil))
        let data = try #require(page.dataRepresentation)
        let sourceVersion = try PDFFileVersion.read(from: url)
        _ = try await PDFPageJournal.shared.save(url: url, pages: [0: data], sourceVersion: sourceVersion, expectedRevision: nil)
        let workspace = WorkspaceStore(documentID: id, directory: store.directory)
        await workspace.load()
        try await workspace.bookmark(pageIndex: 0, title: "Source bookmark")
        let version = try await DocumentHistoryService.shared.capture(document: document, library: store.directory, reason: "With journal", force: true)
        let recoveredID = try await store.restoreHistoryVersion(version)
        let recovered = try #require(store.documents.first(where: { $0.id == recoveredID }))
        let restoredURL = store.url(for: recovered)
        let state = try #require(try await PDFPageJournal.shared.state(for: restoredURL, sourceVersion: PDFFileVersion.read(from: restoredURL)))
        let restoredData = try #require(try await PDFPageJournal.shared.pageData(url: restoredURL, index: 0, state: state))
        #expect(PDFDocument(data: restoredData)?.page(at: 0)?.annotations.count == 1)
        let restoredWorkspace = WorkspaceStore(documentID: recoveredID, directory: store.directory)
        await restoredWorkspace.load()
        #expect(restoredWorkspace.isLoaded)
        #expect(restoredWorkspace.bookmarks.first?.title == "Source bookmark")
        #expect(workspace.documentID == id)
        #expect(FileManager.default.fileExists(atPath: PDFPageJournal.directory(for: url).path))
    }

    @Test func failedIndexCommitKeepsRecoveryAndRollsBackNewFiles() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.directory.appendingPathComponent("Library"))
        await store.loadIfNeeded()
        let id = try await store.importPDFAsync(fixture.url)
        try store.remove(id)
        let archived = try #require(try await DocumentHistoryService.shared.removedDocuments(library: store.directory).first)
        let index = store.directory.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        let before = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
        var failed = false
        do { _ = try await store.recoverRemovedDocument(archived) } catch { failed = true }
        #expect(failed)
        #expect(store.documents.isEmpty)
        #expect(FileManager.default.fileExists(atPath: archived.pdfURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted() == before)
    }

    @Test func retentionAndExpectedFingerprintProtectSource() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.directory.appendingPathComponent("Library"))
        await store.loadIfNeeded()
        let id = try await store.importPDFAsync(fixture.url)
        let document = try #require(store.documents.first)
        let history = DocumentHistoryService()
        for index in 0..<12 {
            var item = document; item.notes = "Version \(index)"
            _ = try await history.capture(document: item, library: store.directory, reason: "Explicit checkpoint", force: true)
        }
        let versions = try await history.versions(documentID: id, library: store.directory)
        #expect(versions.count == DocumentHistoryService.maximumVersions)
        #expect(versions.first?.document.notes == "Version 11")
        var rejected = false
        do { _ = try await history.capture(document: document, library: store.directory, reason: "Stale", expectedFingerprint: "incorrect", force: true) } catch { rejected = true }
        #expect(rejected)
        #expect(FileManager.default.fileExists(atPath: store.url(for: document).path))
    }
}
