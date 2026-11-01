import CryptoKit
import Foundation
import PDFKit

struct PDFFileVersion: Codable, Equatable, Sendable {
    let digest: Data
    init(data: Data) { digest = Data(SHA256.hash(data: data)) }
    private init(digest: Data) { self.digest = digest }

    static func read(from url: URL) throws -> PDFFileVersion {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        return PDFFileVersion(digest: Data(hash.finalize()))
    }
}

/// A private immutable file keeps PDFKit's lazy page reads tied to the version we opened.
final class PDFFileSnapshot: @unchecked Sendable {
    let directory: URL
    let url: URL
    let version: PDFFileVersion
    init(copying source: URL) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Paperdesk-read-" + UUID().uuidString)
        url = directory.appendingPathComponent("document.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: url)
            version = try PDFFileVersion.read(from: url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum PDFSaveError: LocalizedError {
    case conflict
    var errorDescription: String? {
        "This PDF changed in another window. Your draft has not been saved. Keep this editor open to retain it, or cancel and reopen the document before editing again."
    }
}

/// Copies only editable annotations; original artwork is never serialized on the UI executor.
enum PDFAnnotationSnapshot {
    static func data(from source: PDFPage) throws -> Data {
        let page = PDFPage()
        for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
            page.setBounds(source.bounds(for: box), for: box)
        }
        page.rotation = source.rotation
        for annotation in source.annotations.filter(PDFAnnotationEditorModel.isEditable) {
            guard let copy = annotation.copy() as? PDFAnnotation else {
                throw CocoaError(.fileWriteUnknown)
            }
            page.addAnnotation(copy)
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        // Appearance streams may refer to objects owned by the original document.
        defer { withExtendedLifetime(source) {}; withExtendedLifetime(source.document) {} }
        guard let data = document.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

/// Each save owns an independent PDFKit document. The visible PDF stays on the main actor.
actor PDFWriteService {
    static let shared = PDFWriteService()
    func savePages(url: URL, pages: [Int: Data], expectedVersion: PDFFileVersion) throws -> PDFFileVersion {
        guard try PDFFileVersion.read(from: url) == expectedVersion else { throw PDFSaveError.conflict }
        let snapshot = try PDFFileSnapshot(copying: url)
        defer { withExtendedLifetime(snapshot) {} }
        guard snapshot.version == expectedVersion else { throw PDFSaveError.conflict }
        guard let source = PDFDocument(url: snapshot.url) else { throw CocoaError(.fileReadCorruptFile) }
        var owners: [PDFDocument] = []
        var editedPages: [PDFPage] = []
        for (pageIndex, pageData) in pages.sorted(by: { $0.key < $1.key }) {
            guard let replacementDocument = PDFDocument(data: pageData),
                let replacement = replacementDocument.page(at: 0),
                pageIndex >= 0, pageIndex < source.pageCount
            else { throw CocoaError(.fileReadCorruptFile) }
            owners.append(replacementDocument)
            guard let target = source.page(at: pageIndex) else { throw CocoaError(.fileReadCorruptFile) }
            editedPages.append(target)
            let editable: Set<String> = [
                "ink", "highlight", "underline", "strikeout", "freetext", "text", "square", "circle", "line",
            ]
            func isEditable(_ annotation: PDFAnnotation) -> Bool {
                editable.contains(
                    (annotation.type ?? "").lowercased().trimmingCharacters(
                        in: CharacterSet(charactersIn: "/")))
            }
            target.annotations.filter(isEditable).forEach { target.removeAnnotation($0) }
            for annotation in replacement.annotations.filter(isEditable) {
                guard let cloned = annotation.copy() as? PDFAnnotation else {
                    throw CocoaError(.fileWriteUnknown)
                }
                target.addAnnotation(cloned)
            }
            // Reinsert the same page to invalidate PDFKit's original-data write fast path.
            // Keeping the page instance preserves destinations and noneditable annotations.
            source.removePage(at: pageIndex)
            source.insert(target, at: pageIndex)
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".Paperdesk-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        defer {
            withExtendedLifetime(owners) {}
            withExtendedLifetime(editedPages) {}
        }
        guard source.write(to: temporary) else { throw CocoaError(.fileWriteUnknown) }
        let savedVersion = try PDFFileVersion.read(from: temporary)
        // Detect external replacements during serialization as well as stale readers.
        guard try PDFFileVersion.read(from: url) == expectedVersion else { throw PDFSaveError.conflict }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        return savedVersion
    }
}
