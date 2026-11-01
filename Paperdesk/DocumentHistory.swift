import Foundation
import PDFKit
import Darwin

struct DocumentHistoryVersion: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    let document: LibraryDocument
    let reason: String
    let bytes: Int64
    let sourceFingerprint: String
    var metadataOnly: Bool? = nil
    var includesPDF: Bool { metadataOnly != true }
}

struct RemovedDocumentSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let document: LibraryDocument
    let directory: URL
    let pdfURL: URL
    let createdAt: Date
    let notesOnlyRecovery: Bool
}

enum DocumentHistoryError: LocalizedError {
    case changed, tooLarge, invalid, unavailable
    var errorDescription: String? {
        switch self {
        case .changed: "The document changed while its history copy was being made. Try again."
        case .tooLarge: "This document and its sidecars exceed the 100 MB history limit. Export a backup before editing it."
        case .invalid: "This recovery copy is incomplete or could not be verified. The saved copy has been kept."
        case .unavailable: "The document is no longer available in this library."
        }
    }
}

/// History is local, separate from exports, and serialized across app windows.
actor DocumentHistoryService {
    static let shared = DocumentHistoryService()
    static let maximumVersions = 10
    static let maximumBytes: Int64 = 100 * 1024 * 1024
    static let checkpointInterval: TimeInterval = 5 * 60
    private var lastCapture: [String: DocumentHistoryVersion] = [:]

    @discardableResult func capture(document: LibraryDocument, library: URL, reason: String,
                                   expectedFingerprint: String? = nil, force: Bool = false) throws -> DocumentHistoryVersion {
        let files = FileManager.default
        let key = library.path + document.id.uuidString
        if !force, let last = lastCapture[key], Date().timeIntervalSince(last.createdAt) < Self.checkpointInterval,
           files.fileExists(atPath: versionDirectory(last, library: library).path) { return last }
        guard document.filename == URL(fileURLWithPath: document.filename).lastPathComponent else { throw DocumentHistoryError.invalid }
        let source = library.appendingPathComponent(document.filename)
        let before = try LibraryBackup.fingerprint(source)
        let sourceStampBefore = try PDFPageJournal.stamp(source)
        if let expectedFingerprint, before != expectedFingerprint { throw DocumentHistoryError.changed }
        let existing = try versions(documentID: document.id, library: library)
        if !force, let latest = existing.first,
           Date().timeIntervalSince(latest.createdAt) < Self.checkpointInterval {
            lastCapture[key] = latest
            return latest
        }
        let sidecars = ["\(document.id).drawing", "\(document.id).ocr.json", "\(document.id).workspace.json", "\(document.id).inkpages", "\(document.id).handwriting.json", "\(document.id).pageindex.sqlite"]
        let names = [document.filename] + sidecars.filter { files.fileExists(atPath: library.appendingPathComponent($0).path) }
        let bytes = try names.reduce(Int64(0)) { total, name in total + (try Self.diskBytes(library.appendingPathComponent(name))) }
        let journalIndex = library.appendingPathComponent("\(document.id).inkpages/index.json")
        let journalBefore = try? Data(contentsOf: journalIndex)
        let parent = library.appendingPathComponent("History/\(document.id)", isDirectory: true)
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let id = UUID()
        let staging = parent.appendingPathComponent(".pending-\(id)", isDirectory: true)
        let final = parent.appendingPathComponent(id.uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try Self.copyPreservingOriginal(source, to: staging.appendingPathComponent("document.pdf"))
            for name in sidecars where files.fileExists(atPath: library.appendingPathComponent(name).path) {
                let sourceSidecar = library.appendingPathComponent(name)
                let targetSidecar = staging.appendingPathComponent(name)
                if name.hasSuffix(".pageindex.sqlite") { try PageTextDatabase.snapshot(from: sourceSidecar, to: targetSidecar) }
                else { try Self.copyPreservingOriginal(sourceSidecar, to: targetSidecar) }
            }
            guard before == (try LibraryBackup.fingerprint(source)), sourceStampBefore == (try PDFPageJournal.stamp(source)), journalBefore == (try? Data(contentsOf: journalIndex)) else { throw DocumentHistoryError.changed }
            let copiedPDF = staging.appendingPathComponent("document.pdf")
            let copiedOCR = staging.appendingPathComponent("\(document.id).ocr.json")
            if files.fileExists(atPath: copiedOCR.path) {
                let data = try Data(contentsOf: copiedOCR, options: .mappedIfSafe)
                try LibraryBackup.rebasedOCR(data, sourceFingerprint: before, pdfURL: copiedPDF).write(to: copiedOCR, options: .atomic)
            }
            try Self.rebaseDatabase(staging.appendingPathComponent("\(document.id).pageindex.sqlite"), previous: before, pdf: copiedPDF)
            try Self.rebaseHandwriting(staging.appendingPathComponent("\(document.id).handwriting.json"), oldStamp: sourceStampBefore, newStamp: PDFPageJournal.stamp(copiedPDF))
            let version = DocumentHistoryVersion(id: id, createdAt: Date(), document: document, reason: reason,
                                                 bytes: bytes, sourceFingerprint: try LibraryBackup.fingerprint(copiedPDF), metadataOnly: false)
            try JSONEncoder().encode(version).write(to: staging.appendingPathComponent("version.json"), options: .atomic)
            try files.moveItem(at: staging, to: final)
            lastCapture[key] = version
            // Prune only superseded history snapshots. Removed recovery archives are never pruned here.
            var retained = [version] + existing
            var total = retained.reduce(Int64(0)) { $0 + $1.bytes }
            while retained.count > Self.maximumVersions || total > Self.maximumBytes {
                guard retained.count > 1, let oldest = retained.last else { break }
                try files.removeItem(at: versionDirectory(oldest, library: library))
                retained.removeLast(); total -= oldest.bytes
            }
            return version
        } catch {
            try? files.removeItem(at: staging)
            throw error
        }
    }

    func versions(documentID: UUID, library: URL) throws -> [DocumentHistoryVersion] {
        let folder = library.appendingPathComponent("History/\(documentID)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).compactMap { child in
            guard let data = try? Data(contentsOf: child.appendingPathComponent("version.json")),
                  let item = try? JSONDecoder().decode(DocumentHistoryVersion.self, from: data),
                  item.document.id == documentID, child.lastPathComponent == item.id.uuidString,
                  (item.metadataOnly == true || FileManager.default.fileExists(atPath: child.appendingPathComponent("document.pdf").path)) else { return nil }
            return item
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func removedDocuments(library: URL) throws -> [RemovedDocumentSnapshot] {
        let root = library.appendingPathComponent("Removed", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let top = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var metadata = top.filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        for child in top where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            metadata += (try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }) ?? []
        }
        return metadata.compactMap { url in
            guard let data = try? Data(contentsOf: url), let document = try? JSONDecoder().decode(LibraryDocument.self, from: data),
                  url.lastPathComponent == "\(document.id).json",
                  document.filename == URL(fileURLWithPath: document.filename).lastPathComponent else { return nil }
            let parent = url.deletingLastPathComponent()
            let archived = parent.appendingPathComponent(document.filename)
            let hasPDF = FileManager.default.fileExists(atPath: archived.path)
            let pdf = hasPDF ? archived : library.appendingPathComponent(document.filename)
            guard FileManager.default.fileExists(atPath: pdf.path) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? document.importedAt
            return RemovedDocumentSnapshot(id: url.path, document: document, directory: parent, pdfURL: pdf, createdAt: date, notesOnlyRecovery: !hasPDF)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    struct Installation: Sendable {
        let document: LibraryDocument
        let written: [URL]
    }
    func install(version: DocumentHistoryVersion, library: URL) throws -> Installation {
        let folder = versionDirectory(version, library: library)
        let stored = try JSONDecoder().decode(DocumentHistoryVersion.self, from: Data(contentsOf: folder.appendingPathComponent("version.json")))
        guard stored == version else { throw DocumentHistoryError.changed }
        let pdf = stored.includesPDF ? folder.appendingPathComponent("document.pdf") : library.appendingPathComponent(stored.document.filename)
        return try install(document: stored.document, source: pdf, sidecars: stored.includesPDF ? folder : nil,
                           library: library, label: stored.includesPDF ? "Restored" : "Earlier notes")
    }
    func install(removed: RemovedDocumentSnapshot, library: URL) throws -> Installation {
        guard let current = try removedDocuments(library: library).first(where: { $0.id == removed.id }), current == removed else { throw DocumentHistoryError.changed }
        return try install(document: current.document, source: current.pdfURL, sidecars: current.directory,
                           library: library, label: "Recovered")
    }
    func rollback(_ installation: Installation) {
        for url in installation.written { try? FileManager.default.removeItem(at: url) }
    }
    private func install(document: LibraryDocument, source: URL, sidecars: URL?, library: URL, label: String) throws -> Installation {
        let files = FileManager.default
        guard let pdf = PDFDocument(url: source), !pdf.isLocked, pdf.pageCount > 0 else { throw DocumentHistoryError.invalid }
        let before = try LibraryBackup.fingerprint(source)
        let sourceStampBefore = try PDFPageJournal.stamp(source)
        let id = UUID()
        let result = LibraryDocument(id: id, title: document.title + " (\(label))", filename: "\(id).pdf", importedAt: Date(),
                                     notes: document.notes, lastPage: max(0, min(document.lastPage, pdf.pageCount - 1)), folder: document.folder)
        var written: [URL] = []
        do {
            let destination = library.appendingPathComponent(result.filename)
            guard !files.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
            try Self.copyPreservingOriginal(source, to: destination); written.append(destination)
            if let sidecars {
                for suffix in ["drawing", "ocr.json", "workspace.json", "inkpages", "handwriting.json", "pageindex.sqlite"] {
                    let archived = sidecars.appendingPathComponent("\(document.id).\(suffix)")
                    guard files.fileExists(atPath: archived.path) else { continue }
                    let target = library.appendingPathComponent("\(id).\(suffix)")
                    guard !files.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
                    if suffix == "ocr.json" {
                        let data = try Data(contentsOf: archived, options: .mappedIfSafe)
                        let rebased = try LibraryBackup.rebasedOCR(data, sourceFingerprint: before, pdfURL: destination)
                        try rebased.write(to: target, options: .atomic)
                    } else if suffix == "pageindex.sqlite" {
                        try PageTextDatabase.snapshot(from: archived, to: target)
                    } else if suffix == "workspace.json" {
                        let data = try Data(contentsOf: archived, options: .mappedIfSafe)
                        try LibraryBackup.rebasedWorkspace(data, documentID: id).write(to: target, options: .atomic)
                    } else { try Self.copyPreservingOriginal(archived, to: target) }
                    written.append(target)
                }
            }
            try LibraryBackup.rebaseTextDatabase(pdfURL: destination, previousFingerprint: before)
            try Self.rebaseHandwriting(library.appendingPathComponent("\(id).handwriting.json"), oldStamp: sourceStampBefore, newStamp: PDFPageJournal.stamp(destination))
            guard before == (try LibraryBackup.fingerprint(source)), sourceStampBefore == (try PDFPageJournal.stamp(source)) else { throw DocumentHistoryError.changed }
            return Installation(document: result, written: written)
        } catch {
            for url in written { try? files.removeItem(at: url) }
            throw error
        }
    }
    private static func rebaseDatabase(_ database: URL, previous: String, pdf: URL) throws {
        guard FileManager.default.fileExists(atPath: database.path), let source = CGPDFDocument(pdf as CFURL) else { return }
        try PageTextDatabase(url: database).rebase(from: previous, to: LibraryBackup.fingerprint(pdf), pageCount: source.numberOfPages)
    }
    private static func rebaseHandwriting(_ file: URL, oldStamp: String, newStamp: String) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        // A malformed optional cache does not make the underlying recoverable PDF unusable.
        guard var records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for index in records.indices {
            guard let revision = records[index]["revision"] as? String else { continue }
            if revision == oldStamp { records[index]["revision"] = newStamp }
            else if revision.hasPrefix(oldStamp + ":") { records[index]["revision"] = newStamp + revision.dropFirst(oldStamp.count) }
        }
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(to: file, options: .atomic)
    }
    /// APFS clones share unchanged blocks; edits remain independent. Other filesystems use a background copy.
    private static func copyPreservingOriginal(_ source: URL, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        if clonefile(source.path, destination.path, 0) == 0 { return }
        // A failed filesystem operation must not leave an unregistered partial restore.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    private static func diskBytes(_ url: URL) throws -> Int64 {
        let files = FileManager.default
        let attrs = try files.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { return (attrs[.size] as? NSNumber)?.int64Value ?? 0 }
        guard let items = files.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in items {
            let values = try child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }
    private func versionDirectory(_ version: DocumentHistoryVersion, library: URL) -> URL {
        library.appendingPathComponent("History/\(version.document.id)/\(version.id)", isDirectory: true)
    }
}
