import Foundation
import PDFKit
import PencilKit
import Vision

struct HandwritingPage: Codable, Sendable {
    let pageIndex: Int
    let text: String
    let region: PDFNoteRegion
    let revision: String
}

/// Recognition is local and explicit; revisiting a page can reuse its unchanged result.
actor HandwritingService {
    static let shared = HandwritingService()
    static func indexURL(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("handwriting.json")
    }
    private func pages(url: URL) throws -> [HandwritingPage] {
        let file = Self.indexURL(url)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([HandwritingPage].self, from: Data(contentsOf: file))
    }
    private struct SourceState {
        let stamp: String
        let journal: PDFJournalState?
        func revision(_ page: Int) -> String {
            stamp + (journal?.pages[page].map { ":" + $0 } ?? "")
        }
    }
    private static func sourceState(_ url: URL) throws -> SourceState {
        let stamp = try PDFPageJournal.stamp(url)
        let manifest = PDFPageJournal.directory(for: url).appendingPathComponent("index.json")
        let journal: PDFJournalState?
        if FileManager.default.fileExists(atPath: manifest.path) {
            journal = try JSONDecoder().decode(PDFJournalState.self, from: Data(contentsOf: manifest))
            guard journal?.sourceStamp == stamp else { throw PDFSaveError.conflict }
        } else { journal = nil }
        return SourceState(stamp: stamp, journal: journal)
    }
    private func recognizePage(url: URL, index: Int, document: PDFDocument, state: SourceState) async throws -> HandwritingPage {
        let owner: PDFDocument
        let page: PDFPage
        if let name = state.journal?.pages[index] {
            guard name == URL(fileURLWithPath: name).lastPathComponent,
                let journal = PDFDocument(url: PDFPageJournal.directory(for: url).appendingPathComponent(name)),
                let saved = journal.page(at: 0) else { throw PDFSaveError.conflict }
            owner = journal; page = saved
        } else {
            guard let original = document.page(at: index) else { throw DocumentTextError.invalidPage(index) }
            owner = document; page = original
        }
        defer { withExtendedLifetime(owner) {} }
        let geometry = PDFPageGeometry(page: page)
        let size = geometry.displayBounds.size
        let annotations = page.annotations.filter { ($0.type ?? "").lowercased() == "ink" }
        let strokes = annotations.flatMap { annotation in
            InkGeometry.points(in: annotation).filter { !$0.isEmpty }.map { points in
                let controls = points.enumerated().map { offset, point in
                    PKStrokePoint(
                        location: geometry.canvasPoint(fromPDF: point, canvasSize: size),
                        timeOffset: Double(offset) / 120,
                        size: CGSize(
                            width: annotation.border?.lineWidth ?? 3,
                            height: annotation.border?.lineWidth ?? 3), opacity: 1, force: 1, azimuth: 0,
                        altitude: .pi / 2)
                }
                return PKStroke(
                    ink: PKInk(.pen, color: .black),
                    path: PKStrokePath(controlPoints: controls, creationDate: Date()))
            }
        }
        let drawing = PKDrawing(strokes: strokes)
        var text = ""
        if !strokes.isEmpty {
            if #available(macOS 27, iOS 27, *) {
                let recognizer = PKStrokeRecognizer()
                await recognizer.updateDrawing(drawing)
                text = await recognizer.recognizedText() ?? ""
            }
            if text.isEmpty { text = try Self.visionText(drawing: drawing, size: size) }
        }
        try Task.checkCancellation()
        let bounds = annotations.dropFirst().reduce(annotations.first?.bounds ?? .zero) { $0.union($1.bounds) }
        return HandwritingPage(pageIndex: index, text: text, region: PDFNoteRegion(bounds: bounds), revision: state.revision(index))
    }
    // Merge once per operation, including cancellation, without overwriting another window's results.
    private func persist(_ completed: [Int: HandwritingPage], url: URL) throws {
        guard !completed.isEmpty else { return }
        let current = try Self.sourceState(url)
        var cached = Dictionary(try pages(url: url).map { ($0.pageIndex, $0) }, uniquingKeysWith: { _, last in last })
        for (index, page) in completed where page.revision == current.revision(index) { cached[index] = page }
        try JSONEncoder().encode(cached.values.sorted { $0.pageIndex < $1.pageIndex })
            .write(to: Self.indexURL(url), options: .atomic)
    }
    func recognize(url: URL, pageIndex: Int) async throws -> HandwritingPage {
        try Task.checkCancellation()
        let state = try Self.sourceState(url)
        if let cached = try pages(url: url).first(where: { $0.pageIndex == pageIndex && $0.revision == state.revision(pageIndex) }) { return cached }
        guard let document = PDFDocument(url: url) else { throw DocumentTextError.unreadablePDF }
        let result = try await recognizePage(url: url, index: pageIndex, document: document, state: state)
        guard result.revision == (try Self.sourceState(url)).revision(pageIndex) else { throw PDFSaveError.conflict }
        try persist([pageIndex: result], url: url)
        return result
    }
    func indexDocument(url: URL, progress: @Sendable (Double) async -> Void) async throws -> Int {
        let state = try Self.sourceState(url)
        let snapshot = try PDFFileSnapshot(copying: url)
        guard let document = PDFDocument(url: snapshot.url) else { throw DocumentTextError.unreadablePDF }
        defer { withExtendedLifetime(snapshot) {} }
        let cached = Dictionary(try pages(url: url).map { ($0.pageIndex, $0) }, uniquingKeysWith: { _, last in last })
        var completed: [Int: HandwritingPage] = [:]
        var recognized = 0
        do {
            for number in 0..<document.pageCount {
                try Task.checkCancellation()
                if let existing = cached[number], existing.revision == state.revision(number) {
                    if !existing.text.isEmpty { recognized += 1 }
                } else {
                    let hasInk = state.journal?.pages[number] != nil || autoreleasepool {
                        document.page(at: number)?.annotations.contains { ($0.type ?? "").lowercased() == "ink" } ?? false
                    }
                    if hasInk {
                        let result = try await recognizePage(url: url, index: number, document: document, state: state)
                        completed[number] = result
                        if !result.text.isEmpty { recognized += 1 }
                    }
                }
                if number % 16 == 0 || number + 1 == document.pageCount {
                    await progress(Double(number + 1) / Double(document.pageCount))
                }
            }
        } catch {
            try? persist(completed, url: url)
            throw error
        }
        try persist(completed, url: url)
        return recognized
    }
    func search(url: URL, query: String, maxResults: Int = 500) throws -> [DocumentSearchHit] {
        guard !query.isEmpty, maxResults > 0 else { return [] }
        let state = try Self.sourceState(url)
        return try pages(url: url).lazy.filter {
            $0.revision == state.revision($0.pageIndex) && $0.text.localizedStandardContains(query)
        }.prefix(maxResults).map { page in
            let range = (page.text as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            return DocumentSearchHit(pageIndex: page.pageIndex, location: range.location, length: range.length,
                                     snippet: String(page.text.prefix(240)), isOCR: true, boxes: [])
        }
    }
    static func revision(url: URL, pageIndex: Int) throws -> String {
        try sourceState(url).revision(pageIndex)
    }
    private static func visionText(drawing: PKDrawing, size: CGSize) throws -> String {
        let scale = min(2, 2000 / max(1, max(size.width, size.height)))
        let image = drawing.image(from: CGRect(origin: .zero, size: size), scale: scale)
        #if os(macOS)
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                return ""
            }
        #else
            guard let cgImage = image.cgImage else { return "" }
        #endif
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
            separator: "\n")
    }
}
