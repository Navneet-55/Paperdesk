import CoreGraphics
import CoreText
import Foundation
import PDFKit

@main struct TextServiceTests {
    static func makeScan(_ url: URL) throws {
        let size = CGSize(width: 800, height: 600)
        let pixels = CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        pixels.setFillColor(CGColor(gray: 1, alpha: 1))
        pixels.fill(CGRect(origin: .zero, size: size))
        pixels.setFillColor(CGColor(gray: 0, alpha: 1))
        let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
        let string = NSAttributedString(
            string: "Paperdesk CHECKLIST 731", attributes: [.init(kCTFontAttributeName as String): font])
        pixels.textPosition = CGPoint(x: 60, y: 400)
        CTLineDraw(CTLineCreateWithAttributedString(string), pixels)
        let image = pixels.makeImage()!
        let data = NSMutableData()
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: nil, nil)!
        for _ in 0..<2 {
            var rect = CGRect(origin: .zero, size: size)
            let boxData = withUnsafeBytes(of: &rect) { Data($0) as CFData }
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.draw(image, in: rect)
            context.endPDFPage()
        }
        context.closePDF()
        let pdf = PDFDocument(data: data as Data)!
        pdf.page(at: 1)!.rotation = 90
        try pdf.dataRepresentation()!.write(to: url)
    }
    static func inkBounds(_ page: PDFPage, width: Int, height: Int) -> CGRect {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .mediaBox, to: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * width * 4 + x * 4
                if bytes[offset] < 120 && bytes[offset + 1] < 120 && bytes[offset + 2] < 120 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    static func main() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("scan.pdf")
        try makeScan(source)
        let service = DocumentTextService()
        let before = try await service.search(url: source, query: "CHECKLIST")
        precondition(before.isEmpty)
        let first = try await service.recognize(url: source, pages: [0])
        precondition(first.pages.count == 1 && !first.isComplete)
        let ocrHits = try await service.search(url: source, query: "checklist")
        precondition(ocrHits.count == 1 && ocrHits[0].isOCR && !ocrHits[0].boxes.isEmpty)
        let output = try await service.exportSearchablePDF(url: source)
        let exported = PDFDocument(data: output)!
        precondition(exported.pageCount == 2)
        let searchable = exported.findString("CHECKLIST", withOptions: .caseInsensitive)
        print("Text matches after export: \(searchable.count)")
        precondition(searchable.count == 2)
        let original = PDFDocument(url: source)!
        let one = inkBounds(original.page(at: 0)!, width: 800, height: 600)
        let two = inkBounds(exported.page(at: 0)!, width: 800, height: 600)
        print("Original/rendered bounds unrotated: \(one) / \(two)")
        precondition(one == two)
        let three = inkBounds(original.page(at: 1)!, width: 600, height: 800)
        let four = inkBounds(exported.page(at: 1)!, width: 600, height: 800)
        print("Original/rendered bounds rotated: \(three) / \(four)")
        precondition(three == four)
        let complete = try await service.cachedIndex(url: source)!
        precondition(complete.isComplete)
        let allHits = try await service.search(url: source, query: "CHECKLIST")
        precondition(allHits.count == 2)
        let cancelTask = Task { try await service.recognize(url: source, force: true) }
        cancelTask.cancel()
        do {
            _ = try await cancelTask.value
            preconditionFailure("Expected cancellation")
        } catch is CancellationError {} catch { throw error }
        let largeURL = dir.appendingPathComponent("large.pdf")
        let large = PDFDocument()
        var owners: [PDFPage] = []
        for index in 0..<120 {
            let page = exported.page(at: 0)!.copy() as! PDFPage
            owners.append(page)
            large.insert(page, at: index)
        }
        precondition(large.write(to: largeURL))
        let start = Date()
        let largeHits = try await service.search(url: largeURL, query: "CHECKLIST")
        precondition(largeHits.count == 120)
        let capped = try await service.search(url: largeURL, query: "CHECKLIST", maxResults: 10)
        precondition(capped.count == 10)
        withExtendedLifetime(owners) {}
        print("PASS: 120-page native search, bounded results (\(Date().timeIntervalSince(start)) seconds)")
        print(
            "PASS: page OCR, partial cache, async OCR search, auto-complete export, invisible searchable text, rotated visual preservation, cache reuse, cancellation"
        )
    }
}
