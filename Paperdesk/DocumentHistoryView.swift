import SwiftUI

struct DocumentHistoryView: View {
    let store: LibraryStore
    let documentID: UUID?
    var onRestored: ((UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [DocumentHistoryVersion] = []
    @State private var removed: [RemovedDocumentSnapshot] = []
    @State private var loading = true
    @State private var busy = false
    @State private var failure: String?
    @State private var status: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(documentID == nil ? "Recover removed documents" : "Earlier versions", systemImage: "clock.arrow.circlepath").font(.headline)
                    Text("Recovery creates a new library document. Your current document and the saved recovery copy stay unchanged.").font(.subheadline).foregroundStyle(.secondary)
                    if documentID != nil {
                        Text("Local checkpoints are made at most once every five minutes. Up to 10 checkpoints and a 100 MB target are retained per document, always keeping the newest full checkpoint even if it is larger. Older checkpoints may be removed after a new one succeeds. History is not included in library backup exports.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16)
                if loading { ProgressView("Reading local history…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if versions.isEmpty && removed.isEmpty {
                    ContentUnavailableView(documentID == nil ? "No recovery copies" : "No checkpoints yet", systemImage: "clock", description: Text(documentID == nil ? "Removed documents with a readable saved PDF will appear here." : "Edit notes or annotations to start a local history. Your current document is safe."))
                } else {
                    List {
                        ForEach(versions) { version in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                                Text(version.reason).foregroundStyle(.secondary)
                                Text(version.includesPDF ? "PDF and document notes" : "Earlier notes · current PDF required").font(.caption)
                                Button("Restore as new document") { restore(version) }.paperdeskActions().disabled(busy)
                            }.padding(.vertical, 8)
                        }
                        ForEach(removed) { snapshot in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(snapshot.document.title).font(.headline)
                                Text(snapshot.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                if snapshot.notesOnlyRecovery { Text("Saved notes with the current library PDF").font(.caption) }
                                Button("Recover as new document") { recover(snapshot) }.paperdeskActions().disabled(busy)
                            }.padding(.vertical, 8)
                        }
                    }.listStyle(.plain)
                }
                if busy { ProgressView("Restoring a separate copy…") }
                if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
            }
            .navigationTitle(documentID == nil ? "Recovery" : "Version history")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .task { await reload() }
            .alert("Recovery could not be completed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK") { failure = nil } } message: { Text(failure ?? "") }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 600, minHeight: 500)
        #endif
    }
    private func reload() async {
        do {
            if let documentID { versions = try await DocumentHistoryService.shared.versions(documentID: documentID, library: store.directory) }
            else { removed = try await DocumentHistoryService.shared.removedDocuments(library: store.directory) }
        } catch { failure = error.localizedDescription }
        loading = false
    }
    private func restore(_ version: DocumentHistoryVersion) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { let id = try await store.restoreHistoryVersion(version); status = "Restored as a separate document. The current document was kept."; onRestored?(id) }
            catch { failure = error.localizedDescription }
        }
    }
    private func recover(_ snapshot: RemovedDocumentSnapshot) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { let id = try await store.recoverRemovedDocument(snapshot); status = "Recovered as a separate document. The recovery copy was kept."; onRestored?(id) }
            catch { failure = error.localizedDescription }
        }
    }
}
