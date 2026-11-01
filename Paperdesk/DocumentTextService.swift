import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

/// A normalized rectangle in the upright page, with an origin at the bottom left.
struct OCRTextBox: Codable, Sendable, Hashable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct OCRPageText: Codable, Sendable {
    let pageIndex: Int
    let width: Double
    let height: Double
    let text: String
    let boxes: [OCRTextBox]
}

struct OCRIndex: Codable, Sendable {
    let version: Int
    var fingerprint: String
    let pageCount: Int
    var pages: [OCRPageText]
    var recognizedPageCount: Int? = nil
    var isComplete: Bool { (recognizedPageCount ?? Set(pages.map(\.pageIndex)).count) == pageCount }
}

struct DocumentSearchHit: Sendable {
    let pageIndex: Int
    /// UTF-16 offsets into either PDFPage.string or the cached OCR page text.
    let location: Int
    let length: Int
    let snippet: String
    let isOCR: Bool
    let boxes: [OCRTextBox]
    var range: NSRange { NSRange(location: location, length: length) }
}

struct DocumentTextProgress: Sendable {
    let completedPages: Int
    let totalPages: Int
    var fraction: Double { totalPages == 0 ? 1 : Double(completedPages) / Double(totalPages) }
}

enum DocumentTextError: LocalizedError {
    case unreadablePDF
    case invalidPage(Int)
    case cannotRender(Int)
    case cannotCreatePDF, incompatibleIndex
    var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "The PDF could not be opened, or it is locked."
        case .invalidPage(let page): return "Page \(page + 1) is outside the document."
        case .cannotRender(let page): return "Page \(page + 1) could not be rendered for text recognition."
        case .cannotCreatePDF: return "A searchable PDF could not be created."
        case .incompatibleIndex:
            return "The PDF changed after text recognition. Recognize it again before exporting."
        }
    }
}

