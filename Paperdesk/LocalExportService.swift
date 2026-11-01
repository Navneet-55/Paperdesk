import CoreText
import CoreTransferable
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Owns an immutable staged export until the system export dialog finishes.
final class TemporaryExport: @unchecked Sendable {
    let directory: URL
    let url: URL
    init(filename: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Paperdesk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(filename)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

struct PDFExportItem: Transferable {
    let file: TemporaryExport
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in SentTransferredFile(item.file.url) }
    }
}

struct BackupExportItem: Transferable {
    let file: TemporaryExport
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in SentTransferredFile(item.file.url) }
    }
}

actor LocalExportService {
    /// A local, generated sample gives a new library something safe to explore.
    func studySample() throws -> TemporaryExport {
        let file = try TemporaryExport(filename: "Welcome to Offline Study.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: file.url as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        let pages = [
            """
            Learning that lasts

            Retrieval practice means recalling an idea before looking at the source again. Trying to recall a concept reveals what you know and what needs another review.

            Spaced practice spreads review sessions across time. Returning to a topic on different days gives you repeated opportunities to retrieve and connect ideas.

            Interleaving mixes related topics or problem types during practice. Comparing similar ideas can help you notice the features that distinguish them.

            Use Paperdesk’s Offline Study screen to explore these ideas. Choose Summary for selected passages, Key terms for words in context, or Flashcards to recall before revealing a source excerpt.

            Ask this document: What is retrieval practice?
            """,
            """
            Build a study habit

            Elaboration connects a new idea with something you already understand. Explain a concept in your own words and compare your explanation with the source.

            A useful study question focuses on one concept at a time. After answering, check the cited source page and correct anything you missed.

            Study notes preserve the questions and excerpts you want to revisit. Paperdesk saves document notes on this device and includes them in exported library backups.

            Flashcards are prompts for recall. Read the question, try an answer, reveal the excerpt, and return to the cited page for context.

            Paperdesk’s extractive study tools select passages from native PDF text and valid saved OCR. They do not invent missing facts or send your documents to an online service.
            """,
        ]
        for text in pages {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                        "Helvetica" as CFString, 16, nil)
                ])
            let path = CGPath(rect: box.insetBy(dx: 48, dy: 56), transform: nil)
            let frame = CTFramesetterCreateFrame(
                CTFramesetterCreateWithAttributedString(attributed), CFRange(), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return file
    }

    func copyPDF(from source: URL) throws -> TemporaryExport {
        try Task.checkCancellation()
        let result = try TemporaryExport(filename: "Document.pdf")
        try FileManager.default.copyItem(at: source, to: result.url)
        try Task.checkCancellation()
        return result
    }

    /// Same version-1 JSON format as existing backups, streamed in bounded base64 chunks.
    func backup(
        documents: [LibraryDocument], directory: URL,
        progress: @Sendable (Double) async -> Void
    ) async throws -> TemporaryExport {
        try Task.checkCancellation()
        let result = try TemporaryExport(filename: "Paperdesk Backup.json")
        guard FileManager.default.createFile(atPath: result.url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: result.url)
        defer { try? output.close() }
        let encoder = JSONEncoder()
        func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
        try write("{\"version\":1,\"createdAt\":")
        try output.write(contentsOf: encoder.encode(Date()))
        try write(",\"entries\":[")
        for (offset, document) in documents.enumerated() {
            try Task.checkCancellation()
            let pdf = directory.appendingPathComponent(document.filename)
            let before = try LibraryBackup.fingerprint(pdf)
            if offset > 0 { try write(",") }
            try write("{\"document\":")
            try output.write(contentsOf: encoder.encode(document))
            try write(",\"sourceFingerprint\":")
            try output.write(contentsOf: encoder.encode(before))
            for (key, url) in [
                ("pdf", pdf),
                ("drawing", directory.appendingPathComponent("\(document.id).drawing")),
                ("ocr", directory.appendingPathComponent("\(document.id).ocr.json")),
            ] {
                if key != "pdf" && !FileManager.default.fileExists(atPath: url.path) { continue }
                try write(",\"\(key)\":\"")
                try Self.writeBase64(from: url, to: output)
                try write("\"")
            }
            let auxiliary = try LibraryBackup.auxiliarySources(document: document, directory: directory)
            var stamps: [(URL, String)] = []
            try write(",\"auxiliaryFiles\":[")
            for (index, source) in auxiliary.enumerated() {
                try Task.checkCancellation()
                if index > 0 { try write(",") }
                try write("{\"relativePath\":")
                try output.write(contentsOf: encoder.encode(source.relativePath))
                try write(",\"data\":\"")
                let payload: URL
                if source.relativePath.hasSuffix(".pageindex.sqlite") {
                    payload = result.directory.appendingPathComponent("snapshot-\(UUID()).sqlite")
                    try PageTextDatabase.snapshot(from: source.url, to: payload)
                } else {
                    payload = source.url
                    stamps.append((source.url, try PDFPageJournal.stamp(source.url)))
                }
                try Self.writeBase64(from: payload, to: output)
                if payload != source.url { try? FileManager.default.removeItem(at: payload) }
                try write("\"}")
            }
            try write("]")
            for (url, stamp) in stamps where try PDFPageJournal.stamp(url) != stamp { throw CocoaError(.fileReadUnknown) }
            guard try LibraryBackup.fingerprint(pdf) == before else { throw CocoaError(.fileReadUnknown) }
            try write("}")
            await progress(Double(offset + 1) / Double(max(1, documents.count)))
        }
        try write("]}")
        try output.synchronize()
        try Task.checkCancellation()
        return result
    }

    static func writeBase64(from url: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var remainder = Data()
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 48 * 1024), !chunk.isEmpty else { break }
            remainder.append(chunk)
            let length = remainder.count / 3 * 3
            try output.write(contentsOf: remainder.prefix(length).base64EncodedData())
            remainder = Data(remainder.dropFirst(length))
        }
        if !remainder.isEmpty { try output.write(contentsOf: remainder.base64EncodedData()) }
    }
}
