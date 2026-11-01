import AppKit
import Foundation
import PDFKit

@main struct SmokeTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Study.pdf")
        let text = NSAttributedString(
            string: "Paperdesk flight study\nSearchable PDF test",
            attributes: [.font: NSFont.systemFont(ofSize: 24)])
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            text.draw(at: CGPoint(x: 50, y: 650))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: source)
        let directory = root.appendingPathComponent("Library")
        let store = LibraryStore(directory: directory)
        await store.loadIfNeeded()
        let id = try store.importPDF(source)
        precondition(store.documents.count == 1)
        let copy = store.url(for: store.documents[0])
        precondition(FileManager.default.fileExists(atPath: copy.path))
        store.update(id, notes: "Remember checklist", page: 1)
        let reopened = LibraryStore(directory: directory)
        await reopened.loadIfNeeded()
        precondition(reopened.documents[0].notes == "Remember checklist")
        precondition(reopened.documents[0].lastPage == 1)
        let pdf = PDFDocument(url: copy)!
        precondition(pdf.pageCount == 2)
        precondition(pdf.findString("flight", withOptions: .caseInsensitive).count == 2)
        let duplicate = try store.importPDF(source)
        precondition(duplicate != id && store.documents.count == 2)
        let invalid = root.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        var rejected = false
        do { _ = try store.importPDF(invalid) } catch { rejected = true }
        precondition(rejected && store.documents.count == 2)
        try FileManager.default.removeItem(at: source)
        precondition(PDFDocument(url: copy)?.pageCount == 2)
        let brokenDirectory = root.appendingPathComponent("Broken")
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        let brokenIndex = brokenDirectory.appendingPathComponent("library.json")
        let brokenData = Data("corrupt index".utf8)
        try brokenData.write(to: brokenIndex)
        let brokenStore = LibraryStore(directory: brokenDirectory)
        await brokenStore.loadIfNeeded()
        precondition(brokenStore.error != nil)
        do {
            _ = try brokenStore.importPDF(copy)
            preconditionFailure("Must protect unreadable index")
        } catch {}
        let protectedData = try Data(contentsOf: brokenIndex)
        precondition(protectedData == brokenData)
        store.rename(id, title: "Flight manual")
        store.move(id, folder: "Training")
        let organized = LibraryStore(directory: directory)
        await organized.loadIfNeeded()
        precondition(organized.documents.first(where: { $0.id == id })?.title == "Flight manual")
        precondition(organized.documents.first(where: { $0.id == id })?.folder == "Training")
        try store.remove(duplicate)
        precondition(store.documents.count == 1)
        let removed = directory.appendingPathComponent("Removed/\(duplicate).pdf")
        precondition(FileManager.default.fileExists(atPath: removed.path))
        let restored = LibraryStore(directory: directory)
        await restored.loadIfNeeded()
        precondition(restored.documents.count == 1)
        let backup = try LibraryBackup(store: restored)
        let transferDirectory = root.appendingPathComponent("Transfer")
        let transfer = LibraryStore(directory: transferDirectory)
        await transfer.loadIfNeeded()
        _ = try await transfer.restoreBackupData(JSONEncoder().encode(backup))
        precondition(transfer.documents.count == 1 && transfer.documents[0].folder == "Training")
        _ = try await transfer.restoreBackupData(JSONEncoder().encode(backup))
        precondition(transfer.documents.count == 1)
        precondition(PDFDocument(url: transfer.url(for: transfer.documents[0]))?.pageCount == 2)
        print("PASS: backup transfer, duplicate merge protection")
        // Old indexes without folders remain readable.
        let legacyData = try JSONEncoder().encode(restored.documents)
        let legacy = try JSONDecoder().decode([LibraryDocument].self, from: legacyData)
        precondition(legacy.count == 1)
        // An annotation survives PDF serialization and reopening.
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 40, y: 600, width: 200, height: 30), forType: .highlight, withProperties: nil)
        pdf.page(at: 0)!.addAnnotation(annotation)
        let annotated = root.appendingPathComponent("Annotated.pdf")
        precondition(pdf.write(to: annotated))
        precondition(
            PDFDocument(url: annotated)!.page(at: 0)!.annotations.contains(where: { $0.type == "Highlight" }))
        print("PASS: organization, recoverable removal, annotation serialization")
        print(
            "PASS: import, independent library copy, duplicate imports, persistence, page restoration, PDF search, invalid PDF rejection"
        )
    }
}
