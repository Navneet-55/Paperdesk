import CoreText
import Foundation
import PDFKit
import SwiftUI
import Testing

@testable import Paperdesk

#if os(iOS)
    import PencilKit
    import UIKit
#endif

struct PDFFixture {
    let directory: URL
    let url: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("test.pdf")
        let data = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 400, height: 600)
        let consumer = CGDataConsumer(data: data)!
        let context = CGContext(consumer: consumer, mediaBox: &rect, nil)!
        context.beginPDFPage(nil)
        let string = NSAttributedString(
            string: "Approved",
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    "Helvetica" as CFString, 20, nil)
            ])
        context.textPosition = CGPoint(x: 40, y: 500)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func installOCR() throws -> OCRIndex {
        let pdf = PDFDocument(url: url)!
        let page = pdf.page(at: 0)!
        let range = (page.string! as NSString).range(of: "Approved")
        let native = DocumentTextService.uprightRect(page.selection(for: range)!.bounds(for: page), on: page)
        let boxes = [
            OCRTextBox(
                text: "Approved", x: native.minX, y: native.minY, width: native.width, height: native.height),
            OCRTextBox(text: "Approved", x: 0.1, y: 0.2, width: 0.3, height: 0.05),
        ]
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint =
            "1:\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let index = OCRIndex(
            version: 1, fingerprint: fingerprint, pageCount: 1,
            pages: [
                OCRPageText(pageIndex: 0, width: 400, height: 600, text: "Approved\nApproved", boxes: boxes)
            ])
        try JSONEncoder().encode(index).write(to: DocumentTextService.indexURL(for: url))
        return index
    }
}

struct PersistenceTests {
    @Test @MainActor func staleWindowCannotOverwriteInk() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let a = ReaderModel(url: fixture.url, page: 0)
        let b = ReaderModel(url: fixture.url, page: 0)
        await a.load()
        await b.load()
        let first = try PDFAnnotationEditorModel(page: a.document!.page(at: 0)!)
        try first.addInk(points: [CGPoint(x: 20, y: 30), CGPoint(x: 80, y: 50)], width: 3, color: .blue)
        try await first.commit(to: a.document!.page(at: 0)!) { try await a.savePDF() }
        let saved = try Data(contentsOf: fixture.url)
        #expect(PDFDocument(data: saved)!.page(at: 0)!.annotations.contains { $0.type == "Ink" })
        let second = try PDFAnnotationEditorModel(page: b.document!.page(at: 0)!)
        try second.addText("From stale window")
        do {
            try await second.commit(to: b.document!.page(at: 0)!) { try await b.savePDF() }
            Issue.record("A stale save must fail")
        } catch is PDFSaveError {}
        #expect(try Data(contentsOf: fixture.url) == saved)
        #expect(second.changed)
        #expect(second.page.annotations.contains { $0.contents == "From stale window" })
        #expect(b.document!.page(at: 0)!.annotations.isEmpty)
        // A successful writer advances its own version and can save again.
        try first.addText("Next edit")
        try await first.commit(to: a.document!.page(at: 0)!) { try await a.savePDF() }
        let reopened = PDFDocument(url: fixture.url)!
        #expect(reopened.page(at: 0)!.annotations.contains { $0.type == "Ink" })
        #expect(reopened.page(at: 0)!.annotations.contains { $0.contents == "Next edit" })
    }

    @Test func searchKeepsSeparateOCRHitAndDeduplicatesNative() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        _ = try fixture.installOCR()
        let hits = try await DocumentTextService().search(url: fixture.url, query: "approved")
        #expect(hits.count == 2)
        #expect(hits.filter(\.isOCR).count == 1)
        #expect(hits.first(where: \.isOCR)?.boxes.first?.y == 0.2)
    }

    @Test func searchableExportKeepsSeparateOccurrence() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let index = try fixture.installOCR()
        let original = try Data(contentsOf: fixture.url)
        let data = try await DocumentTextService().exportSearchablePDF(url: fixture.url, index: index)
        let exported = try #require(PDFDocument(data: data))
        let matches = exported.findString("Approved", withOptions: .caseInsensitive)
        #expect(matches.count == 2)
        #expect(matches.contains { $0.bounds(for: exported.page(at: 0)!).midY < 200 })
        #expect(try Data(contentsOf: fixture.url) == original)
    }

    @Test func cancelledSearchDoesNotReturnResults() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let task = Task {
            try await DocumentTextService().search(url: fixture.url, query: "Approved")
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
    }
}

