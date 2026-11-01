import Foundation
import CoreGraphics
import Testing
@testable import Paperdesk

struct WorkspaceFeatureTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func recallGradesHaveDistinctPredictableSchedules() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let card = WorkspaceReviewCard(id: UUID(), question: "Prompt", answer: "Source answer", pageIndex: 9999, region: nil, createdAt: now, dueAt: now)
        let again = card.scheduled(.again, at: now)
        let hard = card.scheduled(.hard, at: now)
        let good = card.scheduled(.good, at: now)
        let easy = card.scheduled(.easy, at: now)
        #expect(again.dueAt.timeIntervalSince(now) == 600)
        #expect(hard.intervalDays == 0.5)
        #expect(good.intervalDays == 1)
        #expect(easy.intervalDays == 4)
        #expect(again.dueAt < hard.dueAt && hard.dueAt < good.dueAt && good.dueAt < easy.dueAt)
        #expect(again.lapses == 1 && again.repetitions == 0)
        #expect(good.repetitions == 1)
        let secondGood = good.scheduled(.good, at: good.dueAt)
        #expect(secondGood.intervalDays == 2.5)
        #expect(secondGood.repetitions == 2)
        var difficult = card
        for _ in 0..<30 { difficult = difficult.scheduled(.again, at: now) }
        #expect(difficult.ease == 1.3)
        #expect(difficult.lapses == 30)
        #expect(difficult.intervalDays == 0)
    }

    @Test @MainActor func workspacePersistsIndependentDocumentsAndTargetedRegions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = UUID(), secondID = UUID()
        let first = WorkspaceStore(documentID: firstID, directory: directory)
        let second = WorkspaceStore(documentID: secondID, directory: directory)
        await first.load(); await second.load()
        try await first.bookmark(pageIndex: 9999, title: "Important checklist")
        try await first.bookmark(pageIndex: 9999, title: "Updated label")
        let region = CGRect(x: 24, y: 450, width: 170, height: 35)
        try await first.addMarginNote(pageIndex: 9998, bounds: region, quote: "Quoted source", body: "Read this again")
        try await first.addCard(question: "What is recalled?", answer: "The cited source", pageIndex: 9997, bounds: region)
        let card = try #require(first.cards.first)
        let reviewTime = Date(timeIntervalSince1970: 1_800_000_000)
        try await first.review(cardID: card.id, grade: .good, at: reviewTime)
        try await first.editCard(card.id, question: "Edited prompt", answer: "Edited answer")
        try await second.bookmark(pageIndex: 2, title: "Another document")

        let reopened = WorkspaceStore(documentID: firstID, directory: directory)
        await reopened.load()
        #expect(reopened.isLoaded)
        #expect(reopened.bookmarks.count == 1)
        #expect(reopened.bookmarks.first?.pageIndex == 9999)
        #expect(reopened.bookmarks.first?.title == "Updated label")
        #expect(reopened.marginNotes.first?.region?.bounds == region)
        #expect(reopened.marginNotes.first?.quote == "Quoted source")
        #expect(reopened.cards.first?.question == "Edited prompt")
        #expect(reopened.cards.first?.dueAt == reviewTime.addingTimeInterval(86_400))
        #expect(reopened.dueCards(at: reviewTime).isEmpty)
        #expect(reopened.dueCards(at: reviewTime.addingTimeInterval(86_400)).count == 1)
        #expect(second.bookmarks.first?.pageIndex == 2)
        #expect(second.marginNotes.isEmpty && second.cards.isEmpty)
        // Ten-thousand-page documents add no per-page arrays or PDF reads.
        #expect(try Data(contentsOf: reopened.url).count < 10_000)
    }

    @Test @MainActor func readerWindowsMergeIndependentChanges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let first = WorkspaceStore(documentID: id, directory: directory)
        let second = WorkspaceStore(documentID: id, directory: directory)
        await first.load(); await second.load()
        try await first.bookmark(pageIndex: 4)
        try await second.addMarginNote(pageIndex: 5, body: "Written in the second window")
        try await first.addCard(question: "Prompt", answer: "Answer", pageIndex: 4)
        await second.load()
        #expect(second.bookmarks.count == 1)
        #expect(second.marginNotes.count == 1)
        #expect(second.cards.count == 1)
        #expect(second.workspace.revision == 3)
    }

    @Test @MainActor func corruptWorkspaceIsPreservedAndNeverOverwritten() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(documentID: UUID(), directory: directory)
        let corrupt = Data("Keep this recovery evidence".utf8)
        try corrupt.write(to: store.url)
        await store.load()
        #expect(!store.isLoaded && store.error != nil)
        var rejected = false
        do { try await store.bookmark(pageIndex: 3) }
        catch { rejected = true }
        #expect(rejected)
        #expect(try Data(contentsOf: store.url) == corrupt)
    }

    @Test @MainActor func failedSaveLeavesCurrentRecordsAndDraftSourceUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(documentID: UUID(), directory: directory)
        await store.load()
        try await store.bookmark(pageIndex: 10, title: "Previously saved")
        let original = try Data(contentsOf: store.url)
        // Make the target unreadable as a document, without injecting persistence hooks.
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        try original.write(to: store.url.appendingPathComponent("original-recovery.json"))
        var rejected = false
        do { try await store.addMarginNote(pageIndex: 10, body: "Unsaved editor draft") }
        catch { rejected = true }
        #expect(rejected)
        #expect(store.bookmarks.count == 1)
        #expect(store.marginNotes.isEmpty)
        #expect(store.saveStatus == "Not saved")
        #expect(store.error != nil)
        #expect(try Data(contentsOf: store.url.appendingPathComponent("original-recovery.json")) == original)
    }

    @Test @MainActor func extractiveCardsRemainEditableAndDeletionsPersist() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let store = WorkspaceStore(documentID: id, directory: directory)
        await store.load()
        let count = try await store.addCards(from: "The first quoted paragraph stays verbatim.\nThe second paragraph is also source text.", pageIndex: 3)
        #expect(count == 2)
        #expect(Set(store.cards.map(\.answer)) == ["The first quoted paragraph stays verbatim.", "The second paragraph is also source text."])
        let first = try #require(store.cards.first)
        try await store.removeCard(first.id)
        let reopened = WorkspaceStore(documentID: id, directory: directory)
        await reopened.load()
        #expect(reopened.cards.count == 1)
        #expect(!reopened.cards.contains { $0.id == first.id })
    }
    @Test @MainActor func structuralEditsKeepSourceLinksAndPreserveRemovedPageNotes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let store = WorkspaceStore(documentID: id, directory: directory)
        await store.load()
        try await store.bookmark(pageIndex: 0, title: "Survives")
        try await store.bookmark(pageIndex: 1, title: "Removed with page")
        try await store.addMarginNote(pageIndex: 0, body: "Moved page note")
        try await store.addMarginNote(pageIndex: 1, body: "Keep this removed page note")
        try await store.addCards([
            WorkspaceCardInput(question: "Moved prompt", answer: "Moved answer", pageIndex: 0),
            WorkspaceCardInput(question: "Removed prompt", answer: "Keep this answer", pageIndex: 1)
        ])
        try await store.remapPages(originalToNew: [0: 7, 2: 0])
        #expect(store.bookmarks.count == 1 && store.bookmarks.first?.pageIndex == 7)
        #expect(store.marginNotes.first(where: { $0.body == "Moved page note" })?.pageIndex == 7)
        #expect(store.marginNotes.first(where: { $0.body == "Keep this removed page note" })?.sourceRemoved == true)
        #expect(store.cards.first(where: { $0.question == "Moved prompt" })?.pageIndex == 7)
        let orphan = try #require(store.cards.first(where: { $0.question == "Removed prompt" }))
        #expect(orphan.pageIndex == nil && orphan.answer == "Keep this answer")
        let reopened = WorkspaceStore(documentID: id, directory: directory)
        await reopened.load()
        #expect(reopened.marginNotes.count == 2)
        #expect(reopened.marginNotes.filter(\.sourceRemoved).count == 1)
    }

    @Test @MainActor func bulkCardImportIsOneAtomicWorkspaceRevision() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let store = WorkspaceStore(documentID: id, directory: directory)
        await store.load()
        let inputs = (0..<4_000).map { index in WorkspaceCardInput(question: "Prompt \(index)", answer: "Quoted answer \(index)", pageIndex: index % 10_000) }
        #expect(try await store.addCards(inputs) == 4_000)
        #expect(store.workspace.revision == 1)
        #expect(store.cards.count == 4_000)
        let reopened = WorkspaceStore(documentID: id, directory: directory)
        await reopened.load()
        #expect(reopened.cards.count == 4_000)
        #expect(try Data(contentsOf: store.url).count < 2_000_000)
    }

}
