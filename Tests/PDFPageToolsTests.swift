import AppKit
import CoreText
import Foundation
import PDFKit

@main struct PDFPageToolsTests {
    static func makePDF(at url: URL, labels: [String]) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        for label in labels {
            context.beginPDFPage(nil)
            let text = NSAttributedString(string: label, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 22, nil)])
            context.textPosition = CGPoint(x: 50, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
    }
    static func text(_ document: PDFDocument, _ index: Int) -> String { document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    static func assertFile(_ url: URL, equals data: Data) throws { let current = try Data(contentsOf: url); precondition(current == data) }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaperdeskPageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Original.pdf")
        try makePDF(at: url, labels: ["Alpha", "Bravo", "Charlie"])
        let initial = try Data(contentsOf: url)
        let expected = PDFFileVersion(data: initial)
        let session = try await PDFWriteService.shared.openPageTools(url: url, expectedVersion: expected)
        precondition(session.rows.count == 3 && session.restriction == nil)
        let operations: [PDFPageOperation] = [.rotate(indices: [1], clockwiseDegrees: 90), .move(from: 2, to: 0), .duplicate(index: 1), .insertBlank(at: 2), .delete(indices: [0])]
        let result = try await PDFWriteService.shared.applyPageOperations(url: url, expectedVersion: expected, operations: operations)
        let saved = PDFDocument(url: url)!
        precondition(result.pageCount == 4 && saved.pageCount == 4)
        precondition(text(saved, 0) == "Alpha" && text(saved, 1).isEmpty && text(saved, 2) == "Alpha" && text(saved, 3) == "Bravo")
        precondition(saved.page(at: 3)!.rotation == 90)
        precondition(result.originalToNew == [0: 0, 1: 3])
        let finalData = try Data(contentsOf: url)
        do {
            _ = try await PDFWriteService.shared.applyPageOperations(url: url, expectedVersion: expected, operations: [.insertBlank(at: 0)])
            preconditionFailure("A stale writer must fail")
        } catch PDFSaveError.conflict {}
        try assertFile(url, equals: finalData)
        do {
            _ = try await PDFWriteService.shared.applyPageOperations(url: url, expectedVersion: result.version, operations: [.delete(indices: [0, 1, 2, 3])])
            preconditionFailure("Cannot remove every page")
        } catch PDFPageToolsError.emptyDocument {}
        do {
            _ = try await PDFWriteService.shared.applyPageOperations(url: url, expectedVersion: result.version, operations: [.rotate(indices: [99], clockwiseDegrees: 90)])
            preconditionFailure("Invalid pages must fail")
        } catch PDFPageToolsError.invalidPage {}
        try assertFile(url, equals: finalData)
        let exported = try await PDFWriteService.shared.exportPageSelection(url: url, expectedVersion: result.version, indices: [3, 0])
        let split = PDFDocument(url: exported.url)!
        precondition(split.pageCount == 2 && text(split, 0) == "Alpha" && text(split, 1) == "Bravo")
        try assertFile(url, equals: finalData)
        let other = root.appendingPathComponent("Other.pdf")
        try makePDF(at: other, labels: ["Delta", "Echo"])
        let imports = try await PDFWriteService.shared.stagePageMerge(urls: [other])
        try FileManager.default.removeItem(at: other)
        let merged = try await PDFWriteService.shared.applyPageOperations(url: url, expectedVersion: result.version, operations: [.merge(imports[0])])
        let merge = PDFDocument(url: url)!
        precondition(merged.pageCount == 6 && text(merge, 4) == "Delta" && text(merge, 5) == "Echo")
        let withLinksURL = root.appendingPathComponent("Links.pdf")
        try makePDF(at: withLinksURL, labels: ["First", "Second", "Third"])
        let withLinks = PDFDocument(url: withLinksURL)!
        let first = withLinks.page(at: 0)!, second = withLinks.page(at: 1)!, third = withLinks.page(at: 2)!
        let link = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 100, height: 30), forType: .link, withProperties: nil)
        link.destination = PDFDestination(page: third, at: CGPoint(x: 0, y: 700)); first.addAnnotation(link)
        let outlineRoot = PDFOutline(), bookmark = PDFOutline(); bookmark.label = "Second"; bookmark.destination = PDFDestination(page: second, at: .zero); outlineRoot.insertChild(bookmark, at: 0); withLinks.outlineRoot = outlineRoot
        withLinks.removePage(at: 0); withLinks.insert(first, at: 0)
        precondition(withLinks.write(to: withLinksURL))
        let linksVersion = try PDFFileVersion.read(from: withLinksURL)
        let reordered = try await PDFWriteService.shared.applyPageOperations(url: withLinksURL, expectedVersion: linksVersion, operations: [.move(from: 2, to: 0)])
        let reorderedDoc = PDFDocument(url: withLinksURL)!
        let reorderedFirst = reorderedDoc.page(at: 1)!
        let linkTarget = reorderedFirst.annotations.first { $0.type == "Link" }!.destination!.page!
        precondition(reorderedDoc.index(for: linkTarget) == 0)
        precondition(reorderedDoc.index(for: reorderedDoc.outlineRoot!.child(at: 0)!.destination!.page!) == 2)
        let extracted = try await PDFWriteService.shared.exportPageSelection(url: withLinksURL, expectedVersion: reordered.version, indices: [0, 1])
        let extractedDoc = PDFDocument(url: extracted.url)!, extractedFirst = extractedDoc.page(at: 1)!
        precondition(extractedDoc.index(for: extractedFirst.annotations.first { $0.type == "Link" }!.destination!.page!) == 0)
        let signedURL = root.appendingPathComponent("Signature.pdf")
        try makePDF(at: signedURL, labels: ["Signature source"])
        var signedBytes = try Data(contentsOf: signedURL); signedBytes.append(Data("\n% /ByteRange signature marker\n".utf8)); try signedBytes.write(to: signedURL)
        let signedVersion = PDFFileVersion(data: signedBytes)
        do {
            _ = try await PDFWriteService.shared.applyPageOperations(url: signedURL, expectedVersion: signedVersion, operations: [.insertBlank(at: 0)])
            preconditionFailure("Signature-bearing PDFs must remain unchanged")
        } catch PDFPageToolsError.signature {}
        try assertFile(signedURL, equals: signedBytes)
        if ProcessInfo.processInfo.environment["PAPERDESK_LARGE_PDF_TEST"] == "1" {
            let largeURL = root.appendingPathComponent("Ten Thousand.pdf")
            try makePDF(at: largeURL, labels: (0..<10_000).map { "Page \($0 + 1)" })
            let started = Date()
            let largeVersion = try PDFFileVersion.read(from: largeURL)
            let large = try await PDFWriteService.shared.openPageTools(url: largeURL, expectedVersion: largeVersion)
            precondition(large.rows.count == 10_000)
            let reorderedLarge = try await PDFWriteService.shared.applyPageOperations(url: largeURL, expectedVersion: largeVersion, operations: [.move(from: 9_999, to: 0)])
            precondition(reorderedLarge.pageCount == 10_000 && PDFDocument(url: largeURL)!.page(at: 0)!.string!.contains("Page 10000"))
            print("PASS 10k page metadata + structural move in \(String(format: "%.2f", Date().timeIntervalSince(started)))s (no eager thumbnails)")
        }
        print("PASS: PDF rotation, reorder, duplicate, blank, deletion, merge from staged copy, split, conflict/invalid failure preservation, bookmarks/internal links, signature protection")
    }
}
