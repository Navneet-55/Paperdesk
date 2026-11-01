import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var exportFile: BackupExportItem?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress = 0.0
    @State private var exporting = false
    @State private var importing = false
    @State private var status: String?
    @State private var failure: String?
    @State private var busy = false
    @State private var folderExport = false
    @State private var folderImport = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Library", systemImage: "externaldrive")
                        .font(.headline)
                    Text("\(store.documents.count) documents · PDFs, notes and collections")
                        .foregroundStyle(.secondary)
                }
                Section("Folder backup") {
                    Text("Copies PDFs, workspace cards, bookmarks, notes, ink and text indexes one file at a time. Recommended for large libraries.")
                    Button("Export to folder", systemImage: "folder.badge.plus") { folderExport = true }
                        .disabled(busy || store.documents.isEmpty)
                    Button("Import backup folder", systemImage: "folder") { folderImport = true }.disabled(busy)
                }
                Section("Portable backup") {
                    Text(
                        "A backup includes your PDFs, document notes, collections, reading positions, and saved drawing notes. Save it to Files, iCloud Drive, or another location you choose."
                    )
                    Button("Export library backup", systemImage: "square.and.arrow.up") { exportBackup() }
                        .disabled(store.documents.isEmpty || busy)
                }
                Section("Restore or transfer") {
                    Text(
                        "Importing adds documents whose IDs are not already in this library. Existing documents are kept unchanged. To transfer newer edits to an existing document, export its PDF and notes separately."
                    )
                    Button("Import library backup", systemImage: "square.and.arrow.down") { importing = true }
                        .disabled(busy)
                }
                if busy {
                    ProgressView("Working on library backup…", value: exportProgress)
                    if exportTask != nil { Button("Stop export") { exportTask?.cancel() } }
                }
                if let status { Section { Text(status).foregroundStyle(.secondary) } }
            }
            .formStyle(.grouped)
            .paperdeskActions()
            .navigationTitle("Library backup")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) }
            }
            #if os(macOS)
                .frame(minWidth: 480, minHeight: 380)
            #endif
        }
        .fileExporter(
            isPresented: $exporting, item: exportFile, contentTypes: [.json],
            defaultFilename: "Paperdesk Backup"
        ) { result in
            exportFile = nil
            switch result {
            case .success: status = "Backup exported."
            case .failure(let error): failure = error.localizedDescription
            }
        } onCancellation: {
            exportFile = nil
        }
        .fileImporter(isPresented: $folderExport, allowedContentTypes: [.folder]) { folderBackup($0, exporting: true) }
        .fileImporter(isPresented: $folderImport, allowedContentTypes: [.folder, .package]) { folderBackup($0, exporting: false) }
        .onDisappear { exportTask?.cancel() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            Task { @MainActor in
                busy = true
                defer { busy = false }
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let data = try await Task.detached(priority: .userInitiated) {
                        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 256 * 1024 * 1024 else {
                            throw NSError(domain: "Paperdesk", code: 1, userInfo: [NSLocalizedDescriptionKey: "This JSON backup exceeds 256 MB. Use a folder backup for large libraries."])
                        }
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: 256 * 1024 * 1024 + 1) ?? Data()
                        guard data.count <= 256 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                        return data
                    }
                        .value
                    let count = try await store.restoreBackupData(data)
                    status = "Imported \(count) documents. Existing documents were kept."
                } catch { failure = error.localizedDescription }
            }
        }
        .alert(
            "Backup could not be completed",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    private func folderBackup(_ result: Result<URL, Error>, exporting: Bool) {
        exportTask = Task {
            busy = true
            exportProgress = 0
            defer { busy = false; exportTask = nil }
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                store.flushPendingChanges()
                if exporting {
                    let destination = try await FolderBackupService().export(documents: store.documents, directory: store.directory, parent: url) { value in
                        await MainActor.run { exportProgress = value }
                    }
                    status = "Exported " + destination.lastPathComponent
                } else {
                    let count = try await store.restoreFolderBackup(url)
                    status = "Imported " + String(count) + " documents as separate copies."
                }
            } catch is CancellationError { status = "Backup stopped." }
            catch { failure = error.localizedDescription }
        }
    }

    private func exportBackup() {
        exportTask = Task { @MainActor in
            busy = true
            exportProgress = 0
            defer {
                busy = false
                exportTask = nil
            }
            store.flushPendingChanges()
            let documents = store.documents
            let directory = store.directory
            do {
                let file = try await LocalExportService().backup(documents: documents, directory: directory) {
                    value in
                    await MainActor.run { exportProgress = value }
                }
                try Task.checkCancellation()
                exportFile = BackupExportItem(file: file)
                exporting = true
            } catch is CancellationError { status = "Backup export stopped." } catch {
                failure = error.localizedDescription
            }
        }
    }
}
