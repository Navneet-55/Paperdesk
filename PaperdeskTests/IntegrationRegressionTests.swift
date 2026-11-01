import CoreText
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import Paperdesk

@MainActor struct IntegrationRegressionTests {
    private func artwork(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 600)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        let bitmap = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for y in 0..<64 {
            for x in 0..<64 {
                bitmap.setFillColor(CGColor(red: CGFloat(x) / 64, green: CGFloat(y) / 64, blue: 0.4, alpha: 1))
                bitmap.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        context.beginPDFPage(nil)
        context.draw(try #require(bitmap.makeImage()), in: CGRect(x: 20, y: 20, width: 180, height: 150))
        context.setStrokeColor(CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1))
        context.setLineWidth(3)
        for index in 0..<20 {
            context.move(to: CGPoint(x: 210, y: 20 + index * 6))
            context.addLine(to: CGPoint(x: 370, y: 150 - index * 4))
            context.strokePath()
        }
        let text = NSAttributedString(string: "Printed aviation label 270", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)])
        context.textPosition = CGPoint(x: 30, y: 500)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        context.endPDFPage()
        context.closePDF()
    }
    /// Draws only the PDF content stream, excluding annotation appearances.
    private func background(_ page: PDFPage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8,
            bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        if let ref = page.pageRef { context.drawPDFPage(ref) }
        return Data(bytes: try #require(context.data), count: 1600 * 600)
    }
    private func ink(_ page: PDFPage, x: CGFloat = 40) throws {
        page.addAnnotation(try PDFInkAnnotation.make(points: [CGPoint(x: x, y: 250), CGPoint(x: x + 120, y: 310)],
            width: 8, color: .red, bounds: page.bounds(for: .cropBox)))
    }

    @Test func annotationSnapshotExcludesArtworkAndRetainsGeometry() throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        try artwork(fixture.url)
        let document = try #require(PDFDocument(url: fixture.url))
        let page = try #require(document.page(at: 0))
        page.setBounds(CGRect(x: 10, y: 15, width: 370, height: 560), for: .cropBox)
        page.rotation = 90
        try ink(page)
        let data = try PDFAnnotationSnapshot.data(from: page)
        let snapshot = try #require(PDFDocument(data: data))
        let copy = try #require(snapshot.page(at: 0))
        #expect(copy.rotation == 90)
        #expect(copy.bounds(for: .mediaBox) == page.bounds(for: .mediaBox))
        #expect(copy.bounds(for: .cropBox) == page.bounds(for: .cropBox))
        #expect(copy.annotations.count == 1)
        #expect((copy.string ?? "").isEmpty)
        let empty = PDFPage(); empty.setBounds(page.bounds(for: .mediaBox), for: .mediaBox)
        #expect(try background(copy) == background(empty))
        #expect(page.string?.contains("Printed aviation label") == true)
        #expect(page.annotations.count == 1)
    }

    @Test func canonicalAnnotationSavePreservesImageVectorTextAndLink() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        try artwork(fixture.url)
        var original = try #require(PDFDocument(url: fixture.url))
        let link = PDFAnnotation(bounds: CGRect(x: 30, y: 490, width: 200, height: 30), forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: try #require(URL(string: "https://example.com/manual")))
        original.page(at: 0)?.addAnnotation(link)
        let prepared = fixture.directory.appendingPathComponent("linked.pdf")
        #expect(original.write(to: prepared))
        original = try #require(PDFDocument(url: prepared))
        let page = try #require(original.page(at: 0))
        let before = try background(page)
        try ink(page)
        _ = try await PDFWriteService.shared.savePages(url: prepared, pages: [0: PDFAnnotationSnapshot.data(from: page)],
            expectedVersion: PDFFileVersion.read(from: prepared))
        let saved = try #require(PDFDocument(url: prepared))
        let savedPage = try #require(saved.page(at: 0))
        #expect(try background(savedPage) == before)
        #expect(savedPage.string?.contains("Printed aviation label 270") == true)
        #expect(savedPage.annotations.contains { $0.type == "Ink" })
        #expect(savedPage.annotations.contains { ($0.action as? PDFActionURL)?.url?.absoluteString == "https://example.com/manual" })
    }

    @Test func journalCommitRejectsNewerInkAndFreshStampDetectsReplacement() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let version = try PDFFileVersion.read(from: fixture.url)
        let pdf = try #require(PDFDocument(url: fixture.url))
        let page = try #require(pdf.page(at: 0)); try ink(page)
        let journal = PDFPageJournal()
        let first = try await journal.save(url: fixture.url, pages: [0: PDFAnnotationSnapshot.data(from: page)], sourceVersion: version, expectedRevision: nil)
        let exported = fixture.directory.appendingPathComponent("materialized.pdf")
        try await journal.materialize(url: fixture.url, to: exported, expectedVersion: version)
        try ink(page, x: 190)
        let second = try await journal.save(url: fixture.url, pages: [0: PDFAnnotationSnapshot.data(from: page)], sourceVersion: version, expectedRevision: first.revision)
        await #expect(throws: PDFSaveError.self) {
            try await journal.commitMaterialized(url: fixture.url, temporary: exported, expectedVersion: version, expectedRevision: first.revision)
        }
        #expect(try PDFFileVersion.read(from: fixture.url) == version)
        #expect(try await journal.state(for: fixture.url, sourceVersion: version)?.revision == second.revision)
        _ = try fixture.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let before = try PDFPageJournal.stamp(fixture.url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: fixture.url.path)
        #expect(try PDFPageJournal.stamp(fixture.url) != before)
        await #expect(throws: PDFSaveError.self) { try await journal.state(for: fixture.url, sourceVersion: version) }
    }

    @Test func materializedAndSearchableExportsIncludeJournalInk() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        try artwork(fixture.url)
        let pdf = try #require(PDFDocument(url: fixture.url))
        let page = try #require(pdf.page(at: 0))
        let before = try background(page)
        try ink(page)
        let version = try PDFFileVersion.read(from: fixture.url)
        _ = try await PDFPageJournal.shared.save(url: fixture.url, pages: [0: PDFAnnotationSnapshot.data(from: page)], sourceVersion: version, expectedRevision: nil)
        let visual = fixture.directory.appendingPathComponent("visual.pdf")
        try await PDFPageJournal.shared.materialize(url: fixture.url, to: visual, expectedVersion: version)
        let merged = try #require(PDFDocument(url: visual))
        #expect(try background(#require(merged.page(at: 0))) == before)
        #expect(merged.page(at: 0)?.annotations.count == 1)
        let index = OCRIndex(version: 1, fingerprint: try DocumentTextService.cacheFingerprint(url: fixture.url, pageCount: 1), pageCount: 1,
            pages: [OCRPageText(pageIndex: 0, width: 400, height: 600, text: "", boxes: [])])
        let searchable = fixture.directory.appendingPathComponent("searchable.pdf")
        try await DocumentTextService().writeSearchablePDF(url: fixture.url, to: searchable, index: index, visualURL: visual)
        let flattened = try #require(PDFDocument(url: searchable))
        #expect(try background(#require(flattened.page(at: 0))) != before)
        #expect(flattened.page(at: 0)?.string?.contains("Printed aviation label") == true)
        #expect(PDFDocument(url: fixture.url)?.page(at: 0)?.annotations.isEmpty == true)
    }

    @Test func sparseEraserCrossingAndNearMiss() throws {
        let annotation = try PDFInkAnnotation.make(points: [CGPoint(x: 50, y: 100), CGPoint(x: 250, y: 100)], width: 3, color: .blue,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(InkGeometry.intersects(annotation, stroke: [CGPoint(x: 150, y: 20), CGPoint(x: 150, y: 180)], radius: 3))
        #expect(!InkGeometry.intersects(annotation, stroke: [CGPoint(x: 270, y: 20), CGPoint(x: 270, y: 180)], radius: 3))
        #expect(!InkGeometry.intersects(annotation, stroke: [], radius: 3))
    }

    @Test(arguments: [0.3, 1.0]) func lassoMoveResizeRecolorDeleteAndUndo(alpha: Double) async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let reader = ReaderModel(url: fixture.url, page: 0); await reader.load()
        let page = try #require(reader.document?.page(at: 0))
        reader.view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        reader.ink.active = true
        try reader.ink.addStroke(points: [CGPoint(x: 70, y: 90), CGPoint(x: 110, y: 120)], page: page)
        try reader.ink.addStroke(points: [CGPoint(x: 280, y: 400), CGPoint(x: 320, y: 430)], page: page)
        reader.ink.tool = .lasso
        let polygon = [CGPoint(x: 40, y: 60), CGPoint(x: 150, y: 60), CGPoint(x: 150, y: 150), CGPoint(x: 40, y: 150), CGPoint(x: 40, y: 60)]
        try reader.ink.addViewStroke(points: polygon.map { reader.view.convert($0, from: page) }, page: page)
        #expect(reader.ink.selectedAnnotations.count == 1)
        let selected = try #require(reader.ink.selectedAnnotations.first)
        selected.color = selected.color.withAlphaComponent(CGFloat(alpha))
        let original = try #require(reader.ink.selectionBounds)
        try reader.ink.transformSelection(scale: 1.5, delta: CGPoint(x: 30, y: 50))
        let moved = try #require(reader.ink.selectionBounds)
        #expect(abs(moved.width - original.width * 1.5) < 0.01)
        #expect(abs(moved.midX - original.midX - 30) < 0.01)
        reader.ink.color = .red; reader.ink.recolorSelection()
        #expect(reader.ink.selectedAnnotations.first?.color == InkPlatformColor(Color.red).withAlphaComponent(CGFloat(alpha)))
        #expect(abs((reader.ink.selectedAnnotations.first?.color.cgColor.alpha ?? -1) - CGFloat(alpha)) < 0.001)
        reader.ink.deleteSelection(); #expect(page.annotations.count == 1)
        reader.ink.undo(); #expect(page.annotations.count == 2)
        reader.ink.redo(); #expect(page.annotations.count == 1)
        try await reader.ink.flushAndWait()
        #expect(PDFDocument(url: fixture.url)?.page(at: 0)?.annotations.count == 1)
    }

    @Test func pressureHighlighterAndExplicitShapesStayEditable() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let reader = ReaderModel(url: fixture.url, page: 0); await reader.load()
        let page = try #require(reader.document?.page(at: 0))
        reader.view.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        reader.ink.active = true
        let points = (0..<16).map { CGPoint(x: 40 + $0 * 8, y: 100 + $0) }
        let screen = points.map { reader.view.convert($0, from: page) }
        try reader.ink.addViewStroke(points: screen, page: page, pressures: (0..<16).map { CGFloat($0 + 1) / 16 })
        #expect(Set(page.annotations.compactMap { $0.border?.lineWidth }).count > 1)
        reader.ink.tool = .highlighter
        try reader.ink.addViewStroke(points: screen, page: page)
        #expect(abs((page.annotations.last?.color.cgColor.alpha ?? 1) - 0.3) < 0.01)
        reader.ink.tool = .shape; reader.ink.shape = .rectangle
        try reader.ink.addViewStroke(points: screen, page: page)
        let rectangle = try #require(page.annotations.last)
        #expect(InkGeometry.points(in: rectangle).first?.count == 5)
        #expect(InkGeometry.recognizedShape([.zero, CGPoint(x: 20, y: 1), CGPoint(x: 40, y: 0), CGPoint(x: 60, y: 1)])?.count == 2)
        #expect(InkShape.ellipse.points(from: points).count == 65)
        try await reader.ink.flushAndWait()
    }

    @Test func consolidationFlushesInkLocksEditingAndPreservesPage() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let pdf = try #require(PDFDocument(url: fixture.url))
        let blank = PDFPage(); blank.setBounds(CGRect(x: 0, y: 0, width: 400, height: 600), for: .mediaBox)
        pdf.insert(blank, at: 1)
        let url = fixture.directory.appendingPathComponent("two.pdf"); #expect(pdf.write(to: url))
        let version = try PDFFileVersion.read(from: url)
        _ = try await PDFPageJournal.shared.save(url: url, pages: [:], sourceVersion: version, expectedRevision: nil)
        let reader = ReaderModel(url: url, page: 0); await reader.load(); reader.go(1)
        let page = try #require(reader.document?.page(at: 1))
        try reader.ink.addStroke(points: [CGPoint(x: 30, y: 40), CGPoint(x: 130, y: 60)], page: page)
        reader.editingLocked = true; reader.ink.active = true; #expect(!reader.ink.active)
        reader.editingLocked = false
        try await reader.consolidateJournal()
        #expect(reader.page == 1)
        #expect(reader.ink.pendingPages.isEmpty)
        #expect(PDFDocument(url: url)?.page(at: 1)?.annotations.count == 1)
        #expect(!FileManager.default.fileExists(atPath: PDFPageJournal.directory(for: url).path))
    }

    @Test func folderBackupRoundtripPreservesWorkspaceInkAndDatabase() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.directory.appendingPathComponent("Library")); await store.loadIfNeeded()
        let id = try await store.importPDFAsync(fixture.url)
        store.update(id, notes: "Latest notes")
        let item = try #require(store.documents.first)
        let url = store.url(for: item)
        let workspace = WorkspaceStore(documentID: id, directory: store.directory); await workspace.load()
        try await workspace.bookmark(pageIndex: 0, title: "Checklist")
        try await workspace.addCard(question: "Q", answer: "A", pageIndex: 0)
        let fingerprint = try DocumentTextService.cacheFingerprint(url: url, pageCount: 1)
        let database = try PageTextDatabase(url: DocumentTextService.databaseURL(for: url))
        try database.prepareNative(fingerprint: fingerprint, pageCount: 1)
        try database.storeNativePages([(0, "cached sentinel")], fingerprint: fingerprint)
        let pdf = try #require(PDFDocument(url: url)); let page = try #require(pdf.page(at: 0)); try ink(page)
        _ = try await PDFPageJournal.shared.save(url: url, pages: [0: PDFAnnotationSnapshot.data(from: page)], sourceVersion: PDFFileVersion.read(from: url), expectedRevision: nil)
        let folder = try await FolderBackupService().export(documents: store.documents, directory: store.directory, parent: fixture.directory)
        #expect(try await store.restoreFolderBackup(folder) == 1)
        let restored = try #require(store.documents.first { $0.id != id })
        #expect(restored.notes == "Latest notes")
        let restoredWorkspace = WorkspaceStore(documentID: restored.id, directory: store.directory); await restoredWorkspace.load()
        #expect(restoredWorkspace.bookmarks.first?.title == "Checklist")
        #expect(restoredWorkspace.cards.first?.answer == "A")
        let restoredURL = store.url(for: restored)
        let state = try #require(try await PDFPageJournal.shared.state(for: restoredURL, sourceVersion: PDFFileVersion.read(from: restoredURL)))
        #expect(state.pages.count == 1)
        let restoredDatabase = try PageTextDatabase(url: DocumentTextService.databaseURL(for: restoredURL))
        #expect(try restoredDatabase.nativeText(pageIndex: 0) == "cached sentinel")
        try Data("tampered".utf8).write(to: folder.appendingPathComponent("data/\(id).pdf"))
        await #expect(throws: (any Error).self) { try await store.restoreFolderBackup(folder) }
        #expect(store.documents.count == 2)
    }

    @Test func removalSnapshotsLiveDatabaseWithoutMovingItsConnection() async throws {
        let fixture = try PDFFixture(); defer { fixture.remove() }
        let store = LibraryStore(directory: fixture.directory.appendingPathComponent("Library")); await store.loadIfNeeded()
        let id = try await store.importPDFAsync(fixture.url)
        let item = try #require(store.documents.first)
        let databaseURL = DocumentTextService.databaseURL(for: store.url(for: item))
        let database = try PageTextDatabase(url: databaseURL)
        try database.prepareNative(fingerprint: "test", pageCount: 1)
        try database.storeNativePages([(0, "before removal")])
        try store.remove(id)
        try database.storeNativePages([(0, "active reader writes later")])
        let archived = try PageTextDatabase(url: store.directory.appendingPathComponent("Removed/\(id).pageindex.sqlite"))
        #expect(try archived.nativeText(pageIndex: 0) == "before removal")
        #expect(try database.nativeText(pageIndex: 0) == "active reader writes later")
    }
}
