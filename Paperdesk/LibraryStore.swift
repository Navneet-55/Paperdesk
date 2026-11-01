import Foundation
import Observation
import PDFKit

struct LibraryDocument: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    let filename: String
    let importedAt: Date
    var notes: String = ""
    var lastPage: Int = 0
    var folder: String? = nil
}

@MainActor @Observable final class LibraryStore {
    private(set) var documents: [LibraryDocument] = []
    let directory: URL
    var error: String?
    private var loadFailed = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private let writer = LibraryMetadataWriter()
    private var saveRevision = 0
    private var restoringBackup = false
    @ObservationIgnored private var noteHistoryDates: [UUID: Date] = [:]
    private(set) var isLoading = true
    private(set) var saveStatus = "Saved"
    private var hasLoaded = false
    @ObservationIgnored private var loadTask: Task<[LibraryDocument], Error>?
    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Paperdesk", isDirectory: true)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        isLoading = true
        if loadTask == nil {
            let directory = directory
            loadTask = Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let index = directory.appendingPathComponent("library.json")
                guard FileManager.default.fileExists(atPath: index.path) else { return [] }
                return try JSONDecoder().decode([LibraryDocument].self, from: Data(contentsOf: index))
            }
        }
        do {
            guard let loadTask else { return }
            let loaded = try await loadTask.value
            // Multiple windows may await the same read. Never overwrite later user edits.
            guard !hasLoaded else { return }
            documents = loaded
            loadFailed = false
        } catch {
            loadFailed = true
            self.error = "Could not load the library: \(error.localizedDescription)"
        }
        hasLoaded = true
        isLoading = false
        loadTask = nil
    }

    func retryLoading() async {
        guard loadFailed else { return }
        hasLoaded = false
        await loadIfNeeded()
    }
    func url(for document: LibraryDocument) -> URL { directory.appendingPathComponent(document.filename) }
    @discardableResult func importPDF(_ source: URL) throws -> UUID {
        guard hasLoaded, !loadFailed else {
            throw NSError(
                domain: "Paperdesk", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The library index could not be read. Restore library.json before importing more documents."
                ])
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard let pdf = PDFDocument(url: source), pdf.pageCount > 0, !pdf.isLocked else {
            throw NSError(
                domain: "Paperdesk", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Choose a readable, unlocked PDF with at least one page."
                ])
        }
        let id = UUID()
        let item = LibraryDocument(
            id: id, title: source.deletingPathExtension().lastPathComponent, filename: "\(id).pdf",
            importedAt: Date())
        try FileManager.default.copyItem(at: source, to: url(for: item))
        documents.insert(item, at: 0)
        do { try persist() } catch {
            documents.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: url(for: item))
            throw error
        }
        return id
    }
    @discardableResult func importPDFAsync(_ source: URL) async throws -> UUID {
        guard hasLoaded, !loadFailed else {
            throw NSError(
                domain: "Paperdesk", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The library index could not be read. Restore library.json before importing more documents."
                ])
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let item = LibraryDocument(
            id: id, title: source.deletingPathExtension().lastPathComponent, filename: "\(id).pdf",
            importedAt: Date())
        let destination = url(for: item)
        try await Task.detached(priority: .userInitiated) {
            guard let pdf = PDFDocument(url: source), pdf.pageCount > 0, !pdf.isLocked else {
                throw NSError(
                    domain: "Paperdesk", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Choose a readable, unlocked PDF with at least one page."
                    ])
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
        do {
            try Task.checkCancellation()
            documents.insert(item, at: 0)
            try persist()
        } catch {
            documents.removeAll { $0.id == id }
            await Task.detached { try? FileManager.default.removeItem(at: destination) }.value
            throw error
        }
        return id
    }
    func update(_ id: UUID, notes: String? = nil, page: Int? = nil, deferred: Bool = false) {
        if let notes, let prior = documents.first(where: { $0.id == id }), prior.notes != notes { captureNotesCheckpoint(prior) }
        mutate(id, deferred: deferred) { item in
            if let notes { item.notes = notes }
            if let page { item.lastPage = max(0, page) }
        }
    }

    func appendStudyNote(_ id: UUID, text: String) throws {
        guard hasLoaded, !loadFailed, let index = documents.firstIndex(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let previous = documents[index].notes
        captureNotesCheckpoint(documents[index])
        documents[index].notes += text
        do { try persist() } catch {
            documents[index].notes = previous
            throw error
        }
    }

    private func captureNotesCheckpoint(_ prior: LibraryDocument) {
        guard hasLoaded, !loadFailed else { return }
        if let date = noteHistoryDates[prior.id], Date().timeIntervalSince(date) < DocumentHistoryService.checkpointInterval { return }
        noteHistoryDates[prior.id] = Date()
        let library = directory
        Task {
            do { _ = try await DocumentHistoryService.shared.capture(document: prior, library: library, reason: "Before notes changed") }
            catch { self.error = "Notes were kept, but a history checkpoint could not be made: \(error.localizedDescription)" }
        }
    }
    @discardableResult func restoreHistoryVersion(_ version: DocumentHistoryVersion) async throws -> UUID {
        guard hasLoaded, !loadFailed else { throw DocumentHistoryError.unavailable }
        let installation = try await DocumentHistoryService.shared.install(version: version, library: directory)
        return try await commitRecovery(installation)
    }
    @discardableResult func recoverRemovedDocument(_ snapshot: RemovedDocumentSnapshot) async throws -> UUID {
        guard hasLoaded, !loadFailed else { throw DocumentHistoryError.unavailable }
        let installation = try await DocumentHistoryService.shared.install(removed: snapshot, library: directory)
        return try await commitRecovery(installation)
    }
    private func commitRecovery(_ installation: DocumentHistoryService.Installation) async throws -> UUID {
        let item = installation.document
        do { try await PDFPageJournal.shared.rebase(url: url(for: item)) }
        catch { await DocumentHistoryService.shared.rollback(installation); throw error }
        guard !documents.contains(where: { $0.id == item.id }) else {
            await DocumentHistoryService.shared.rollback(installation)
            throw CocoaError(.fileWriteFileExists)
        }
        documents.insert(item, at: 0)
        do { try persist() }
        catch {
            documents.removeAll { $0.id == item.id }
            await DocumentHistoryService.shared.rollback(installation)
            throw error
        }
        return item.id
    }
    func rename(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        mutate(id) { $0.title = title }
    }
    func move(_ id: UUID, folder: String?) {
        let cleaned = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(id) { $0.folder = cleaned?.isEmpty == false ? cleaned : nil }
    }
    private func mutate(_ id: UUID, deferred: Bool = false, change: (inout LibraryDocument) -> Void) {
        guard hasLoaded, !loadFailed, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let previous = documents[index]
        change(&documents[index])
        if deferred {
            scheduleSave()
            return
        }
        do { try persist() } catch {
            documents[index] = previous
            self.error = "Could not save changes: \(error.localizedDescription)"
        }
    }
    func remove(_ id: UUID) throws {
        guard hasLoaded, !loadFailed, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        let item = documents[index]
        let files = FileManager.default
        let removed = directory.appendingPathComponent("Removed", isDirectory: true)
        let names = [item.filename, "\(id).drawing", "\(id).ocr.json", "\(id).workspace.json", "\(id).inkpages", "\(id).handwriting.json"]
        let metadataName = "\(id).json"
        var archive = removed
        var snapshot: URL?
        var moved: [(source: URL, archived: URL)] = []
        var membershipRemoved = false
        do {
            try files.createDirectory(at: removed, withIntermediateDirectories: true)
            // Preserve earlier recovery copies, including documents restored from a backup.
            if (names + [metadataName]).contains(where: {
                files.fileExists(atPath: removed.appendingPathComponent($0).path)
            }) {
                archive = removed.appendingPathComponent("\(id)-\(UUID().uuidString)", isDirectory: true)
                try files.createDirectory(at: archive, withIntermediateDirectories: true)
            }
            // SQLite readers may still own a connection. Archive a transactionally consistent
            // copy and leave the live database at its original path until those readers close.
            let database = DocumentTextService.databaseURL(for: url(for: item))
            if files.fileExists(atPath: database.path) {
                try PageTextDatabase.snapshot(from: database, to: archive.appendingPathComponent(database.lastPathComponent))
            }
            let metadata = archive.appendingPathComponent(metadataName)
            // Capture current (possibly debounced) notes before moving any library files.
            try JSONEncoder().encode(item).write(to: metadata, options: .atomic)
            snapshot = metadata
            for name in names {
                let source = directory.appendingPathComponent(name)
                if files.fileExists(atPath: source.path) {
                    let destination = archive.appendingPathComponent(name)
                    try files.moveItem(at: source, to: destination)
                    moved.append((source, destination))
                }
            }
            // Same-volume moves above do not read/copy large PDFs. Commit membership last.
            documents.remove(at: index)
            membershipRemoved = true
            try persist()
        } catch {
            let removalError = error
            if membershipRemoved { documents.insert(item, at: index) }
            var recoveryErrors: [String] = []
            for pair in moved.reversed() {
                do { try files.moveItem(at: pair.archived, to: pair.source) } catch {
                    recoveryErrors.append(error.localizedDescription)
                }
            }
            // Keep the snapshot even after successful rollback: if the index commit
            // failed it may be the only saved copy of the latest deferred notes.
            var message =
                "Could not remove this document. It remains in your library. \(removalError.localizedDescription)"
            if !recoveryErrors.isEmpty {
                message +=
                    " Some files could not be restored; their recovery copies remain in \(archive.path). \(recoveryErrors.joined(separator: "; "))"
            }
            if let snapshot {
                message += " A recovery copy of the latest notes is saved at \(snapshot.path)."
            }
            self.error = message
            throw NSError(
                domain: "Paperdesk", code: 3,
                userInfo: [NSLocalizedDescriptionKey: message, NSUnderlyingErrorKey: removalError])
        }
    }
    /// Flush before switching libraries or ending a scene. Also orders all earlier queued writes.
    func flushPendingChanges() {
        guard hasLoaded, !loadFailed else { return }
        do { try persist() } catch { self.error = "Could not save changes: \(error.localizedDescription)" }
    }
    private func scheduleSave() {
        saveStatus = "Saving…"
        pendingSave?.cancel()
        saveRevision += 1
        let revision = saveRevision
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            let snapshot = self.documents
            let destination = self.directory.appendingPathComponent("library.json")
            do {
                try await self.writer.write(snapshot, to: destination)
                if self.saveRevision == revision { self.saveStatus = "Saved" }
            } catch {
                if self.saveRevision == revision {
                    self.saveStatus = "Not saved"
                    self.error = "Could not save changes: \(error.localizedDescription)"
                }
            }
        }
    }
    private func persist() throws {
        pendingSave?.cancel()
        pendingSave = nil
        saveRevision += 1
        do {
            try writer.writeSynchronously(documents, to: directory.appendingPathComponent("library.json"))
            saveStatus = "Saved"
        } catch {
            saveStatus = "Not saved"
            throw error
        }
    }

    /// Folder payloads are copied/verified off the UI thread, with no whole-PDF buffers.
    /// Each restored document receives a new identity; existing edits stay untouched.
    func restoreFolderBackup(_ source: URL) async throws -> Int {
        guard hasLoaded, !loadFailed, !restoringBackup else { throw CocoaError(.fileReadCorruptFile) }
        restoringBackup = true
        defer { restoringBackup = false }
        let service = FolderBackupService()
        let installation = try await service.install(source: source, library: directory)
        do {
            try Task.checkCancellation()
            documents += installation.documents
            try persist()
            return installation.documents.count
        } catch {
            let added = Set(installation.documents.map(\.id))
            documents.removeAll { added.contains($0.id) }
            await service.rollback(installation)
            throw error
        }
    }

    /// Archive parsing, PDF validation, and bulk file I/O do not run on the UI thread.
    func restoreBackupData(_ data: Data) async throws -> Int {
        guard hasLoaded, !loadFailed, !restoringBackup else { throw CocoaError(.fileReadCorruptFile) }
        restoringBackup = true
        defer { restoringBackup = false }
        let archive = try await Task.detached(priority: .userInitiated) {
            guard data.count <= LibraryBackup.maximumJSONRestoreBytes else {
                throw NSError(domain: "PaperdeskBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a folder backup for a library this large. JSON restore keeps the decoded archive in memory."])
            }
            let archive = try JSONDecoder().decode(LibraryBackup.self, from: data)
            guard archive.version == 1, archive.entries.count <= 100_000 else { throw CocoaError(.fileReadCorruptFile) }
            for entry in archive.entries {
                guard let pdf = PDFDocument(data: entry.pdf), !pdf.isLocked, pdf.pageCount > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            return archive
        }.value
        var seen = Set(documents.map(\.id))
        let additions = archive.entries.filter { seen.insert($0.document.id).inserted }
        let directory = self.directory
        let written = try await Task.detached(priority: .userInitiated) {
            var written: [URL] = []
            do {
                for entry in additions {
                    let id = entry.document.id
                    let contents: [(String, Data?)] = [
                        ("\(id).pdf", entry.pdf), ("\(id).drawing", entry.drawing),
                        ("\(id).ocr.json", entry.ocr),
                    ]
                    for (name, data) in contents {
                        guard let data else { continue }
                        let url = directory.appendingPathComponent(name)
                        guard !FileManager.default.fileExists(atPath: url.path) else {
                            throw CocoaError(.fileWriteFileExists)
                        }
                        let contents =
                            name.hasSuffix(".ocr.json")
                            ? try LibraryBackup.rebasedOCR(
                                data, sourceFingerprint: entry.sourceFingerprint,
                                pdfURL: directory.appendingPathComponent("\(id).pdf")) : data
                        try contents.write(to: url, options: .atomic)
                        written.append(url)
                    }
                    let pdfURL = directory.appendingPathComponent("\(id).pdf")
                    written += try LibraryBackup.installAuxiliaries(entry.auxiliaryFiles ?? [], document: entry.document, pdfURL: pdfURL, directory: directory)
                    try await PDFPageJournal.shared.rebase(url: pdfURL)
                    try LibraryBackup.rebaseTextDatabase(pdfURL: pdfURL, previousFingerprint: entry.sourceFingerprint)
                }
                return written
            } catch {
                for url in written { try? FileManager.default.removeItem(at: url) }
                throw error
            }
        }.value
        documents += additions.map { entry in
            let d = entry.document
            return LibraryDocument(
                id: d.id, title: d.title, filename: "\(d.id).pdf", importedAt: d.importedAt, notes: d.notes,
                lastPage: d.lastPage, folder: d.folder)
        }
        // Enqueue immediately on the main actor so subsequent saves cannot pass this snapshot.
        pendingSave?.cancel()
        saveRevision += 1
        do {
            try persist()
        } catch {
            // Keep edits to existing documents made while disk I/O was in flight.
            let newIDs = Set(additions.map { $0.document.id })
            documents.removeAll { newIDs.contains($0.id) }
            await Task.detached { for url in written { try? FileManager.default.removeItem(at: url) } }.value
            throw error
        }
        return additions.count
    }
}