#if os(iOS)
    @MainActor struct PencilRegressionTests {
        func stroke(y: CGFloat = 50, mask: UIBezierPath? = nil) -> PKStroke {
            let points = (0...10).map { index in
                PKStrokePoint(
                    location: CGPoint(x: CGFloat(index) * 10, y: y),
                    timeOffset: Double(index) / 10, size: CGSize(width: 2, height: 2),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(
                ink: PKInk(.pen, color: .blue),
                path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)),
                mask: mask)
        }

        @Test func pendingUndoRedoPreservesIndividualStrokes() {
            let history = PencilDrawingHistory()
            let one = PKDrawing(strokes: [stroke()])
            let two = PKDrawing(strokes: [stroke(), stroke(y: 80)])
            history.record(one)
            history.record(two)
            #expect(history.undo().strokes.count == 1)
            #expect(history.redo().strokes.count == 2)
            #expect(history.undo().strokes.count == 1)
            #expect(history.undo().strokes.isEmpty)
            #expect(history.canRedo)
            #expect(history.redo().strokes.count == 1)
            history.record(PKDrawing(strokes: [stroke(y: 100)]))
            #expect(!history.canRedo)
            history.reset()
            #expect(!history.canUndo && !history.canRedo)
        }

        @Test func maskLeavesGapAfterPDFRoundTrip() throws {
            let mask = UIBezierPath(rect: CGRect(x: -10, y: 0, width: 40, height: 100))
            mask.append(UIBezierPath(rect: CGRect(x: 70, y: 0, width: 40, height: 100)))
            let ink = stroke(mask: mask)
            let samples = PencilInkConversion.visibleSamples(ink)
            #expect(samples.count == 2)
            #expect(
                samples.allSatisfy { points in
                    points.allSatisfy { $0.location.x <= 31 } || points.allSatisfy { $0.location.x >= 69 }
                })
            let fixture = try PDFFixture()
            defer { fixture.remove() }
            let pdf = PDFDocument(url: fixture.url)!
            let editor = try PDFAnnotationEditorModel(page: pdf.page(at: 0)!)
            try editor.addPencilDrawing(
                PKDrawing(strokes: [ink]), canvasSize: CGSize(width: 400, height: 600))
            let restored = try #require(PDFDocument(data: editor.page.dataRepresentation!))
            #expect(restored.page(at: 0)!.annotations.filter { $0.type == "Ink" }.count == 2)
            try editor.undo()
            #expect(editor.page.annotations.isEmpty)
            try editor.redo()
            #expect(editor.page.annotations.count == 2)
        }

        @Test func backgroundLeaseEndsExactlyOnceOnCompletionOrExpiry() {
            var ended: [UIBackgroundTaskIdentifier] = []
            var expiration: (@MainActor @Sendable () -> Void)?
            let lifetime = DrawingSaveLifetime(
                begin: { handler in
                    expiration = handler
                    return UIBackgroundTaskIdentifier(rawValue: 42)
                }, end: { ended.append($0) })
            expiration?()
            lifetime.finish()
            #expect(ended.count == 1)
            let completed = DrawingSaveLifetime(
                begin: { handler in
                    expiration = handler
                    return UIBackgroundTaskIdentifier(rawValue: 43)
                }, end: { ended.append($0) })
            completed.finish()
            expiration?()
            #expect(ended.count == 2)
        }

        @Test func olderQueuedDrawingCannotReplaceFinalSave() async throws {
            let fixture = try PDFFixture()
            defer { fixture.remove() }
            let url = fixture.directory.appendingPathComponent("notes.drawing")
            let writer = DrawingSaveService()
            try await writer.save(
                DrawingSnapshot(drawing: PKDrawing(strokes: [stroke(), stroke(y: 80)])), url: url, revision: 2
            )
            try await writer.save(
                DrawingSnapshot(drawing: PKDrawing(strokes: [stroke()])), url: url, revision: 1)
            #expect(try PKDrawing(data: Data(contentsOf: url)).strokes.count == 2)
        }
    }
#endif
