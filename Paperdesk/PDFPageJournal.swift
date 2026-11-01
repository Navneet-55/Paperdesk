import Foundation
import PDFKit
import ObjectiveC

private var journalOwnerKey: UInt8 = 0

struct PDFJournalState: Codable, Sendable {
    let sourceVersion: PDFFileVersion
    var sourceStamp: String
    var revision: UUID
    var pages: [Int: String]
}

/// Large PDFs save only the changed pages. Full PDF serialization is reserved for explicit export/edit operations.
actor PDFPageJournal {
    static let shared = PDFPageJournal()
    static func directory(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("inkpages")
    }
    static func stamp(_ url: URL) throws -> String {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(value[.size] ?? 0):\((value[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(value[.systemFileNumber] ?? 0)"
    }
    func state(for url: URL, sourceVersion: PDFFileVersion) throws -> PDFJournalState? {
        let manifest = Self.directory(for: url).appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        let state = try JSONDecoder().decode(PDFJournalState.self, from: Data(contentsOf: manifest))
        guard state.sourceVersion == sourceVersion, state.sourceStamp == (try Self.stamp(url)) else {
            throw PDFSaveError.conflict
        }
        return state
    }
    func save(url: URL, pages: [Int: Data], sourceVersion: PDFFileVersion, expectedRevision: UUID?) throws
        -> PDFJournalState
    {
        let current = try state(for: url, sourceVersion: sourceVersion)
        guard current?.revision == expectedRevision else { throw PDFSaveError.conflict }
        let folder = Self.directory(for: url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var next =
            try current
            ?? PDFJournalState(
                sourceVersion: sourceVersion, sourceStamp: Self.stamp(url), revision: UUID(), pages: [:])
        let previousFiles = next.pages
        var staged: [URL] = []
        do {
            for (page, data) in pages {
                guard page >= 0, let pdf = PDFDocument(data: data), pdf.pageCount == 1 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let name = "\(page)-\(UUID()).pdf"
                let destination = folder.appendingPathComponent(name)
                try data.write(to: destination, options: .atomic)
                staged.append(destination)
                next.pages[page] = name
            }
            next.revision = UUID()
            guard next.sourceStamp == (try Self.stamp(url)) else { throw PDFSaveError.conflict }
            try JSONEncoder().encode(next).write(
                to: folder.appendingPathComponent("index.json"), options: .atomic)
            for (page, name) in previousFiles where next.pages[page] != name {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
            return next
        } catch {
            staged.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }
    func rebase(url: URL) throws {
        let manifest = Self.directory(for: url).appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return }
        var state = try JSONDecoder().decode(PDFJournalState.self, from: Data(contentsOf: manifest))
        guard state.sourceVersion == (try PDFFileVersion.read(from: url)) else { throw PDFSaveError.conflict }
        state.sourceStamp = try Self.stamp(url)
        try JSONEncoder().encode(state).write(to: manifest, options: .atomic)
    }
    func pageData(url: URL, index: Int, state: PDFJournalState) throws -> Data? {
        guard let name = state.pages[index], name == URL(fileURLWithPath: name).lastPathComponent else {
            return nil
        }
        return try Data(contentsOf: Self.directory(for: url).appendingPathComponent(name))
    }
    /// Used for export and before structural edits. The source and journal stay intact on failure.
    func materialize(url: URL, to destination: URL, expectedVersion: PDFFileVersion) throws {
        guard try PDFFileVersion.read(from: url) == expectedVersion else { throw PDFSaveError.conflict }
        let journal = try state(for: url, sourceVersion: expectedVersion)
        guard let journal, !journal.pages.isEmpty else {
            try FileManager.default.copyItem(at: url, to: destination)
            return
        }
        let snapshot = try PDFFileSnapshot(copying: url)
        guard let document = PDFDocument(url: snapshot.url) else { throw CocoaError(.fileReadCorruptFile) }
        var owners: [PDFDocument] = []
        for index in journal.pages.keys.sorted() {
            try Task.checkCancellation()
            guard let data = try pageData(url: url, index: index, state: journal),
                let owner = PDFDocument(data: data), let source = owner.page(at: 0),
                let target = document.page(at: index)
            else { throw CocoaError(.fileReadCorruptFile) }
            owners.append(owner)
            Self.apply(source: source, to: target)
            document.removePage(at: index)
            document.insert(target, at: index)
        }
        defer { withExtendedLifetime(owners) {}; withExtendedLifetime(snapshot) {} }
        guard document.write(to: destination), try PDFFileVersion.read(from: url) == expectedVersion,
            try state(for: url, sourceVersion: expectedVersion)?.revision == journal.revision
        else { try? FileManager.default.removeItem(at: destination); throw PDFSaveError.conflict }
    }
    func commitMaterialized(url: URL, temporary: URL, expectedVersion: PDFFileVersion, expectedRevision: UUID?) throws {
        guard try PDFFileVersion.read(from: url) == expectedVersion,
            try state(for: url, sourceVersion: expectedVersion)?.revision == expectedRevision
        else { throw PDFSaveError.conflict }
        let destination = url.deletingLastPathComponent().appendingPathComponent(
            ".consolidated-\(UUID()).pdf")
        try FileManager.default.copyItem(at: temporary, to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: destination)
        try? FileManager.default.removeItem(at: Self.directory(for: url))
    }
    @MainActor static func apply(data: Data, to target: PDFPage) throws {
        guard let owner = PDFDocument(data: data), let source = owner.page(at: 0) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        apply(source: source, to: target)
    }
    static func apply(source: PDFPage, to target: PDFPage) {
        target.annotations.filter(PDFAnnotationEditorModel.isEditable).forEach { target.removeAnnotation($0) }
        for annotation in source.annotations.filter(PDFAnnotationEditorModel.isEditable) {
            if let copy = annotation.copy() as? PDFAnnotation {
                objc_setAssociatedObject(
                    copy, &journalOwnerKey, source.document, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                target.addAnnotation(copy)
            }
        }
    }
}
