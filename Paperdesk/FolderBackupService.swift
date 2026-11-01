import Foundation
import PDFKit

struct FolderBackupManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let relativePath: String
        let byteCount: Int64
        let digest: Data
    }
    struct Entry: Codable, Sendable {
        let document: LibraryDocument
        let sourceFingerprint: String
        let files: [File]
    }
    let version: Int
    let createdAt: Date
    let entries: [Entry]
}

/// Folder backups copy one file at a time; PDF payloads never enter a JSON/base64 buffer.
/// Only active documents and their current workspace, drawing, OCR and annotation
/// journal are included. Local Removed and History archives remain on this device.
actor FolderBackupService {
    struct Installation: Sendable {
        let documents: [LibraryDocument]
        let written: [URL]
    }
    typealias Progress = @Sendable (Double) async -> Void

    func export(documents: [LibraryDocument], directory: URL, parent: URL, progress: Progress? = nil) async throws -> URL {
        guard documents.count <= 100_000, Set(documents.map(\.id)).count == documents.count else { throw Self.invalid() }
        let files = FileManager.default
        let staging = parent.appendingPathComponent(".Paperdesk-Backup-\(UUID())", isDirectory: true)
        let destination = parent.appendingPathComponent("Paperdesk Backup-\(UUID()).paperdeskbackup", isDirectory: true)
        try files.createDirectory(at: staging.appendingPathComponent("data"), withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        var entries: [FolderBackupManifest.Entry] = []
        for (offset, document) in documents.enumerated() {
            try Task.checkCancellation()
            guard document.filename == URL(fileURLWithPath: document.filename).lastPathComponent else { throw Self.invalid() }
            let pdfURL = directory.appendingPathComponent(document.filename)
            let before = try LibraryBackup.fingerprint(pdfURL)
            let auxiliary = try LibraryBackup.auxiliarySources(document: document, directory: directory)
            var sources: [(String, URL)] = [("\(document.id).pdf", pdfURL)]
            for suffix in ["drawing", "ocr.json"] {
                let name = "\(document.id).\(suffix)", url = directory.appendingPathComponent("\(document.id).\(suffix)")
                if files.fileExists(atPath: url.path) { sources.append((name, url)) }
            }
            sources += auxiliary.map { ($0.relativePath, $0.url) }
            var captured: [FolderBackupManifest.File] = []
            var stamps: [(URL, String)] = []
            for (relativePath, source) in sources {
                try Task.checkCancellation()
                try LibraryBackup.requireRegularFile(source)
                let output = staging.appendingPathComponent("data/" + relativePath)
                try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                if relativePath.hasSuffix(".pageindex.sqlite") {
                    try PageTextDatabase.snapshot(from: source, to: output)
                } else {
                    let stamp = try PDFPageJournal.stamp(source)
                    try files.copyItem(at: source, to: output)
                    guard try PDFPageJournal.stamp(source) == stamp else { throw Self.changed() }
                    stamps.append((source, stamp))
                }
                let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let version = try PDFFileVersion.read(from: output)
                captured.append(FolderBackupManifest.File(relativePath: relativePath, byteCount: Int64(size), digest: version.digest))
            }
            for (url, stamp) in stamps where try PDFPageJournal.stamp(url) != stamp { throw Self.changed() }
            guard try LibraryBackup.fingerprint(pdfURL) == before else { throw Self.changed() }
            entries.append(FolderBackupManifest.Entry(document: document, sourceFingerprint: before, files: captured))
            if let progress { await progress(Double(offset + 1) / Double(max(1, documents.count))) }
        }
        let manifest = FolderBackupManifest(version: 1, createdAt: Date(), entries: entries)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: destination)
        return destination
    }

    /// Stages and verifies all imports before publishing any new library membership.
    /// A new document ID prevents accidental replacement of edits already on the device.
    func install(source: URL, library: URL, progress: Progress? = nil) async throws -> Installation {
        let files = FileManager.default
        try Self.requireDirectory(source)
        let manifestURL = source.appendingPathComponent("manifest.json")
        try LibraryBackup.requireRegularFile(manifestURL)
        guard (try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128 * 1024 * 1024 else { throw Self.invalid() }
        let manifest = try JSONDecoder().decode(FolderBackupManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, manifest.entries.count <= 100_000,
              Set(manifest.entries.map { $0.document.id }).count == manifest.entries.count else { throw Self.invalid() }
        try Self.requireDirectory(source.appendingPathComponent("data", isDirectory: true))
        let staging = library.appendingPathComponent(".Paperdesk-Restore-\(UUID())", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        var imported: [LibraryDocument] = []
        var destinations: [URL] = []
        var written: [URL] = []
        do {
            for (offset, entry) in manifest.entries.enumerated() {
                try Task.checkCancellation()
                let oldID = entry.document.id
                guard entry.files.count <= 1_000_000, Set(entry.files.map(\.relativePath)).count == entry.files.count,
                      entry.files.contains(where: { $0.relativePath == "\(oldID).pdf" }),
                      entry.files.allSatisfy({ Self.allowed($0.relativePath, documentID: oldID) && $0.byteCount >= 0 && $0.digest.count == 32 }) else { throw Self.invalid() }
                let newID = UUID()
                for file in entry.files {
                    let input = source.appendingPathComponent("data/" + file.relativePath)
                    if file.relativePath.contains("/") { try Self.requireDirectory(input.deletingLastPathComponent()) }
                    try LibraryBackup.requireRegularFile(input)
                    guard Int64(try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == file.byteCount else { throw Self.invalid() }
                    let mapped = Self.remap(file.relativePath, from: oldID, to: newID)
                    let output = staging.appendingPathComponent(mapped)
                    try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try files.copyItem(at: input, to: output)
                    guard try PDFFileVersion.read(from: output).digest == file.digest else { throw Self.invalid() }
                }
                let pdfURL = staging.appendingPathComponent("\(newID).pdf")
                guard let pdf = CGPDFDocument(pdfURL as CFURL), !pdf.isEncrypted || pdf.isUnlocked, pdf.numberOfPages > 0 else { throw Self.invalid() }
                let workspaceURL = staging.appendingPathComponent("\(newID).workspace.json")
                if files.fileExists(atPath: workspaceURL.path) {
                    let data = try Data(contentsOf: workspaceURL)
                    let workspace = try JSONDecoder().decode(DocumentWorkspace.self, from: data)
                    guard workspace.version == 1, workspace.documentID == oldID else { throw Self.invalid() }
                    try LibraryBackup.rebasedWorkspace(data, documentID: newID).write(to: workspaceURL, options: .atomic)
                }
                let ocrURL = staging.appendingPathComponent("\(newID).ocr.json")
                if files.fileExists(atPath: ocrURL.path) {
                    let data = try LibraryBackup.rebasedOCR(Data(contentsOf: ocrURL), sourceFingerprint: entry.sourceFingerprint, pdfURL: pdfURL)
                    try data.write(to: ocrURL, options: .atomic)
                }
                let journal = staging.appendingPathComponent("\(newID).inkpages", isDirectory: true)
                if files.fileExists(atPath: journal.path) {
                    try Self.validateJournal(folder: journal, pdfURL: pdfURL)
                    try await PDFPageJournal.shared.rebase(url: pdfURL)
                }
                try LibraryBackup.rebaseTextDatabase(pdfURL: pdfURL, previousFingerprint: entry.sourceFingerprint)
                let old = entry.document
                imported.append(LibraryDocument(id: newID, title: old.title, filename: "\(newID).pdf", importedAt: old.importedAt, notes: old.notes, lastPage: max(0, min(old.lastPage, pdf.numberOfPages - 1)), folder: old.folder))
                for suffix in ["pdf", "drawing", "ocr.json", "workspace.json", "pageindex.sqlite", "inkpages"] {
                    let url = staging.appendingPathComponent("\(newID).\(suffix)")
                    if files.fileExists(atPath: url.path) { destinations.append(url) }
                }
                if let progress { await progress(Double(offset + 1) / Double(max(1, manifest.entries.count))) }
            }
            try Task.checkCancellation()
            for staged in destinations {
                let destination = library.appendingPathComponent(staged.lastPathComponent)
                guard !files.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
                try files.moveItem(at: staged, to: destination)
                written.append(destination)
            }
            return Installation(documents: imported, written: written)
        } catch {
            for url in written.reversed() { try? files.removeItem(at: url) }
            throw error
        }
    }
    func rollback(_ installation: Installation) {
        for url in installation.written.reversed() { try? FileManager.default.removeItem(at: url) }
    }
    private static func validateJournal(folder: URL, pdfURL: URL) throws {
        let state = try JSONDecoder().decode(PDFJournalState.self, from: Data(contentsOf: folder.appendingPathComponent("index.json")))
        guard let pdf = CGPDFDocument(pdfURL as CFURL), state.sourceVersion == (try PDFFileVersion.read(from: pdfURL)), Set(state.pages.values).count == state.pages.count else { throw invalid() }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard Set(names) == Set(["index.json"] + state.pages.values) else { throw invalid() }
        for (page, name) in state.pages {
            guard (0..<pdf.numberOfPages).contains(page), LibraryBackup.validJournalPageName(name) == page else { throw invalid() }
            let url = folder.appendingPathComponent(name)
            try LibraryBackup.requireRegularFile(url)
            guard let one = CGPDFDocument(url as CFURL), one.numberOfPages == 1 else { throw invalid() }
        }
    }
    private static func allowed(_ name: String, documentID: UUID) -> Bool {
        ["\(documentID).pdf", "\(documentID).drawing", "\(documentID).ocr.json"].contains(name)
            || LibraryBackup.isAllowedAuxiliaryPath(name, documentID: documentID)
    }
    private static func remap(_ name: String, from old: UUID, to new: UUID) -> String {
        new.uuidString + name.dropFirst(old.uuidString.count)
    }
    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw invalid() }
    }
    private static func invalid() -> NSError {
        NSError(domain: "PaperdeskBackup", code: 2, userInfo: [NSLocalizedDescriptionKey: "This folder backup is incomplete, incompatible, or contains an unsafe path. Existing library documents have been kept."])
    }
    private static func changed() -> NSError {
        NSError(domain: "PaperdeskBackup", code: 3, userInfo: [NSLocalizedDescriptionKey: "A document changed while its backup was being copied. Save your edits, then export the backup again."])
    }
}
