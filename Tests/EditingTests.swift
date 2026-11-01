import AppKit
import Foundation
import PDFKit
import SwiftUI

@main struct EditingTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Manual.pdf")
        let pdf = PDFDocument()
        for _ in 0..<2 {
            let image = NSImage(size: CGSize(width: 612, height: 792))
            image.lockFocus()
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: 612, height: 792).fill()
            image.unlockFocus()
            pdf.insert(PDFPage(image: image)!, at: pdf.pageCount)
        }
        let source = pdf.page(at: 0)!
        let link = PDFAnnotation(
            bounds: CGRect(x: 40, y: 40, width: 100, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: pdf.page(at: 1)!, at: CGPoint(x: 0, y: 700))
        source.addAnnotation(link)
        precondition(pdf.write(to: url))
        for rotation in [0, 90, 180, 270] {
            source.rotation = rotation
            source.setBounds(CGRect(x: 12, y: 18, width: 580, height: 740), for: .cropBox)
            let geometry = PDFPageGeometry(page: source)
            let original = CGPoint(x: 150, y: 230)
            let screen = geometry.canvasPoint(fromPDF: original, canvasSize: CGSize(width: 450, height: 600))
            let restored = geometry.pdfPoint(fromCanvas: screen, canvasSize: CGSize(width: 450, height: 600))
            precondition(abs(restored.x - original.x) < 0.001 && abs(restored.y - original.y) < 0.001)
        }
        source.rotation = 0
        let model = try PDFAnnotationEditorModel(page: source)
        try model.addInk(points: [CGPoint(x: 80, y: 90), CGPoint(x: 150, y: 180)], width: 3, color: .blue)
        precondition(model.editableAnnotations.count == 1 && source.annotations.count == 1)
        try model.undo()
        precondition(model.editableAnnotations.isEmpty)
        try model.redo()
        precondition(model.editableAnnotations.count == 1)
        let index = model.editableAnnotations[0].index
        let before = model.page.annotations[index].bounds
        try model.move(index: index, displayDX: 20, displayDY: 10)
        precondition(model.page.annotations[index].bounds != before)
        try model.resize(index: index, scale: 1.25)
        try model.recolor(index: index, color: .red)
        try await model.commit(to: source) {
            let data = source.dataRepresentation!
            _ = try await PDFWriteService.shared.savePages(
                url: url, pages: [0: data], expectedVersion: PDFFileVersion(data: try Data(contentsOf: url)))
        }
        let saved = PDFDocument(url: url)!
        let savedPage = saved.page(at: 0)!
        precondition(savedPage.annotations.contains { $0.type == "Ink" })
        let savedLink = savedPage.annotations.first { $0.type == "Link" }!
        precondition(savedLink.destination?.page != nil)
        precondition(saved.index(for: savedLink.destination!.page!) == 1)
        let deleting = try PDFAnnotationEditorModel(page: source)
        try deleting.remove(index: deleting.editableAnnotations[0].index)
        try await deleting.commit(to: source) {
            _ = try await PDFWriteService.shared.savePages(
                url: url, pages: [0: source.dataRepresentation!],
                expectedVersion: PDFFileVersion(data: try Data(contentsOf: url)))
        }
        precondition(!PDFDocument(url: url)!.page(at: 0)!.annotations.contains { $0.type == "Ink" })
        let failing = try PDFAnnotationEditorModel(page: source)
        try failing.addText("Never commit")
        var rejected = false
        do { try await failing.commit(to: source) { throw CocoaError(.fileWriteNoPermission) } } catch {
            rejected = true
        }
        precondition(rejected && !source.annotations.contains { $0.type == "FreeText" })
        let store = LibraryStore(directory: root.appendingPathComponent("Library"))
        await store.loadIfNeeded()
        let id = try store.importPDF(url)
        for i in 0..<1000 { store.update(id, notes: "Latest note \(i)", deferred: true) }
        store.rename(id, title: "Renamed")
        store.flushPendingChanges()
        let reopened = LibraryStore(directory: store.directory)
        await reopened.loadIfNeeded()
        precondition(
            reopened.documents[0].notes == "Latest note 999" && reopened.documents[0].title == "Renamed")
        print(
            "PASS: rotated/cropped geometry, ink edit/save/delete, undo/redo, failure rollback, internal PDF links, 1000 deferred saves"
        )
    }
}
