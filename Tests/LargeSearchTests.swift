import CoreGraphics
import CoreText
import Foundation
import PDFKit

private actor SearchProgressGate {
    private var arrived = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        arrived = true; waiting?.resume(); waiting = nil
        await withCheckedContinuation { release = $0 }
    }
    func wait() async {
        if arrived { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func resume() { release?.resume(); release = nil }
}

@main struct LargeSearchTests {
    static func createPDF(_ url: URL, count: Int, label: (Int) -> String) throws {
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw CocoaError(.fileWriteUnknown) }
        for index in 0..<count {
            autoreleasepool {
                context.beginPDFPage(nil)
                let text = NSAttributedString(string: label(index), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 18, nil)])
                context.textPosition = CGPoint(x: 50, y: 700)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
                context.endPDFPage()
            }
        }
        context.closePDF()
    }
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaperdeskLargeSearch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nativeURL = directory.appendingPathComponent("Ten thousand.pdf")
        try createPDF(nativeURL, count: 10_000) { "Café native page \($0) needle-\(String(format: "%05d", $0))" }
        let service = DocumentTextService()
        let firstStart = Date()
        let first = try await service.search(url: nativeURL, query: "needle-09999")
        let firstTime = Date().timeIntervalSince(firstStart)
        precondition(first.count == 1 && first[0].pageIndex == 9_999)
        let database = try PageTextDatabase(url: DocumentTextService.databaseURL(for: nativeURL))
        precondition(tryCount(database) == 10_000)
        let repeatStart = Date()
        let repeated = try await DocumentTextService().search(url: nativeURL, query: "needle-09999")
        let repeatTime = Date().timeIntervalSince(repeatStart)
        precondition(repeated.count == 1 && repeated[0].pageIndex == 9_999)
        let unicode = try await service.search(url: nativeURL, query: "CAFE", maxResults: 50_000)
        precondition(unicode.count == 10_000)
        // A cache-only token proves a fresh service reads disk rows, not PDFPage.string.
        try database.storeNativePages([(9_999, "Cache-only sentinel Café needle-09999")])
        let cached = try await DocumentTextService().search(url: nativeURL, query: "Cache-only sentinel")
        precondition(cached.count == 1 && cached[0].pageIndex == 9_999)
        let gate = SearchProgressGate()
        let cancellation = Task {
            try await service.search(url: nativeURL, query: "nothing matches") { _ in await gate.pause() }
        }
        await gate.wait()
        // SQLite writes can finish while the search awaits UI progress: no held read lock.
        try database.storeNativePages([(9_999, "Café native page 9999 needle-09999")])
        cancellation.cancel(); await gate.resume()
        do { _ = try await cancellation.value; preconditionFailure("Search cancellation must propagate") } catch is CancellationError {}
        print("PASS: 10k native pages first search \(String(format: "%.3f", firstTime))s, new-service cached search \(String(format: "%.3f", repeatTime))s, durable cache, Unicode cap, cancellation/no lock across progress")

        let mixedURL = directory.appendingPathComponent("One thousand mixed.pdf")
        try createPDF(mixedURL, count: 1_000) { "Native page \($0) Café" }
        let fingerprint = try DocumentTextService.cacheFingerprint(url: mixedURL, pageCount: 1_000)
        let mixedDatabase = try PageTextDatabase(url: DocumentTextService.databaseURL(for: mixedURL))
        let generation = try mixedDatabase.ocrGeneration(fingerprint: fingerprint, pageCount: 1_000, create: true)!
        let mixedPDF = PDFDocument(url: mixedURL)!
        var pending: [OCRPageText] = []
        for index in 0..<1_000 {
            try autoreleasepool {
                let page = mixedPDF.page(at: index)!, native = page.string!.trimmingCharacters(in: .whitespacesAndNewlines)
                let selection = page.selection(for: NSRange(location: 0, length: (native as NSString).length))!
                let nativeRect = DocumentTextService.uprightRect(selection.bounds(for: page), on: page)
                let boxes = [OCRTextBox(text: native, x: nativeRect.minX, y: nativeRect.minY, width: nativeRect.width, height: nativeRect.height), OCRTextBox(text: "Scanned unique \(index)", x: 0.1, y: 0.25, width: 0.6, height: 0.03)]
                pending.append(OCRPageText(pageIndex: index, width: 612, height: 792, text: boxes.map(\.text).joined(separator: "\n"), boxes: boxes))
                if pending.count == 32 { try mixedDatabase.storeOCRPages(pending, generation: generation); pending.removeAll(keepingCapacity: true) }
            }
        }
        try mixedDatabase.storeOCRPages(pending, generation: generation)
        let summary = try await service.cachedIndex(url: mixedURL)!
        precondition(summary.pages.count == 250 && summary.recognizedPageCount == 1_000 && summary.isComplete)
        let resumed = try await service.recognize(url: mixedURL)
        precondition(resumed.isComplete && resumed.recognizedPageCount == 1_000 && resumed.pages.count == 250)
        let requested = try await service.recognize(url: mixedURL, pages: [999])
        precondition(requested.pages.count == 1 && requested.pages[0].pageIndex == 999)
        let lastPage = try await service.cachedPage(url: mixedURL, pageIndex: 999)
        precondition(lastPage?.text.contains("Scanned unique 999") == true)
        let nativeMixed = try await service.search(url: mixedURL, query: "Native")
        precondition(nativeMixed.count == 1_000 && nativeMixed.allSatisfy { !$0.isOCR })
        let scanned = try await service.search(url: mixedURL, query: "Scanned")
        precondition(scanned.count == 1_000 && scanned.allSatisfy(\.isOCR))
        let output = directory.appendingPathComponent("Searchable.pdf")
        try await service.writeSearchablePDF(url: mixedURL, to: output)
        let exported = PDFDocument(url: output)!
        precondition(exported.pageCount == 1_000 && exported.page(at: 999)!.string!.contains("Scanned unique 999"))
        precondition(exported.page(at: 0)!.string!.components(separatedBy: "Native").count == 2)
        let backupPDF = directory.appendingPathComponent("Restored.pdf")
        try FileManager.default.copyItem(at: mixedURL, to: backupPDF)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: backupPDF.path)
        let backupDB = DocumentTextService.databaseURL(for: backupPDF)
        try PageTextDatabase.snapshot(from: DocumentTextService.databaseURL(for: mixedURL), to: backupDB)
        let restored = try PageTextDatabase(url: backupDB)
        let restoredFingerprint = try DocumentTextService.cacheFingerprint(url: backupPDF, pageCount: 1_000)
        try restored.rebase(from: fingerprint, to: restoredFingerprint, pageCount: 1_000)
        let restoredPage = try await DocumentTextService().cachedPage(url: backupPDF, pageIndex: 999)
        precondition(restoredPage?.text.contains("Scanned unique 999") == true)
        // A known annotation-only update rebases both native rows and durable OCR.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: mixedURL.path)
        try await service.refreshIndexFingerprint(url: mixedURL, previousFingerprint: fingerprint)
        let afterAnnotations = try await service.cachedIndex(url: mixedURL)
        precondition(afterAnnotations?.recognizedPageCount == 1_000)
        // Unrelated/stale generations remain physically preserved, but are not read as current.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: mixedURL.path)
        let stale = try await service.cachedIndex(url: mixedURL)
        let retainedCount = try mixedDatabase.ocrCount(generation: generation)
        precondition(stale == nil && retainedCount == 1_000)
        print("PASS: 1k cached OCR resume, <=250 summary preview, requested page999, geometric native/OCR dedup, full searchable export beyond preview, consistent SQLite backup/rebase, annotation refresh, stale OCR retained")
    }
    static func tryCount(_ database: PageTextDatabase) -> Int { try! database.nativePageCount() }
}