/// All writes share one FIFO; synchronous commits wait behind any already queued snapshot.
private final class LibraryMetadataWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.paperdesk.library-metadata", qos: .utility)
    func writeSynchronously(_ documents: [LibraryDocument], to url: URL) throws {
        try queue.sync { try JSONEncoder().encode(documents).write(to: url, options: .atomic) }
    }
    @MainActor func write(_ documents: [LibraryDocument], to url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try JSONEncoder().encode(documents).write(to: url, options: .atomic)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct LibraryBackup: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let document: LibraryDocument
        let pdf: Data
        let drawing: Data?
        var ocr: Data? = nil
        var sourceFingerprint: String? = nil
        var auxiliaryFiles: [AuxiliaryFile]? = nil
    }
    struct AuxiliaryFile: Codable, Sendable {
        let relativePath: String
        let data: Data
    }
    struct AuxiliarySource: Sendable {
        let relativePath: String
        let url: URL
    }
    static let maximumJSONRestoreBytes = 256 * 1024 * 1024

    static func validateJSONRestoreSize(_ url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumJSONRestoreBytes else {
            throw NSError(domain: "PaperdeskBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "This JSON backup is too large to restore safely in memory. Use a folder backup for large libraries; it restores one file at a time."])
        }
    }
    static func isAllowedAuxiliaryPath(_ path: String, documentID: UUID) -> Bool {
        let id = documentID.uuidString
        if path == "\(id).workspace.json" || path == "\(id).pageindex.sqlite" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "\(id).inkpages" else { return false }
        if parts[1] == "index.json" { return true }
        return validJournalPageName(String(parts[1])) != nil
    }
    static func validJournalPageName(_ name: String) -> Int? {
        guard name.hasSuffix(".pdf") else { return nil }
        let stem = String(name.dropLast(4))
        let pieces = stem.split(separator: "-", maxSplits: 1)
        guard pieces.count == 2, let page = Int(pieces[0]), page >= 0, page < Int.max,
              String(page) == pieces[0], UUID(uuidString: String(pieces[1])) != nil else { return nil }
        return page
    }
    static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
    }
    static func auxiliarySources(document: LibraryDocument, directory: URL) throws -> [AuxiliarySource] {
        let files = FileManager.default
        let id = document.id
        var result: [AuxiliarySource] = []
        for suffix in ["workspace.json", "pageindex.sqlite"] {
            let name = "\(id).\(suffix)", url = directory.appendingPathComponent("\(id).\(suffix)")
            guard files.fileExists(atPath: url.path) else { continue }
            try requireRegularFile(url)
            if suffix == "workspace.json" {
                let data = try Data(contentsOf: url)
                let workspace = try JSONDecoder().decode(DocumentWorkspace.self, from: data)
                guard workspace.version == 1, workspace.documentID == id else { throw CocoaError(.fileReadCorruptFile) }
            }
            result.append(AuxiliarySource(relativePath: name, url: url))
        }
        let journal = directory.appendingPathComponent("\(id).inkpages", isDirectory: true)
        if files.fileExists(atPath: journal.path) {
            let values = try journal.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            let indexURL = journal.appendingPathComponent("index.json")
            try requireRegularFile(indexURL)
            let state = try JSONDecoder().decode(PDFJournalState.self, from: Data(contentsOf: indexURL))
            let pdfURL = directory.appendingPathComponent(document.filename)
            guard let pdf = CGPDFDocument(pdfURL as CFURL),
                  state.sourceVersion == (try PDFFileVersion.read(from: pdfURL)), state.sourceStamp == (try PDFPageJournal.stamp(pdfURL)),
                  Set(state.pages.values).count == state.pages.count else { throw CocoaError(.fileReadCorruptFile) }
            result.append(AuxiliarySource(relativePath: "\(id).inkpages/index.json", url: indexURL))
            for (page, name) in state.pages.sorted(by: { $0.key < $1.key }) {
                guard (0..<pdf.numberOfPages).contains(page), validJournalPageName(name) == page else { throw CocoaError(.fileReadCorruptFile) }
                let url = journal.appendingPathComponent(name)
                try requireRegularFile(url)
                result.append(AuxiliarySource(relativePath: "\(id).inkpages/\(name)", url: url))
            }
        }
        return result
    }
    static func auxiliaryData(document: LibraryDocument, directory: URL) throws -> [AuxiliaryFile] {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Paperdesk-aux-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try auxiliarySources(document: document, directory: directory).map { source in
            let url: URL
            if source.relativePath.hasSuffix(".pageindex.sqlite") {
                url = temporary.appendingPathComponent(source.url.lastPathComponent)
                try PageTextDatabase.snapshot(from: source.url, to: url)
            } else { url = source.url }
            return AuxiliaryFile(relativePath: source.relativePath, data: try Data(contentsOf: url))
        }
    }
    static func validateAuxiliaries(_ auxiliary: [AuxiliaryFile], document: LibraryDocument, pdfURL: URL) throws {
        guard Set(auxiliary.map(\.relativePath)).count == auxiliary.count,
              auxiliary.allSatisfy({ isAllowedAuxiliaryPath($0.relativePath, documentID: document.id) }),
              let pdf = CGPDFDocument(pdfURL as CFURL) else { throw CocoaError(.fileReadCorruptFile) }
        if let workspaceFile = auxiliary.first(where: { $0.relativePath.hasSuffix(".workspace.json") }) {
            let workspace = try JSONDecoder().decode(DocumentWorkspace.self, from: workspaceFile.data)
            guard workspace.version == 1, workspace.documentID == document.id else { throw CocoaError(.fileReadCorruptFile) }
        }
        let prefix = "\(document.id).inkpages/"
        let journalFiles = auxiliary.filter { $0.relativePath.hasPrefix(prefix) }
        if !journalFiles.isEmpty {
            guard let manifest = journalFiles.first(where: { $0.relativePath == prefix + "index.json" }) else { throw CocoaError(.fileReadCorruptFile) }
            let state = try JSONDecoder().decode(PDFJournalState.self, from: manifest.data)
            guard state.sourceVersion == (try PDFFileVersion.read(from: pdfURL)), Set(state.pages.values).count == state.pages.count,
                  Set(journalFiles.map(\.relativePath)) == Set([prefix + "index.json"] + state.pages.values.map { prefix + $0 }) else { throw CocoaError(.fileReadCorruptFile) }
            for (pageIndex, name) in state.pages {
                guard (0..<pdf.numberOfPages).contains(pageIndex), validJournalPageName(name) == pageIndex,
                      let pageFile = journalFiles.first(where: { $0.relativePath == prefix + name }),
                      let provider = CGDataProvider(data: pageFile.data as CFData),
                      let page = CGPDFDocument(provider), page.numberOfPages == 1 else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
    }
    static func installAuxiliaries(_ auxiliary: [AuxiliaryFile], document: LibraryDocument, pdfURL: URL, directory: URL) throws -> [URL] {
        try validateAuxiliaries(auxiliary, document: document, pdfURL: pdfURL)
        let files = FileManager.default
        var written: [URL] = []
        do {
            if auxiliary.contains(where: { $0.relativePath.hasPrefix("\(document.id).inkpages/") }) {
                let folder = directory.appendingPathComponent("\(document.id).inkpages", isDirectory: true)
                guard !files.fileExists(atPath: folder.path) else { throw CocoaError(.fileWriteFileExists) }
                try files.createDirectory(at: folder, withIntermediateDirectories: false)
                written.append(folder)
            }
            for file in auxiliary {
                let destination = directory.appendingPathComponent(file.relativePath)
                guard !files.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
                try file.data.write(to: destination, options: .atomic)
                if !file.relativePath.contains("/") { written.append(destination) }
            }
            return written
        } catch {
            for url in written.reversed() { try? files.removeItem(at: url) }
            throw error
        }
    }
    static func rebaseTextDatabase(pdfURL: URL, previousFingerprint: String?) throws {
        let database = pdfURL.deletingPathExtension().appendingPathExtension("pageindex.sqlite")
        guard let previousFingerprint, FileManager.default.fileExists(atPath: database.path), let pdf = CGPDFDocument(pdfURL as CFURL) else { return }
        let cache = try PageTextDatabase(url: database)
        try cache.rebase(from: previousFingerprint, to: fingerprint(pdfURL), pageCount: pdf.numberOfPages)
    }

    let version: Int
    let createdAt: Date
    let entries: [Entry]

    init(documents: [LibraryDocument], directory: URL) throws {
        version = 1
        createdAt = Date()
        entries = try documents.map { document in
            let pdfURL = directory.appendingPathComponent(document.filename)
            let before = try Self.fingerprint(pdfURL)
            let pdf = try Data(contentsOf: pdfURL)
            let drawingURL = directory.appendingPathComponent("\(document.id).drawing")
            let ocrURL = directory.appendingPathComponent("\(document.id).ocr.json")
            let drawing =
                FileManager.default.fileExists(atPath: drawingURL.path)
                ? try Data(contentsOf: drawingURL) : nil
            let ocr = FileManager.default.fileExists(atPath: ocrURL.path) ? try Data(contentsOf: ocrURL) : nil
            let auxiliary = try Self.auxiliaryData(document: document, directory: directory)
            guard before == (try Self.fingerprint(pdfURL)) else { throw CocoaError(.fileReadUnknown) }
            return Entry(document: document, pdf: pdf, drawing: drawing, ocr: ocr, sourceFingerprint: before, auxiliaryFiles: auxiliary)
        }
    }
    @MainActor init(store: LibraryStore) throws {
        try self.init(documents: store.documents, directory: store.directory)
    }
    /// Only rebase a cache proven to describe the PDF captured in this archive.
    /// Legacy backups lack that proof and keep their old fingerprint, which is safely ignored.
    static func rebasedOCR(_ data: Data, sourceFingerprint: String?, pdfURL: URL) throws -> Data {
        guard let sourceFingerprint,
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["fingerprint"] as? String == sourceFingerprint,
            json["version"] as? Int == 1,
            let pageCount = json["pageCount"] as? Int,
            let pdf = CGPDFDocument(pdfURL as CFURL), pdf.numberOfPages == pageCount
        else { return data }
        json["fingerprint"] = try fingerprint(pdfURL)
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }
    /// Recovery creates a new library identity while keeping the original source links.
    static func rebasedWorkspace(_ data: Data, documentID: UUID) throws -> Data {
        let source = try JSONDecoder().decode(DocumentWorkspace.self, from: data)
        guard source.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        var rebased = DocumentWorkspace(documentID: documentID)
        rebased.revision = source.revision
        rebased.bookmarks = source.bookmarks
        rebased.marginNotes = source.marginNotes
        rebased.cards = source.cards
        return try JSONEncoder().encode(rebased)
    }
    static func fingerprint(_ url: URL) throws -> String {
        guard let pdf = CGPDFDocument(url as CFURL) else { throw CocoaError(.fileReadCorruptFile) }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return
            "\(pdf.numberOfPages):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
}