/// Owns separate PDF objects on its executor. Never pass UI PDFPage/PDFDocument
/// instances here. Cancellation takes effect between pages and after Vision returns.
actor DocumentTextService {
    typealias Progress = @Sendable (DocumentTextProgress) async -> Void

    static let databaseThreshold = 1_000
    static func databaseURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("pageindex.sqlite")
    }
    static func cacheFingerprint(url: URL, pageCount: Int) throws -> String {
        try fingerprint(url: url, pageCount: pageCount)
    }
    static func indexURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("ocr.json")
    }

    /// Search keeps Foundation's Unicode/diacritic matching. Large PDFs cache native
    /// page strings on disk; repeated searches never need to parse those PDF pages again.
    func search(url: URL, query: String, maxResults: Int = 10_000, progress: Progress? = nil) async throws -> [DocumentSearchHit] {
        try Task.checkCancellation()
        let limit = min(maxResults, 10_000)
        guard !query.isEmpty, limit > 0 else { return [] }
        guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else { throw DocumentTextError.unreadablePDF }
        let count = pdf.pageCount
        let fingerprint = try Self.fingerprint(url: url, pageCount: count)
        let database = count >= Self.databaseThreshold ? try largeDatabase(url: url, pageCount: count, fingerprint: fingerprint) : nil
        try database?.prepareNative(fingerprint: fingerprint, pageCount: count)
        let generation = try database?.ocrGeneration(fingerprint: fingerprint, pageCount: count)
        let legacyIndex = database == nil ? try loadIndex(url: url, pageCount: count) : nil
        let legacyOCR = Dictionary((legacyIndex?.pages ?? []).map { ($0.pageIndex, $0) }, uniquingKeysWith: { first, _ in first })
        var hits: [DocumentSearchHit] = []
        var pendingNative: [(Int, String)] = []
        for pageIndex in 0..<count {
            try Task.checkCancellation()
            let found: [DocumentSearchHit] = try autoreleasepool {
                let cachedNative = try database?.nativeText(pageIndex: pageIndex)
                var loadedPage: PDFPage?
                func page() -> PDFPage? {
                    if loadedPage == nil { loadedPage = pdf.page(at: pageIndex) }
                    return loadedPage
                }
                let native = cachedNative ?? page()?.string ?? ""
                if database != nil && cachedNative == nil { pendingNative.append((pageIndex, native)) }
                var results = Self.find(query, in: native, pageIndex: pageIndex, boxes: [], isOCR: false, limit: limit - hits.count)
                let ocr: OCRPageText?
                if let database, let generation { ocr = try database.ocrPage(generation: generation, pageIndex: pageIndex) }
                else { ocr = legacyOCR[pageIndex] }
                if let ocr, hits.count + results.count < limit, (ocr.text as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]).location != NSNotFound {
                    let covered: [Bool]
                    if let database, let generation, let cached = try database.ocrCoverage(generation: generation, pageIndex: pageIndex), cached.count == ocr.boxes.count {
                        covered = cached
                    } else {
                        covered = ocr.boxes.map { box in page().map { Self.hasNativeText(box.text, covering: [box], on: $0) } ?? false }
                        if let database, let generation { try database.storeOCRCoverage(covered, generation: generation, pageIndex: pageIndex) }
                    }
                    let coverage = Dictionary(zip(ocr.boxes, covered), uniquingKeysWith: { first, _ in first })
                    results += Self.find(query, in: ocr.text, pageIndex: pageIndex, boxes: ocr.boxes, isOCR: true, limit: limit - hits.count - results.count) { hit in
                        !hit.boxes.allSatisfy { coverage[$0] == true }
                    }
                }
                return results
            }
            hits.append(contentsOf: found)
            if pendingNative.count >= 32 { try database?.storeNativePages(pendingNative, fingerprint: fingerprint); pendingNative.removeAll(keepingCapacity: true) }
            if (pageIndex + 1).isMultiple(of: 16) || pageIndex + 1 == count || hits.count >= limit {
                // No SQLite statement/transaction is alive across this await.
                try database?.storeNativePages(pendingNative, fingerprint: fingerprint); pendingNative.removeAll(keepingCapacity: true)
                if let progress { await progress(DocumentTextProgress(completedPages: pageIndex + 1, totalPages: count)) }
            }
            if hits.count >= limit { break }
        }
        try database?.storeNativePages(pendingNative, fingerprint: fingerprint)
        try Task.checkCancellation()
        guard try Self.fingerprint(url: url, pageCount: count) == fingerprint else { throw DocumentTextError.incompatibleIndex }
        return hits
    }

    /// Recognizes every requested page, caching a completed page after each pass.
    /// Existing valid pages are reused, so cancellation can be resumed safely.
    func recognize(
        url: URL, pages requestedPages: [Int]? = nil, force: Bool = false, progress: Progress? = nil
    ) async throws -> OCRIndex {
        try Task.checkCancellation()
        guard let source = CGPDFDocument(url as CFURL), !source.isEncrypted || source.isUnlocked,
            source.numberOfPages > 0
        else { throw DocumentTextError.unreadablePDF }
        let count = source.numberOfPages
        let fingerprint = try Self.fingerprint(url: url, pageCount: count)
        if count >= Self.databaseThreshold {
            return try await recognizeLarge(url: url, source: source, fingerprint: fingerprint, requestedPages: requestedPages, force: force, progress: progress)
        }
        var index =
            try loadIndex(url: url, pageCount: count)
            ?? OCRIndex(version: 1, fingerprint: fingerprint, pageCount: count, pages: [])
        let requested = Array(Set(requestedPages ?? Array(0..<count))).sorted()
        for page in requested where !(0..<count).contains(page) { throw DocumentTextError.invalidPage(page) }
        for (offset, pageIndex) in requested.enumerated() {
            try Task.checkCancellation()
            if force || !index.pages.contains(where: { $0.pageIndex == pageIndex }) {
                let pageText = try Self.recognizePage(source: source, pageIndex: pageIndex)
                try Task.checkCancellation()
                // Do not attach results to a file modified during recognition.
                guard try Self.fingerprint(url: url, pageCount: count) == fingerprint else {
                    throw DocumentTextError.incompatibleIndex
                }
                index.pages.removeAll { $0.pageIndex == pageIndex }
                index.pages.append(pageText)
                index.pages.sort { $0.pageIndex < $1.pageIndex }
                try saveIndex(index, url: url)
            }
            if let progress, (offset + 1).isMultiple(of: 16) || offset + 1 == requested.count {
                await progress(DocumentTextProgress(completedPages: offset + 1, totalPages: requested.count))
            }
        }
        try Task.checkCancellation()
        return index
    }

    func cachedIndex(url: URL) throws -> OCRIndex? {
        guard let pdf = CGPDFDocument(url as CFURL) else { throw DocumentTextError.unreadablePDF }
        let count = pdf.numberOfPages
        if count >= Self.databaseThreshold {
            let fingerprint = try Self.fingerprint(url: url, pageCount: count)
            let database = try largeDatabase(url: url, pageCount: count, fingerprint: fingerprint)
            guard let generation = try database.ocrGeneration(fingerprint: fingerprint, pageCount: count) else { return nil }
            return try largeSummary(database: database, generation: generation, fingerprint: fingerprint, pageCount: count)
        }
        return try loadIndex(url: url, pageCount: count)
    }

    /// Read any OCR page, including pages beyond a large index's bounded preview.
    func cachedPage(url: URL, pageIndex: Int) throws -> OCRPageText? {
        guard let pdf = CGPDFDocument(url as CFURL), (0..<pdf.numberOfPages).contains(pageIndex) else { throw DocumentTextError.invalidPage(pageIndex) }
        let count = pdf.numberOfPages
        if count >= Self.databaseThreshold {
            let fingerprint = try Self.fingerprint(url: url, pageCount: count)
            let database = try largeDatabase(url: url, pageCount: count, fingerprint: fingerprint)
            guard let generation = try database.ocrGeneration(fingerprint: fingerprint, pageCount: count) else { return nil }
            return try database.ocrPage(generation: generation, pageIndex: pageIndex)
        }
        return try loadIndex(url: url, pageCount: count)?.pages.first { $0.pageIndex == pageIndex }
    }

    /// Call only after a successful annotation-only save. Page content is unchanged.
    func refreshIndexFingerprint(url: URL, previousFingerprint: String? = nil) throws {
        guard let pdf = CGPDFDocument(url as CFURL) else { throw DocumentTextError.unreadablePDF }
        let count = pdf.numberOfPages, fingerprint = try Self.fingerprint(url: url, pageCount: pdf.numberOfPages)
        let databaseURL = Self.databaseURL(for: url)
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let database = try PageTextDatabase(url: databaseURL)
            if let previousFingerprint { try database.rebase(from: previousFingerprint, to: fingerprint, pageCount: count) }
        }
        let sidecar = Self.indexURL(for: url)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        var index = try JSONDecoder().decode(OCRIndex.self, from: Data(contentsOf: sidecar))
        guard count == index.pageCount, index.version == 1, index.fingerprint == previousFingerprint else { return }
        index.fingerprint = fingerprint
        try saveIndex(index, url: url)
    }

    /// Exports upright source pages plus invisible recognized text. This produces
    /// a new flattened document; annotations/forms become visual content and
    /// source outlines, links, signatures and interactive form fields are omitted.
    func exportSearchablePDF(url: URL, index suppliedIndex: OCRIndex? = nil, progress: Progress? = nil)
        async throws -> Data
    {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await writeSearchablePDF(url: url, to: destination, index: suppliedIndex, progress: progress)
        return try Data(contentsOf: destination)
    }

    func writeSearchablePDF(
        url: URL, to destination: URL, index suppliedIndex: OCRIndex? = nil, visualURL: URL? = nil, progress: Progress? = nil
    ) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        try Task.checkCancellation()
        guard let source = CGPDFDocument(url as CFURL), !source.isEncrypted || source.isUnlocked,
            source.numberOfPages > 0
        else { throw DocumentTextError.unreadablePDF }
        let count = source.numberOfPages
        let fingerprint = try Self.fingerprint(url: url, pageCount: count)
        let database = count >= Self.databaseThreshold ? try largeDatabase(url: url, pageCount: count, fingerprint: fingerprint) : nil
        let candidate = try suppliedIndex ?? cachedIndex(url: url)
        let index: OCRIndex
        let durableGeneration = try database?.ocrGeneration(fingerprint: fingerprint, pageCount: count)
        let complete = try durableGeneration.flatMap { generation in try database?.ocrCount(generation: generation) } == count
        if let candidate, (database != nil ? complete : Set(candidate.pages.map(\.pageIndex)).count == count), candidate.version == 1, candidate.pageCount == count,
            candidate.fingerprint == fingerprint
        {
            index = candidate
        } else {
            index = try await recognize(url: url, progress: progress)
        }
        guard index.version == 1, index.pageCount == count, index.fingerprint == fingerprint else {
            throw DocumentTextError.incompatibleIndex
        }
        let generation = try database?.ocrGeneration(fingerprint: fingerprint, pageCount: count)
        let ocrPages = Dictionary(
            index.pages.map { ($0.pageIndex, $0) }, uniquingKeysWith: { first, _ in first })
        // PDFKit draws source annotations as well as the PDF page artwork.
        guard let visualPDF = PDFDocument(url: visualURL ?? url), !visualPDF.isLocked else {
            throw DocumentTextError.unreadablePDF
        }
        guard let consumer = CGDataConsumer(url: destination as CFURL),
            let output = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw DocumentTextError.cannotCreatePDF }
        var closed = false
        defer { if !closed { output.closePDF() } }
        for pageIndex in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = source.page(at: pageIndex + 1),
                    let visualPage = visualPDF.page(at: pageIndex)
                else { throw DocumentTextError.invalidPage(pageIndex) }
                let size = Self.displaySize(page)
                let rect = CGRect(origin: .zero, size: size)
                let pageInfo = [kCGPDFContextMediaBox as String: Self.rectData(rect)] as CFDictionary
                output.beginPDFPage(pageInfo)
                output.saveGState()
                visualPage.draw(with: .mediaBox, to: output)
                output.restoreGState()
                let recognized: OCRPageText?
                if let database, let generation { recognized = try database.ocrPage(generation: generation, pageIndex: pageIndex) }
                else { recognized = ocrPages[pageIndex] }
                if let recognized {
                    for box in recognized.boxes
                    where !Self.hasNativeText(box.text, covering: [box], on: visualPage) {
                        Self.drawInvisibleText(box, pageSize: size, context: output)
                    }
                }
                output.endPDFPage()
            }
            if let progress, (pageIndex + 1).isMultiple(of: 16) || pageIndex + 1 == count {
                await progress(DocumentTextProgress(completedPages: pageIndex + 1, totalPages: count))
            }
        }
        output.closePDF()
        closed = true
        try Task.checkCancellation()
        guard try Self.fingerprint(url: url, pageCount: count) == fingerprint else {
            throw DocumentTextError.incompatibleIndex
        }
        guard let exported = CGPDFDocument(destination as CFURL), exported.numberOfPages == count else {
            throw DocumentTextError.cannotCreatePDF
        }
        completed = true
    }

    /// OCR uses upright media-box coordinates; native selections use unrotated page space.
    static func uprightRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        let transform = page.transform(for: .mediaBox)
        let bounds = page.bounds(for: .mediaBox).applying(transform)
        let displayed = rect.applying(transform)
        return CGRect(
            x: (displayed.minX - bounds.minX) / bounds.width,
            y: (displayed.minY - bounds.minY) / bounds.height,
            width: displayed.width / bounds.width, height: displayed.height / bounds.height)
    }

    static func hasNativeText(_ text: String, covering boxes: [OCRTextBox], on page: PDFPage) -> Bool {
        guard !boxes.isEmpty, let native = page.string, !text.isEmpty else { return false }
        let string = native as NSString
        var cursor = 0
        var nativeRects: [CGRect] = []
        while cursor < string.length {
            let range = string.range(
                of: text, options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: cursor, length: string.length - cursor))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if let selection = page.selection(for: range) {
                nativeRects += selection.selectionsByLine().map {
                    uprightRect($0.bounds(for: page), on: page)
                }
            }
            cursor = NSMaxRange(range)
        }
        return boxes.allSatisfy { box in
            nativeRects.contains { rect in
                let overlap = rect.intersection(box.rect)
                guard !overlap.isNull else { return false }
                let smallerArea = min(rect.width * rect.height, box.rect.width * box.rect.height)
                return smallerArea > 0 && overlap.width * overlap.height / smallerArea >= 0.5
            }
        }
    }

    private func largeDatabase(url: URL, pageCount: Int, fingerprint: String) throws -> PageTextDatabase {
        let database = try PageTextDatabase(url: Self.databaseURL(for: url))
        if try !database.legacyMigrationComplete(fingerprint: fingerprint),
            FileManager.default.fileExists(atPath: Self.indexURL(for: url).path),
            let legacy = try loadIndex(url: url, pageCount: pageCount) {
            let generation = try database.ocrGeneration(fingerprint: fingerprint, pageCount: pageCount, create: true)!
            // One-time migration keeps the legacy JSON intact for older backups.
            for start in stride(from: 0, to: legacy.pages.count, by: 32) {
                try Task.checkCancellation()
                try database.storeOCRPages(Array(legacy.pages[start..<min(start + 32, legacy.pages.count)]), generation: generation, replace: false)
            }
            try database.markLegacyMigrationComplete(fingerprint: fingerprint)
        }
        return database
    }
    private func largeSummary(database: PageTextDatabase, generation: Int64, fingerprint: String, pageCount: Int, preferredPages: [Int]? = nil) throws -> OCRIndex {
        let preview: [OCRPageText]
        if let preferredPages {
            preview = try Array(Set(preferredPages)).sorted().prefix(250).compactMap { try database.ocrPage(generation: generation, pageIndex: $0) }
        } else { preview = try database.ocrPreview(generation: generation) }
        return OCRIndex(version: 1, fingerprint: fingerprint, pageCount: pageCount, pages: preview, recognizedPageCount: try database.ocrCount(generation: generation))
    }
    private func recognizeLarge(url: URL, source: CGPDFDocument, fingerprint: String, requestedPages: [Int]?, force: Bool, progress: Progress?) async throws -> OCRIndex {
        let count = source.numberOfPages
        let database = try largeDatabase(url: url, pageCount: count, fingerprint: fingerprint)
        let generation = try database.ocrGeneration(fingerprint: fingerprint, pageCount: count, create: true)!
        let requested = Array(Set(requestedPages ?? Array(0..<count))).sorted()
        for page in requested where !(0..<count).contains(page) { throw DocumentTextError.invalidPage(page) }
        for (offset, pageIndex) in requested.enumerated() {
            try Task.checkCancellation()
            if try force || !database.hasOCRPage(generation: generation, pageIndex: pageIndex) {
                let recognized = try Self.recognizePage(source: source, pageIndex: pageIndex)
                try Task.checkCancellation()
                guard try Self.fingerprint(url: url, pageCount: count) == fingerprint else { throw DocumentTextError.incompatibleIndex }
                try database.storeOCRPages([recognized], generation: generation)
            }
            if let progress, (offset + 1).isMultiple(of: 16) || offset + 1 == requested.count {
                await progress(DocumentTextProgress(completedPages: offset + 1, totalPages: requested.count))
            }
        }
        try Task.checkCancellation()
        return try largeSummary(database: database, generation: generation, fingerprint: fingerprint, pageCount: count, preferredPages: requestedPages)
    }
    private static func recognizePage(source: CGPDFDocument, pageIndex: Int) throws -> OCRPageText {
        try autoreleasepool {
            guard let page = source.page(at: pageIndex + 1) else { throw DocumentTextError.invalidPage(pageIndex) }
            let (image, size) = try Self.render(page, pageIndex: pageIndex)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let boxes = (request.results ?? []).compactMap { observation -> OCRTextBox? in
                guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
                let box = observation.boundingBox
                return OCRTextBox(text: text, x: box.minX, y: box.minY, width: box.width, height: box.height)
            }
            return OCRPageText(pageIndex: pageIndex, width: size.width, height: size.height, text: boxes.map(\.text).joined(separator: "\n"), boxes: boxes)
        }
    }

    private func loadIndex(url: URL, pageCount: Int) throws -> OCRIndex? {
        let sidecar = Self.indexURL(for: url)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }
        // A corrupt/stale OCR cache must never make an otherwise healthy PDF unreadable.
        guard let data = try? Data(contentsOf: sidecar),
            let index = try? JSONDecoder().decode(OCRIndex.self, from: data),
            index.version == 1, index.pageCount == pageCount,
            index.fingerprint == (try Self.fingerprint(url: url, pageCount: pageCount)),
            index.pages.allSatisfy({ (0..<pageCount).contains($0.pageIndex) })
        else { return nil }
        return index
    }
    private func saveIndex(_ index: OCRIndex, url: URL) throws {
        try JSONEncoder().encode(index).write(to: Self.indexURL(for: url), options: .atomic)
    }
    private static func fingerprint(url: URL, pageCount: Int) throws -> String {
        // URL resource values can be cached across a replace/restore. Fetch fresh file
        // attributes so external replacements never silently reuse an old text index.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (values[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(pageCount):\(size):\(modified)"
    }
    private static func find(
        _ query: String, in text: String, pageIndex: Int, boxes: [OCRTextBox], isOCR: Bool, limit: Int,
        include: (DocumentSearchHit) -> Bool = { _ in true }
    ) -> [DocumentSearchHit] {
        guard !text.isEmpty, limit > 0 else { return [] }
        let string = text as NSString
        var results: [DocumentSearchHit] = []
        var cursor = 0
        while cursor < string.length, results.count < limit {
            let range = string.range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: cursor, length: string.length - cursor))
            guard range.location != NSNotFound, range.length > 0 else { break }
            let start = max(0, range.location - 45)
            let end = min(string.length, NSMaxRange(range) + 70)
            let snippet = string.substring(with: NSRange(location: start, length: end - start))
                .replacingOccurrences(of: "\n", with: " ")
            var matchingBoxes: [OCRTextBox] = []
            if isOCR {
                var lineOffset = 0
                for box in boxes {
                    let lineRange = NSRange(location: lineOffset, length: (box.text as NSString).length)
                    if NSIntersectionRange(range, lineRange).length > 0 { matchingBoxes.append(box) }
                    lineOffset += lineRange.length + 1
                }
            }
            let hit = DocumentSearchHit(
                pageIndex: pageIndex, location: range.location, length: range.length, snippet: snippet,
                isOCR: isOCR, boxes: matchingBoxes)
            if include(hit) { results.append(hit) }
            cursor = NSMaxRange(range)
        }
        return results
    }
    private static func displaySize(_ page: CGPDFPage) -> CGSize {
        let bounds = page.getBoxRect(.mediaBox).standardized
        return abs(page.rotationAngle) % 180 == 90
            ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    }
    private static func render(_ page: CGPDFPage, pageIndex: Int) throws -> (CGImage, CGSize) {
        let size = displaySize(page)
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            throw DocumentTextError.cannotRender(pageIndex)
        }
        let scale = min(3, 2200 / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded(.up)))
        let height = max(1, Int((size.height * scale).rounded(.up)))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw DocumentTextError.cannotRender(pageIndex) }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.concatenate(
            page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw DocumentTextError.cannotRender(pageIndex) }
        return (image, size)
    }
    private static func drawInvisibleText(_ box: OCRTextBox, pageSize: CGSize, context: CGContext) {
        let rect = CGRect(
            x: box.x * pageSize.width, y: box.y * pageSize.height, width: box.width * pageSize.width,
            height: box.height * pageSize.height)
        guard rect.width > 0, rect.height > 0, !box.text.isEmpty else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, max(1, rect.height), nil)
        let attributed = NSAttributedString(
            string: box.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        guard width > 0, ascent + descent > 0 else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / width, y: rect.height / (ascent + descent))
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }
    private static func rectData(_ rect: CGRect) -> CFData {
        var value = rect
        return withUnsafeBytes(of: &value) { Data($0) as CFData }
    }
}
