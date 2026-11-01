import Foundation
import Testing

@testable import Paperdesk

struct LibraryOverviewTests {
    @Test func collectionNamesAreLiteral() {
        let document = LibraryDocument(
            id: UUID(), title: "Reading", filename: "a.pdf",
            importedAt: Date(), folder: "folder:all")
        #expect(LibraryFilter.collection("folder:all").includes(document))
        #expect(!LibraryFilter.collection("all").includes(document))
        #expect(!LibraryFilter.unfiled.includes(document))
        #expect(LibraryFilter.all.includes(document))
    }

    @Test func coversReuseBoundedRasterData() async throws {
        let fixture = try PDFFixture()
        defer { fixture.remove() }
        let cache = DocumentCoverCache()
        let first = try await cache.cover(for: fixture.url)
        #expect(first != nil)
        try FileManager.default.removeItem(at: fixture.url)
        let cached = try await cache.cover(for: fixture.url)
        #expect(first == cached)
        await cache.invalidate()
        #expect(try await cache.cover(for: fixture.url) == nil)
    }

    #if os(iOS)
        @Test @MainActor func drawingRevisionsSurviveCoordinatorLifetimes() {
            let firstSession = (0..<3).map { _ in DrawingRevisionSequence.next() }
            let reopenedSession = DrawingRevisionSequence.next()
            #expect(firstSession[0] < firstSession[1])
            #expect(firstSession[1] < firstSession[2])
            #expect(reopenedSession > firstSession[2])
        }
    #endif
}
