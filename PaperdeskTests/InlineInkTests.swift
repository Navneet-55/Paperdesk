import PDFKit
import Testing
@testable import Paperdesk

@MainActor struct InlineInkTests {
    @Test func writingUsesTheReaderAndSurvivesZoomAndReopen() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let reader = ReaderModel(url: fixture.url, page: 0)
        await reader.load()
        let page = try #require(reader.document?.page(at: 0))
        let originalView = reader.view
        reader.view.frame = CGRect(x: 0, y: 0, width: 700, height: 800)
        reader.ink.active = true
        #expect(reader.view === originalView)
        #expect(reader.view.isInMarkupMode)
        #expect(reader.view.pageOverlayViewProvider === reader.ink)
        for scale in [CGFloat(1), 2.5, 0.75] {
            reader.view.autoScales = false
            reader.view.scaleFactor = scale
            let points = [CGPoint(x: 70, y: 120), CGPoint(x: 160, y: 180)]
            let screen = points.map { reader.view.convert($0, from: page) }
            try reader.ink.addViewStroke(points: screen, page: page)
            let annotation = try #require(page.annotations.last)
            #expect(abs(annotation.bounds.midX - 115) < 1)
            #expect(abs(annotation.bounds.midY - 150) < 1)
        }
        await reader.ink.savePending()
        #expect(reader.ink.pendingPages.isEmpty)
        let reopened = try #require(PDFDocument(url: fixture.url)?.page(at: 0))
        #expect(reopened.annotations.filter { $0.type == "Ink" }.count == 3)
        reader.ink.active = false
        #expect(!reader.view.isInMarkupMode)
    }

    @Test func undoAndRedoPersistWithoutReplacingTheReader() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let reader = ReaderModel(url: fixture.url, page: 0)
        await reader.load()
        let page = try #require(reader.document?.page(at: 0))
        try reader.ink.addStroke(points: [CGPoint(x: 40, y: 80)], page: page)
        await reader.ink.savePending()
        reader.ink.undo()
        await reader.ink.savePending()
        #expect(PDFDocument(url: fixture.url)?.page(at: 0)?.annotations.isEmpty == true)
        reader.ink.redo()
        await reader.ink.savePending()
        #expect(PDFDocument(url: fixture.url)?.page(at: 0)?.annotations.count == 1)
    }

    @Test func staleSaveRetainsVisibleInkAndPendingRetry() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let current = ReaderModel(url: fixture.url, page: 0)
        let stale = ReaderModel(url: fixture.url, page: 0)
        await current.load()
        await stale.load()
        let page = try #require(current.document?.page(at: 0))
        try current.ink.addStroke(points: [CGPoint(x: 40, y: 80)], page: page)
        await current.ink.savePending()
        let stalePage = try #require(stale.document?.page(at: 0))
        try stale.ink.addStroke(points: [CGPoint(x: 140, y: 280)], page: stalePage)
        await stale.ink.savePending()
        #expect(!stale.ink.pendingPages.isEmpty)
        #expect(stalePage.annotations.count == 1)
        #expect(stale.error != nil)
        let saved = try #require(PDFDocument(url: fixture.url)?.page(at: 0)?.annotations.first)
        #expect(saved.bounds.midX < 50)
    }
}
